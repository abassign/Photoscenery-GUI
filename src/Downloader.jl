# Save as: src/Downloader.jl
module Downloader

using ..Commons, ..StatusMonitor, Images, Downloads, Printf, LightXML, ..JobFactory
using Base.Threads: @spawn
using FileIO, PNGFiles

export MapServer, populate_queue!, start_chunk_downloads_parallel!, enqueue_chunk_jobs!, enqueue_high!, enqueue_low!


"""
const CHUNK_QUEUE = Channel{Commons.ChunkJob}(100)
Channel{Any}: Creates a channel (FIFO queue) capable of transmitting data of any type (Any).
Inf: Specifies that the channel has unlimited capacity (can contain an infinite number of elements).

const JOBS_DONE_COUNTER = Ref{Int}(0)
Ref{Int}: Creates a mutable reference to an integer value.
(0): Initializes the counter to 0.
Purpose:
Tracks the number of successfully completed jobs.

const FAILED_JOBS_COUNT = Ref{Int}(0)
Identical structure to JOBS_DONE_COUNTER.
Purpose:
Tracks failed jobs (e.g. due to exceptions).

A producer queues jobs in CHUNK_QUEUE.
Multiple workers take jobs from the channel.
Counters track processing status:
JOBS_DONE_COUNTER: Completed jobs.
FAILED_JOBS_COUNT: Failed jobs.
Synchronization: The channel automatically handles concurrent access.
"""
const CHUNK_QUEUE = Channel{Commons.ChunkJob}(100)
const FALLBACK_QUEUE = Channel{Tuple{Int, Int}}(50) # Channel for failed (tile_id, size_id)
const JOBS_DONE_COUNTER = Threads.Atomic{Int}(0)
const FAILED_JOBS_COUNT = Threads.Atomic{Int}(0)
const PENDING_JOBS = Threads.Atomic{Int}(0)

# --- PRIORITY ---
const CHUNK_Q_HIGH = Channel{Commons.ChunkJob}(512)
const CHUNK_Q_LOW  = Channel{Commons.ChunkJob}(4096)

# Map (temp_path -> :high | :low) to reinsert retries in the same class
const JOB_CLASS = Dict{String,Symbol}()
const JOB_CLASS_LOCK = ReentrantLock()


# Enqueue helpers (reuse your enqueue_chunk_jobs! for counters/logs)
enqueue_high!(jobs::Vector{Commons.ChunkJob}) = begin
    lock(JOB_CLASS_LOCK) do
        for j in jobs; JOB_CLASS[j.temp_path] = :high; end
    end
    enqueue_chunk_jobs!(CHUNK_Q_HIGH, jobs)
end


enqueue_low!(jobs::Vector{Commons.ChunkJob}) = begin
    lock(JOB_CLASS_LOCK) do
        for j in jobs; JOB_CLASS[j.temp_path] = :low; end
    end
    enqueue_chunk_jobs!(CHUNK_Q_LOW, jobs)
end


struct MapServer
    id::Int64
    webUrlBase::Union{String,Nothing}
    webUrlCommand::Union{String,Nothing}
    name::Union{String,Nothing}
    comment::Union{String,Nothing}
    proxy::Union{String,Nothing}
    errorCode::Int64

    function MapServer(id::Int, aProxy::Union{String, Nothing}=nothing)
        try
            serversRoot = get_elements_by_tagname(LightXML.root(parse_file("params.xml")), "servers")
            for server in get_elements_by_tagname(serversRoot[1], "server")
                if server !== nothing && strip(content(find_element(server, "id"))) == string(id)
                    webUrlBase = strip(content(find_element(server, "url-base")))
                    webUrlCommand = map(c -> c == '|' ? '&' : c, strip(content(find_element(server, "url-command"))))
                    name = strip(content(find_element(server, "name")))
                    comment = strip(content(find_element(server, "comment")))
                    return new(id, webUrlBase, webUrlCommand, name, comment, aProxy, 0)
                end
            end
            @warn "Map server with ID=$id not found in params.xml."
            return new(id, nothing, nothing, nothing, nothing, nothing, 410)
            catch err
            @error "Failed to parse params.xml. Error: $err"
            return new(id, nothing, nothing, nothing, nothing, nothing, 411)
        end
    end
end

