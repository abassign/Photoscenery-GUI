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
using .Commons: chunk_pixel_size

export prepare_paths_and_location, process_target_area, create_precoverage_jobs, create_chunk_jobs, process_fill_holes, recover_orphaned_tiles

function generate_all_tiles(
    area::MapCoordinates,
    cfg::Dict,
    rootPath::String,
    rootPath_save::String;
    heading_deg::Union{Nothing,Float64}=nothing,   # ← passato dal chiamante in DAA
    alt_ft::Union{Nothing,Float64}=nothing         # ← passato dal chiamante (quota AGL)
    )
    # (tile, metrica_per_ordinamento, distanza_radiale) per tie-break
    tiles_with_distance = Vector{Tuple{TileMetadata, Float64, Float64}}()

    lat_step      = 0.125
    base_size_id  = get(cfg, "size", 4)
    mode_is_daa   = get(cfg, "mode", "manual") == "daa"
    offset        = 0.0

    if mode_is_daa offset = 0.25 end  # ~1/4° leggera espansione bbox per sicurezza bordi (non altera il filtro circolare)

    # 1) Griglia base dal raggio (in gradi)
    # ATTENZIONE Questo algortmo per ricavare lat_min_grid lat_max_grid lon_min_grid lon_max_grid è essenziale che non venga variato in funzione
    # del metodo atottato di arrotondamento, altrimenti avremo disallineamento nei tiles!
    radius_deg   = area.radius * (1 / 60)
    lat_min_grid = floor((area.lat - radius_deg - offset) / lat_step) * lat_step
    lat_max_grid = ceil((area.lat + radius_deg + offset) / lat_step) * lat_step
    lon_min_grid = floor(((area.lon - offset) - radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)
    lon_max_grid = ceil(((area.lon + offset) + radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)

    @info "GeoEngine: Generazione griglia tile (filtro radiale; LOD anisotropo in DAA)…"

    # 3) Parametri ellisse DAA: larghezza = diametro area ⇒ B = radius
    A = get(cfg, "daa_forward_nm", area.radius * 1.5)  # semi‑asse lungo rotta
    B = area.radius                                    # semi‑asse laterale (richiesta)
    θ = mode_is_daa && heading_deg !== nothing ? deg2rad(heading_deg) : 0.0

    for lat in lat_min_grid:lat_step:lat_max_grid
        current_lon_step = tileWidth(lat)
        for lon in lon_min_grid:current_lon_step:lon_max_grid
            latC = lat + lat_step / 2
            lonC = lon + current_lon_step / 2
            tile_id = index(latC, lonC)

            # --- INCLUSIONE: SOLO cerchio centrato (copertura invariata) ---
            radial_nm = Geodesics.surface_distance(
                lonC, latC, area.lon, area.lat, Geodesics.localEarthRadius(latC)
                ) / 1852.0
            radial_nm <= area.radius || continue

            # --- METRICA per priorità/LOD ---
            metric_nm = radial_nm
            if mode_is_daa
                Δnorth_nm = (latC - area.lat) * 60.0
                Δeast_nm  = (lonC - area.lon) * Commons.longDegOnLatitudeNm(latC)
                x_forward =  Δnorth_nm * cos(θ) + Δeast_nm * sin(θ)
                y_side    = -Δnorth_nm * sin(θ) + Δeast_nm * cos(θ)
                # distanza “unitaria” ellittica riportata in NM (scala con radius)
                metric_nm = sqrt((x_forward/A)^2 + (y_side/B)^2) * area.radius
            end

            # --- LOD adattivo + pavimento sdwn ---
            alt_used_ft = alt_ft === nothing ? 1000.0 : alt_ft
            adaptive_id  = Commons.adaptive_size_id(base_size_id, alt_used_ft, metric_nm, 90.0)
            min_size_id  = get(cfg, "sdwn", base_size_id)
            effective_id = max(min_size_id, adaptive_id)

            params = getSizeAndCols(effective_id)
            if params === nothing
                @warn "ID risoluzione non valido ($effective_id) per tile $tile_id. Salto."
                continue
            end
            effective_width, effective_cols = params

            # Cache (salta se già presente / spostato)
            if ddsFindScanner.has_suitable_tile(tile_id, effective_id, rootPath, rootPath_save, cfg)
                @info "GeoEngine.generate_all_tiles: Tile $tile_id già presente con risoluzione adeguata. Salto."
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

    # Ordinamento con tie‑break: prima metrica ellittica (o radiale), poi distanza radiale
    sort!(tiles_with_distance, by = item -> (item[2], item[3]))
    sorted_tiles = [item[1] for item in tiles_with_distance]
    return unique(t -> t.id, sorted_tiles)
end


"""
Crea una lista di job a bassa risoluzione per una pre-copertura veloce.
Viene generato un solo "chunk job" per ogni tile.
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
        # Definiamo sia x che y. Per un singolo chunk, sono entrambi 1.
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

    # Recupera la modalità di sovrascrittura dalla configurazione del job
    over_mode = get(cfg, "over", 1) # Default a 1 per sicurezza

    for tile in tiles

        # Applica il controllo solo per i tile con risoluzione > 2
        if tile.size_id > 2
            # Controlla lo score della versione a bassa risoluzione (pre-copertura)
            precover_score = ddsFindScanner.get_tile_score(tile.id, precover_level)

            if precover_score != -1.0 && precover_score < low_detail_threshold
                @warn "GeoEngine: Download inibito per tile ID $(tile.id) (sizeId: $(tile.size_id)). Score pre-copertura ($(precover_score)) è inferiore alla soglia ($(low_detail_threshold))."
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
            # nome file: tileId_sizeId_total_yflipped_x_overMODE.png
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
    heading_deg::Union{Nothing,Float64}=nothing,
    alt_ft::Union{Nothing,Float64}=nothing
    )
    tmp_dir = joinpath(save_path, "tmp")
    mkpath(tmp_dir)

    tiles = generate_all_tiles(
        area, cfg, root_path, save_path;
        heading_deg=heading_deg, alt_ft=alt_ft
        )
    if isempty(tiles)
        @info "GeoEngine: Nessun tile da processare per l'area specificata."
        return nothing
    end

    nworkers = get(cfg, "workers", 8)
    Downloader.start_chunk_downloads_parallel!(nworkers, map_server, cfg, root_path, save_path, tmp_dir)

    min_required_unclamped = minimum(t -> t.size_id, tiles)
    precover_gap = get(cfg, "precover_gap", 1)
    desired_level = min_required_unclamped - precover_gap
    precover_level = clamp(desired_level, 0, 2)

    # --- FASE 1: PRE-COVERAGE E ATTESA ---
    @info "GeoEngine: Fase 1 - Avvio pre-coverage (livello $(precover_level)) e attesa completamento..."
    precoverage_jobs = create_precoverage_jobs(tiles, precover_level, tmp_dir)
    if !isempty(precoverage_jobs)
        Downloader.enqueue_high!(precoverage_jobs)

        # ATTENDI che i download di pre-copertura finiscano
        while Downloader.PENDING_JOBS[] > 0
            sleep(1)
        end
        @info "GeoEngine: Download di pre-copertura completati. Attesa assemblaggio e indicizzazione..."
        # ATTENDI che l'assemblaggio e l'indicizzazione finiscano (con un timeout)
        # Diamo al sistema fino a 60 secondi per processare i file scaricati.
        wait_time = 0
        max_wait = 60
        while wait_time < max_wait
            # Controlliamo se l'ULTIMO tile della lista è stato indicizzato.
            # È un buon indicatore che il processo è completo.
            last_tile_id = tiles[end].id
            if ddsFindScanner.get_tile_score(last_tile_id, precover_level) != -1.0
                @info "GeoEngine: Indicizzazione pre-copertura completata."
                break
            end
            sleep(2)
            wait_time += 2
        end
        if wait_time >= max_wait
            @warn "GeoEngine: Timeout attesa indicizzazione pre-copertura. I controlli di score potrebbero non essere accurati."
        end
    end
    # --- FINE FASE 1 ---

    # --- FASE 2: ALTA RISOLUZIONE CON CONTROLLO ---
    @info "GeoEngine: Fase 2 - Generazione job ad alta risoluzione con controllo dello score..."
    # La chiamata ora passa i parametri extra necessari
    high_res_jobs = create_chunk_jobs(tiles, cfg, tmp_dir, precover_level)

    if get(cfg, "mode", "manual") == "daa"
        frac = get(cfg, "daa_priority_frac", 0.35)
        cut  = clamp(ceil(Int, length(high_res_jobs) * frac), 1, length(high_res_jobs))
        jobs_hi = high_res_jobs[1:cut]
        jobs_lo = cut < length(high_res_jobs) ? high_res_jobs[(cut+1):end] : Commons.ChunkJob[]
        Downloader.enqueue_high!(jobs_hi)
        Downloader.enqueue_low!(jobs_lo)
    else
        Downloader.enqueue_low!(high_res_jobs)
    end
    # --- FINE FASE 2 ---

    @info "GeoEngine: Job ad alta risoluzione accodati. Il processo continuerà in background."
end


"""
count_existing_neighbors(latC::Float64, lonC::Float64) -> Int

Data la coordinata centrale di un potenziale tassello, calcola gli ID dei suoi
4 vicini cardinali (N, E, S, O) e restituisce il numero di quelli che esistono già.
"""
function count_existing_neighbors(latC::Float64, lonC::Float64)::Int
    neighbor_count = 0
    lat_step = 0.125
    lon_step = Commons.tileWidth(latC)

    # Definiamo SOLO le 4 direzioni cardinali (Nord, Sud, Est, Ovest)
    neighbor_offsets = [
        (lat_step, 0.0),      # N (Nord)
        (-lat_step, 0.0),     # S (Sud)
        (0.0, lon_step),      # E (Est)
        (0.0, -lon_step)      # O (Ovest)
        ]

    for (d_lat, d_lon) in neighbor_offsets
        # Calcola il centro e l'ID del vicino
        neighbor_latC = latC + d_lat
        neighbor_lonC = lonC + d_lon
        neighbor_id = Commons.index(neighbor_latC, neighbor_lonC)

        # Controlla se il vicino esiste
        if !isempty(ddsFindScanner.find_file_by_id(neighbor_id))
            neighbor_count += 1
        end
    end

    return neighbor_count
end


"""
process_fill_holes(bounds, cfg, map_server, root_path, save_path, tmp_dir)

Analizza un'area definita da `bounds`, identifica i tasselli mancanti che
hanno almeno 3 vicini cardinali e accoda i job per il loro download.
"""
function process_fill_holes(bounds, cfg::Dict, map_server::Downloader.MapServer, root_path::String, save_path::String, tmp_dir::String)
    @info "GeoEngine: Inizio analisi 'fill holes' per l'area" bounds

    # ... (tutta la logica di scansione della griglia e identificazione dei buchi rimane identica) ...
    lat_min = floor(bounds.south / 0.125) * 0.125
    lat_max = ceil(bounds.north / 0.125) * 0.125
    lon_min = bounds.west
    lon_max = bounds.east

    missing_tiles = Vector{Commons.TileMetadata}()
    base_size_id = get(cfg, "size", 4)

    @info "Scansione griglia da lat ($lat_min, $lat_max) e lon ($lon_min, $lon_max)"
    for lat in lat_min:0.125:lat_max
        lon_step = Commons.tileWidth(lat)
        for lon in floor(lon_min / lon_step) * lon_step : lon_step : ceil(lon_max / lon_step) * lon_step
            latC = lat + 0.125 / 2
            lonC = lon + lon_step / 2
            tile_id = Commons.index(latC, lonC)

            if isempty(ddsFindScanner.find_file_by_id(tile_id))
                neighbor_count = count_existing_neighbors(latC, lonC)
                if neighbor_count >= 3
                    @info "Trovato buco interno da riempire: ID $tile_id (vicini: $neighbor_count)"
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
    # ... (fine della logica di scansione) ...

    if isempty(missing_tiles)
        @info "GeoEngine: Nessun buco interno trovato nell'area visibile."
        return
    end

    @info "GeoEngine: Trovati $(length(missing_tiles)) buchi da riempire. Avvio processi..."

    # 1. Avvia i worker di download
    nworkers = get(cfg, "workers", 8)
    Downloader.start_chunk_downloads_parallel!(nworkers, map_server, cfg, root_path, save_path, tmp_dir)

    # 2. Crea e accoda i job
    high_res_jobs = create_chunk_jobs(missing_tiles, cfg, tmp_dir)
    Downloader.enqueue_low!(high_res_jobs)
    @info "GeoEngine: $(length(high_res_jobs)) chunk job accodati per riempire i buchi."

    # Anche qui, non c'è nessuna chiamata a monitor_and_assemble o wait.
    # La funzione termina qui, e i servizi in background faranno il resto.
    @info "GeoEngine: Job per 'fill holes' accodati. Download e assemblaggio procederanno in background."
end


# -----------------------------------------------------------------------------
#  2. Path & location helper
# -----------------------------------------------------------------------------

"""
prepare_paths_and_location(cfg::Dict, home_path::String)

Prepares the essential file system paths and target coordinates required for a download job.

    This function determines:
    1. The save path for generated tiles (typically `Orthophotos-saved`).
    2. The root path for final output tiles (typically `Orthophotos`).
    3. The list of coordinate centers (`route_vec`) around which tiles will be generated.

    If the configuration includes a predefined route, it is used directly. Otherwise, a single
    target area is created based on the provided `lat`, `lon`, and `radius`.

    # Arguments
    - `cfg::Dict`: Configuration dictionary containing keys like:
    - `"lat"`, `"lon"`: Central coordinates of the area (required).
    - `"radius"`: Radius of coverage (in degrees, required).
    - `"save_path"` (optional): Custom override for the output path.
    - `"path"` (optional): Path to an existing orthophoto root directory.
    - `home_path::String`: Base directory, typically the path of the current module or application.

    # Returns
    - `route_vec::Vector{Tuple{Float64, Float64}}`: List of center points for target areas.
    - `radius::Float64`: The radius used for area generation.
    - `root_path::String`: Path where final `.dds` tiles will be stored.
    - `save_path::String`: Path where intermediate and temporary data will be stored.

    # Notes
    - The logic gracefully handles missing folders by creating them if needed.
    - If no explicit path is given, it defaults to searching for a folder named `Orthophotos`.

    # Example
    route, radius, root, save = prepare_paths_and_location(cfg, @__DIR__)
"""
function prepare_paths_and_location(cfg::Dict{String,Any}, home_path::AbstractString)
    route_vec = Vector{Any}()
    position_on_route = nothing
    radius_nm = get(cfg, "radius", 10.0)

    # 1. Priorità massima: coordinate lat/lon dirette
    if haskey(cfg, "lat") && haskey(cfg, "lon")
        StatusMonitor.log_message("GeoEngine: Localizzazione tramite coordinate dirette Lat/Lon...")
        push!(route_vec, (cfg["lat"], cfg["lon"]))

        # 2. Priorità media: file di rotta
    elseif get(cfg, "route", nothing) !== nothing
        StatusMonitor.log_message("GeoEngine: Localizzazione tramite ROUTE ($(cfg["route"]))...")
        (loaded, pos) = Route.loadRoute(cfg["route"], radius_nm)
        append!(route_vec, loaded)
        position_on_route = pos

        # 3. Priorità bassa: codice ICAO
    elseif get(cfg, "icao", nothing) !== nothing
        StatusMonitor.log_message("GeoEngine: Localizzazione tramite ICAO ($(cfg["icao"]))...")
        (lat, lon, err) = Route.selectIcao(cfg["icao"], radius_nm)
        err == 0 && lat !== nothing && push!(route_vec, (lat, lon))

        # 4. Caso di default
    else
        StatusMonitor.log_message("GeoEngine: Coordinate di default (modalità demo).")
        push!(route_vec, (47.26, 11.34))
    end

    # Logica per percorsi di salvataggio
    root_path = get(cfg, "path", nothing)
    # Se nessun percorso è stato fornito dalla configurazione, ne cerchiamo uno di default.
    if root_path === nothing
        @info "Nessun percorso specificato, ricerca di una cartella 'Orthophotos' esistente..."
        candidates = [
            normpath(joinpath(dirname(dirname(home_path)), "photoscenery", "Orthophotos")),
            normpath(joinpath(dirname(home_path), "photoscenery", "Orthophotos")),
            normpath(joinpath(home_path, "photoscenery", "Orthophotos")),
            ]
        idx = findfirst(isdir, candidates)

        # Se viene trovata una cartella esistente, usiamo quella.
        # Altrimenti, usiamo il terzo candidato come default da creare.
        root_path = if idx !== nothing
            @info "Trovata cartella esistente: $(candidates[idx])"
            candidates[idx]
        else
            @info "Nessuna cartella esistente, verrà usato il percorso di default: $(candidates[3])"
            candidates[3]
        end
    end
    mkpath(root_path)
    StatusMonitor.log_message("GeoEngine: Percorso Orthophoto impostato su ⇒ $root_path")

    # Logica per save_path (invariata)
    save_path_str = get(cfg, "save", nothing)
    nosave = get(cfg, "nosave", false)
    save_path = nosave ? nothing : (save_path_str isa AbstractString ? save_path_str : root_path * "-saved")

    if save_path !== nothing
        mkpath(save_path)
        StatusMonitor.log_message("GeoEngine: Percorso di salvataggio impostato su ⇒ $save_path")
    end

    return route_vec, position_on_route, root_path, save_path
end


"""
    recover_orphaned_tiles(tmp_dir, root_path, save_path, cfg)

Scansiona la cartella `tmp` all'avvio alla ricerca di tile già assemblati
(es. 1234567.dds) ma non ancora posizionati. Tenta di recuperarli
e posizionarli correttamente, pulendo la cartella da file completati.
"""
function recover_orphaned_tiles(tmp_dir::String, root_path::String, save_path::String, cfg::Dict)
    @info "GeoEngine: Avvio scansione di recupero per tile orfani in: $tmp_dir"
    recovered_count = 0

    # Pattern per i file assemblati: 7 cifre seguite da .dds o .png
    assembled_file_re = r"^(\d{7})\.(dds|png)$"

    try
        for filename in readdir(tmp_dir)
            m = match(assembled_file_re, filename)
            if m !== nothing
                source_path = joinpath(tmp_dir, filename)
                tile_id = parse(Int, m.captures[1])
                is_dds = lowercase(m.captures[2]) == "dds"

                @info "Trovato potenziale tile orfano: $filename"

                # 1. Dobbiamo dedurre il size_id leggendo le dimensioni del file
                success, width, _ = is_dds ? Commons.getDDSSize(source_path) : Commons.getPNGSize(source_path)
                if !success
                    @warn "Impossibile leggere le dimensioni del file orfano $filename, lo ignoro."
                    continue
                end

                size_id = Commons.getSizeFromWidth(width)
                if size_id === nothing
                    @warn "Dimensioni non standard per il file orfano $filename, lo ignoro."
                    continue
                end

                # 2. Ricostruisci i metadati minimi necessari per place_tile!
                lonC, latC, lonLL, latLL, xidx, yidx, _, _ = Commons.coordFromIndex(tile_id)
                _, cols = Commons.getSizeAndCols(size_id)
                lon_step = Commons.tileWidth(latC)
                tile_meta = Commons.TileMetadata(tile_id, size_id, lonLL, latLL, lonLL + lon_step, latLL + 0.125, xidx, yidx, lonC, latC, lon_step, width, cols)

                # 3. Chiama la funzione di posizionamento
                @info "Tentativo di recupero e posizionamento per tile ID $tile_id..."
                if ddsFindScanner.place_tile!(source_path, tile_meta, root_path, save_path, cfg)
                    recovered_count += 1
                    @info "Recupero tile ID $tile_id completato con successo."
                else
                    @warn "Posizionamento del tile orfano ID $tile_id fallito."
                end
            end
        end
        if recovered_count > 0
            @info "GeoEngine: Recuperati e posizionati con successo $recovered_count tile orfani."
        else
            @info "GeoEngine: Nessun tile orfano da recuperare trovato."
        end
    catch e
        @error "Errore durante il processo di recupero dei tile orfani" exception=(e, catch_backtrace())
    end
end


end # module GeoEngine

