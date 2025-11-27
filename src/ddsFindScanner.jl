#=
Module: ddsFindScanner
Description: Scans directories for DDS/PNG files matching a specific naming convention,
             maintains a persistent index, allows searching by ID, and moving files
             between 'Orthophotos' and 'Orthophotos-saved' directories.
Author: abassign@gmail.com
License: GPL 2
Date 2025-06-01
=#

module ddsFindScanner

PROGRAM_VERSION = "0.1.0"

using ..Commons
using ..AppLogger
using ..ScanDir
using ..DetailScore


using JSON
using FilePathsBase
using LightXML
using Random: shuffle

# --- Exports ---
# Functions made available when this module is used by other code
export startFind, find_file_by_id, moveImage, set_data_file_path!, syncScan, printStats, place_tile!, generate_coverage_json, has_suitable_tile, get_tile_score
export get_total_indexed_size_bytes, get_all_indexed_records, update_path_in_index

# Global Variable for scan interval
const SCAN_INTERVAL_S = Ref(60) # Default to 60 seconds
# Number of files to randomly check at startup to validate the index.
const QUICK_CHECK_SAMPLE_SIZE = 100
# If the percentage of inconsistent files (missing or modified) exceeds this threshold,
# the entire index will be regenerated.
const QUICK_CHECK_FAILURE_THRESHOLD_PERCENT = 1.0

const SCORE_CACHE = Dict{Tuple{String,Int64}, Tuple{Float64,Int}}()
const SCORE_LOCK  = ReentrantLock()

const SKIP_NOACCESS = e -> begin
    dir = hasproperty(e, :path) ? getproperty(e, :path) :
          hasproperty(e, :file) ? getproperty(e, :file) :
          "(unknown path)"
    @warn "ddsFindScanner.Skipping inaccessible directory: $dir — $(e.msg)"
end

using Dates

const DEFAULT_METADATA = Dict(
    "version"    => "1.0",
    "last_scan"  => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    )
const _is_scanning = Ref(false)
const _last_scan_duration = Ref{Int}(0)

using Logging
using Printf


@static if Base.isdefined(Main, :AppLogger) && Main.AppLogger.logger[] !== nothing
    Logging.global_logger(Main.AppLogger.logger[])
end

macro dinfo(msg)
    esc(quote
        local _f = (@isdefined __FUNCTION__) ? __FUNCTION__ : nothing
        @info $msg _func=_f
    end)
end

macro dwarn(msg)
    esc(quote
        local _f = (@isdefined __FUNCTION__) ? __FUNCTION__ : nothing
        @warn $msg _func=_f
    end)
end

macro derror(msg)
    esc(quote
        try
            local _f = (@isdefined __FUNCTION__) ? __FUNCTION__ : nothing
            @error $msg _func=_f
        catch log_e
            println(stderr, "ddsFindScanner.derror: LOGGER FAILURE: ", log_e)
        end
    end)
end


# --- Global State ---

# Thread lock for safe concurrent access to shared data
const _data_lock = ReentrantLock()
const _coverage_lock = ReentrantLock()
# In-memory dictionary holding information about found files (path -> details)
const _existing_data = Dict{String, Any}()
# Boolean flag to control the background update loop
const _should_continue = Ref{Bool}(true)

# --- Configuration ---

# Filename for storing the persistent file index
const _data_file = Ref("dds_files.json")
const data_file = _data_file[]
# List of root directories to scan for files
const directories = begin
    dirs = [homedir()] # Start with the user's home directory
    # Add common mount points if they exist
    isdir("/media") && push!(dirs, "/media")
    isdir("/mnt") && push!(dirs, "/mnt")
    dirs
end


# --- Utility Functions ---


function get_score_complex(path::String;
                           min_samples::Int=150, max_samples::Int=2000, batch::Int=100,
                           gedge::Int=25, tol_rel::Float64=0.06)

    mt  = isfile(path) ? Int64(mtime(path)) : 0
    key = (path, mt)

    if haskey(SCORE_CACHE, key)
        sc, ns = SCORE_CACHE[key]
        return sc, ns
    end

    r = detail_score_file(path; min_samples=min_samples, max_samples=max_samples,
                          batch=batch, gedge=gedge, tol_rel=tol_rel)
    lock(SCORE_LOCK) do
        SCORE_CACHE[key] = (r.score, r.samples)
    end
    return r.score, r.samples
end


function set_data_file_path!(path::String)
    _data_file[] = path
    @dinfo "Index file path set to: $(_data_file[])"
end


function find_all_versions_by_id(id::Int)
    matches = []
    lock(_data_lock) do
        for (path, record) in _existing_data
            if get(record, "id", -1) == id
                push!(matches, record) # Adds the entire record (Dict)
            end
        end
    end
    return matches
end


"""
    get_total_indexed_size_bytes() -> Int64
Returns the total size in bytes of all indexed DDS/PNG files.
"""
function get_total_indexed_size_bytes()::Int64
    total_size_bytes = 0
    lock(_data_lock) do
        for (_, record) in _existing_data
            total_size_bytes += get(record, "size", 0)
        end
    end
    return total_size_bytes
end

"""
    get_all_indexed_records() -> Vector{Dict}
Returns a vector of all file records (including path and metadata).
"""
function get_all_indexed_records()::Vector{Dict}
    records = []
    lock(_data_lock) do
        for (path, record) in _existing_data
            # Create a full record including the path key
            full_record = copy(record)
            full_record["path"] = path # Include the path in the record copy
            push!(records, full_record)
        end
    end
    return records
