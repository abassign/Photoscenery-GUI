# Salva come: src/Downloader.jl
module Downloader

using ..Commons, ..StatusMonitor, Images, Downloads, Printf, LightXML, ..JobFactory
using Base.Threads: @spawn
using FileIO, PNGFiles

export MapServer, populate_queue!, start_chunk_downloads_parallel!, enqueue_chunk_jobs!, enqueue_high!, enqueue_low!


"""
const CHUNK_QUEUE = Channel{Commons.ChunkJob}(100)
Channel{Any}: Crea un canale (coda FIFO) in grado di trasmettere dati di qualsiasi tipo (Any).
Inf: Specifica che il canale ha capacità illimitata (può contenere un numero infinito di elementi).

const JOBS_DONE_COUNTER = Ref{Int}(0)
Ref{Int}: Crea un riferimento mutabile a un valore intero.
(0): Inizializza il contatore a 0.
Scopo:
Tiene traccia del numero di lavori completati con successo.

const FAILED_JOBS_COUNT = Ref{Int}(0)
Struttura identica a JOBS_DONE_COUNTER.
Scopo:
Tiene traccia dei lavori falliti (es. a causa di eccezioni).

Un produttore accoda lavori in CHUNK_QUEUE.
Worker multipli prelevano lavori dal canale.
I contatori tengono traccia dello stato dell'elaborazione:
JOBS_DONE_COUNTER: Lavori completati.
FAILED_JOBS_COUNT: Lavori falliti.
Sincronizzazione: Il canale gestisce automaticamente l'accesso concorrente.
"""
const CHUNK_QUEUE = Channel{Commons.ChunkJob}(100)
const FALLBACK_QUEUE = Channel{Tuple{Int, Int}}(50) # Canale per (tile_id, size_id) falliti
const JOBS_DONE_COUNTER = Threads.Atomic{Int}(0)
const FAILED_JOBS_COUNT = Threads.Atomic{Int}(0)
const PENDING_JOBS = Threads.Atomic{Int}(0)

# --- PRIORITÀ ---
const CHUNK_Q_HIGH = Channel{Commons.ChunkJob}(512)
const CHUNK_Q_LOW  = Channel{Commons.ChunkJob}(4096)

# Mappa (temp_path → :high | :low) per reinserire i retry nella stessa classe
const JOB_CLASS = Dict{String,Symbol}()
const JOB_CLASS_LOCK = ReentrantLock()


# Helper di enqueue (riusano la tua enqueue_chunk_jobs! per contatori/log)
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
        # Controllo firma PNG
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

