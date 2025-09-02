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

using JSON
using FilePathsBase


# --- Exports ---
# Functions made available when this module is used by other code
export startFind, find_file_by_id, moveImage, set_data_file_path!, syncScan, printStats, place_tile!, generate_coverage_json, has_suitable_tile


const SKIP_NOACCESS = e -> begin
    dir = hasproperty(e, :path) ? getproperty(e, :path) :
          hasproperty(e, :file) ? getproperty(e, :file) :
          "(percorso sconosciuto)"
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


function set_data_file_path!(path::String)
    _data_file[] = path
    @dinfo "Index file path set to: $(_data_file[])"
end


function find_all_versions_by_id(id::Int)
    matches = []
    lock(_data_lock) do
        for (path, record) in _existing_data
            if get(record, "id", -1) == id
                push!(matches, record) # Aggiunge l'intero record (Dict)
            end
        end
    end
    return matches
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
    get_file_info(path::String, isDDS::Bool=false, isPNG::Bool=false) -> Tuple

Gathers file metadata including dimensions (using Commons module), size,
extracted ID, modification time, and calculated sizeId.

Returns a tuple: (isValid, path, size, id, last_modified_str, sizeId, width, height)
`isValid` is true if dimensions could be read.
"""
function get_file_info(path::String, isDDS::Bool = false, isPNG::Bool = false)

    try
        stat_info = stat(path)
        size = stat_info.size
        id = _extract_id_from_filename(path)
        dimension = (false, 0, 0) # Default invalid dimension

        if isDDS
            dimension = Commons.getDDSSize(path)
        elseif isPNG
            dimension = Commons.getPNGSize(path)
        end

        # Check if dimensions were successfully read
        if dimension[1]
            width = dimension[2]
            height = dimension[3]

            sizeId = Commons.getSizeFromWidth(width)
            if sizeId == nothing
                return (false, path, 0, nothing, "", -1, 0, 0)
            end

            last_modified = Dates.format(Dates.unix2datetime(stat_info.mtime), "yyyy-mm-dd HH:MM:SS")
            return (true, path, size, id, last_modified, sizeId, width, height)
        else
            # Dimensions could not be read
            return (false, path, 0, nothing, "", -1, 0, 0)
        end
    catch e
        @dinfo "Error getting file info for $path: $e"
        return (false, path, 0, nothing, "", -1, 0, 0)
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
    # Crea un logger che scrive in append su un file 'scanner.log'
    logger = SimpleLogger(open("scanner.log", "a"))

    # Primo messaggio per sapere che il task è partito
    with_logger(logger) do
        @dinfo "ddsFindScanner._periodic_update: Background scanner task started."
    end

    while _should_continue[]
        try
            # Tutta la logica del ciclo viene eseguita con il logger impostato sul file
            with_logger(logger) do
                @dinfo "ddsFindScanner._periodic_update: Starting new scan cycle..."

                # La funzione scan_directories ora è più silenziosa
                files_from_scan, dds_count, png_count = scan_directories(scan_paths)
                @dinfo "ddsFindScanner._periodic_update: Scan complete. Found $dds_count DDS, $png_count PNG files."

                added_count = 0
                updated_count = 0

                lock(_data_lock) do
                    # update_data ora ritorna i conteggi invece di stampare
                    added_count, updated_count = update_data(_existing_data, files_from_scan)

                    @dinfo "ddsFindScanner._periodic_update: Index update: $added_count new, $updated_count updated."

                    # Salva l'indice solo se ci sono stati cambiamenti
                    if added_count > 0 || updated_count > 0
                        @dinfo "ddsFindScanner._periodic_update: Saving index to $(_data_file[])..."
                        current_metadata = Dict(
                            "program_version" => program_version,
                            "scanned_paths" => scan_paths
                            )
                        save_data(Dict("last_scan" => Dates.now()), _existing_data)
                        @dinfo "ddsFindScanner._periodic_update: Index saved."
                    else
                        @dinfo "ddsFindScanner._periodic_update: No changes to the index. Skipping save."
                    end
                end # fine del lock

                @dinfo "ddsFindScanner._periodic_update: Update cycle finished at $(Dates.format(Dates.now(), "HH:MM:SS"))."
            end # fine del with_logger
            catch e
            # Anche gli errori vengono scritti sul file di log
            with_logger(logger) do
                @error "ddsFindScanner._periodic_update: Critical error during periodic update." exception=(e, catch_backtrace())
            end
        end
        sleep(60)
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
    file_data = Vector{Tuple{String, Int64, Int64, String, Int64, Int64, Int64}}()
    dds_count = 0
    png_count = 0

    for dir in dirs_to_scan
        # Il messaggio di scansione ora viene loggato da _periodic_update
        try
            for (root, _, files) in walkdir(dir; onerror = SKIP_NOACCESS)
                if occursin("/Orthophotos/", root) || occursin("/Orthophotos-saved/", root)
                    for file in files
                        full_path = joinpath(root, file)
                        is_dds = endswith(lowercase(file), ".dds")
                        is_png = endswith(lowercase(file), ".png")
                        filename_pattern_match = match(r"^\d{7}\.(dds|DDS|png|PNG)$", file) !== nothing

                        if (is_dds || is_png) && filename_pattern_match
                            info = get_file_info(full_path, is_dds, is_png)
                            if info[1]
                                push!(file_data, info[2:8])
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

Genera il file `coverage.json` per la visualizzazione web. Applica una logica di
priorità per mostrare solo la versione più rilevante di ogni tile:
1. I tile nella cartella /Orthophotos/ hanno sempre la precedenza su quelli in /Orthophotos-saved/.
2. A parità di locazione, viene scelta la versione con la risoluzione (`sizeId`) più alta.
Il file generato include l'ID, il BBOX, il sizeId e la data di modifica per ogni tile.
"""
function generate_coverage_json()
    @info "ddsFindScanner: Avvio generazione di coverage.json con logica di priorità..."

    # Funzione helper interna per calcolare il BBOX (invariata)
    function get_tile_bbox_from_id(tile_id::Int)
        _, _, lon_base, lat_base, x, y, _, _ = Commons.coordFromIndex(tile_id)
        lat_ref = lat_base + (y * 0.125) + 0.0625
        width = Commons.tileWidth(lat_ref)
        lonLL = lon_base + x * width; latLL = lat_base + y * 0.125
        lonUR = lonLL + width; latUR = latLL + 0.125
        return (latLL=latLL, lonLL=lonLL, latUR=latUR, lonUR=lonUR)
    end

    # Dizionario per tenere traccia del miglior candidato per ogni tile_id
    tile_candidates = Dict{Int, Dict{String, Any}}()

    lock(_data_lock) do
        for (path, record) in _existing_data
            tile_id = get(record, "id", nothing)
            size_id = get(record, "sizeId", nothing)
            # Leggiamo la data, con un valore di default per sicurezza
            last_mod = get(record, "last_modified", "1970-01-01 00:00:00")

            (tile_id === nothing || size_id === nothing) && continue

            is_in_ortho = occursin("/Orthophotos/", path) && !occursin("/Orthophotos-saved/", path)

            # Creiamo il record del candidato corrente, includendo la data
            current_candidate = Dict(
                "sizeId" => size_id,
                "isInOrtho" => is_in_ortho,
                "last_modified" => last_mod
                )

            if !haskey(tile_candidates, tile_id)
                # Se è il primo che troviamo, lo aggiungiamo come candidato
                tile_candidates[tile_id] = current_candidate
            else
                # Se abbiamo già un candidato, applichiamo le regole di priorità
                existing_candidate = tile_candidates[tile_id]

                # REGOLA 1: Il nuovo è in Orthophotos, il vecchio no -> il nuovo vince.
                if current_candidate["isInOrtho"] && !existing_candidate["isInOrtho"]
                    tile_candidates[tile_id] = current_candidate
                    # REGOLA 2: Entrambi sono nella stessa "zona" -> vince la risoluzione più alta.
                    elseif current_candidate["isInOrtho"] == existing_candidate["isInOrtho"]
                    if current_candidate["sizeId"] > existing_candidate["sizeId"]
                        tile_candidates[tile_id] = current_candidate
                    end
                end
            end
        end
    end

    # Costruiamo l'output finale basandoci sui candidati scelti
    output_data = []
    for (tile_id, info) in tile_candidates
        push!(output_data, Dict(
            "id"            => tile_id,
            "bbox"          => get_tile_bbox_from_id(tile_id),
            "sizeId"        => info["sizeId"], # Virgola corretta
            "last_modified" => info["last_modified"]
            ))
    end

    @info "ddsFindScanner: Scrivo $(length(output_data)) tile unici in coverage.json..."
    try
        open("coverage.json", "w") do f
            JSON.print(f, output_data)
        end
        @info "ddsFindScanner: Report 'coverage.json' aggiornato con successo! ✅"
        catch e
        @error "ddsFindScanner: Impossibile scrivere il file coverage.json" exception=(e, catch_backtrace())
    end