end

"""
    update_path_in_index(old_path::String, new_path::String)

Updates the file index to reflect a change in file location.
Requires holding the lock outside or modifying the implementation (using lock inside for safety).
"""
function update_path_in_index(old_path::String, new_path::String)
    lock(_data_lock) do
        if haskey(_existing_data, old_path)
            record = delete!(_existing_data, old_path)
            _existing_data[new_path] = record
            @dinfo "ddsFindScanner: Index updated from $old_path to $new_path."

            # Save the updated index immediately after a successful move
            save_data(DEFAULT_METADATA, _existing_data)
        else
            @dwarn "ddsFindScanner: Cannot update path for $old_path, not found in index."
        end
    end
end


"""
    _validate_index_consistency(file_data::Dict{String, Any}) -> Tuple{Bool, Float64}

Performs a quick consistency check on a sample of index entries.
Verifies if files still exist and if their modification date has not changed.

# Arguments
- `file_data`: The file dictionary loaded from `dds_files.json`.

# Returns
A tuple `(is_consistent, mismatch_percentage)` where:
- `is_consistent`: `true` if the discrepancy percentage is below the threshold.
- `mismatch_percentage`: The percentage of inconsistent files found in the sample.
"""
function _validate_index_consistency(file_data::AbstractDict)::Tuple{Bool, Float64}
    num_files_in_index = length(file_data)
    if num_files_in_index == 0
        return (true, 0.0) # An empty index is always consistent.
    end

    # Determine the actual sample size to check
    sample_size = min(QUICK_CHECK_SAMPLE_SIZE, num_files_in_index)

    # Extract a random sample of paths from the index
    all_paths = collect(keys(file_data))
    # `shuffle!` modifies the array in place, so we use a copy.
    sample_paths = first(shuffle(copy(all_paths)), sample_size)

    inconsistent_count = 0
    @info "ddsFindScanner: Running Quick Check on $sample_size files (out of $num_files_in_index total)..."

    for path in sample_paths
        record = file_data[path]

        # 1. Check if the file still exists
        if !isfile(path)
            inconsistent_count += 1
            continue # Useless to check further if the file is missing
        end

        # 2. Check if the modification date matches
        try
            saved_mtime_str = get(record, "last_modified", "")
            # The stat() function can fail if the file is deleted in the meantime
            current_mtime_dt = Dates.unix2datetime(stat(path).mtime)
            saved_mtime_dt = Dates.DateTime(saved_mtime_str, "yyyy-mm-dd HH:MM:SS")

            # Compare with a 1 second tolerance to avoid precision issues
            if abs(saved_mtime_dt - current_mtime_dt) > Millisecond(1000)
                inconsistent_count += 1
            end
        catch e
            # If `stat` fails or date parsing fails, consider it inconsistent.
            @warn "ddsFindScanner: Error checking file '$path' in Quick Check." exception=(e, catch_backtrace())
            inconsistent_count += 1
        end
    end

    mismatch_percentage = (inconsistent_count / sample_size) * 100.0
    is_consistent = mismatch_percentage <= QUICK_CHECK_FAILURE_THRESHOLD_PERCENT

    if !is_consistent
        @warn "ddsFindScanner: Quick Check failed. Detected a mismatch of $(@sprintf("%.1f", mismatch_percentage))%."
    else
        @info "ddsFindScanner: Quick Check passed. The index is consistent."
    end

    return (is_consistent, mismatch_percentage)
end


"""
    _extract_id_from_filename(path::String) -> Union{Int, Nothing}

Extracts the numeric ID (expected to be the part before the first dot)
from a filename. Returns `nothing` if parsing fails.
"""
function _extract_id_from_filename(path::String)
    filename = basename(path)
    # Extract the part before the first dot
    name_part = split(filename, '.')[1]
    try
        # Attempt to parse the extracted part as an integer
        return parse(Int, name_part)
    catch
        # Return nothing if parsing fails (e.g., filename doesn't start with digits)
        return nothing
    end
end


"""
Gathers file metadata including dimensions, size, ID, modification time,
sizeId, and the new detail score.
Returns a tuple: (isValid, path, size, id, last_modified_str, sizeId, width, height, score)
`isValid` is true if dimensions could be read.
"""
function get_file_info(path::String, isDDS::Bool = false, isPNG::Bool = false)
    try
        stat_info = stat(path)
        size = stat_info.size
        id = _extract_id_from_filename(path)
        dimension = (false, 0, 0)

        if isDDS
            dimension = Commons.getDDSSize(path)
            elseif isPNG
            dimension = Commons.getPNGSize(path)
        end

        if dimension[1]
            width = dimension[2]
            height = dimension[3]
            sizeId = Commons.getSizeFromWidth(width)

            # Calculate score only for valid files with dimensions.
            # Use default values for min_samples to not slow down scanning too much.
            score_result = detail_score_file(path; min_samples=150, max_samples=1000)
            score = score_result.score

            if sizeId === nothing
                # Return a tuple with the correct number of elements
                return (false, path, 0, nothing, "", -1, 0, 0, -1.0)
            end

            last_modified = Dates.format(Dates.unix2datetime(stat_info.mtime), "yyyy-mm-dd HH:MM:SS")
            # Add score to the returned tuple
            return (true, path, size, id, last_modified, sizeId, width, height, score)
        else
            return (false, path, 0, nothing, "", -1, 0, 0, -1.0)
        end
    catch e
        @dinfo "Error getting file info for $path: $e"
        return (false, path, 0, nothing, "", -1, 0, 0, -1.0)
    end