Scarica un chunk PNG, gestendo manualmente i reindirizzamenti (HTTP 301/302).
Valida la firma e l'header del file PNG, e lo scrive su disco in modo atomico
per prevenire file corrotti.
"""
function download_and_validate_png(url::String, dest_path::String; headers::Dict=Dict(), timeout::Real=60.0, max_redirects::Int=5)
    current_url = url

    # Ciclo per gestire fino a 'max_redirects' reindirizzamenti
    for i in 1:max_redirects
        buffer = IOBuffer()
        try
            @info "Downloader.download_and_validate_png: Tentativo di download da $(current_url)"
            Downloads.download(current_url, buffer; headers=headers, timeout=timeout)

            # Se il download ha successo, valida e salva il file
            data = take!(buffer)
            if isempty(data); throw(ErrorException("Risposta vuota dal server")); end

            # Logica di validazione PNG
            try
                if length(data) < 24 || view(data, 1:8) != UInt8[0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]
                    throw(ArgumentError("Downloader.download_and_validate_png: Firma PNG non valida"))
                end
                if view(data, 13:16) != b"IHDR"; throw(ArgumentError("Chunk IHDR mancante")); end
                ihdr_len = Int(data[9]) << 24 | Int(data[10]) << 16 | Int(data[11]) << 8 | Int(data[12])
                if ihdr_len != 13; throw(ArgumentError("Downloader.download_and_validate_png: Lunghezza IHDR non valida")); end
                catch e
                rethrow(ErrorException("Downloader.download_and_validate_png: Validazione PNG fallita: $e"))
            end

            # Logica di scrittura atomica su disco
            temp_path = dest_path * ".tmp"
            try
                # Assicura che la directory di destinazione esista prima di scrivere.
                mkpath(dirname(temp_path))
                write(temp_path, data)
                FileIO.load(temp_path)
                mv(temp_path, dest_path, force=true)
                @info "Downloader.download_and_validate_png: write image $(dest_path)"
            catch e
                ispath(temp_path) && rm(temp_path, force=true)
                rethrow(ErrorException("Downloader.download_and_validate_png: Scrittura su disco fallita: $e"))
                FileIO.load(temp_path)
            end

            return filesize(dest_path)

        catch e
            # Gestione dell'errore di redirect
            if e isa Downloads.RequestError && (e.response.status == 301 || e.response.status == 302)
                # Gli header sono una lista di coppie, non un dizionario. Cerca la chiave "location".
                location_idx = findfirst(p -> lowercase(p.first) == "location", e.response.headers)

                if location_idx !== nothing
                    # Estrai il valore della coppia trovata
                    new_url = e.response.headers[location_idx].second
                    @info "Downloader.download_and_validate_png: Reindirizzato a $new_url"
                    current_url = new_url # Aggiorna l'URL e il ciclo for tenterà di nuovo
                else
                    throw(ErrorException("Downloader.download_and_validate_png: Errore di redirect (301/302), ma header 'Location' non trovato."))
                end
            else
                # Se è un altro tipo di errore (es. timeout), lancialo di nuovo
                rethrow(e)
            end
        end
    end # Fine del ciclo for

    throw(ErrorException("Downloader.download: Troppi reindirizzamenti ($max_redirects) per l'URL: $url"))
end


"""
_restore_best_cached_tile(tile_id::Int, requested_size_id::Int, root_path::String, save_path::String, cfg::Dict; allow_higher::Bool=true)

Esplora tutte le possibili risoluzioni per `tile_id` sia nella directory di output (`root_path`) sia in quella di cache/salvataggio (`save_path`).
Restituisce la `size_id` del tile ripristinato (o già presente) più vicina a `requested_size_id` (stessa → più vicina sotto → eventualmente sopra),
oppure `nothing` se non ha trovato nulla.