end


"""
load_data(file_path::String) -> (Union{Dict, Nothing}, Dict{String, Any})

Loads the persistent index. Returns a tuple: (metadata, file_data).
Returns (nothing, empty_dict) if the file doesn't exist or is invalid.
    """
function load_data()
    file_path = _data_file[] # Usa il percorso globale
    if isfile(file_path)
        try
            @dinfo "ddsFindScanner.load_data: Loading existing data from $(file_path)..."
            json_data = JSON.parsefile(file_path)
            # Controlla che la struttura sia quella attesa
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
        # Salva l'indice principale
        open(file_path, "w") do io
            JSON.print(io, full_data, 4)
        end

        # --- AGGIORNAMENTO AUTOMATICO ---
        # Dopo aver salvato, lancia la generazione di coverage.json
        # in un task asincrono per non bloccare l'operazione corrente.
        @info "ddsFindScanner.save_data: Indice principale salvato. Avvio rigenerazione di coverage.json..."
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

    for (path, size, id, last_modified_str, sizeId, width, height) in new_scan_results
        new_record = Dict(
            "id" => id,
            "size" => size,
            "last_modified" => last_modified_str,
            "sizeId" => sizeId,
            "width" => width,
            "height" => height
        )

        if haskey(existing_data, path)
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
    # Ritorna i conteggi al chiamante
    return added_count, updated_count