end

# --- Core Functionality ---

"""
    find_file_by_id(id::Int, sizeId::Union{Int,Nothing}=nothing; verbose::Bool=false) -> Vector{String}

Searches the in-memory index (`_existing_data`) for files matching the given `id`.
Optionally filters by `sizeId`. Prints results if `verbose` is true.

Returns a vector of matching file paths.
"""
function find_file_by_id(id::Int, sizeId::Union{Int,Nothing}=nothing; verbose::Bool=false)
    matches = String[]
    lock(_data_lock) do # Ensure thread-safe access to the dictionary
        for (path, record) in _existing_data
            # Extract ID and sizeId from the record, providing defaults if keys are missing
            file_id = get(record, "id", -1) # Use -1 as a sentinel for missing ID
            # Use -1 as a sentinel for missing sizeId; 0 is a valid sizeId
            file_size_id = get(record, "sizeId",-1)
            # Debugging output if verbose mode is enabled
            verbose && @dinfo "Checking: $path | ID: $file_id | SizeID: $file_size_id | Target ID: $id | Target SizeID: $sizeId"
            # Check if the file ID matches the target ID
            match_id = (file_id === id)
            # Check if sizeId matches: either no sizeId filter is applied (sizeId === nothing)
            # or the file's sizeId matches the target sizeId.
            match_size = (sizeId === nothing) || (file_size_id == sizeId)
            # If both ID and size (if specified) match, add the path to the results
            if match_id && match_size
                push!(matches, path)
            end
        end
    end # lock released here

    # Print summary if verbose mode is enabled
    if verbose
        if isempty(matches)
            # Construct appropriate "not found" message
            msg = sizeId === nothing ?
                "No files found for ID $id (any sizeId)" :
                "No files found for ID $id and sizeId $sizeId"
            @dinfo ("ddsFindScanner.find_file_by_id: $(msg)")
        else
            # Construct "found" message
            count = length(matches)
            size_info = sizeId === nothing ? "with any sizeId" : "with sizeId $sizeId"
            @dinfo ("ddsFindScanner.find_file_by_id: Found $count file(s) for ID $id $size_info:")
            # List the found files with their sizeId
            for (i, p) in enumerate(matches)
                # Safely access sizeId from the record for display
                record_size_id = lock(_data_lock) do
                    get(_existing_data[p], "sizeId", "N/A") # Display N/A if missing
                end
                @dinfo ("ddsFindScanner.find_file_by_id: [$i] [sizeId:$record_size_id] $p")
            end
        end
    end

    return matches
end


"""
    _print_statistics(data::Dict{String, Any})

Calculates and prints statistics about the files in the index, including
total size and counts per sizeId.
"""
function _print_statistics(data::Dict{String, Any})
    # Initialize counts for each expected sizeId (0 through 5)
    size_id_counts = Dict(i => 0 for i in 0:5)
    total_size_bytes = 0

    # Iterate through the indexed files
    for (_, record) in data
        # Accumulate total size
        total_size_bytes += get(record, "size", 0) # Add file size, default to 0 if missing

        # Count files per sizeId
        if haskey(record, "sizeId")
            size_id = record["sizeId"]
            # Increment count if size_id is within the expected range
            if size_id in keys(size_id_counts)
                size_id_counts[size_id] += 1
            end
            # Optionally handle unexpected sizeIds here (e.g., log a warning)
        end
    end

    # Convert total size to Megabytes for readability
    total_size_mb = total_size_bytes / (1024 * 1024)

    # Print the calculated statistics
    println(@sprintf("Total indexed files size: %.2f MB", total_size_mb))
    # Format the counts per sizeId string
    size_counts_str = join(["s$k: $(size_id_counts[k])" for k in sort(collect(keys(size_id_counts)))], ", ")
    println("File counts by sizeId: ", size_counts_str)
end


"""
    _periodic_update()

Runs in a background task, periodically rescanning directories, updating
the in-memory index, saving it to disk, and printing statistics.
Continues until `_should_continue` is set to false.
"""
function _periodic_update(scan_paths::Vector{String}, program_version::String)
    # Create a logger that appends to a 'scanner.log' file
    logger = SimpleLogger(open("scanner.log", "a"))

    # First message to know the task has started
    with_logger(logger) do
        @dinfo "ddsFindScanner._periodic_update: The Background scanning process will start in $(SCAN_INTERVAL_S[]) sec."
    end

    while _should_continue[]
        try
            # All loop logic is executed with the logger set to the file
            with_logger(logger) do
                @dinfo "ddsFindScanner._periodic_update: Starting new scan cycle..."

                # The scan_directories function is now quieter
                files_from_scan, dds_count, png_count = scan_directories(scan_paths)
                @dinfo "ddsFindScanner._periodic_update: Scan complete. Found $dds_count DDS, $png_count PNG files."

                added_count = 0
                updated_count = 0

                lock(_data_lock) do
                    # update_data now returns counts instead of printing
                    added_count, updated_count = update_data(_existing_data, files_from_scan)

                    @dinfo "ddsFindScanner._periodic_update: Index update: $added_count new, $updated_count updated."

                    # Save index only if there were changes
                    if added_count > 0 || updated_count > 0
                        @dinfo "ddsFindScanner._periodic_update: Saving index to $(_data_file[])..."
                        current_metadata = Dict(
                            "program_version" => program_version,
                            "scanned_paths"   => scan_paths,
                            "last_scan"       => Dates.now(),
                            )
                        save_data(current_metadata, _existing_data)
                        @dinfo "ddsFindScanner._periodic_update: Index saved."
                    else
                        @dinfo "ddsFindScanner._periodic_update: No changes to the index. Skipping save."
                    end
                end # end of lock

                @dinfo "ddsFindScanner._periodic_update: Update cycle finished at $(Dates.format(Dates.now(), "HH:MM:SS"))."
            end # end of with_logger
            catch e
                # Errors are also written to the log file
                with_logger(logger) do
                    @error "ddsFindScanner._periodic_update: Critical error during periodic update." exception=(e, catch_backtrace())
            end
        end
        @dinfo "ddsFindScanner._periodic_update: The Background scanning process will start in $(SCAN_INTERVAL_S[])  sec."
        sleep(SCAN_INTERVAL_S[])
    end

    with_logger(logger) do
        @dinfo "ddsFindScanner._periodic_update: Background scanner task stopped."
    end