function _getMapServerReplace(urlCmd::String, varString::String, varValue)
    return replace(urlCmd, varString => string(round(varValue, digits=6)))
end

function _getMapServerURL(m::MapServer, bbox, pixel_size)
    if m.errorCode != 0; return "", 412; end
    urlCmd = m.webUrlCommand
    urlCmd = _getMapServerReplace(urlCmd, "{latLL}", bbox.latLL)
    urlCmd = _getMapServerReplace(urlCmd, "{lonLL}", bbox.lonLL)
    urlCmd = _getMapServerReplace(urlCmd, "{latUR}", bbox.latUR)
    urlCmd = _getMapServerReplace(urlCmd, "{lonUR}", bbox.lonUR)
    urlCmd = _getMapServerReplace(urlCmd, "{szWidth}", Int(pixel_size.width))
    urlCmd = _getMapServerReplace(urlCmd, "{szHight}", Int(pixel_size.height))
    return m.webUrlBase * urlCmd, 0
end

function enqueue_chunk_jobs!(channel::Channel{ChunkJob}, jobs::Vector{ChunkJob})
    @info "download_worker.enqueue_chunk_jobs!: Enqueued $(length(jobs)) jobs into the channel"
    for job in jobs
        put!(channel, job)
    end
    @info "download_worker.enqueue_chunk_jobs!: #1"
    Threads.atomic_add!(Downloader.PENDING_JOBS, length(jobs))
    @info "download_worker.enqueue_chunk_jobs!: #2"
end

function validate_png_file(path::String)::Bool
    try
        # PNG signature check
        open(path, "r") do io
            signature = read(io, 8)
            return signature == UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        end
    catch e
        @warn "Downloader.validate_png_file: PNG validation failed for $path: $e"
        return false
    end
end

"""
download_and_validate_png(...)

Downloads a PNG chunk, manually handling redirects (HTTP 301/302).
Validates the PNG signature and header, and writes it to disk atomically
to prevent corrupt files.
"""
function download_and_validate_png(url::String, dest_path::String; headers::Dict=Dict(), timeout::Real=60.0, max_redirects::Int=5)
    current_url = url

    # Loop to handle up to 'max_redirects' redirects
    for i in 1:max_redirects
        buffer = IOBuffer()
        try
            @info "Downloader.download_and_validate_png: Download attempt from $(current_url)"
            Downloads.download(current_url, buffer; headers=headers, timeout=timeout)

            # If download succeeds, validate and save the file
            data = take!(buffer)
            if isempty(data); throw(ErrorException("Empty response from server")); end

            # PNG validation logic
            try
                if length(data) < 24 || view(data, 1:8) != UInt8[0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]
                    throw(ArgumentError("Downloader.download_and_validate_png: Invalid PNG signature"))
                end
                if view(data, 13:16) != b"IHDR"; throw(ArgumentError("Missing IHDR Chunk")); end
                ihdr_len = Int(data[9]) << 24 | Int(data[10]) << 16 | Int(data[11]) << 8 | Int(data[12])
                if ihdr_len != 13; throw(ArgumentError("Downloader.download_and_validate_png: Invalid IHDR length")); end
                catch e
                rethrow(ErrorException("Downloader.download_and_validate_png: PNG validation failed: $e"))
            end

            # Atomic disk writing logic
            temp_path = dest_path * ".tmp"
            try
                # Ensure destination directory exists before writing.
                mkpath(dirname(temp_path))
                write(temp_path, data)
                FileIO.load(temp_path)
                mv(temp_path, dest_path, force=true)
                @info "Downloader.download_and_validate_png: write image $(dest_path)"
            catch e
                ispath(temp_path) && rm(temp_path, force=true)
                rethrow(ErrorException("Downloader.download_and_validate_png: Disk write failed: $e"))
                FileIO.load(temp_path)
            end

            return filesize(dest_path)

        catch e
            # Redirect error handling
            if e isa Downloads.RequestError && (e.response.status == 301 || e.response.status == 302)
                # Headers are a list of pairs, not a dictionary. Search for "location" key.
                location_idx = findfirst(p -> lowercase(p.first) == "location", e.response.headers)

                if location_idx !== nothing
                    # Extract value of found pair
                    new_url = e.response.headers[location_idx].second
                    @info "Downloader.download_and_validate_png: Redirected to $new_url"
                    current_url = new_url # Update URL and loop will try again
                else
                    throw(ErrorException("Downloader.download_and_validate_png: Redirect error (301/302), but 'Location' header not found."))
                end
            else
                # If it's another error type (e.g. timeout), rethrow it
                rethrow(e)
            end
        end
    end # Fine del ciclo for

    throw(ErrorException("Downloader.download: Too many redirects ($max_redirects) for URL: $url"))