end


"""
place_tile!(source_path, tile, rootPath, rootPath_saved)

Funzione centralizzata e intelligente per posizionare un file tile.
1.  Controlla se a destinazione (`rootPath`) esiste già un file.
2.  Se esiste, lo sposta nella corretta directory di backup (`rootPath_saved`).
3.  Sposta il file sorgente (`source_path`) nella destinazione finale.
4.  Aggiorna l'indice dei file in tutte le fasi.
"""

# In src/ddsFindScanner.jl

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
        filename = basename(source_path)
        final_dest_dir = joinpath(rootPath, dir10, dir1)
        final_dest_path = joinpath(final_dest_dir, filename)

        if normpath(source_path) == normpath(final_dest_path)
            @info "ddsFindScanner.place_tile: Source is already at final destination. No action needed."
            return true
        end

        # Se un file esiste già a destinazione...
        if isfile(final_dest_path)
            overwrite_mode = get(cfg, "over", 0)

            # Logica per --over 0 (non sovrascrivere)
            if overwrite_mode == 0
                @info "ddsFindScanner.place_tile: Tile $(final_dest_path) exists. Skipping as for --over 0"
                rm(source_path, force=true)
                return true
            end

            # Tentiamo di leggere la larghezza del file esistente.
            is_success, actual_width, _ = Commons.getDDSSize(final_dest_path)
            if !is_success; is_success, actual_width, _ = Commons.getPNGSize(final_dest_path); end

            if !is_success
                # Se non riusciamo a leggere il file, è corrotto o un link rotto.
                # Lo rimuoviamo invece di tentare uno spostamento che fallirebbe.
                @warn "ddsFindScanner.place_tile: Could not read existing file at '$(final_dest_path)'. It might be corrupt. Removing it to make way for the new file."
                try
                    rm(final_dest_path, force=true)
                catch e
                    @error "ddsFindScanner.place_tile: Failed to remove problematic file '$final_dest_path'." exception=(e, catch_backtrace())
                end
            else
                # Se la lettura ha successo, procediamo con la logica di sovrascrittura
                if overwrite_mode == 1 && tile.width <= actual_width
                    @info "ddsFindScanner.place_tile: Existing tile ($actual_width) px is larger or same size. Skipping."
                    rm(source_path, force=true)
                    return true
                end

                # Se siamo qui, dobbiamo sovrascrivere. Spostiamo il vecchio file nel backup.
                @info "ddsFindScanner.place_tile: Backing up existing file from '$final_dest_path'..."
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

        # A questo punto, la destinazione finale è libera. Spostiamo il nuovo file.
        @info "ddsFindScanner.place_tile: Placing file from '$source_path' to '$final_dest_path'."
        mkpath(final_dest_dir)
        mv(source_path, final_dest_path, force=true)

        # Aggiorna l'indice con il nuovo file
        lock(_data_lock) do
            stat_info = stat(final_dest_path)
            _existing_data[final_dest_path] = Dict(
                "id" => tile.id, "size" => stat_info.size,
                "last_modified" => Dates.format(now(), "yyyy-mm-dd HH:MM:SS"),
                "sizeId" => tile.size_id, "width" => tile.width,
                "height" => tile.width
                )
            save_data(DEFAULT_METADATA, _existing_data)
        end
        return true
        catch e
            @error "ddsFindScanner.place_tile: Error during tile placement exception=$(e)"
        return false
    end