end


"""
    scan_directories(directories::Vector{String}) -> Tuple{Vector, Int, Int}

Scans the specified `directories` recursively. Looks for files within subdirectories
containing '/Orthophotos/' or '/Orthophotos-saved/' in their path.
Collects info for files matching the pattern `ddddddd.(dds|DDS|png|PNG)`.

Returns:
- A vector of tuples, where each tuple contains file info:
  `(path, size, id, last_modified_str, sizeId, width, height)`
- Count of valid DDS files found.
- Count of valid PNG files found.
"""
function scan_directories(dirs_to_scan::Vector{String})
    file_data = Vector{Tuple{String, Int64, Int64, String, Int64, Int64, Int64, Float64}}()
    dds_count = 0
    png_count = 0

    for dir in dirs_to_scan
        try
            for (root, _, files) in walkdir(dir; onerror = SKIP_NOACCESS)
                path_components = splitpath(root)
                if ("Orthophotos" in path_components) || ("Orthophotos-saved" in path_components)
                    for file in files
                        full_path = joinpath(root, file)
                        is_dds = endswith(lowercase(file), ".dds")
                        is_png = endswith(lowercase(file), ".png")
                        filename_pattern_match = match(r"^\d{7}\.(dds|DDS|png|PNG)$", file) !== nothing
                        if (is_dds || is_png) && filename_pattern_match
                            info = get_file_info(full_path, is_dds, is_png)
                            if info[1]
                                # Now we take 8 elements (up to score)
                                push!(file_data, info[2:9]) # MODIFIED: from 2:8 to 2:9
                                is_dds ? (dds_count += 1) : (png_count += 1)
                            end
                        end
                    end
                end
            end
        catch e
            @error "ddsFindScanner.scan_directories: Directory scan error for $(dir): $(e)"
        end
    end
    return file_data, dds_count, png_count
end


"""
generate_coverage_json()

Generates the `coverage.json` file for web visualization. Applies a logic of
priority to show only the most relevant version of each tile:
1. Tiles in /Orthophotos/ folder always take precedence over those in /Orthophotos-saved/.
2. Given the same location, the version with the highest resolution (`sizeId`) is chosen.
The generated file includes ID, BBOX, sizeId and modification date for each tile.
"""
function generate_coverage_json()
    @info "ddsFindScanner: Starting coverage.json generation with priority logic..."

    # Internal helper function to calculate BBOX (unchanged)
    function get_tile_bbox_from_id(tile_id::Int)
        _, _, lon_base, lat_base, x, y, _, _ = Commons.coordFromIndex(tile_id)
        lat_ref = lat_base + (y * 0.125) + 0.0625
        width = Commons.tileWidth(lat_ref)
        lonLL = lon_base + x * width; latLL = lat_base + y * 0.125
        lonUR = lonLL + width; latUR = latLL + 0.125
        return (latLL=latLL, lonLL=lonLL, latUR=latUR, lonUR=lonUR)
    end

    # Dictionary to track the best candidate for each tile_id
    tile_candidates = Dict{Int, Dict{String, Any}}()

    lock(_data_lock) do
        for (path, record) in _existing_data
            tile_id = get(record, "id", nothing)
            size_id = get(record, "sizeId", nothing)
            # Read date, with a default value for safety
            last_mod = get(record, "last_modified", "1970-01-01 00:00:00")

            detail_score = get(record, "detail_score", -1.0)
            (tile_id === nothing || size_id === nothing) && continue

            is_in_ortho = occursin("/Orthophotos/", path) && !occursin("/Orthophotos-saved/", path)

            # Create current candidate record, including date
            current_candidate = Dict(
                "sizeId" => size_id,
                "isInOrtho" => is_in_ortho,
                "last_modified" => last_mod,
                "detail_score"  => detail_score
                )

            if !haskey(tile_candidates, tile_id)
                # If it's the first one found, add it as candidate
                tile_candidates[tile_id] = current_candidate
            else
                # If we already have a candidate, apply priority rules
                existing_candidate = tile_candidates[tile_id]

                # RULE 1: The new one is in Orthophotos, the old one is not -> the new one wins.
                if current_candidate["isInOrtho"] && !existing_candidate["isInOrtho"]
                    tile_candidates[tile_id] = current_candidate
                    # RULE 2: Both are in the same "zone" -> highest resolution wins.
                    elseif current_candidate["isInOrtho"] == existing_candidate["isInOrtho"]
                    if current_candidate["sizeId"] > existing_candidate["sizeId"]
                        tile_candidates[tile_id] = current_candidate
                    end
                end
            end
        end
    end

    # Build final output based on chosen candidates
    output_data = []
    for (tile_id, info) in tile_candidates
        push!(output_data, Dict(
            "id"            => tile_id,
            "bbox"          => get_tile_bbox_from_id(tile_id),
            "sizeId"        => info["sizeId"],
            "last_modified" => info["last_modified"],
            "detail_score"  => info["detail_score"]
            ))
    end

    @info "ddsFindScanner: Writing $(length(output_data)) unique tiles to coverage.json..."
    try
        lock(_coverage_lock) do
            open("coverage.json", "w") do f
                JSON.print(f, output_data)
            end
        end
        @info "ddsFindScanner: Report 'coverage.json' successfully updated! ✅ (Path: $(abspath("coverage.json")))"
    catch e
        @error "ddsFindScanner: Unable to write coverage.json file" exception=(e, catch_backtrace())
    end
