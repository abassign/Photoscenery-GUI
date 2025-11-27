###############################################################################
# GeoEngine.jl
#
# This module implements the core orchestration logic for processing geographic
# target areas into assembled orthophoto tiles.
#
# Given a latitude, longitude, radius and user-defined configuration, it:
#   1. Computes the list of tiles needed to cover the requested area.
#   2. Subdivides each tile into smaller chunks for download.
#   3. Downloads each chunk in parallel from a map server.
#   4. Monitors a temporary directory for complete sets of chunks per tile.
#   5. Assembles, compresses, and relocates the final DDS files.
#
# It serves as the central entry point for launching tile generation jobs
# via the GUI or other automation layers (e.g., API requests).
#
# Dependencies:
#   - Commons.jl      (coordinate models, configuration)
#   - Downloader.jl   (HTTP-based tile downloads)
#   - TileAssembler.jl (canvas stitching and DDS compression)
#   - AssemblyMonitor.jl (asynchronous tile monitoring and conversion)
#
# Typical entry point:
#   GeoEngine.process_target_area(area, cfg, map_server, root, save)
#
# Author: [abassign@gmail.com Adriano Bassignana], © [2025-07]
###############################################################################

module GeoEngine

using Printf: @sprintf
using Logging
using FilePathsBase
using Dates
using ..Commons, ..Downloader, ..TileProcessor, ..Route, ..Geodesics, ..StatusMonitor
using ..AssemblyMonitor
using ..ddsFindScanner, ..JobFactory
using ..AirportsNavaids
using .Commons: chunk_pixel_size

export prepare_paths_and_location, process_target_area, create_precoverage_jobs, create_chunk_jobs, process_fill_holes, recover_orphaned_tiles, search_airports, create_cascading_jobs