end


"""
_restore_best_cached_tile(tile_id::Int, requested_size_id::Int, root_path::String, save_path::String, cfg::Dict; allow_higher::Bool=true)

Explores all possible resolutions for `tile_id` in both output directory (`root_path`) and cache/save directory (`save_path`).
Returns the `size_id` of the restored (or already present) tile closest to `requested_size_id` (same -> closest below -> eventually above),
or `nothing` if nothing found.

Rules:
- Prefer **DDS** to **PNG** if both present.
- Candidate order by "distance" from request: [requested, requested-1, requested+1, requested-2, requested+2, ...]
(the "above" is included only if `allow_higher=true`).
- If the file is in `save_path`, it **copies** it to `root_path` keeping the filename.
"""
function _restore_best_cached_tile(tile_id::Int, requested_size_id::Int,
                                   root_path::String, save_path::String, cfg::Dict;
                                   allow_higher::Bool=true)
    # typical range: 0..6 (can raise in cfg with "max_size_id")
    max_id = get(cfg, "max_size_id", 6)
    min_id = 0

    # helper: does a file (dds/png) already exist for this tile in output?
    _has_in_output = function (sid::Int)
        width, _ = Commons.getSizeAndCols(sid)
        dest_dir  = Commons.tile_dest_dir(tile_id, width, root_path)
        if !isdir(dest_dir); return false; end
        files = readdir(dest_dir)
        any(endswith.(lowercase.(files), ".dds")) || any(endswith.(lowercase.(files), ".png"))
    end

    # Candidate order by "distance" from request
    candidates = Int[]
    max_d = max(requested_size_id - min_id, max_id - requested_size_id)
    for d in 0:max_d
        s1 = requested_size_id - d
        s2 = requested_size_id + d
        if d == 0
            (s1 >= min_id && s1 <= max_id) && push!(candidates, s1)
        else
            (s1 >= min_id) && push!(candidates, s1)
            (allow_higher && s2 <= max_id) && push!(candidates, s2)
        end
    end

    # 1) If already present in output, that's enough
    for sid in candidates
        if _has_in_output(sid)
            @info "Restore(move): found existing tile $tile_id at size $sid in output"
            return sid
        end
    end

    # 2) Try to move from cache with official function
    for sid in candidates
        status = ddsFindScanner.moveImage(root_path, save_path, tile_id, sid, cfg)
        # convention: "moved" = moved, "skip" = already present/no action
        if status in ("moved", "skip")
            @info "Restore(move): tile $tile_id satisfied by cached size=$sid (status=$status)"
            return sid
        end
    end

    return nothing
end