end


"""
load_data(file_path::String) -> (Union{Dict, Nothing}, Dict{String, Any})

Loads the persistent index. Returns a tuple: (metadata, file_data).
Returns (nothing, empty_dict) if the file doesn't exist or is invalid.
    """
function load_data()
    file_path = _data_file[] # Use global path
    if isfile(file_path)
        try
            @dinfo "ddsFindScanner.load_data: Loading existing data from $(file_path)..."
            json_data = JSON.parsefile(file_path)
            # Check that structure is as expected
            if haskey(json_data, "metadata") && haskey(json_data, "files")
                @dinfo "ddsFindScanner.load_data: Data loaded successfully."
                return (json_data["metadata"], json_data["files"])
            else
                @dinfo "ddsFindScanner.load_data: Warning: Invalid index format in $(file_path). Rebuilding."
                return (nothing, Dict{String, Any}())
            end
            catch e
            @dinfo "ddsFindScanner.load_data: Error loading data from $(file_path): $e. Rebuilding."
            return (nothing, Dict{String, Any}())
        end
    else
        @dinfo "ddsFindScanner.load_data: Data file $(file_path) not found. Starting with empty index."
        return (nothing, Dict{String, Any}())
    end
end


"""
Saves the metadata and file index to a JSON file and automatically
triggers the regeneration of the web coverage report.
"""
function save_data(metadata::Dict, file_data::Dict{String, Any})
    file_path = _data_file[]
    full_data = Dict(
        "metadata" => metadata,
        "files" => file_data
    )
    try
        # Save main index
        open(file_path, "w") do io
            JSON.print(io, full_data, 4)
        end

        # --- AUTOMATIC UPDATE ---
        # After saving, launch coverage.json generation
        # in an asynchronous task to not block current operation.
        @info "ddsFindScanner.save_data: Main index saved. Starting coverage.json regeneration..."
        @async generate_coverage_json()

    catch e
        @error "ddsFindScanner.save_data: Error saving data to $file_path: $e"
    end
end


"""
save_index()

Wrapper around `save_data` that uses the default `data_file` and `_existing_data`.
"""
function save_index()
    lock(_data_lock) do
        save_data(DEFAULT_METADATA, _existing_data)
    end
end


"""
    update_data(existing_data::Dict{String, Any}, new_scan_results::Vector{Tuple})

Updates the `existing_data` dictionary based on `new_scan_results`.
Adds new files and updates existing entries if the modification time is newer.

`new_scan_results` is a vector of tuples:
`(path, size, id, last_modified_str, sizeId, width, height)`
"""
function update_data(existing_data::Dict{String, Any}, new_scan_results::Vector)
    updated_count = 0
    added_count = 0

    # Add 'score' to the list of variables extracted from the tuple
    for (path, size, id, last_modified_str, sizeId, width, height, score) in new_scan_results
        new_record = Dict(
            "id" => id,
            "size" => size,
            "last_modified" => last_modified_str,
            "sizeId" => sizeId,
            "width" => width,
            "height" => height,
            "detail_score" => score
        )

        if haskey(existing_data, path)
            # Update logic based on mtime does not change
            existing_last_modified_str = existing_data[path]["last_modified"]
            try
                parsed_existing = Dates.DateTime(existing_last_modified_str, "yyyy-mm-dd HH:MM:SS")
                parsed_new = Dates.DateTime(last_modified_str, "yyyy-mm-dd HH:MM:SS")
                if parsed_new > parsed_existing
                    existing_data[path] = new_record
                    updated_count += 1
                end
            catch e
                @error "ddsFindScanner.update_data: Error parsing timestamp for $(path). Skipping update. exception=$(e)"
            end
        else
            existing_data[path] = new_record
            added_count += 1
        end
    end
    return added_count, updated_count
end