end


function moveImage(rootPath::String, rootPath_saved::String, id::Int, target_sizeId::Int, cfg::Dict)
    @info "ddsFindScanner.moveImage: Ricerca tile da cache per ID $id, sizeId $target_sizeId"

    # [La logica per trovare il "best_candidate" rimane la stessa]
    candidates = Tuple{String, Dict}[]
    lock(_data_lock) do
        for (path, record) in _existing_data
            if get(record, "id", -1) == id && get(record, "sizeId", -1) == target_sizeId
                push!(candidates, (path, record))
            end
        end
    end

    if isempty(candidates)
        @info "ddsFindScanner.moveImage: Nessun candidato trovato."
        return "not_found"
    end

    sort!(candidates, by = x -> get(x[2], "last_modified", ""), rev=true)
    candidate_path, candidate_record = candidates[1]

    # Crea un oggetto TileMetadata temporaneo con le info necessarie
    # per la funzione place_tile!
    lon, lat, _, _, _, _, _, _ = Commons.coordFromIndex(id)
    width = get(candidate_record, "width", 0)
    cols_params = Commons.getSizeAndCols(target_sizeId)
    cols = cols_params === nothing ? 1 : cols_params[2]

    temp_tile_meta = Commons.TileMetadata(
        id, target_sizeId, lon, lat, 0.0, 0.0, 0, 0, 0.0, 0.0, 0.0, width, cols
        )

    # Chiama la nuova funzione centralizzata per fare il lavoro pesante
    success = place_tile!(candidate_path, temp_tile_meta, rootPath, rootPath_saved, cfg)

    return success ? "moved" : "error"
end