Regole:
- Preferisce **DDS** a **PNG** se entrambi presenti.
- Ordine ricerca per distanza: [requested, requested-1, requested+1, requested-2, requested+2, ...]
(l’“above” è incluso solo se `allow_higher=true`).
- Se il file è in `save_path`, lo **copia** in `root_path` mantenendo il nome file.
"""
function _restore_best_cached_tile(tile_id::Int, requested_size_id::Int,
                                   root_path::String, save_path::String, cfg::Dict;
                                   allow_higher::Bool=true)
    # range tipico: 0..6 (puoi alzarlo in cfg con "max_size_id")
    max_id = get(cfg, "max_size_id", 6)
    min_id = 0

    # helper: esiste già un file (dds/png) per questo tile in output?
    _has_in_output = function (sid::Int)
        width, _ = Commons.getSizeAndCols(sid)
        dest_dir  = Commons.tile_dest_dir(tile_id, width, root_path)
        if !isdir(dest_dir); return false; end
        files = readdir(dest_dir)
        any(endswith.(lowercase.(files), ".dds")) || any(endswith.(lowercase.(files), ".png"))
    end

    # Ordine candidati per "distanza" dalla richiesta
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

    # 1) Se è già presente in output, basta così
    for sid in candidates
        if _has_in_output(sid)
            @info "Restore(move): found existing tile $tile_id at size $sid in output"
            return sid
        end
    end

    # 2) Prova a spostare dalla cache con la funzione ufficiale
    for sid in candidates
        status = ddsFindScanner.moveImage(root_path, save_path, tile_id, sid, cfg)
        # convenzione: "moved" = spostato, "skip" = già presente/nessuna azione
        if status in ("moved", "skip")
            @info "Restore(move): tile $tile_id satisfied by cached size=$sid (status=$status)"
            return sid
        end
    end

    return nothing
end


function download_worker(worker_id::Int, map_server::MapServer, cfg::Dict)
    @info "Downloader: ✅ Started priority worker id=$worker_id"
    start_time = time()
    downloaded_bytes = 0

    while true
        # Priorità: serviamo prima l'alta priorità se presente
        job = if isready(CHUNK_Q_HIGH)
            take!(CHUNK_Q_HIGH)
        else
            take!(CHUNK_Q_LOW)    # blocca qui se entrambe vuote
        end

        job === :stop && break

        # Se esiste già un file valido per questo chunk, evita lavoro inutile
        if isfile(job.temp_path) && filesize(job.temp_path) > get(cfg, "min_chunk_bytes", 64)
            try
                if validate_png_file(job.temp_path)
                    bytes = filesize(job.temp_path)
                    StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
                    Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
                    Threads.atomic_add!(PENDING_JOBS, -1)
                    continue
                end
                catch e
                @warn "Downloader: file validation failed, re-downloading: $(job.temp_path)"
                rm(job.temp_path, force=true)
            end
        end

        StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :in_progress)
        url, err = _getMapServerURL(map_server, job.bbox, job.pixel_size)

        # Errore URL → prova retry con backoff, poi fallback
        if err != 0
            @warn "Downloader: URL generation FAILED for $(job.tile_id)-$(job.chunk_xy); will retry"
            if job.retries_left > 0
                attempts   = get(cfg, "attempts", get(cfg, "attemps", 5))
                idx        = max(0, attempts - job.retries_left)
                base_sleep = get(cfg, "retry_backoff_base", 1.7)
                cap_sleep  = get(cfg, "retry_max_sleep", 20.0)
                sleep(min(cap_sleep, base_sleep^idx))

                new_job = Commons.ChunkJob(job.tile_id, job.size_id, job.chunk_xy, job.bbox, job.pixel_size, job.temp_path, job.retries_left - 1)
                local cls::Symbol
                lock(JOB_CLASS_LOCK) do
                    cls = get(JOB_CLASS, job.temp_path, :high)
                    JOB_CLASS[new_job.temp_path] = cls
                end
                (cls === :high ? put!(CHUNK_Q_HIGH, new_job) : put!(CHUNK_Q_LOW, new_job))
            else
                @warn "Downloader: URL generation permanent failure → fallback"
                put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :failed)
                Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                Threads.atomic_add!(PENDING_JOBS, -1)
            end
            continue
        end

        # Parametri retry/timeout progressivi
        attempts   = get(cfg, "attempts", get(cfg, "attemps", 5))      # tentativi totali per chunk (incl. il 1°)
        base_to    = Float64(get(cfg, "timeout", 90))                   # timeout base al 1° tentativo
        idx        = max(0, attempts - job.retries_left)                # 0,1,2,...
        grow       = get(cfg, "retry_timeout_factor", 1.6)              # fattore crescita timeout
        cap_to     = Float64(get(cfg, "retry_timeout_cap", 300))        # tetto massimo
        timeout_sec = min(cap_to, base_to * (grow^idx))

        headers = Dict("User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36")

        try
            bytes = download_and_validate_png(url, job.temp_path; headers=headers, timeout=Float64(timeout_sec))
            StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
            Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
            Threads.atomic_add!(PENDING_JOBS, -1)
            downloaded_bytes += bytes

            catch e
            st = try e.response.status catch; 0 end

            # Fallback SOLO per errori definitivi (contenuto/server)
            if e isa Downloads.RequestError && (st in (404, 410, 500))
                @warn "Downloader: definitive server/content error ($st) on $(job.tile_id)-$(job.chunk_xy) → fallback"
                put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :failed)
                Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                Threads.atomic_add!(PENDING_JOBS, -1)

            else
                # Transienti: timeout/lentezza/429/503/504 ecc. → RETRY
                @warn "Downloader: transient error ($st) on $(job.tile_id)-$(job.chunk_xy); will retry" exception=(e, catch_backtrace())
                isfile(job.temp_path) && rm(job.temp_path, force=true)

                if job.retries_left > 0
                    base_sleep = get(cfg, "retry_backoff_base", 1.7)
                    cap_sleep  = get(cfg, "retry_max_sleep", 20.0)
                    sleep(min(cap_sleep, base_sleep^idx))

                    new_job = Commons.ChunkJob(
                        job.tile_id, job.size_id, job.chunk_xy,
                        job.bbox, job.pixel_size, job.temp_path,
                        job.retries_left - 1
                        )
                    # reinserisci nella stessa classe (HIGH/LOW) del job originale
                    local cls::Symbol
                    lock(JOB_CLASS_LOCK) do
                        cls = get(JOB_CLASS, job.temp_path, :high)
                        JOB_CLASS[new_job.temp_path] = cls
                    end
                    if cls === :high
                        put!(CHUNK_Q_HIGH, new_job)
                    else
                        put!(CHUNK_Q_LOW, new_job)
                    end
                else
                    @warn "Downloader: retries exhausted for $(job.tile_id)-$(job.chunk_xy) → fallback"
                        put!(FALLBACK_QUEUE, (job.tile_id, job.size_id))
                        StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :failed)
                        Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
                        Threads.atomic_add!(PENDING_JOBS, -1)
                end
            end
        end
    end

    elapsed = time() - start_time
    mb = downloaded_bytes / 1024^2
    @info "Worker $worker_id finished. Time: $(round(elapsed, digits=1))s, Downloaded: $(round(mb, digits=2)) MiB."
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
        # Evita di processare lo stesso fallback più volte
        if (tile_id, failed_size_id) in processed_fallbacks
            continue
        end
        push!(processed_fallbacks, (tile_id, failed_size_id))

        @info "Fallback: Ricevuto tile fallito $tile_id (size $failed_size_id). Avvio procedura di recupero."

        # 1. Tenta prima di tutto di ripristinare da cache (qualsiasi risoluzione valida)
        restored_sid = _restore_best_cached_tile(tile_id, failed_size_id, root_path, save_path, cfg)
        if restored_sid !== nothing
            @info "Fallback: SUCCESS! Tile $tile_id recuperato dalla cache con size $restored_sid."
            # Pulisci i chunk temporanei del tentativo fallito
            try
                for f in readdir(tmp_dir)
                    if startswith(f, "$(tile_id)_$(failed_size_id)_")
                        rm(joinpath(tmp_dir, f), force=true)
                    end
                end
            catch e
                @warn "Fallback: Errore durante la pulizia dei chunk per $tile_id" exception=(e, catch_backtrace())
            end
            continue # Lavoro finito per questo tile, passa al prossimo
        end

        # 2. Se il ripristino da cache fallisce, procedi con il download a risoluzione inferiore
        new_size_id = failed_size_id - 1
        if new_size_id < 0
            @warn "Fallback: Tile $tile_id fallito anche alla risoluzione minima. Abbandono."
            continue
        end

        @info "Fallback: Cache non disponibile per tile $tile_id. Tento il re-download a size $new_size_id."

        # 3. Pulisci i chunk vecchi prima di crearne di nuovi
        try
            for f in readdir(tmp_dir)
                if startswith(f, "$(tile_id)_$(failed_size_id)_")
                    rm(joinpath(tmp_dir, f), force=true)
                end
            end
        catch e
            @warn "Fallback: Errore durante la pulizia dei chunk per $tile_id" exception=(e, catch_backtrace())
        end

        # 4. Genera e accoda i nuovi job a risoluzione ridotta
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
                @info "Fallback: Accodamento di $(length(new_jobs)) nuovi chunk per tile $tile_id a size $new_size_id."
                enqueue_low!(new_jobs)
            end
        catch e
            @error "Fallback: Impossibile generare nuovi chunk job per $tile_id." exception=(e, catch_backtrace())
        end
    end
end


function populate_queue!(jobs::Vector{ChunkJob})
    while isready(CHUNK_QUEUE) take!(CHUNK_QUEUE) end
    JOBS_DONE_COUNTER[] = 0
    FAILED_JOBS_COUNT[] = 0
    PENDING_JOBS[] = length(jobs)  # Inizializza il contatore

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
    # Avvia i worker di download
    for i in 1:nworkers
        @async download_worker(i, map_server, cfg)
    end
    @async fallback_manager(map_server, cfg, root_path, save_path, tmp_dir)
    @info "✅ Downloader: Started $nworkers download workers and 1 fallback manager."
end


end