"""
place_tile!(source_path, tile, rootPath, rootPath_saved)

Centralized and intelligent function to place a tile file.
1.  Checks if a file already exists at destination (`rootPath`).
2.  If it exists, moves it to the correct backup directory (`rootPath_saved`).
3.  Moves source file (`source_path`) to final destination.
4.  Updates file index in all phases.
"""
function place_tile!(
    source_path::String,
    tile::Commons.TileMetadata,
    rootPath::String,
    rootPath_saved::String,
    cfg::Dict
    )
    if !isfile(source_path)
        @warn "ddsFindScanner.place_tile: Source file not found: $source_path"
        return false
    end

    try
        dir10, dir1 = Commons.tile_dirs(tile.latLL, tile.lonLL)
        file_extension = splitext(source_path)[2]
        filename = "$(tile.id)$(file_extension)" # Correct final name
        final_dest_dir = joinpath(rootPath, dir10, dir1)
        final_dest_path = joinpath(final_dest_dir, filename)

        # If a file already exists at destination...
        if isfile(final_dest_path)
            overwrite_mode = get(cfg, "over", 1)

            # --- Overwrite logic block ---
            if overwrite_mode == 0
                @info "ddsFindScanner.place_tile: Tile $(tile.id) exists. Archiving new tile as per --over 0 rule."
                # Archive the new file instead of deleting it
                backup_dir = joinpath(rootPath_saved, string(tile.width), dir10, dir1)
                backup_path = joinpath(backup_dir, filename) # Use the correct final name
                mkpath(backup_dir)
                mv(source_path, backup_path, force=true)
                # (Optional: update index for archived file)
                return true
            end

            # If we are in over=1 or over=2, we must compare dimensions
            is_success, actual_width, _ = Commons.getDDSSize(final_dest_path)
            if !is_success; is_success, actual_width, _ = Commons.getPNGSize(final_dest_path); end

            # Debug checkpoint: print values before comparison
            println("--- DEBUG place_tile! ---")
            println("Tile ID: $(tile.id)")
            println("NEW tile width (tile.width): $(tile.width)")
            println("OLD tile width (actual_width): $(actual_width)")
            println("Overwrite Mode: $overwrite_mode")
            println("-------------------------")

            if !is_success
                @warn "Unable to read existing file at '$(final_dest_path)'. It will be removed."
                try; rm(final_dest_path, force=true); catch e; @error "Unable to remove corrupt file" exception=(e, catch_backtrace()); end
            else
                if overwrite_mode == 1 && tile.width <= actual_width
                    @info "Existing tile ($actual_width px) is better or equal. Archiving new tile ($tile.width px)."

                    backup_dir = joinpath(rootPath_saved, string(tile.width), dir10, dir1)
                    backup_path = joinpath(backup_dir, filename)
                    mkpath(backup_dir)
                    mv(source_path, backup_path, force=true)
                    # (Optional: update index)
                    return true
                end

                # If we are here, we must overwrite. Move old file to backup.
                @info "Backing up existing file from '$final_dest_path'..."
                backup_dir = joinpath(rootPath_saved, string(actual_width), dir10, dir1)
                backup_path = joinpath(backup_dir, filename)
                mkpath(backup_dir)
                mv(final_dest_path, backup_path, force=true)

                lock(_data_lock) do
                    if haskey(_existing_data, final_dest_path)
                        record = delete!(_existing_data, final_dest_path)
                        _existing_data[backup_path] = record
                    end
                end
            end
        end

        # At this point, final destination is free. Move new file.
        @info "Placing and renaming file from '$source_path' to '$final_dest_path'."
        mkpath(final_dest_dir)
        mv(source_path, final_dest_path, force=true)

        # Update index with new file
        score_result = detail_score_file(final_dest_path; min_samples=150, max_samples=1000)
        score = score_result.score
        lock(_data_lock) do
            stat_info = stat(final_dest_path)
            _existing_data[final_dest_path] = Dict(
                "id"             => tile.id,
                "size"           => stat_info.size,
                "last_modified"  => Dates.format(now(), "yyyy-mm-dd HH:MM:SS"),
                "sizeId"         => tile.size_id,
                "width"          => tile.width,
                "height"         => tile.width,
                "detail_score"   => score
            )
            save_data(DEFAULT_METADATA, _existing_data)
        end
        return true
    catch e
        @error "Error placing tile" exception=(e, catch_backtrace())
        return false
    end
end

function moveImage(rootPath::String, rootPath_saved::String, id::Int, target_sizeId::Int, cfg::Dict)
    @info "ddsFindScanner.moveImage: Searching tile from cache for ID $id, sizeId $target_sizeId"

    # [Logic to find "best_candidate" remains the same]
    candidates = Tuple{String, Dict}[]
    lock(_data_lock) do
        for (path, record) in _existing_data
            if get(record, "id", -1) == id && get(record, "sizeId", -1) == target_sizeId
                push!(candidates, (path, record))
            end
        end
    end

    if isempty(candidates)
        @info "ddsFindScanner.moveImage: No candidate found."
        return "not_found"
    end

    sort!(candidates, by = x -> get(x[2], "last_modified", ""), rev=true)
    candidate_path, candidate_record = candidates[1]

    # Create a temporary TileMetadata object with necessary info
    # for place_tile! function
    lon, lat, _, _, _, _, _, _ = Commons.coordFromIndex(id)
    width = get(candidate_record, "width", 0)
    cols_params = Commons.getSizeAndCols(target_sizeId)
    cols = cols_params === nothing ? 1 : cols_params[2]

    temp_tile_meta = Commons.TileMetadata(
        id, target_sizeId, lon, lat, 0.0, 0.0, 0, 0, 0.0, 0.0, 0.0, width, cols
        )

    # Call new centralized function to do the heavy lifting
    success = place_tile!(candidate_path, temp_tile_meta, rootPath, rootPath_saved, cfg)

    return success ? "moved" : "error"
end