"""
startFind(scan_paths::Vector{String}, program_version::String)

Initializes the scanner. Automatically decides whether to load the existing
index or trigger a full rebuild based on metadata comparison.
"""
function startFind(scan_paths::Vector{String}, program_version::String)
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
                "scanned_paths" => scan_paths
                )
            save_data(Dict("last_scan" => Dates.now()), _existing_data)

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
* scandisce la Home e /mnt
* usa la costante `PROGRAM_VERSION`
"""
function startFind()
    lock(_data_lock) do
        _is_scanning[] = true
    end
    scan_start_time = time_ns()

    try
        # Esegue la scansione vera e propria
        syncScan()  # scansione sincrona

        scan_end_time = time_ns()
        scan_duration_ms = scan_end_time - scan_start_time

        lock(_data_lock) do
            _last_scan_duration[] = scan_duration_ms
        end

        @info "ddsFindScanner.startFind(): Scansione completata in $scan_duration_ms ms"
    finally
        lock(_data_lock) do
            _is_scanning[] = false
        end
    end
end


"""
has_suitable_tile(id, target_sizeId, rootPath, savePath, cfg) -> Bool

Esegue un controllo "read-only" per determinare se un tassello adeguato
esiste già in `rootPath` o `savePath`, basandosi sulla logica di `--over`.
Non sposta alcun file.
"""
function has_suitable_tile(id::Int, target_sizeId::Int, rootPath::String, savePath::String, cfg::Dict)
    overwrite_mode = get(cfg, "over", 1) # Default a 1 (sovrascrivi se migliore)

    # Trova tutte le versioni esistenti del tile, ovunque si trovino
    all_versions = find_all_versions_by_id(id)
    if isempty(all_versions)
        return false # Non esiste, quindi non è "suitable"
    end

    # Trova la versione con la risoluzione più alta tra quelle esistenti
    best_existing = sort(all_versions, by = v -> get(v, "sizeId", -1), rev=true)[1]
    best_existing_sizeId = get(best_existing, "sizeId", -1)

    if overwrite_mode == 0
        # Mai sovrascrivere: se esiste (a qualsiasi risoluzione), è "suitable".
        return true
        elseif overwrite_mode == 1
        # Sovrascrivi solo se il nuovo è migliore: è "suitable" se l'esistente è >= del nuovo.
        return best_existing_sizeId >= target_sizeId
        elseif overwrite_mode == 2
        # Sovrascrivi sempre: nessun file esistente è "suitable" per bloccare un nuovo download.
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
                # Filtra solo le cartelle di interesse per le performance
                found = any(startswith.(splitpath(root), "Orthophotos"))
                if !found
                    continue
                end

                for file in files
                    fullpath = joinpath(root, file)

                    # Saltiamo i file che non corrispondono al nostro pattern
                    if isnothing(match(r"^\d+\.(dds|png)$"i, file))
                        continue
                    end

                    # Determiniamo il tipo di file e chiamiamo la funzione helper
                    # che legge anche le dimensioni in pixel.
                    is_dds = endswith(lowercase(file), ".dds")
                    is_png = endswith(lowercase(file), ".png")

                    if is_dds || is_png
                        is_valid, _, size, id, last_modified, sizeId, width, height = get_file_info(fullpath, is_dds, is_png)

                        # Aggiungiamo il record all'indice solo se è un'immagine valida
                        if is_valid && id !== nothing
                            new_data[fullpath] = Dict(
                                "id"            => id,
                                "name"          => basename(fullpath),
                                "size"          => size,          # Dimensione in bytes
                                "last_modified" => last_modified,
                                "sizeId"        => sizeId,        # Classe dimensionale 0..6
                                "width"         => width,
                                "height"        => height
                            )
                        end
                    end
                end
            end
        end

        # Aggiorna lo stato globale e salva su disco
        empty!(_existing_data)
        merge!(_existing_data, new_data)
        save_index()

        @info "ddsFindScanner.syncScan: Synchronous scan complete. Found $(length(_existing_data)) valid image entries."
    end
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

        @info "Statistiche scansione DDS/PNG:"
        @info "=============================="
        @info "Totale files DDS trovati: $dds_count"
        @info "Totale files PNG trovati: $png_count"
        @info "Tempo ultima scansione: $scan_duration_ms ms"

        @info "Distribuzione per cartelle (ordinata):"
        for dir in sort(collect(keys(dir_counts)))
            count = dir_counts[dir]
            @info "• $dir: $count files"
        end
    end
end



@dinfo ("ddsFindScanner: module loaded. Call startFind() to begin.")

end # module