function _____download_worker(worker_id::Int, map_server::MapServer, cfg::Dict)
    @info "Downloader: ✅ Started priority worker id=$worker_id"
    start_time = time()
    downloaded_bytes = 0

    while true
        # Priority: serve high priority first if present
        job = if isready(CHUNK_Q_HIGH)
            take!(CHUNK_Q_HIGH)
        else
            take!(CHUNK_Q_LOW)
        end

        if job === :stop
            @info "Worker $worker_id: Received STOP signal."
            break
        end

        # --- DEBUG: Tracciamento Job ---
        @info "Worker $worker_id: Prelevato job $(basename(job.temp_path)) (SizeID: $(job.size_id))"

        # Safety block to catch single job crashes
        try
            # If a valid file already exists for this chunk, avoid useless work
            if isfile(job.temp_path) && filesize(job.temp_path) > get(cfg, "min_chunk_bytes", 64)
                try
                    if validate_png_file(job.temp_path)
                        bytes = filesize(job.temp_path)
                        StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
                        Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
                        Threads.atomic_add!(PENDING_JOBS, -1)
                        @info "Worker $worker_id: File già presente e valido. Salto."
                        continue
                    end
                catch e
                    @warn "Downloader: file validation failed, re-downloading: $(job.temp_path)"
                    rm(job.temp_path, force=true)
                end
            end

            StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :in_progress)

            # URL Generation
            url, err = _getMapServerURL(map_server, job.bbox, job.pixel_size)

            if err != 0
                @warn "Worker $worker_id: URL generation FAILED ($err) for $(job.tile_id)"
                # ... (existing URL retry logic unchanged) ...
                # For brevity, if it fails here, put in fallback or retry as in your original code
                # (Ensure you keep your URL retry logic here, if present)
                put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                Threads.atomic_add!(PENDING_JOBS, -1)
                continue
            end

            # Retry parameters
            attempts    = get(cfg, "attempts", 5)
            base_to     = Float64(get(cfg, "timeout", 30))

            # --- DEBUG ---
            @info "Worker $worker_id: Generated URL: $url"

            headers = Dict("User-Agent" => "Mozilla/5.0 (PhotoscenaryBot)")

            try
                # Actual download
                bytes = download_and_validate_png(url, job.temp_path; headers=headers, timeout=base_to)

                # Success
                StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
                Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
                Threads.atomic_add!(PENDING_JOBS, -1)
                downloaded_bytes += bytes
                @info "Worker $worker_id: Download completed for $(basename(job.temp_path)) ($bytes bytes)"

            catch e
                st = try e.response.status catch; 0 end

                if e isa Downloads.RequestError && (st in (404, 410, 500))
                    @warn "Worker $worker_id: Definitive server error ($st) on $(basename(job.temp_path))"
                    put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                    Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                    Threads.atomic_add!(PENDING_JOBS, -1)
                else
                    @warn "Worker $worker_id: Transient/network error on $(basename(job.temp_path)): $e"

                    # Simplified Retry logic for debug (or use your complete one)
                    if job.retries_left > 0
                        sleep(1.0)
                        new_job = Commons.ChunkJob(job.tile_id, job.size_id, job.chunk_xy, job.bbox, job.pixel_size, job.temp_path, job.retries_left - 1)
                        # Re-queue in LOW for resume
                        put!(CHUNK_Q_LOW, new_job)
                    else
                        @warn "Worker $worker_id: Retries exhausted."
                        put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                        Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                        Threads.atomic_add!(PENDING_JOBS, -1)
                    end
                end
            end

        catch crash_e
            # --- CRITICAL POINT: CATCH WORKER CRASH ---
            @error "Worker $worker_id: SUDDEN CRASH processing $(basename(job.temp_path))" exception=(crash_e, catch_backtrace())
            Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
            Threads.atomic_add!(PENDING_JOBS, -1)
        end
    end

    elapsed = time() - start_time
    mb = downloaded_bytes / 1024^2
    @info "Worker $worker_id finished session. Downloaded: $(round(mb, digits=2)) MiB."
end