"""
startFind(scan_paths::Vector{String}, program_version::String)

Initializes the scanner. Automatically decides whether to load the existing
index or trigger a full rebuild based on metadata comparison.
"""
function startFind(scan_paths::Vector{String}, program_version::String)

    # Reads scan interval from params.xml
    try
        if isfile("params.xml")
            xdoc = parse_file("params.xml")
            settings_node = find_element(root(xdoc), "settings")
            if settings_node !== nothing
                interval_node = find_element(settings_node, "scan_interval_seconds")
                if interval_node !== nothing
                    SCAN_INTERVAL_S[] = parse(Int, content(interval_node))
                end
            end
        end
    catch e
        @warn "Unable to read 'scan_interval_seconds' from params.xml. Default of 300s will be used." exception=(e, catch_backtrace())
        SCAN_INTERVAL_S[] = 300 # Restore default in case of error
    end

    @dinfo ("ddsFindScanner.startFind: Initializing ddsFindScanner...")

    rebuild_needed = false
    rebuild_reason = ""

    metadata, file_data = load_data()

    if metadata === nothing
        rebuild_needed = true
            rebuild_reason = "Index file not found or invalid."
    else
        if get(metadata, "program_version", "") != program_version
            rebuild_needed = true
                rebuild_reason = "Program version has changed."
        elseif Set(get(metadata, "scanned_paths", [])) != Set(scan_paths)
            rebuild_needed = true
            rebuild_reason = "Scan paths have changed."
        else
            # --- QUICK CHECK BLOCK ---
            # Metadata is valid, now running a quick consistency check.
            is_consistent, mismatch_percent = _validate_index_consistency(file_data)
            if !is_consistent
                rebuild_needed = true
                rebuild_reason = "Index is stale (mismatch of $(@sprintf("%.1f", mismatch_percent))% detected)."
            end
            # If 'is_consistent' is true, 'rebuild_needed' remains false and we proceed
            # with quick loading.
        end
    end

    lock(_data_lock) do
        empty!(_existing_data)
        if rebuild_needed
            @dinfo ("ddsFindScanner.startFind: REBUILDING INDEX: $rebuild_reason")
            @dinfo ("ddsFindScanner.startFind: Performing initial synchronous scan...")
            files_from_sync_scan, _, _ = scan_directories(scan_paths)
            update_data(_existing_data, files_from_sync_scan)

            @dinfo ("ddsFindScanner.startFind: Performing initial synchronous save of the new index...")
            current_metadata = Dict(
                "program_version" => program_version,
                "scanned_paths"   => scan_paths,
                "last_scan"       => Dates.now(),
                )
            save_data(current_metadata, _existing_data)

            @dinfo ("ddsFindScanner.startFind: Initial save complete. The file dds_files.json is now available.")
        else
            @dinfo ("ddsFindScanner.startFind: Index is up-to-date. Loading data into memory.")
            merge!(_existing_data, file_data)
        end

        @dinfo ("ddsFindScanner.startFind: Initial statistics:")
        _print_statistics(_existing_data)
    end

    @dinfo ("ddsFindScanner.startFind: Starting background update task for long-running sessions...")
    @async _periodic_update(scan_paths, program_version)

    @dinfo ("ddsFindScanner.startFind: [OK] Scanner service is active in the background.")
    return
end


"""
startFind()

Convenience wrapper:
* scans Home and /mnt
* uses `PROGRAM_VERSION` constant
"""
function startFind()
    lock(_data_lock) do
        _is_scanning[] = true
    end
    scan_start_time = time_ns()

    try
        # Performs the actual scan
        syncScan()  # synchronous scan

        scan_end_time = time_ns()
        scan_duration_ms = (scan_end_time - scan_start_time)/1000000

        lock(_data_lock) do
            _last_scan_duration[] = scan_duration_ms
        end

        @info "ddsFindScanner.startFind(): Scan completed in $scan_duration_ms ms"
    finally
        lock(_data_lock) do
            _is_scanning[] = false
        end
    end
end


"""
has_suitable_tile(id, target_sizeId, rootPath, savePath, cfg) -> Bool

Performs a "read-only" check to determine if a suitable tile
already exists in `rootPath` or `savePath`, based on `--over` logic.
Does not move any file.
"""
function has_suitable_tile(id::Int, target_sizeId::Int, rootPath::String, savePath::String, cfg::Dict)
    overwrite_mode = get(cfg, "over", 1) # Default to 1 (overwrite if better)

    # Find all existing versions of the tile, wherever they are
    all_versions = find_all_versions_by_id(id)
    if isempty(all_versions)
        return false # Does not exist, so it is not "suitable"
    end

    # Find version with highest resolution among existing ones
    best_existing = sort(all_versions, by = v -> get(v, "sizeId", -1), rev=true)[1]
    best_existing_sizeId = get(best_existing, "sizeId", -1)

    if overwrite_mode == 0
        # Never overwrite: if it exists (at any resolution), it is "suitable".
        return true
        elseif overwrite_mode == 1
        # Overwrite only if new is better: "suitable" if existing is >= new.
        return best_existing_sizeId >= target_sizeId
        elseif overwrite_mode == 2
        # Always overwrite: no existing file is "suitable" to block a new download.
        return false
    end

    return false # Default
end


"""
getTailGroupByIndex(index::Int) -> Union{String, Nothing}

Returns the full path of the file associated with the numeric index.
Looks for an exact match between `index` and the ID extracted from filenames.
"""
function getTailGroupByIndex(index::Int)
    return find_file_by_id(index)
end