function generate_all_tiles(
    area::MapCoordinates,
    cfg::Dict,
    rootPath::String,
    rootPath_save::String;
    heading_deg::Union{Nothing,Float64}=nothing,   # ← passato dal chiamante in DAA
    alt_ft::Union{Nothing,Float64}=nothing         # ← passato dal chiamante (quota AGL)
    )
    # (tile, sorting_metric, radial_distance) for tie-break
    tiles_with_distance = Vector{Tuple{TileMetadata, Float64, Float64}}()

    lat_step      = 0.125
    base_size_id  = get(cfg, "size", 4)
    mode_is_daa   = get(cfg, "mode", "manual") == "daa"
    offset        = 0.0

    if mode_is_daa offset = 0.25 end  # ~1/4° slight bbox expansion for edge safety (does not alter circular filter)

    # 1) Base grid from radius (in degrees)
    # WARNING This algorithm to derive lat_min_grid lat_max_grid lon_min_grid lon_max_grid is essential that it is not varied depending
    # on the rounding method adopted, otherwise we will have misalignment in the tiles!
    radius_deg   = area.radius * (1 / 60)
    lat_min_grid = floor((area.lat - radius_deg - offset) / lat_step) * lat_step
    lat_max_grid = ceil((area.lat + radius_deg + offset) / lat_step) * lat_step
    lon_min_grid = floor(((area.lon - offset) - radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)
    lon_max_grid = ceil(((area.lon + offset) + radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)

    @info "GeoEngine: Generating tile grid (radial filter; anisotropic LOD in DAA)..."

    # 3) DAA ellipse parameters: width = area diameter => B = radius
    A = get(cfg, "daa_forward_nm", area.radius * 1.5)  # semi-axis along route
    B = area.radius                                    # semi-axis lateral (requested)
    θ = mode_is_daa && heading_deg !== nothing ? deg2rad(heading_deg) : 0.0

    for lat in lat_min_grid:lat_step:lat_max_grid
        current_lon_step = tileWidth(lat)
        for lon in lon_min_grid:current_lon_step:lon_max_grid
            latC = lat + lat_step / 2
            lonC = lon + current_lon_step / 2
            tile_id = index(latC, lonC)

            # --- INCLUSION: ONLY centered circle (coverage unchanged) ---
            radial_nm = Geodesics.surface_distance(
                lonC, latC, area.lon, area.lat, Geodesics.localEarthRadius(latC)
                ) / 1852.0
            radial_nm <= area.radius || continue

            # --- METRIC for priority/LOD ---
            metric_nm = radial_nm
            if mode_is_daa
                Δnorth_nm = (latC - area.lat) * 60.0
                Δeast_nm  = (lonC - area.lon) * Commons.longDegOnLatitudeNm(latC)
                x_forward =  Δnorth_nm * cos(θ) + Δeast_nm * sin(θ)
                y_side    = -Δnorth_nm * sin(θ) + Δeast_nm * cos(θ)
                # "unit" elliptical distance reported in NM (scales with radius)
                metric_nm = sqrt((x_forward/A)^2 + (y_side/B)^2) * area.radius
            end

            # --- Adaptive LOD + sdwn floor ---
            alt_used_ft = alt_ft === nothing ? 1000.0 : alt_ft
            adaptive_id  = Commons.adaptive_size_id(base_size_id, alt_used_ft, metric_nm, 90.0)
            min_size_id  = get(cfg, "sdwn", base_size_id)
            effective_id = max(min_size_id, adaptive_id)

            params = getSizeAndCols(effective_id)
            if params === nothing
                @warn "Invalid resolution ID ($effective_id) for tile $tile_id. Skipping."
                continue
            end
            effective_width, effective_cols = params

            # Cache (skip if already present / moved)
            if ddsFindScanner.has_suitable_tile(tile_id, effective_id, rootPath, rootPath_save, cfg)
                @info "GeoEngine.generate_all_tiles: Tile $tile_id already present with adequate resolution. Skipping."
                continue
            end

            tile = TileMetadata(
                tile_id, effective_id,
                lon, lat, lon + current_lon_step, lat + lat_step,
                Commons.x_index(latC, lonC), Commons.y_index(latC),
                lonC, latC, current_lon_step,
                effective_width, effective_cols
                )
            push!(tiles_with_distance, (tile, metric_nm, radial_nm))
        end
    end

    # Sorting with tie-break: first elliptical metric (or radial), then radial distance
    sort!(tiles_with_distance, by = item -> (item[2], item[3]))
    sorted_tiles = [item[1] for item in tiles_with_distance]
    return unique(t -> t.id, sorted_tiles)
end


"""
Creates a list of low-resolution jobs for fast pre-coverage.
Only one "chunk job" is generated for each tile.
"""
function create_precoverage_jobs(
    tiles::Vector{TileMetadata},
    precover_size_id::Int,
    tmp_dir::String
    )::Vector{ChunkJob}
    jobs = Vector{ChunkJob}()
    width, _ = Commons.getSizeAndCols(precover_size_id)
    retries = 3

    for tile in tiles
        bbox = (lonLL = tile.lonLL, latLL = tile.latLL, lonUR = tile.lonUR, latUR = tile.latUR)
        ps = Commons.chunk_pixel_size(width, 1, tile.latUR - tile.latLL, tile.lonUR - tile.lonLL)
        # Define both x and y. For a single chunk, they are both 1.
        total_chunks = 1; x = 1; y = 1; y_flipped = 1;
        over_mode = 1
        temp_filename = "$(tile.id)_$(precover_size_id)_$(total_chunks)_$(y_flipped)_$(x)_over$(over_mode).png"
        temp_path = joinpath(tmp_dir, temp_filename)
        if isfile(temp_path) && filesize(temp_path) > 64
            continue
        end
        push!(jobs, ChunkJob(tile.id, precover_size_id, (x, y), bbox, (width = ps.width, height = ps.height), temp_path, retries))
    end
    return jobs
end


# In src/GeoEngine.jl
function create_chunk_jobs(
    tiles::Vector{TileMetadata},
    cfg::Dict,
    tmp_dir::String,
    precover_level::Int = 0
    )::Vector{ChunkJob}
    jobs = Vector{ChunkJob}()
    retries = get(cfg, "attempts", get(cfg, "attemps", 5))

    # Retrieve overwrite mode from job configuration
    over_mode = get(cfg, "over", 1) # Default to 1 for safety

    for tile in tiles

        # Apply check only for tiles with resolution > 2
        if tile.size_id > 2
            # Check score of low-resolution version (pre-coverage)
            precover_score = ddsFindScanner.get_tile_score(tile.id, precover_level)

            if precover_score != -1.0 && precover_score < low_detail_threshold
                @warn "GeoEngine: Download inhibited for tile ID $(tile.id) (sizeId: $(tile.size_id)). Pre-coverage score ($(precover_score)) is below threshold ($(low_detail_threshold))."
                continue
            end
        end

        ΔLon_deg = (tile.lonUR - tile.lonLL) / tile.cols
        ΔLat_deg = (tile.latUR - tile.latLL) / tile.cols
        abs(ΔLon_deg) < 1e-12 && continue

        ps = Commons.chunk_pixel_size(tile)
        total_chunks = tile.cols * tile.cols

        for y in 1:tile.cols, x in 1:tile.cols
            y_flipped = tile.cols - y + 1
            # filename: tileId_sizeId_total_yflipped_x_overMODE.png
            temp_filename = "$(tile.id)_$(tile.size_id)_$(total_chunks)_$(y_flipped)_$(x)_over$(over_mode).png"
            temp_path = joinpath(tmp_dir, temp_filename)
            if isfile(temp_path) && filesize(temp_path) >= get(cfg, "min_chunk_bytes", 64)
                continue
            end
            chunk_lonLL = tile.lonLL + (x - 1) * ΔLon_deg
            chunk_latLL = tile.latLL + (y - 1) * ΔLat_deg
            chunk_bbox  = (lonLL = chunk_lonLL, latLL = chunk_latLL, lonUR = chunk_lonLL + ΔLon_deg, latUR = chunk_latLL + ΔLat_deg)
            push!(jobs, ChunkJob(tile.id, tile.size_id, (x, y), chunk_bbox, (width = ps.width, height = ps.height), temp_path, retries))
        end
    end
    return jobs
end


"""
create_cascading_jobs(tile::TileMetadata, cfg::Dict, tmp_dir::String, precover_level::Int) -> Vector{ChunkJob}

Generates a set of ChunkJobs that includes the optimal resolution of the tile (tile.size_id)
and, optionally, fallback levels (lower levels) to ensure coverage.
"""

function create_cascading_jobs(
    tile::TileMetadata,
    cfg::Dict,
    tmp_dir::String,
    precover_level::Int,
    root_path::String,
    save_path::String
    )::Vector{ChunkJob}

    all_jobs = Vector{ChunkJob}()
    target_id = tile.size_id
    min_fallback_id = 2

    # 1. JOB GENERATION FOR OPTIMAL RESOLUTION
    jobs_hi = create_chunk_jobs([tile], cfg, tmp_dir, precover_level)
    append!(all_jobs, jobs_hi)

    # 2. FALLBACK JOB GENERATION
    if target_id > min_fallback_id
        for fallback_id in min_fallback_id:(target_id - 1)

            # **CORRECTION**: Pass root_path and save_path
            if ddsFindScanner.has_suitable_tile(tile.id, fallback_id, root_path, save_path, cfg)
                @info "GeoEngine: Found suitable resolution $fallback_id for fallback of tile $(tile.id). Skipping."
                continue
            end

            # ... (the rest of the temp_tile creation logic remains unchanged)

            temp_width, temp_cols = Commons.getSizeAndCols(fallback_id)
            temp_tile = Commons.TileMetadata(
                tile.id, fallback_id,
                tile.lonLL, tile.latLL, tile.lonUR, tile.latUR,
                tile.x, tile.y,
                tile.lonC, tile.latC, tile.lon_step,
                temp_width, temp_cols
            )

            jobs_low = create_chunk_jobs([temp_tile], cfg, tmp_dir)
            append!(all_jobs, jobs_low)
        end
    end

    return all_jobs
end


"""
process_target_area(
    area::MapCoordinates,
    cfg::Dict,
    map_server::MapServer,
    root_path::String,
    save_path::String
    )

    Main orchestration function that processes a geographic target area by generating tiles,
    launching chunk download workers, and triggering asynchronous DDS assembly.

    This function executes the complete pipeline for acquiring and assembling orthophoto tiles
    from a remote map server. It:
    1. Computes the list of tiles covering the area of interest.
    2. Launches the DDS assembly monitor asynchronously (to allow real-time processing).
    3. Generates all chunk download jobs for the tiles.
    4. Starts the parallel download of chunk images using worker tasks.
    5. Waits for all downloads to complete before returning.

    # Arguments
    - `area::MapCoordinates`: The geographic area to process (center and radius in degrees).
    - `cfg::Dict`: Configuration dictionary (e.g. tile size, overlap, server index).
    - `map_server::MapServer`: The remote imagery server used to retrieve tile images.
    - `root_path::String`: Root path where the final DDS tiles will be stored.
    - `save_path::String`: Working path where temporary chunk files and converted tiles go.

    # Notes
    - The DDS assembly system is launched early and processes tiles in real-time as chunks are completed.
    - This function is non-blocking only for DDS assembly; it waits for downloads to finish.
    - Intended to be called from higher-level modules such as `GuiMode`.

    # Example
    GeoEngine.process_target_area(area, cfg, server, "/Orthophotos", "/Orthophotos-saved")
"""
function process_target_area(
    area::MapCoordinates,
    cfg::Dict,
    map_server::MapServer,
    root_path::String,
    save_path::String,
    tmp_dir::String,
    heading_deg::Union{Nothing,Float64}=nothing,
    alt_ft::Union{Nothing,Float64}=nothing
    )

    tiles = generate_all_tiles(
        area, cfg, root_path, save_path;
        heading_deg=heading_deg, alt_ft=alt_ft
        )
    if isempty(tiles)
        @info "GeoEngine: No tiles to process for the specified area."
        return nothing
    end

    nworkers = get(cfg, "workers", 8)
    Downloader.start_chunk_downloads_parallel!(nworkers, map_server, cfg, root_path, save_path, tmp_dir)

    min_required_unclamped = minimum(t -> t.size_id, tiles)
    precover_gap = get(cfg, "precover_gap", 1)
    desired_level = min_required_unclamped - precover_gap
    precover_level = clamp(desired_level, 0, 2)

    # --- PHASE 1: PRE-COVERAGE AND WAIT ---
    @info "GeoEngine: Phase 1 - Starting pre-coverage (level $(precover_level)) and waiting for completion..."
    precoverage_jobs = create_precoverage_jobs(tiles, precover_level, tmp_dir)
    if !isempty(precoverage_jobs)
        Downloader.enqueue_high!(precoverage_jobs)

        # WAIT for pre-coverage downloads to finish
        while Downloader.PENDING_JOBS[] > 0
            sleep(1)
        end
        @info "GeoEngine: Pre-coverage downloads completed. Waiting for assembly and indexing..."
        # WAIT for assembly and indexing to finish (with a timeout)
        # Give the system up to 60 seconds to process downloaded files.
        wait_time = 0
        max_wait = 60
        while wait_time < max_wait
            # Check if the LAST tile in the list has been indexed.
            # It's a good indicator that the process is complete.
            last_tile_id = tiles[end].id
            if ddsFindScanner.get_tile_score(last_tile_id, precover_level) != -1.0
                @info "GeoEngine: Pre-coverage indexing completed."
                break
            end
            sleep(2)
            wait_time += 2
        end
        if wait_time >= max_wait
            @warn "GeoEngine: Pre-coverage indexing wait timeout. Score checks might not be accurate."
        end
    end
    # --- END PHASE 1 ---

    # --- PHASE 2: HIGH RESOLUTION WITH CHECK AND FALLBACK CASCADE ---
    @info "GeoEngine: Phase 2 - Generating high-resolution jobs with score check and fallback cascade..."

    # Collect all chunk jobs (target + fallback) for all tiles
    all_cascading_jobs = Vector{Commons.ChunkJob}()

    for tile in tiles
        # The call passes necessary extra parameters
        jobs = create_cascading_jobs(tile, cfg, tmp_dir, precover_level, root_path, save_path)
        append!(all_cascading_jobs, jobs)
    end

    if isempty(all_cascading_jobs)
        @info "GeoEngine: No chunk jobs to enqueue (all tiles are suitable or inhibited)."
        return nothing
    end

    # 2. Priority subdivision (DAA vs Manual)

    if get(cfg, "mode", "manual") == "daa"
        frac = get(cfg, "daa_priority_frac", 0.35)

        # In DAA mode, high priority is given only to the *first* target_id jobs,
        # while fallbacks all go to low priority.
        cut  = clamp(ceil(Int, length(all_cascading_jobs) * frac), 1, length(all_cascading_jobs))
        jobs_hi = all_cascading_jobs[1:cut]
        jobs_lo = cut < length(all_cascading_jobs) ? all_cascading_jobs[(cut+1):end] : Commons.ChunkJob[]
        Downloader.enqueue_high!(jobs_hi)
        Downloader.enqueue_low!(jobs_lo)
    else
        # In Manual mode, all jobs (target + fallback) have the same low priority
        Downloader.enqueue_low!(all_cascading_jobs)
    end
    # --- END PHASE 2 ---

    @info "GeoEngine: $(length(all_cascading_jobs)) chunk jobs (including fallbacks) enqueued. The process will continue in background."
end


"""
count_existing_neighbors(latC::Float64, lonC::Float64) -> Int

Given the central coordinate of a potential tile, calculates the IDs of its
4 cardinal neighbors (N, E, S, W) and returns the number of those that already exist.
"""
function count_existing_neighbors(latC::Float64, lonC::Float64)::Int
    neighbor_count = 0
    lat_step = 0.125
    lon_step = Commons.tileWidth(latC)

    # Define ONLY the 4 cardinal directions (North, South, East, West)
    neighbor_offsets = [
        (lat_step, 0.0),      # N (North)
        (-lat_step, 0.0),     # S (South)
        (0.0, lon_step),      # E (East)
        (0.0, -lon_step)      # W (West)
        ]

    for (d_lat, d_lon) in neighbor_offsets
        # Calculate neighbor center and ID
        neighbor_latC = latC + d_lat
        neighbor_lonC = lonC + d_lon
        neighbor_id = Commons.index(neighbor_latC, neighbor_lonC)

        # Check if neighbor exists
        if !isempty(ddsFindScanner.find_file_by_id(neighbor_id))
            neighbor_count += 1
        end
    end

    return neighbor_count
end


"""
process_fill_holes(bounds, cfg, map_server, root_path, save_path, tmp_dir)

Analyzes an area defined by `bounds`, identifies missing tiles that
have at least 3 cardinal neighbors, and enqueues jobs for their download.
"""
function process_fill_holes(bounds, cfg::Dict, map_server::Downloader.MapServer, root_path::String, save_path::String, tmp_dir::String)
    @info "GeoEngine: Starting 'fill holes' analysis for area" bounds

    # ... (all grid scanning and hole identification logic remains identical) ...
    lat_min = floor(bounds.south / 0.125) * 0.125
    lat_max = ceil(bounds.north / 0.125) * 0.125
    lon_min = bounds.west
    lon_max = bounds.east

    missing_tiles = Vector{Commons.TileMetadata}()
    base_size_id = get(cfg, "size", 4)

    @info "Scanning grid from lat ($lat_min, $lat_max) and lon ($lon_min, $lon_max)"
    for lat in lat_min:0.125:lat_max
        lon_step = Commons.tileWidth(lat)
        for lon in floor(lon_min / lon_step) * lon_step : lon_step : ceil(lon_max / lon_step) * lon_step
            latC = lat + 0.125 / 2
            lonC = lon + lon_step / 2
            tile_id = Commons.index(latC, lonC)

            if isempty(ddsFindScanner.find_file_by_id(tile_id))
                neighbor_count = count_existing_neighbors(latC, lonC)
                if neighbor_count >= 3
                    @info "Found internal hole to fill: ID $tile_id (neighbors: $neighbor_count)"
                    width, cols = Commons.getSizeAndCols(base_size_id)
                    x_idx, y_idx = Commons.x_index(latC, lonC), Commons.y_index(latC)

                    tile = Commons.TileMetadata(
                        tile_id, base_size_id,
                        lon, lat, lon + lon_step, lat + 0.125,
                        x_idx, y_idx,
                        lonC, latC, lon_step,
                        width, cols
                        )
                    push!(missing_tiles, tile)
                end
            end
        end
    end
    # ... (end of scanning logic) ...

    if isempty(missing_tiles)
        @info "GeoEngine: No internal holes found in visible area."
        return
    end

    @info "GeoEngine: Found $(length(missing_tiles)) holes to fill. Starting processes..."

    # 1. Start download workers
    nworkers = get(cfg, "workers", 8)
    Downloader.start_chunk_downloads_parallel!(nworkers, map_server, cfg, root_path, save_path, tmp_dir)

    # 2. Create and enqueue jobs
    high_res_jobs = create_chunk_jobs(missing_tiles, cfg, tmp_dir)
    Downloader.enqueue_low!(high_res_jobs)
    @info "GeoEngine: $(length(high_res_jobs)) chunk jobs enqueued to fill holes."

    # Also here, there is no call to monitor_and_assemble or wait.
    # The function ends here, and background services will do the rest.
    @info "GeoEngine: 'fill holes' jobs enqueued. Download and assembly will proceed in background."
end


# -----------------------------------------------------------------------------
#  2. Path & location helper
# -----------------------------------------------------------------------------

"""
prepare_paths_and_location(cfg::Dict, home_path::String)

Determines root and save paths with a robust fallback logic:
1. Uses the configured path (if valid and writable).
2. If it fails, searches for existing 'Orthophotos' folders nearby.
3. If it fails, uses the current program directory (guaranteed writable).
"""
function prepare_paths_and_location(cfg::Dict{String,Any}, home_path::AbstractString)
    route_vec = Vector{Any}()
    position_on_route = nothing
    radius_nm = get(cfg, "radius", 10.0)

    # --- 1. Gestione Coordinate (invariata) ---
    if haskey(cfg, "lat") && haskey(cfg, "lon")
        StatusMonitor.log_message("GeoEngine: Localization via direct Lat/Lon coordinates...")
        push!(route_vec, (cfg["lat"], cfg["lon"]))
        elseif get(cfg, "route", nothing) !== nothing
        StatusMonitor.log_message("GeoEngine: Localization via ROUTE ($(cfg["route"]))...")
        (loaded, pos) = Route.loadRoute(cfg["route"], radius_nm)
        append!(route_vec, loaded)
        position_on_route = pos
        elseif get(cfg, "icao", nothing) !== nothing
        StatusMonitor.log_message("GeoEngine: Localization via ICAO ($(cfg["icao"]))...")
        (lat, lon, err) = Route.selectIcao(cfg["icao"], radius_nm)
        err == 0 && lat !== nothing && push!(route_vec, (lat, lon))
    else
        StatusMonitor.log_message("GeoEngine: Default coordinates (demo mode).")
        push!(route_vec, (47.26, 11.34))
    end

    # =================================================================================
    # ROBUST PATH LOGIC
    # =================================================================================

    project_root = pwd()

    # Helper function to test if a path is writable
    function is_writable_dir(path)
        try
            if !isdir(path)
                mkpath(path) # Try to create
            end
            # Try to write a temporary file
            test_file = joinpath(path, ".write_test")
            touch(test_file)
            rm(test_file)
            return true
        catch
            return false
        end
    end

    # --- STEP 1: Determine root_path (Orthophotos) ---

    root_path_cfg = get(cfg, "path", nothing)
    local root_path = nothing

    # 1. Explicit Configuration Attempt
    if root_path_cfg !== nothing
        if is_writable_dir(root_path_cfg)
            root_path = root_path_cfg
        else
            @warn "GeoEngine: Configured path '$root_path_cfg' is not accessible/writable. Searching alternatives..."
        end
    end

    # 2. Automatic Search Attempt (If config fails or is missing)
    if root_path === nothing
        # Logical candidates
        container_dir = normpath(dirname(project_root))
        candidates = [
            # Classic sibling folder
            normpath(joinpath(container_dir, "photoscenery", "Orthophotos")),
            # Local project folder
            normpath(joinpath(project_root, "Orthophotos"))
            ]

        # Search for the first candidate that ALREADY exists and is writable
        for cand in candidates
            if isdir(cand) && is_writable_dir(cand)
                @info "GeoEngine: Found existing Orthophotos folder: $cand"
                root_path = cand
                break
            end
        end

        # 3. Final Fallback (Local Creation)
        if root_path === nothing
            root_path = normpath(joinpath(project_root, "Orthophotos"))
            @warn "GeoEngine: No valid folder found. Using safe local path: $root_path"
        end
    end

    # Ensure it is created (should pass if is_writable_dir worked, but for safety)
    try
        mkpath(root_path)
        StatusMonitor.log_message("GeoEngine: Active Orthophoto path => $root_path")
        catch e
        # Desperate case: error even in local folder?
        error("GeoEngine: Unable to create Orthophotos folder in $root_path. Permission error: $e")
    end


    # --- STEP 2: Determine save_path (Orthophotos-saved) ---

    save_path_cfg = get(cfg, "save", nothing)
    nosave = get(cfg, "nosave", false)
    local save_path = nothing

    if !nosave
        # 1. Explicit Configuration Attempt
        if save_path_cfg !== nothing
            if is_writable_dir(save_path_cfg)
                save_path = save_path_cfg
            else
                @warn "GeoEngine: Configured save path '$save_path_cfg' is not accessible."
            end
        end

        # 2. Consistent Fallback (Next to root_path)
        if save_path === nothing
            # If root_path is ".../photoscenery/Orthophotos", put saved in ".../photoscenery/Orthophotos-saved"
            parent_dir = dirname(root_path)
            candidate_save = joinpath(parent_dir, "Orthophotos-saved")

            # If root_path is the root itself (strange but possible), use a subfolder
            if parent_dir == root_path
                candidate_save = joinpath(root_path, "saved_tiles")
            end

            save_path = candidate_save
            @info "GeoEngine: Using automatic save path: $save_path"
        end

        # Creation
        try
            mkpath(save_path)
            StatusMonitor.log_message("GeoEngine: Active Save path => $save_path")
            catch e
            @warn "GeoEngine: Unable to create save path $save_path. Disabling save."
            save_path = nothing
        end
    end

    return route_vec, position_on_route, root_path, save_path
end


"""
    recover_orphaned_tiles(...)

Scans `tmp`. Keeps `watchlist` synchronized.
- Removes non-existing files from the list.
- Adds found files. Sets `deleteOnExit = true` ONLY if `is_first_run` is true.
"""
function recover_orphaned_tiles(
    tmp_dir::String,
    root_path::String,
    save_path::String,
    cfg::Dict,
    watchlist::Union{Dict{String, Bool}, Nothing} = nothing,
    watchlist_lock::Union{ReentrantLock, Nothing} = nothing,
    is_first_run::Bool = false
)
    if is_first_run
        @info "GeoEngine: Initial orphan scan (Cycle 0) in: $tmp_dir"
    end

    assembled_file_re = r"^(\d{7})\.(dds|png)$"
    chunk_file_re = r"^(\d+)_(\d+)_(\d+)_(\d+)_(\d+)_over(\d)\.png$"

    chunk_groups = Dict{Int, Any}()

    try
        if !isdir(tmp_dir); return; end

        all_files = readdir(tmp_dir)

        for filename in all_files
            source_path = joinpath(tmp_dir, filename)
            if !isfile(source_path); continue; end

            # --- A. Complete Tiles ---
            m_assembled = match(assembled_file_re, filename)
            if m_assembled !== nothing
                tile_id = parse(Int, m_assembled.captures[1])
                is_dds = lowercase(m_assembled.captures[2]) == "dds"

                success_size, width, _ = is_dds ? Commons.getDDSSize(source_path) : Commons.getPNGSize(source_path)

                if !success_size || (size_id = Commons.getSizeFromWidth(width)) === nothing
                    _safe_add_to_watchlist(watchlist, watchlist_lock, source_path, is_first_run, filename)
                    continue
                end

                # Metadata reconstruction logic (Corrected with offset)
                # 1. Get grid base
                _, _, grid_lon, grid_lat, xidx, yidx, _, _ = Commons.coordFromIndex(tile_id)
                # 2. Calculate Tile Lat
                tile_latLL = grid_lat + (yidx * 0.125)
                # 3. Calculate Tile Width and Lon
                tile_width_deg = Commons.tileWidth(tile_latLL)
                tile_lonLL = grid_lon + (xidx * tile_width_deg)

                # Centers and bbox for place_tile
                lonC = tile_lonLL + tile_width_deg/2
                latC = tile_latLL + 0.125/2
                _, cols = Commons.getSizeAndCols(size_id)

                tile_meta = Commons.TileMetadata(tile_id, size_id,
                    tile_lonLL, tile_latLL, tile_lonLL + tile_width_deg, tile_latLL + 0.125,
                    xidx, yidx, lonC, latC, tile_width_deg, width, cols)

                if ddsFindScanner.place_tile!(source_path, tile_meta, root_path, save_path, cfg)
                    @info "Complete orphan $filename successfully recovered."
                else
                    _safe_add_to_watchlist(watchlist, watchlist_lock, source_path, is_first_run, filename)
                end
                continue
            end

            # --- B. Chunk (Resume Analysis) ---
            m_chunk = match(chunk_file_re, filename)
            if m_chunk !== nothing
                t_id   = parse(Int, m_chunk.captures[1])
                t_size = parse(Int, m_chunk.captures[2])
                t_tot  = parse(Int, m_chunk.captures[3])
                t_yf   = parse(Int, m_chunk.captures[4])
                t_x    = parse(Int, m_chunk.captures[5])
                t_over = parse(Int, m_chunk.captures[6])

                cols = Int(sqrt(t_tot))
                t_y = cols - t_yf + 1

                if !haskey(chunk_groups, t_id)
                    chunk_groups[t_id] = Dict(
                        "size" => t_size,
                        "total" => t_tot,
                        "cols" => cols,
                        "over" => t_over,
                        "present_coords" => Set{Tuple{Int,Int}}(),
                        "paths" => String[]
                    )
                end

                push!(chunk_groups[t_id]["present_coords"], (t_x, t_y))
                push!(chunk_groups[t_id]["paths"], source_path)
                _safe_add_to_watchlist(watchlist, watchlist_lock, source_path, is_first_run, filename)
                continue
            end

            # --- C. Garbage ---
            if endswith(filename, ".png") || endswith(filename, ".dds") || endswith(filename, ".part")
                _safe_add_to_watchlist(watchlist, watchlist_lock, source_path, is_first_run, filename)
            end
        end

        # --- STEP 2: Resume Missing Chunks ---
        if is_first_run && !isempty(chunk_groups)
            @info "GeoEngine: Orphan chunk analysis for completion attempt..."

            resume_jobs = Vector{Commons.ChunkJob}()
            resumed_tiles_count = 0

            for (t_id, info) in chunk_groups
                present = info["present_coords"]
                total_chunks = info["total"]
                cols = info["cols"]
                size_id = info["size"]

                if length(present) < total_chunks
                    missing_count = total_chunks - length(present)
                    @info "Tile $t_id: Found $(length(present))/$total_chunks chunks. Resuming for $missing_count missing."

                    # === CORRECT COORDINATE CALCULATION ===
                    # 1. Get GRID base (e.g. 14.0, 42.0) and indices (x=2, y=3)
                    _, _, grid_lon, grid_lat, xidx, yidx, _, _ = Commons.coordFromIndex(t_id)

                    # 2. Calculate LL point of specific TILE
                    tile_latLL = grid_lat + (yidx * 0.125)
                    tile_width_deg = Commons.tileWidth(tile_latLL)
                    tile_lonLL = grid_lon + (xidx * tile_width_deg)

                    # 3. Build temporary metadata for pixel size calculation
                    lonC = tile_lonLL + tile_width_deg/2
                    latC = tile_latLL + 0.125/2
                    width_px, _ = Commons.getSizeAndCols(size_id)

                    temp_tile = Commons.TileMetadata(
                        t_id, size_id,
                        tile_lonLL, tile_latLL, tile_lonLL + tile_width_deg, tile_latLL + 0.125,
                        xidx, yidx, lonC, latC, tile_width_deg,
                        width_px, cols
                    )

                    # 4. Calculate correct pixel dimensions (rectangular if necessary)
                    ps = Commons.chunk_pixel_size(temp_tile)

                    # 5. Delta degrees for single CHUNK
                    chunk_dLon = tile_width_deg / cols
                    chunk_dLat = 0.125 / cols

                    for cx in 1:cols, cy in 1:cols
                        if !((cx, cy) in present)
                            # 6. Calculate geographic coordinates of the CHUNK starting from TILE LL
                            #    (NOT from Grid LL as before!)
                            c_lonLL = tile_lonLL + (cx - 1) * chunk_dLon
                            c_latLL = tile_latLL + (cy - 1) * chunk_dLat

                            c_bbox = (lonLL=c_lonLL, latLL=c_latLL, lonUR=c_lonLL+chunk_dLon, latUR=c_latLL+chunk_dLat)

                            y_flipped = cols - cy + 1
                            fname = "$(t_id)_$(size_id)_$(total_chunks)_$(y_flipped)_$(cx)_over$(info["over"]).png"
                            fpath = joinpath(tmp_dir, fname)

                            job = Commons.ChunkJob(
                                t_id, size_id, (cx, cy), c_bbox,
                                (width=ps.width, height=ps.height),
                                fpath, 5
                            )
                            push!(resume_jobs, job)
                        end
                    end

                    # Remove existing chunks from watchlist
                    if watchlist !== nothing && watchlist_lock !== nothing
                        lock(watchlist_lock) do
                            for p in info["paths"]; delete!(watchlist, p); end
                        end
                    end
                    resumed_tiles_count += 1
                end
            end

            if !isempty(resume_jobs)
                @info "GeoEngine: Enqueuing $resumed_tiles_count tiles (total $(length(resume_jobs)) chunks) to Downloader (LOW queue)."

                download_cfg = copy(cfg)
                if !haskey(download_cfg, "attempts"); download_cfg["attempts"] = 5; end
                if !haskey(download_cfg, "timeout"); download_cfg["timeout"] = 30; end

                server_id = get(cfg, "server", 1)
                real_server = Downloader.MapServer(server_id)
                nworkers = get(cfg, "workers", 8)

                Downloader.start_chunk_downloads_parallel!(nworkers, real_server, download_cfg, root_path, save_path, tmp_dir)

                # USE LOW QUEUE FOR IMMEDIATE UNBLOCK
                Downloader.enqueue_low!(resume_jobs)
            end
        end

    catch e
        @error "Error in recover_orphaned_tiles loop" exception=(e, catch_backtrace())
    end
end


# Internal helper function to reduce lock code duplication
function _safe_add_to_watchlist(wl, lock_obj, path, is_first, fname)
    if wl !== nothing && lock_obj !== nothing
        lock(lock_obj) do
            if !haskey(wl, path)
                wl[path] = is_first
                if is_first
                    @info "Orphan detected at startup: $fname (will be deleted on exit)."
                end
            end
        end
    end
end


# ---- Transitional shim (deprecatable later) ----
search_airports(q::AbstractString; limit::Int=10) =
    AirportsNavaids.search_airports(q; limit=limit)

resolve_icao(icao::AbstractString) =
    AirportsNavaids.resolve_icao(icao)

"""
search_airports(q::AbstractString, limit::Integer=10)

Search airports by ICAO (exact 4-letter match) or by name/city (if available in Route module).
Returns a vector of NamedTuple with fields: (icao, name, lat, lon, elev_ft).
"""
function __search_airports(q::AbstractString, limit::Integer=10)
    q_norm = strip(q)
    results = NamedTuple{(:icao, :name, :lat, :lon, :elev_ft)}[]

    # helper: extract field from NamedTuple or Dict (Symbol or String)
    _extract(a, sym::Symbol, default) =
        hasproperty(a, sym) ? getfield(a, sym) :
        (a isa AbstractDict ? get(a, sym, get(a, String(sym), default)) : default)

    # Case 1: 4-letter ICAO -> resolve directly
    if length(q_norm) == 4 && all(isletter, q_norm)
        icao = uppercase(q_norm)
        lat, lon, err = Route.selectIcao(icao, 0.0)
        if err == 0 && lat !== nothing
            push!(results, (icao=icao, name=icao, lat=lat, lon=lon, elev_ft=missing))
        end
        return first(results, min(length(results), limit))
    end

    # Case 2: name/city -> try search functions if they exist in Route
    matches = Any[]
    if isdefined(Route, :search_by_name)
        matches = Route.search_by_name(q_norm, limit)
    elseif isdefined(Route, :searchAirports)
        matches = Route.searchAirports(q_norm, limit)
    elseif isdefined(Route, :find_airports)
        matches = Route.find_airports(q_norm, limit)
    else
        return results  # no search function available
    end

    for a in matches
        icao = String(_extract(a, :icao, ""))
        name = String(_extract(a, :name,  icao))
        lat  = Float64(_extract(a, :lat,  NaN))
        lon  = Float64(_extract(a, :lon,  NaN))
        elev = _extract(a, :elev_ft, missing)
        push!(results, (icao=icao, name=name, lat=lat, lon=lon, elev_ft=elev))
    end

    return first(results, min(length(results), limit))
end



end # module GeoEngine