function download_worker(worker_id::Int, map_server::MapServer, cfg::Dict)
    @info "Downloader: ✅ Started priority worker id=$worker_id"
    start_time = time()
    downloaded_bytes = 0

    while true
        # Priority: serve high priority first if present
        job = if isready(CHUNK_Q_HIGH)
            take!(CHUNK_Q_HIGH)
        else
            take!(CHUNK_Q_LOW)
        end

        if job === :stop
            @info "Worker $worker_id: Received STOP signal."
            break
        end

        # --- DEBUG: Tracciamento Job ---
        @info "Worker $worker_id: Prelevato job $(basename(job.temp_path)) (SizeID: $(job.size_id))"

        # Safety block to catch single job crashes
        try
            # If a valid file already exists for this chunk, avoid useless work
            if isfile(job.temp_path) && filesize(job.temp_path) > get(cfg, "min_chunk_bytes", 64)
                try
                    if validate_png_file(job.temp_path)
                        bytes = filesize(job.temp_path)
                        StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
                        Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
                        Threads.atomic_add!(PENDING_JOBS, -1)
                        @info "Worker $worker_id: File già presente e valido. Salto."
                        continue
                    end
                catch e
                    @warn "Downloader: file validation failed, re-downloading: $(job.temp_path)"
                    rm(job.temp_path, force=true)
                end
            end

            StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :in_progress)

            # URL Generation
            url, err = _getMapServerURL(map_server, job.bbox, job.pixel_size)

            if err != 0
                @warn "Worker $worker_id: URL generation FAILED ($err) for $(job.tile_id)"
                put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                Threads.atomic_add!(PENDING_JOBS, -1)
                continue
            end

            # --- CORRECTION: Safe parameter reading ---
            # Use an inline helper or explicit logic to avoid 'nothing' conversions

            attempts_val = get(cfg, "attempts", 5)
            attempts = (attempts_val === nothing) ? 5 : Int(attempts_val)

            timeout_val = get(cfg, "timeout", 30)
            base_to = (timeout_val === nothing) ? 30.0 : Float64(timeout_val)

            idx        = max(0, attempts - job.retries_left)

            grow_val   = get(cfg, "retry_timeout_factor", 1.6)
            grow       = (grow_val === nothing) ? 1.6 : Float64(grow_val)

            cap_val    = get(cfg, "retry_timeout_cap", 300)
            cap_to     = (cap_val === nothing) ? 300.0 : Float64(cap_val)

            timeout_sec = min(cap_to, base_to * (grow^idx))
            # ------------------------------------------------

            # @info "Worker $worker_id: URL generato: $url"

            headers = Dict("User-Agent" => "Mozilla/5.0 (PhotoscenaryBot)")

            try
                # Actual download
                bytes = download_and_validate_png(url, job.temp_path; headers=headers, timeout=timeout_sec) # Use calculated timeout_sec

                # Success
                StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
                Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
                Threads.atomic_add!(PENDING_JOBS, -1)
                downloaded_bytes += bytes
                @info "Worker $worker_id: Download completed for $(basename(job.temp_path)) ($bytes bytes)"

            catch e
                st = try e.response.status catch; 0 end

                if e isa Downloads.RequestError && (st in (404, 410, 500))
                    @warn "Worker $worker_id: Definitive server error ($st) on $(basename(job.temp_path))"
                    put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                    Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                    Threads.atomic_add!(PENDING_JOBS, -1)
                else
                    @warn "Worker $worker_id: Transient/network error on $(basename(job.temp_path)): $e"

                    if job.retries_left > 0
                        sleep(1.0)
                        new_job = Commons.ChunkJob(job.tile_id, job.size_id, job.chunk_xy, job.bbox, job.pixel_size, job.temp_path, job.retries_left - 1)
                        # Re-queue LOW for resume
                        put!(CHUNK_Q_LOW, new_job)
                    else
                        @warn "Worker $worker_id: Retries exhausted."
                        put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                        Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                        Threads.atomic_add!(PENDING_JOBS, -1)
                    end
                end
            end

        catch crash_e
            # --- CATCH WORKER CRASH ---
            @error "Worker $worker_id: SUDDEN CRASH processing $(basename(job.temp_path))" exception=(crash_e, catch_backtrace())
            Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
            Threads.atomic_add!(PENDING_JOBS, -1)
        end
    end

    elapsed = time() - start_time
    mb = downloaded_bytes / 1024^2
    @info "Worker $worker_id finished session. Downloaded: $(round(mb, digits=2)) MiB."
end