"""
getTailGroupByIndex(index::Int, path::String) -> Union{Tuple{String, Any}, Nothing}

Finds all files corresponding to the index and checks if any of them contains the given path.
    Returns a tuple (file path, nothing) or `nothing` if not found or not matching.
"""
function getTailGroupByIndex(index::Int, path::String)
    filepaths = find_file_by_id(index)
    if filepaths === nothing || isempty(filepaths)
        return nothing
    end

    for fp in filepaths
        if occursin(path, fp)
            return fp, nothing
        end
    end

    return nothing
end


"""
copyTilesByIndex(index::Int, dest_dir::String)

Copies the first available file associated with the given index to the destination folder.
"""
function copyTilesByIndex(index::Int, dest_dir::String)
    filepaths = find_file_by_id(index)
    if filepaths === nothing || isempty(filepaths)
        @warn "ddsFindScanner.copyTilesByIndex: No file path associated with index $index"
        return nothing
    end

    for path in filepaths
        if isfile(path)
            filename = basename(path)
            dest_path = joinpath(dest_dir, filename)
            cp(path, dest_path; force=true)
            @dinfo "ddsFindScanner.copyTilesByIndex: Copied file for index $index to $dest_path"
            return dest_path
        end
    end

    @warn "ddsFindScanner.copyTilesByIndex: No existing file found to copy for index $index"
    return nothing
end


"""
createFilesListTypeDDSandPNG() -> Vector{String}

Returns a list of all DDS and PNG files stored in the _existing_data map.
Useful for building photo scenery file lists.
"""
function createFilesListTypeDDSandPNG()
    lock(_data_lock) do
        return filter(p -> endswith(p, ".png") || endswith(p, ".dds"), keys(_existing_data)) |> collect
    end
end


"""
is_valid_orthophoto_path(path::String) -> Bool

Checks whether the path follows the expected tile directory structure like:
/e000n40/e009n44/nnnnnnn.dds
"""
function is_valid_orthophoto_path(path::String)::Bool
    # Convert to lowercase to be safe
    path = lowercase(path)

    # Match segments like /e000n40/e009n44/
    m = match(r"/[ew]\d{3}[ns]\d{2}/[ew]\d{3}[ns]\d{2}/", path)
    if m === nothing
        return false
    end

    # Match filename like 7-digit number + .dds or .png
    filename = basename(path)
    return occursin(r"^\d{7}\.(dds|png)$", filename)
end


"""
syncScan()

Performs a synchronous full scan of all configured directories.
This enhanced version gathers full image metadata (including pixel dimensions
and sizeId) for each file, creating a richer index.
"""
function syncScan()
    lock(_data_lock) do
        new_data = Dict{String, Any}()

        for dir in directories
            @info "ddsFindScanner.syncScan: Scanning directory: $dir"
            for (root, _, files) in walkdir(dir; onerror = SKIP_NOACCESS)
                # Filter only interesting folders for performance
                if !("Orthophotos" in splitpath(root))
                    continue
                end

                for file in files
                    fullpath = joinpath(root, file)

                    # Skip files that do not match our pattern
                    if isnothing(match(r"^\d+\.(dds|png)$"i, file))
                        continue
                    end

                    # Determine file type and call helper function
                    # which also reads pixel dimensions.
                    is_dds = endswith(lowercase(file), ".dds")
                    is_png = endswith(lowercase(file), ".png")

                    if is_dds || is_png
                        is_valid, _, size, id, last_modified, sizeId, width, height, score = get_file_info(fullpath, is_dds, is_png)

                        # Add record to index only if it is a valid image
                        if is_valid && id !== nothing
                            new_data[fullpath] = Dict(
                                "id"            => id,
                                "name"          => basename(fullpath),
                                "size"          => size,          # Size in bytes
                                "last_modified" => last_modified,
                                "sizeId"        => sizeId,        # Dimensional class 0..6
                                "width"         => width,
                                "height"        => height,
                                "detail_score"  => score
                            )
                        end
                    end
                end
            end
        end

        # Update global state and save to disk
        empty!(_existing_data)
        merge!(_existing_data, new_data)
        save_index()

        @info "ddsFindScanner.syncScan: Synchronous scan complete. Found $(length(_existing_data)) valid image entries."
    end
end


"""
get_tile_score(id::Int, size_id::Int) -> Float64

Searches index for specific tile by ID and sizeId and returns its
`detail_score`. Returns -1.0 if tile is not found or has no score.
"""
function get_tile_score(id::Int, size_id::Int)::Float64
    lock(_data_lock) do
        for (path, record) in _existing_data
            if get(record, "id", -1) == id && get(record, "sizeId", -1) == size_id
                return get(record, "detail_score", -1.0)
            end
        end
    end
    return -1.0 # Not found
end


function printStats()
    lock(_data_lock) do
        dds_count = 0
        png_count = 0
        dir_counts = Dict{String, Int}()

        for (filepath, details) in _existing_data
            if endswith(filepath, ".dds")
                dds_count += 1
                elseif endswith(filepath, ".png")
                png_count += 1
            end

            dir = dirname(filepath)
            dir_counts[dir] = get(dir_counts, dir, 0) + 1
        end

        scan_duration_ms = _last_scan_duration[]

        @info "DDS/PNG scan statistics:"
        @info "=============================="
        @info "Total DDS files found: $dds_count"
        @info "Total PNG files found: $png_count"
        @info "Last scan time: $scan_duration_ms ms"

        @info "Folder distribution (sorted):"
        for dir in sort(collect(keys(dir_counts)))
            count = dir_counts[dir]
            @info "• $dir: $count files"
        end
    end
end



@dinfo ("ddsFindScanner: module loaded. Call startFind() to begin.")

end # module