"""
    fallback_manager(map_server::MapServer, cfg::Dict, root_path::String, save_path::String, tmp_dir::String)

A dedicated asynchronous worker that processes failed tiles from the `FALLBACK_QUEUE`.
For each failed tile, it first checks if a lower-resolution version already exists in the
cache (`-saved` directory). If so, it copies it. Otherwise, it attempts to re-download
it at a progressively lower resolution.
"""
function fallback_manager(map_server::MapServer, cfg::Dict, root_path::String, save_path::String, tmp_dir::String)
    @info "✅ Fallback Manager started. Waiting for failed tiles..."
    processed_fallbacks = Set{Tuple{Int, Int}}()

    for (tile_id, failed_size_id) in FALLBACK_QUEUE
        # Avoid processing the same fallback multiple times
        if (tile_id, failed_size_id) in processed_fallbacks
            continue
        end
        push!(processed_fallbacks, (tile_id, failed_size_id))

        @info "Fallback: Received failed tile $tile_id (size $failed_size_id). Starting recovery procedure."

        # 1. Try first to restore from cache (any valid resolution)
        restored_sid = _restore_best_cached_tile(tile_id, failed_size_id, root_path, save_path, cfg)
        if restored_sid !== nothing
            @info "Fallback: SUCCESS! Tile $tile_id recovered from cache with size $restored_sid."
            # Clean temporary chunks of failed attempt
            try
                for f in readdir(tmp_dir)
                    if startswith(f, "$(tile_id)_$(failed_size_id)_")
                        rm(joinpath(tmp_dir, f), force=true)
                    end
                end
            catch e
                @warn "Fallback: Error cleaning chunks for $tile_id" exception=(e, catch_backtrace())
            end
            continue # Work done for this tile, move to next
        end

        # 2. If cache restore fails, proceed with lower resolution download
        new_size_id = failed_size_id - 1
        if new_size_id < 0
            @warn "Fallback: Tile $tile_id failed even at minimum resolution. Abandoning."
            continue
        end

        @info "Fallback: Cache not available for tile $tile_id. Attempting re-download at size $new_size_id."

        # 3. Clean old chunks before creating new ones
        try
            for f in readdir(tmp_dir)
                if startswith(f, "$(tile_id)_$(failed_size_id)_")
                    rm(joinpath(tmp_dir, f), force=true)
                end
            end
        catch e
            @warn "Fallback: Error cleaning chunks for $tile_id" exception=(e, catch_backtrace())
        end

        # 4. Generate and enqueue new reduced resolution jobs
        try
            _, _, lon_base, lat_base, lon_step, lat_step, _, _ = Commons.coordFromIndex(tile_id)
            width, cols = Commons.getSizeAndCols(new_size_id)
            fallback_tile = Commons.TileMetadata(
                tile_id, new_size_id,
                lon_base, lat_base, lon_base + lon_step, lat_base + lat_step,
                0, 0, 0.0, 0.0, lon_step, width, cols
                )
            new_jobs = create_chunk_jobs([fallback_tile], cfg, tmp_dir)

            if !isempty(new_jobs)
                @info "Fallback: Enqueuing $(length(new_jobs)) new chunks for tile $tile_id at size $new_size_id."
                enqueue_low!(new_jobs)
            end
        catch e
            @error "Fallback: Unable to generate new chunk jobs for $tile_id." exception=(e, catch_backtrace())
        end
    end
end


function populate_queue!(jobs::Vector{ChunkJob})
    while isready(CHUNK_QUEUE) take!(CHUNK_QUEUE) end
    JOBS_DONE_COUNTER[] = 0
    FAILED_JOBS_COUNT[] = 0
    PENDING_JOBS[] = length(jobs)  # Initialize counter

    if isempty(jobs)
        close(CHUNK_QUEUE)
        return
    end

    for job in jobs
        put!(CHUNK_QUEUE, job)
    end
    @info "Downloader.populate_queue: populated with $(length(jobs)) jobs."
end

"""
    start_chunk_downloads_parallel!(nworkers::Int, map_server::MapServer, cfg::Dict)

    Launches `nworkers` asynchronous download workers that process chunk jobs from the shared
    `CHUNK_QUEUE`. Each worker repeatedly pulls jobs from the queue, attempts to download the
    corresponding image from the specified `map_server`, and validates it before marking it as completed.

    # Arguments
    - `nworkers::Int`: Number of concurrent asynchronous download workers to start.
    - `map_server::MapServer`: Server configuration used to build the URL for each chunk.
    - `cfg::Dict`: User or system configuration options (e.g. timeout, retry policies).

    # Behavior
    - Each worker runs independently and pulls jobs from the global channel `CHUNK_QUEUE`.
    - The process continues until a `:stop` symbol is received or the queue is empty.
    - Worker state updates (progress, failures, etc.) are managed via the `StatusMonitor`.

    # Note
    - Ensure `CHUNK_QUEUE` is populated before calling this function.
    - This function is non-blocking: it spawns workers via `@async`.

    # Example
    start_chunk_downloads_parallel!(4, map_server, cfg)
"""
function start_chunk_downloads_parallel!(nworkers::Int, map_server::MapServer, cfg::Dict, root_path::String, save_path::String, tmp_dir::String)
    @info "✅ Downloader.start_chunk_downloads_parallel: Starting..."
    # Start download workers
    for i in 1:nworkers
        @async download_worker(i, map_server, cfg)
    end
    @async fallback_manager(map_server, cfg, root_path, save_path, tmp_dir)
    @info "✅ Downloader: Started $nworkers download workers and 1 fallback manager."
end


end
