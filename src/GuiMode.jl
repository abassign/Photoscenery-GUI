# GuiMode.jl - Web GUI Server Module
#
# Purpose: Provides HTTP server functionality for the Photoscenery web interface.
#          Handles static file serving, API endpoints for job management,
#          and FlightGear connectivity.
#
# Dependencies:
#   - Connector.jl: Manages FlightGear connection and position tracking
#   - GeoEngine.jl: Handles geographical calculations and path preparation
#   - ddsFindScanner.jl: Manages DDS tile file operations
#   - Photoscenary.dds2pngDXT1: Converts DDS tiles to PNG for preview
#   - Commons.jl: Provides shared data structures and utilities
#   - Downloader.jl: Handles map tile downloading
#   - Route.jl: Manages route calculations and ICAO resolution
#
# Features:
#   - HTTP server (default: http://127.0.0.1:8000)
#   - Interactive map for tile visualization/download
#   - API endpoints for job control and FGFS connectivity
#   - Asynchronous job processing
#   - Live preview of DDS tiles
#
# Key Components:
#   - Job Queue: Manages download/conversion tasks
#   - FlightGear Connector: Real-time aircraft position tracking
#   - Preview Generator: Converts DDS → PNG for web display
#
# API Endpoints:
#   POST /api/start-job    : Queue a new tile job
#   GET  /api/fgfs-status  : Fetch live aircraft data
#   GET  /preview?id=:id   : Generate tile preview
#   POST /api/shutdown     : Terminate server

module GuiMode

export run

using ..Connector, ..GeoEngine, ..ddsFindScanner, ..Photoscenary.dds2pngDXT1, ..Commons, ..Downloader, ..Route, ..AppConfig, ..AssemblyMonitor
using ..AirportsNavaids
using Logging, JSON3, HTTP, Images, Dates, LightXML
using Base.Threads: @spawn
using Base.Threads: Atomic, atomic_add!


# State Management

const SERVER_START_TIME = now()

const FGFS_CONNECTION = Ref{Union{Connector.FGFSPositionRoute, Nothing}}(nothing)

const APP_CONFIG = Ref{Dict}()

# Infinite job queue for processing download/conversion tasks
const JOB_QUEUE = Channel{Dict}(Inf)
# Channel for notifying frontend about completed jobs
const COMPLETED_JOBS = Channel{Int}(Inf)
# Atomic counter for assigning unique job IDs
const JOB_ID_COUNTER = Atomic{Int}(0)
# Background worker task that processes the job queue
const JOB_WORKER = Ref{Task}()

# Reentrant lock for thread-safe FlightGear connection management
const FGFS_LOCK = ReentrantLock()

# Function to get a new unique job ID in a thread-safe manner
next_job_id() = atomic_add!(JOB_ID_COUNTER, 1)


# Unified Request Handler - Main HTTP Router
#
# This function serves as the central router for all incoming HTTP requests.
# It analyzes the request method and path to determine the appropriate handler
# function or static file to serve. This is the main entry point for all
# HTTP traffic processed by the server.
#
# Routing Logic:
#   1. First checks for special system requests (favicon, devtools)
#   2. Routes GET requests to appropriate API endpoints or static files
#   3. Routes POST requests to API endpoints for data processing
#   4. Returns 404 for any unmatched routes
#
# Request Flow:
#   - Extract HTTP method and target path
#   - Check for system-level requests to ignore
#   - Route to API handlers based on method and path
#   - Fallback to static file serving for unmatched GET requests
#   - Return appropriate HTTP responses with correct status codes
#
# Parameters:
#   - req: HTTP.Request object containing method, target, headers, and body
#
# Returns:
#   - HTTP.Response object with appropriate status code, headers, and body
#   - Various status codes: 200 (OK), 204 (No Content), 404 (Not Found)
#
# Note: This function implements a simple but effective routing system
#       without external routing dependencies, keeping the server lightweight.

function handle(req::HTTP.Request)
    m = req.method
    p = req.target

    # Ignore irrelevant requests
    if p == "/favicon.ico"
        return HTTP.Response(204)
    end
    if p == "/.well-known/appspecific/com.chrome.devtools.json"
        return HTTP.Response(404)
    end

    # Handle API routes
    if m == "GET"
        if p == "/api/connection-state"
            conn = FGFS_CONNECTION[]
            st = conn === nothing ? "disconnected" :
                conn.actual === nothing ? "connecting" : "connected"

            body = JSON3.write((state = st,
                                server_time = Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS")))
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json",
                "Cache-Control" => "no-store",
                "Connection"    => "close",
                "Content-Length"=> string(sizeof(body))],   # forza content-length
                body
            )
        elseif p == "/api/session-info"
            return h_session_info(req)
        elseif p == "/api/fgfs-status"
            return h_fgfs_status(req)
        elseif p == "/api/completed-jobs"
            body = JSON3.write(Base.n_avail(JOB_QUEUE))
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json",
                "Cache-Control" => "no-store",
                "Connection"    => "close",
                "Content-Length"=> string(sizeof(body))],
                body
            )
        elseif p == "/api/queue-size"
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Base.n_avail(JOB_QUEUE)))
        elseif startswith(p, "/preview")
            return h_preview(req)
        elseif p == "/api/map-servers"
            return h_get_map_servers(req)
        elseif p == "/api/app-config"
            return h_app_config(req)
        elseif p == "/api/paths"
            return h_get_paths(req)
        elseif startswith(p, "/api/resolve-icao")
            return h_resolve_icao(req)
        elseif startswith(p, "/api/airports/search")
            return h_airports_search(req)
        elseif p == "/api/routes"
            return h_list_routes(req)
        elseif startswith(p, "/api/routes/")
            return h_download_route(req)
        elseif p == "/coverage.json"
            path = "coverage.json"  # adegua se lo salvi altrove
            if isfile(path)
                bytes = read(path)
                return HTTP.Response(
                    200,
                    ["Content-Type"  => "application/json",
                    "Cache-Control" => "no-store",
                    "Connection"    => "close",
                    "Content-Length"=> string(length(bytes))],
                    bytes
                )
            else
                return HTTP.Response(
                    404,
                    ["Content-Type" => "text/plain",
                    "Connection"   => "close"],
                    "coverage.json not found"
                )
            end
        elseif startswith(p, "/api/geo/box")
            return h_geo_box(req)
        elseif p == "/api/airports/resolve"
            return h_airports_resolve(req)
        elseif p == "/api/nav/circle"
            return h_nav_circle(req)
        else
            return serve_static_file(req)
        end
    elseif m == "POST"
        if p == "/api/connect"
            return h_connect(req)
        elseif p == "/api/disconnect"
            return h_disconnect(req)
        elseif p == "/api/start-job"
            return h_start_job(req)
        elseif p == "/api/fill-holes"
            return h_fill_holes(req)
        elseif p == "/api/shutdown"
            return h_shutdown(req)
        elseif p == "/api/paths"
            return h_set_paths(req)
        elseif p == "/api/save-route"
            return h_save_route(req)
        else
            return HTTP.Response(404, "Not found")
        end
    end

    return HTTP.Response(404, "Not found")
end


###############################################################################
# API Route Handlers
#
# This section contains all the functions that handle specific API endpoints.
# Each function is responsible for processing a particular type of request
# and returning an appropriate HTTP response.
#
# Functions follow the naming convention h_<endpoint> for consistency.
# All handlers receive HTTP.Request objects and return HTTP.Response objects.
# Error handling is implemented within each handler to provide meaningful
# responses to the client.
###############################################################################

function h_session_info(_req)
    payload = (startTime=SERVER_START_TIME,)
    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(payload))
end

# Handler for starting a new tile download job
#
# This endpoint processes job requests, validates parameters, resolves ICAO
# codes to coordinates if needed, and adds the job to the processing queue.
#
# Parameters (from JSON body):
#   - lat: Latitude coordinate (optional if ICAO provided)
#   - lon: Longitude coordinate (optional if ICAO provided)
#   - icao: Airport ICAO code (optional if lat/lon provided)
#   - radius: Search radius for tile processing
#
# Returns:
#   - 200 OK with job ID and coordinates on success
#   - 400 Bad Request if ICAO cannot be resolved

function h_start_job(req)
    # Force keys to be strings for consistent dictionary access
    params = Dict{String, Any}(string(k) => v for (k, v) in pairs(JSON3.read(req.body)))

    job_id = next_job_id()
    params["job_id"] = job_id

    # Handle ICAO resolution if lat/lon coordinates are missing
    if !haskey(params, "lat") || !haskey(params, "lon")
        try
            coords = GeoEngine.get_coords_from_icao(params["icao"])
            params["lat"] = coords.lat
            params["lon"] = coords.lon
            catch e
            return HTTP.Response(400, "Cannot resolve ICAO: $(params["icao"])")
        end
    end

    # Add job to the processing queue
    put!(JOB_QUEUE, params)

    # Prepare response payload with job details
    response_payload = Dict(
        "jobId"  => job_id,
        "lat"    => params["lat"],
        "lon"    => params["lon"],
        "radius" => params["radius"]
        )
    HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response_payload))
end


# Handler for retrieving completed job notifications
#
# This endpoint allows the frontend to check which jobs have completed
# processing. It drains the COMPLETED_JOBS channel and returns all
# completed job IDs that have accumulated since the last check.
#
# Parameters: None
#
# Returns:
#   - 200 OK with JSON array of completed job IDs

function h_completed_jobs(_req)
    # Collect all completed job IDs from the notification channel
    completed_ids = Int[]
    while isready(COMPLETED_JOBS)
        push!(completed_ids, take!(COMPLETED_JOBS))
    end
    HTTP.Response(200, JSON3.write(completed_ids))
end


function h_fill_holes(req)
    params = JSON3.read(req.body)
    job_id = next_job_id() # Assegniamo un ID anche a questo tipo di job

    # Accodiamo un nuovo tipo di "meta-job" che verrà gestito da launch_job_from_api
    job_params = Dict(
        "job_id"   => job_id,
        "mode"     => "fill_holes", # Un nuovo modo per identificarlo
        "bounds"   => params.bounds,
        "settings" => params.settings
        )

    put!(JOB_QUEUE, job_params)

    # Rispondi subito al client per non tenerlo in attesa
    response_payload = Dict("status" => "Fill holes job queued", "jobId" => job_id)
    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response_payload))
end


# Handler for server shutdown
#
# This endpoint provides a clean way to shutdown the server from the web interface.
# It logs the shutdown request and terminates the application process.
#
# Parameters: None
#
# Returns:
#   - This function does not return as it calls exit(0)

function h_shutdown(_req)
    @info "Shutdown requested by client"
    exit(0)
end


# Handler for establishing FlightGear connection
#
# This endpoint creates a new connection to FlightGear simulator via Telnet.
# It ensures thread-safe connection management by using a lock and properly
# handles cleanup of existing connections before creating new ones.
#
# Parameters (from JSON body):
#   - port: FlightGear Telnet port (default: 5000)
#   - host: FlightGear host address (fixed: 127.0.0.1)
#
# Returns:
#   - 200 OK with success message on successful connection start
#   - 500 Internal Server Error if connection fails
#
# Note: This function is thread-safe and handles connection cleanup

function h_connect(req)
    lock(FGFS_LOCK) do
        # 1. If a connection already exists, close it first to avoid conflicts
        if FGFS_CONNECTION[] !== nothing
            @info "GuiMode.h_connect: Found existing connection. Closing before creating new one."
            try
                sock = getfield(FGFS_CONNECTION[], :telnet).sock
                if sock !== nothing && isopen(sock)
                    close(sock)
                end
                catch e
                @warn "GuiMode.h_connect: Error closing previous socket." exception=(e, catch_backtrace())
            end
            FGFS_CONNECTION[] = nothing
            sleep(0.5) # Pause to ensure proper closure
        end

        # 2. Proceed to create a new clean connection
        try
            params = JSON3.read(req.body)
            port   = get(params, "port", 5000)
            host   = "127.0.0.1"
            @info "Starting new FGFS connection to $host:$port"
            # Increase debug level to 2 to see position logs
            FGFS_CONNECTION[] = Connector.getFGFSPositionSetTask(host, port, 10.0, 0.5, 0)
            return HTTP.Response(200, "Connection task started.")
            catch e
            @error "Connection failed" exception=(e, catch_backtrace())
            FGFS_CONNECTION[] = nothing
            return HTTP.Response(500, "Connection failed: $(sprint(showerror, e))")
        end
    end # Lock is automatically released here
end


# Handler for disconnecting from FlightGear
#
# This endpoint safely terminates the connection to FlightGear simulator.
# It checks if a connection exists and properly closes the socket before
# clearing the connection reference.
#
# Parameters: None
#
# Returns:
#   - 200 OK with confirmation message

function h_disconnect(_req)
    # Close FlightGear connection if it exists
    if FGFS_CONNECTION[] !== nothing
        sock = getfield(FGFS_CONNECTION[], :telnet).sock
        isopen(sock) && close(sock)
        FGFS_CONNECTION[] = nothing
    end
    HTTP.Response(200, "FlightGear connection terminated")
end


# Handler for retrieving FlightGear status and position data
#
# This endpoint provides real-time aircraft position and status information
# from the connected FlightGear simulator. It handles different connection
# states (disconnected, connecting, connected) and returns appropriate data.
#
# Parameters: None
#
# Returns:
#   - 200 OK with JSON containing:
#     - active: Boolean indicating connection status
#     - lat: Latitude in degrees (if active)
#     - lon: Longitude in degrees (if active)
#     - heading: Aircraft heading in degrees (if active)
#     - altitude: Altitude in feet (if active)
#     - speed: Speed in mph (if active)
function h_fgfs_status(_req)
    conn = FGFS_CONNECTION[]

    # Handle different connection states: no task, task connecting, task with data
    if conn === nothing || conn.actual === nothing
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((active=false,)))
    else
        # Connection is active and we have position data
        pos = conn.actual

        # Use correct field names from the FGFSPosition struct
        # calculated in Connector.jl
        payload = (
            active=true,
            lat=pos.latitudeDeg,
            lon=pos.longitudeDeg,
            heading=pos.directionDeg,
            altitude=pos.altitudeFt,
            speed=pos.speedMph
            )
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(payload))
    end
end


# Handler for generating coverage JSON file
#
# This endpoint triggers the generation of a coverage.json file that contains
# information about available DDS tiles and their geographic coverage. This
# file is used by the frontend to display tile availability on the map.
#
# Parameters: None
#
# Returns:
#   - 200 OK with confirmation message

function h_generate_coverage(_req)
    # Trigger coverage JSON generation
    ddsFindScanner.generate_coverage_json()
    HTTP.Response(200, "coverage.json updated")
end

function h_serve_coverage(_req)
    path = "coverage.json"
    if !isfile(path)
        return HTTP.Response(
            404,
            ["Content-Type" => "text/plain", "Connection" => "close"],
            "coverage.json not found"
        )
    end
    body = read(path)
    return HTTP.Response(
        200,
        ["Content-Type" => "application/json",
         "Cache-Control" => "no-store",
         "Connection"    => "close"],  # <-- evita EPIPE
        body
    )
end

# Handler for generating tile preview images
#
# This endpoint converts DDS tile files to PNG format for web display.
# It accepts a tile ID and optional width parameter, locates the
# corresponding DDS file, and converts it to a PNG image blob.
#
# Parameters (from query string):
#   - id: Tile ID (required)
#   - w: Preview width in pixels (optional, default: 512)
#
# Returns:
#   - 200 OK with PNG image data and appropriate Content-Type
#   - 404 Not Found if tile with specified ID doesn't exist

function h_preview(req)
    # Generate PNG preview from DDS tile
    id = parse(Int, HTTP.queryparams(req)["id"])
    w  = parse(Int, get(HTTP.queryparams(req), "w", "512"))
    paths = ddsFindScanner.find_file_by_id(id)
    isempty(paths) && return HTTP.Response(404, "Tile not found")
    dds_path = first(paths)
    png_blob = dds2pngDXT1.convert(dds_path, w)
    HTTP.Response(200, ["Content-Type" => "image/png"], png_blob)
end


# Handler for serving static files (HTML, CSS, JavaScript)
#
# This function serves static files from the filesystem, handling the root path
# by serving map.html and other paths by stripping the leading slash.
# It automatically determines the appropriate MIME type based on file extension.
#
# Parameters:
#   - req: HTTP.Request object containing the target path
#
# Returns:
#   - 200 OK with file content and appropriate Content-Type
#   - 204 No Content for favicon.ico requests
#   - 404 Not Found if file doesn't exist
#   - 500 Internal Server Error if file reading fails

function serve_static_file(req)
    # Serve static files (HTML, CSS, JS) from the filesystem
    req.target == "/favicon.ico" && return HTTP.Response(204)
    filepath = req.target == "/" ? "map.html" : lstrip(req.target, '/')
    isfile(filepath) || return HTTP.Response(404, "File not found: $(req.target)")
    try
        body = read(filepath)
        # Determine appropriate MIME type based on file extension
        mime = endswith(filepath, ".html")  ? "text/html" :
            endswith(filepath, ".js")    ? "application/javascript" :
                endswith(filepath, ".css")   ? "text/css" :
                    endswith(filepath, ".json")  ? "application/json" : "text/plain"
                HTTP.Response(200, ["Content-Type" => mime], body)
                catch e
        HTTP.Response(500, "Internal error")
    end
end


# Handler for resolving ICAO codes to geographic coordinates
#
# This endpoint converts airport ICAO codes to latitude/longitude coordinates
# using the Route module's selectIcao function. It handles various error
# conditions including missing parameters, ambiguous codes, and lookup failures.
#
# Parameters (from query string):
#   - icao: Airport ICAO code (required, 4 characters)
#
# Returns:
#   - 200 OK with JSON containing lat/lon coordinates on success
#   - 400 Bad Request if ICAO parameter is missing
#   - 404 Not Found if ICAO code cannot be resolved
#   - 500 Internal Server Error for unexpected failures

# GET /api/resolve-icao?icao=XXXX
# NOTE: legacy route kept for compatibility with old JS.
function h_resolve_icao(req::HTTP.Request)
    qs   = HTTP.URIs.queryparams(HTTP.URIs.URI(String(req.target)))
    raw  = get(qs, "icao", "")
    q    = String(raw)               # evita SubString
    q_uc = uppercase(q)

    # 1) Caso "sembra un ICAO" (4-5 alfanumerici): prova resolve diretto
    if occursin(r"^[A-Z0-9]{4,5}$", q_uc)
        a = AirportsNavaids.resolve_icao(q_uc)
        if a === nothing
            # fallback: forse l'utente ha scritto un IATA o un codice locale → prova full-text
            cand = AirportsNavaids.search_airports(q; limit=5)
            if isempty(cand)
                return HTTP.Response(404, ["Content-Type"=>"application/json"],
                                     JSON3.write((error="not found", query=q)))
                elseif length(cand) == 1
                return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON3.write(cand[1]))
            else
                # Ambiguo: ritorna lista
                arr = [ (icao=x.icao, name=x.name, lat=x.lat, lon=x.lon, elev_ft=x.elev_ft) for x in cand ]
                return HTTP.Response(409, ["Content-Type"=>"application/json"], JSON3.write((error="ambiguous", query=q, items=arr)))
            end
        else
            return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON3.write(a))
        end
    end

    # 2) Caso "testo libero" (es: 'ROMA', 'BERGAMO'): usa ricerca full-text
    cand = AirportsNavaids.search_airports(q; limit=5)
    if isempty(cand)
        return HTTP.Response(404, ["Content-Type"=>"application/json"], JSON3.write((error="not found", query=q)))
    elseif length(cand) == 1
        return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON3.write(cand[1]))
    else
        arr = [ (icao=x.icao, name=x.name, lat=x.lat, lon=x.lon, elev_ft=x.elev_ft) for x in cand ]
        return HTTP.Response(409, ["Content-Type"=>"application/json"], JSON3.write((error="ambiguous", query=q, items=arr)))
    end
end


"""
Legge params.xml e restituisce una lista di server disponibili in formato JSON.
"""
function h_get_map_servers(req)
    servers_list = []
    try
        xdoc = parse_file("params.xml")
        servers_node = find_element(root(xdoc), "servers")
        if servers_node !== nothing
            for server_node in child_elements(servers_node)
                if name(server_node) == "server"
                    server_id = content(find_element(server_node, "id"))
                    server_name = content(find_element(server_node, "name"))
                    push!(servers_list, Dict("id" => parse(Int, server_id), "name" => server_name))
                end
            end
        end
    catch e
        @error "Impossibile leggere o parsare params.xml per i server" exception=(e, catch_backtrace())
        return HTTP.Response(500, "Error reading server list from params.xml")
    end

    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(servers_list))
end


function h_app_config(req)
    # Legge il valore "server" dalla config salvata, con un default di 1 se non presente
    default_server_id = get(APP_CONFIG[], "server", 1)
    low_detail_threshold = get(APP_CONFIG[], "low_detail_threshold", 1.0)
    payload = Dict(
        "default_server" => default_server_id,
        "low_detail_threshold" => low_detail_threshold
    )
    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(payload))
end


"""
Restituisce i percorsi 'path' e 'save' attualmente in uso.
"""
function h_get_paths(req)
    lock(FGFS_LOCK) do # Usiamo un lock per l'accesso sicuro alla config
        payload = Dict(
            "path" => get(APP_CONFIG[], "path", "N/A"),
            "save" => get(APP_CONFIG[], "save", "N/A")
            )
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(payload))
    end
end

"""
Aggiorna i percorsi 'path' e 'save' nella configurazione di sessione.
"""
function h_set_paths(req)
    try
        params = JSON3.read(req.body)
        new_path = get(params, "path", nothing)
        new_save = get(params, "save", nothing)

        lock(FGFS_LOCK) do
            if new_path !== nothing
                APP_CONFIG[][ "path" ] = new_path
                mkpath(new_path) # Tentiamo di creare la cartella se non esiste
            end
            if new_save !== nothing
                APP_CONFIG[][ "save" ] = new_save
                mkpath(new_save)
            end
        end

        @info "Percorsi aggiornati via API" path=new_path save=new_save
        return HTTP.Response(200, "Paths updated successfully")
        catch e
        @error "Errore nell'aggiornamento dei percorsi via API" exception=(e, catch_backtrace())
        return HTTP.Response(500, "Failed to update paths")
    end
end

function h_save_route(req::HTTP.Request)
    # payload: { waypoints: [{name?,lat,lon,alt_ft?}...], dep_icao?, arr_icao? }
    body = JSON3.read(req.body)
    waypoints = get(body, "waypoints", nothing)
    dep_icao = get(body, "dep_icao", nothing)
    arr_icao = get(body, "arr_icao", nothing)
    include_ele = false  # puoi esporlo più avanti

    if waypoints === nothing || length(waypoints) < 2
        return HTTP.Response(400, "At least 2 waypoints required")
    end

    # funzione di lookup ICAO → (lat,lon) riusando Route.selectIcao
    lookup = icao::String -> begin
        (lat, lon, err) = Route.selectIcao(icao, 0.0)
        err == 0 || error("Cannot resolve ICAO $icao (err=$err)")
        (lat=lat, lon=lon)
    end

    # cartella di uscita: dentro la save path di sessione, in "routes"
    out_base = get(APP_CONFIG[], "save", "Orthophotos-saved")
    out_dir  = joinpath(out_base, "routes")
    mkpath(out_dir)

    try
        (filename, gpx) = Route.save_route_gpx(
            waypoints;
            dep_icao=dep_icao,
            arr_icao=arr_icao,
            lookup_icao=lookup,
            outdir=out_dir,
            include_ele=include_ele,
            route_name=nothing
        )
        # rispondi con filename + gpx (così la UI può scaricarlo subito)
        payload = Dict("filename"=>filename, "gpx"=>gpx)
        return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON3.write(payload))
    catch e
        @error "h_save_route: failed to save GPX" exception=(e, catch_backtrace())
        return HTTP.Response(500, "Failed to save GPX: $(sprint(showerror, e))")
    end
end

function _routes_outdir()
    out_base = get(APP_CONFIG[], "save", "Orthophotos-saved")
    out_dir  = joinpath(out_base, "routes")
    mkpath(out_dir)
    return out_dir
end

function h_list_routes(_req::HTTP.Request)
    dir = _routes_outdir()
    files = filter(f -> endswith(f, ".gpx"), readdir(dir; join=true))
    # Ordina per mtime desc
    sorted = sort(files, by=f->stat(f).mtime, rev=true)
    data = [Dict(
        "name"=>basename(f),
        "size"=>stat(f).size,
        "mtime"=>string(stat(f).mtime)
    ) for f in sorted]
    return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON3.write(data))
end

function h_download_route(req::HTTP.Request)
    dir = _routes_outdir()
    # /api/routes/<filename>
    segments = split(req.target, '/')
    if length(segments) < 4
        return HTTP.Response(400, "Missing filename")
    end
    fname = segments[end]
    path = joinpath(dir, fname)
    if !isfile(path)
        return HTTP.Response(404, "Route not found")
    end
    body = read(path)
    return HTTP.Response(
        200,
        ["Content-Type"=>"application/gpx+xml",
         "Content-Disposition"=>"attachment; filename=$(fname)"],
        body
    )
end

function h_airports_search(req::HTTP.Request)
    params = HTTP.queryparams(req)
    q     = get(params, "q", "") |> String
    limit = parse(Int, get(params, "limit", "10"))
    isempty(q) && return HTTP.Response(400, "Missing q")

    try
        # 1) Cerca SEMPRE sia negli aeroporti (inclusi eliporti) che nei navaid
        results_ap = AirportsNavaids.search_airports(q;  limit = limit)
        results_nv = AirportsNavaids.search_navaids(q;   limit = limit)

        # Helper per leggere i campi in modo robusto
        _extract(a, sym::Symbol, default) =
            hasproperty(a, sym) ? getfield(a, sym) :
                (a isa AbstractDict ? get(a, sym, get(a, String(sym), default)) : default)

        # 2) Mappa gli aeroporti
        items_ap = [Dict(
            "kind"         => "airport",
            "icao"         => String(_extract(a, :icao, "")),
            "name"         => String(_extract(a, :name, "")),
            "lat"          => Float64(_extract(a, :lat,  NaN)),
            "lon"          => Float64(_extract(a, :lon,  NaN)),
            "elev_ft"      => _extract(a, :elev_ft, missing),
            "municipality" => String(_extract(a, :municipality, "")),
            "iata_code"    => String(_extract(a, :iata_code, ""))
            ) for a in results_ap]

        # 3) Mappa i navaid (ident -> icao, type nel campo iata_code per mostrarlo fra parentesi)
        items_nv = [Dict(
            "kind"         => "navaid",
            "icao"         => String(_extract(nv, :ident, "")),
            "name"         => String(_extract(nv, :name, "")),
            "lat"          => Float64(_extract(nv, :lat,  NaN)),
            "lon"          => Float64(_extract(nv, :lon,  NaN)),
            "elev_ft"      => _extract(nv, :elev_ft, missing),
            "municipality" => "",
            "iata_code"    => String(_extract(nv, :type, ""))  # es. "VOR", "NDB"
            ) for nv in results_nv]

            # 4) Unisci; opzionale: taglia a 'limit' risultati totali
            items = vcat(items_ap, items_nv)
            if length(items) > limit
                items = items[1:limit]
            end

        return HTTP.Response(
            200,
            ["Content-Type" => "application/json"],
            JSON3.write(Dict("items" => items))
            )
    catch e
        @error "airports/search failed" exception=(e, catch_backtrace())
        return HTTP.Response(500, "airports search not available")
    end
end



function h_connection_state(_req::HTTP.Request)
    # metti qui eventuali flag reali se li hai:
    payload = Dict(
        "ok" => true,
        "fgfs_connected" => get(GLOBAL_STATE, :fgfs_connected, false),
        "server_time" => Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS")
    )
    return HTTP.Response(
        200,
        ["Content-Type" => "application/json", "Connection" => "close"],
        JSON3.write(payload)
    )
end

# -------- helpers sottotipi airport --------
@inline function _is_heli(a::Dict)
    t = lowercase(String(get(a, "type", get(a,"kind",""))))
    return occursin("heliport", t) || occursin("helipad", t)
end

@inline function _has_iata(a::Dict)
    v = get(a, "iata", nothing)
    return !(v === nothing || v === missing || String(v) == "" )
end

@inline function _is_major(a::Dict)
    # large/medium => major; se manca il type, considera major se ha IATA
    t = lowercase(String(get(a, "type", "")))
    return occursin("large_airport", t) || occursin("medium_airport", t) || _has_iata(a)
end

function h_geo_box(req::HTTP.Request)
    qs = HTTP.URIs.queryparams(HTTP.URIs.URI(String(req.target)))

    # bbox
    nw_lat = parse(Float64, get(qs, "nw_lat", "0"))
    nw_lon = parse(Float64, get(qs, "nw_lon", "0"))
    se_lat = parse(Float64, get(qs, "se_lat", "0"))
    se_lon = parse(Float64, get(qs, "se_lon", "0"))

    # types può essere:
    #  - "all" | "airports" | "navaids" (back-compat)
    #  - CSV con sottotipi: airports_major,airports_minor,heliports,navaids
    types_raw = lowercase(get(qs, "types", "all"))
    types_set = Set(split(types_raw, ','))

    # back-compat: mappa "all"/"airports" ai sottotipi
    if types_raw == "all"
        empty!(types_set)
        push!(types_set, "airports_major", "airports_minor", "heliports", "navaids")
    elseif types_raw == "airports"
        empty!(types_set)
        push!(types_set, "airports_major", "airports_minor", "heliports")
    end

    # quali gruppi servono davvero
    want_nv   = "navaids"        in types_set
    want_amaj = "airports_major" in types_set
    want_amin = "airports_minor" in types_set
    want_heli = "heliports"      in types_set

    # cap (totali per gruppo; lato client puoi passare &max_total=..., qui li applichiamo per-gruppo)
    max_airports_total = parse(Int, get(qs, "max_total", get(qs, "max_airports", "1000")))
    max_navaids_total  = parse(Int, get(qs, "max_total", get(qs, "max_navaids",  "1000")))

    # chiama una sola volta il collector (altrimenti = doppio lavoro)
    include_airports = (want_amaj || want_amin || want_heli)
    include_navaids  = want_nv

    collected = AirportsNavaids.collect_bbox(
        nw_lat, nw_lon, se_lat, se_lon;
        include_airports=include_airports,
        include_navaids=include_navaids,
        # chiediamo un po' più ampio e poi tagliamo per sottotipo
        max_airports = max(2*max_airports_total, 10_000),
        max_navaids  = max_navaids_total,
    )

    # risposta con chiavi separate
    resp = Dict{String,Any}()

    # navaid: passa diretto (già filtrati nel bbox)
    if want_nv
        resp["navaids"] = get(collected, "navaids", Any[])
        if length(resp["navaids"]) > max_navaids_total
            resize!(resp["navaids"], max_navaids_total)
        end
    end

    # airports: splitta in tre array
    if include_airports
        airports_all = get(collected, "airports", Any[])
        majors   = Any[]
        minors   = Any[]
        helis    = Any[]

        for a in airports_all
            if _is_heli(a)
                push!(helis, a)
            elseif _is_major(a)
                push!(majors, a)
            else
                push!(minors, a)
            end
        end

        # cap per gruppo
        if want_amaj
            if length(majors) > max_airports_total
                resize!(majors, max_airports_total)
            end
            resp["airports_major"] = majors
        end
        if want_amin
            if length(minors) > max_airports_total
                resize!(minors, max_airports_total)
            end
            resp["airports_minor"] = minors
        end
        if want_heli
            if length(helis) > max_airports_total
                resize!(helis, max_airports_total)
            end
            resp["heliports"] = helis
        end
    end

    # per completezza, includi bbox/contatori se ti servono in futuro
    # (commenta se vuoi una payload minimale)
    # resp["bbox"]   = collected["bbox"]

    return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON3.write(resp))
end


function h_geo_circle(req::HTTP.Request)
    qs = HTTP.URIs.queryparams(HTTP.URIs.URI(String(req.target)))
    lat = parse(Float64, get(qs, "lat", "0"))
    lon = parse(Float64, get(qs, "lon", "0"))
    rkm = parse(Float64, get(qs, "r_km", "10"))

    types = lowercase(get(qs, "types", "all"))
    inc_ap = types in ("all","airports")
    inc_nv = types in ("all","navaids")

    max_ap = parse(Int, get(qs, "max_airports", "10000"))
    max_nv = parse(Int, get(qs, "max_navaids",  "10000"))

    body = AirportsNavaids.circle_json(lat, lon, rkm;
                                       include_airports=inc_ap,
                                       include_navaids=inc_nv,
                                       max_airports=max_ap,
                                       max_navaids=max_nv)
    return HTTP.Response(200, ["Content-Type"=>"application/json"], body)
end


# GET /api/airports/resolve?icao=LIME
function h_airports_resolve(req::HTTP.Request)
    qs   = HTTP.URIs.queryparams(HTTP.URIs.URI(String(req.target)))
    icao = String(get(qs, "icao", ""))
    a    = AirportsNavaids.resolve_icao(icao)

    if a === nothing
        return HTTP.Response(404, ["Content-Type"=>"application/json"], JSON3.write((error="not found",)))
    end
    return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON3.write(a))
end

# GET /api/nav/circle?lat=...&lon=...&radius_nm=...
function h_nav_circle(req::HTTP.Request)
    qs   = HTTP.URIs.queryparams(HTTP.URIs.URI(String(req.target)))
    lat  = try parse(Float64, get(qs, "lat", "0")) catch; 0.0 end
    lon  = try parse(Float64, get(qs, "lon", "0")) catch; 0.0 end
    r_nm = try parse(Float64, get(qs, "radius_nm", "20")) catch; 20.0 end
    r_nm = clamp(r_nm, 0.1, 500.0)

    json = AirportsNavaids.circle_json(lat, lon, r_nm;
                                        include_airports=true, include_navaids=true,
                                        max_airports=1000, max_navaids=1000)

    return HTTP.Response(200, ["Content-Type"=>"application/json"], json)
end

###############################################################################
# Background Worker Management
#
# This section contains functions for managing the background job processing
# system. The background worker runs asynchronously and processes jobs from
# the queue without blocking the main HTTP server thread.
###############################################################################

# Background Worker Starter - Job Processing System Initialization
#
# This function initializes and starts the background worker that processes
# the job queue. It creates a persistent task that continuously monitors
# the JOB_QUEUE channel and dispatches jobs for parallel processing.
#
# Architecture:
#   - Creates a single persistent task using @spawn
#   - The task runs an infinite loop that waits for jobs
#   - Each job is processed in a separate parallel task
#   - Provides non-blocking job processing for the HTTP server
#
# Job Processing Flow:
#   1. Main worker task waits for jobs in JOB_QUEUE channel
#   2. When a job arrives, it spawns a new parallel task
#   3. The parallel task executes the actual job processing
#   4. Main worker continues waiting for next job (non-blocking)
#   5. Completed jobs notify the frontend via COMPLETED_JOBS channel
#
# Thread Safety:
#   - Uses Julia's @spawn for true parallel execution
#   - Each job runs in its own task context
#   - Atomic operations for job ID assignment
#   - Channel-based communication for thread safety
#
# Error Handling:
#   - Each job is wrapped in try-catch block
#   - Failed jobs are logged but don't crash the worker
#   - Completion notification is sent regardless of success/failure
#
# Resource Management:
#   - Worker task is stored in JOB_WORKER Ref for lifecycle management
#   - Channels are unbounded (Inf capacity) to prevent blocking
#   - No explicit cleanup needed - tasks are garbage collected
#
# Parameters: None
#
# Returns: Nothing (side effect: starts background task)
#
# Note: This function should be called once during server startup
#       The worker runs indefinitely until the server shuts down

function start_background_worker()
    # Start the background worker that processes the job queue
    JOB_WORKER[] = @spawn begin
        # This loop acts as a "dispatcher" for incoming jobs
        for job in JOB_QUEUE
            # For each received job, spawn a new async task
            # that executes it in parallel without blocking the main loop
            @spawn begin
                job_id = job["job_id"]
                try
                    @info "Starting job #$job_id in parallel task" job
                    # Execute the actual job processing
                    launch_job_from_api(job)
                    @info "Job #$job_id completed successfully"
                    catch e
                    @error "Job #$job_id failed" exception=(e, catch_backtrace())
                finally
                    # Always notify job completion (success or failure)
                    # so the green indicator can disappear from UI
                    put!(COMPLETED_JOBS, job_id)
                end
            end
        end
    end
end

###############################################################################
# Server Error Handler - HTTP Server Error Management
#
# This section contains the global error handler for the HTTP server.
# It provides centralized error processing and logging for all server
# operations, ensuring graceful handling of unexpected failures.
###############################################################################

# Global HTTP Server Error Handler
#
# This function serves as the centralized error handler for the HTTP server.
# It is called automatically by the HTTP.jl server when any unhandled
# exception occurs during request processing. The handler categorizes
# errors and provides appropriate logging based on error type.
#
# Error Classification Strategy:
#   - Broken Pipe Errors (EPIPE): Client disconnected prematurely
#   - All Other Errors: Critical server failures requiring attention
#
# Error Handling Logic:
#   - Checks if the error is a Base.IOError with EPIPE code
#   - Treats EPIPE as a warning (common occurrence with web clients)
#   - Treats all other errors as critical failures
#   - Provides detailed exception logging with stack traces
#
# Logging Strategy:
#   - EPIPE errors: Logged as warnings to reduce alarm
#     These are normal when clients close connections unexpectedly
#   - Other errors: Logged as critical errors with full stack traces
#     These indicate potential server bugs or serious issues
#
# Parameters:
#   - req: HTTP.Request object that triggered the error
#   - e: Exception object that was thrown
#
# Returns: Nothing (side effect: logs the error)
#
# Error Types Handled:
#   - Base.IOError with UV_EPIPE code: Client disconnection
#   - All other exception types: Server failures
#
# Integration:
#   - This function is passed to HTTP.serve() as the on_error callback
#   - Automatically called by the HTTP server when exceptions occur
#   - Prevents server crashes from unhandled exceptions
#
# Note: This handler provides graceful degradation rather than
#       attempting to recover from errors. The server continues
#       running even when individual requests fail.

function handle_server_error(req, e)
    # Check if the error is a "broken pipe" (client disconnected)
    if isa(e, Base.IOError) && e.code == Base.UV_EPIPE
        # Log as warning instead of error, less alarming
        @warn "Client connection closed prematurely (EPIPE)" request_target=req.target
    else
        # For all other errors, which are potentially serious,
        # continue logging them as critical errors
        @error "Critical server error!" exception=(e, catch_backtrace())
    end
end

###############################################################################
# Server Startup and Configuration
#
# This section contains the main server initialization and startup logic.
# It handles command line argument parsing, service initialization,
# and launching the HTTP server with proper configuration.
###############################################################################

# Main Server Startup Function - HTTP Server Initialization
#
# This is the primary entry point for starting the web GUI server.
# It handles command line argument parsing, initializes background services,
# configures logging, and launches the HTTP server with appropriate settings.
#
# Startup Sequence:
#   1. Parse command line arguments for HTTP port configuration
#   2. Set default host and port values
#   3. Configure global logging settings
#   4. Start background services (DDS scanner, job worker)
#   5. Launch the HTTP server with custom error handler
#   6. Log server startup information
#
# Command Line Arguments:
#   --http[=PORT]: Specify HTTP port (default: 8000)
#   Examples:
#     --http          → Use default port 8000
#     --http=8080     → Use port 8080
#     (no argument)   → Use default port 8000
#
# Configuration Parameters:
#   - host: Server bind address (fixed: 127.0.0.1 for local access)
#   - port: HTTP port for web interface (default: 8000, configurable)
#   - logging: Console logger with Info level verbosity
#   - error_handler: Custom error handling function
#   - verbose: Disabled to reduce log noise
#
# Background Services Started:
#   - DDS Scanner: Asynchronous tile file discovery (ddsFindScanner.startFind())
#   - Job Worker: Background job processing queue (start_background_worker())
#
# Server Features:
#   - HTTP/1.1 server with keep-alive support
#   - Static file serving (HTML, CSS, JavaScript)
#   - RESTful API endpoints
#   - Real-time FlightGear connectivity
#   - Asynchronous job processing
#   - Custom error handling and logging
#
# Parameters:
#   - args: Vector{String} of command line arguments (default: ARGS)
#
# Returns: Nothing (side effect: starts HTTP server that runs indefinitely)
#
# Error Handling:
#   - Command line parsing errors use default values
#   - Server startup errors are logged and may cause program termination
#   - Runtime errors are handled by the custom error handler
#
# Usage Examples:
#   - run()                    → Start with default settings (port 8000)
#   - run(["--http=8080"])     → Start on port 8080
#   - run(["--http"])          → Start with default port (explicit)
#
# Note: This function blocks indefinitely once the HTTP server starts.
#       The server runs until explicitly shut down via /api/shutdown or
#       terminated by the operating system.

function run(args::Vector{String}=ARGS)
    # 1. Parsa gli argomenti e inizializza la configurazione globale
    APP_CONFIG[] = AppConfig.parse_args(args)

    # 2. Determina i percorsi una sola volta all'avvio
    home_path = @__DIR__
    _, _, initial_root_path, initial_save_path = GeoEngine.prepare_paths_and_location(APP_CONFIG[], home_path)

    # 3. Salva i percorsi definitivi nella configurazione globale
    APP_CONFIG[][ "path" ] = initial_root_path
    APP_CONFIG[][ "save" ] = initial_save_path

    # 4. Costruisci la lista COMPLETA dei percorsi da scansionare
    @info "GuiMode: Costruzione della lista dei percorsi di scansione..."

    # 4a. Carica i metadati dall'indice esistente per recuperare i percorsi precedenti
    metadata, _ = ddsFindScanner.load_data()
    previous_paths = String[]
    if metadata !== nothing
        # Usiamo get() per sicurezza, nel caso la chiave non esista
        previous_paths = get(metadata, "scanned_paths", [])
        @info "Trovati $(length(previous_paths)) percorsi dalle scansioni precedenti."
    end

    # 4b. Unisci i percorsi attivi con quelli precedenti usando un Set per evitare duplicati
    combined_paths = Set{String}()
    push!(combined_paths, initial_root_path)
    if initial_save_path !== nothing
        push!(combined_paths, initial_save_path)
    end
    union!(combined_paths, previous_paths) # Aggiunge tutti i percorsi precedenti al set

    # Converte il set di nuovo in un vettore per la funzione
    final_scan_paths = collect(combined_paths)
    @info "Scansione avviata su un totale di $(length(final_scan_paths)) percorsi unici."

    # 5. Avvia lo scanner DDS in modo intelligente con la lista completa
    ddsFindScanner.startFind(final_scan_paths, ddsFindScanner.PROGRAM_VERSION)

    # 6. Definisci tmp_dir qui, dove è visibile a tutta la funzione
    tmp_dir = joinpath(initial_save_path, "tmp")
    mkpath(tmp_dir) # Assicurati che la cartella tmp esista

    # Esegui il recupero dei tile orfani prima di avviare i servizi principali
    ## GeoEngine.recover_orphaned_tiles(tmp_dir, initial_root_path, initial_save_path, APP_CONFIG[])
    @async begin
        while true
            sleep(60) # ogni 1 minuti, regola a piacere
            try
                GeoEngine.recover_orphaned_tiles(tmp_dir, initial_root_path, initial_save_path, APP_CONFIG[])
                catch e
                @error "Recover orphaned tiles periodic failed" exception=(e, catch_backtrace())
            end
        end
    end

    # Start Airports/Navaids service asynchronously (non blocca la GUI)
    try
        AirportsNavaids.start!(; async=true)   # 👈 ora chiami diretto, senza Photoscenary.
        @info "[AirportsNavaids] background bootstrap started"
    catch e
        @warn "[AirportsNavaids] could not start" exception=e
    end

    port = get(APP_CONFIG[], "http", 8000)
    host = "127.0.0.1"

    # 5. Configura il logger e avvia i servizi in background
    global_logger(ConsoleLogger(stderr, Logging.Info))
    start_background_worker()

    # 6. Usa le variabili corrette (`initial_...` e `tmp_dir`) per avviare il monitor
    runtime_cfg = Dict{String, Any}(APP_CONFIG[])
    @async AssemblyMonitor.monitor_and_assemble(initial_root_path, initial_save_path, tmp_dir, runtime_cfg)

    @info "Web GUI server running at http://$host:$port/"
    HTTP.serve(handle, host, port; on_error=handle_server_error, verbose=false)
end

###############################################################################
# Job Processing Function
#
# This section contains the core job processing logic that handles tile
# download and conversion operations. It manages job configuration,
# path preparation, and coordinates with various modules for processing.
###############################################################################

# Core Job Processing Function - Tile Download and Conversion Handler
#
# This function implements the main job processing logic for downloading
# and converting map tiles for the FlightGear simulator. It processes
# job parameters, prepares file paths, and orchestrates the tile processing
# workflow through multiple modules.
#
# Job Processing Workflow:
#   1. Extract and validate job parameters from the request
#   2. Handle special parameter processing (sdwn configuration)
#   3. Build configuration dictionary for tile processing
#   4. Prepare file paths and location data using GeoEngine
#   5. Initialize map server for downloading operations
#   6. Process each coordinate in the route vector
#   7. Execute tile processing for each geographic area
#
# Parameter Processing:
#   - job_id: Unique identifier for logging and tracking
#   - lat/lon: Geographic coordinates for tile processing
#   - radius: Search radius for tile coverage area
#   - size: Tile size parameter for processing
#   - over: Overlap parameter for tile edges
#   - server: Map server selection for downloads
#   - sdwn: Special download parameter (-1/0 = disabled, other values = enabled)
#
# Special Parameter Handling:
#   - sdwn parameter: Complex logic to handle disabled/enabled states
#     - Default: -1 (disabled)
#     - JSON null: Treated as disabled (0)
#     - Numeric values: Converted to Int for processing
#     - This parameter controls special download behavior
#
# Module Integration:
#   - GeoEngine: Path preparation and geographic calculations
#   - Downloader: Map server initialization and tile downloading
#   - Commons: Map coordinate data structures
#   - Route: Route vector processing and coordinate management
#
# File Management:
#   - Uses @__DIR__ to get current module path for relative paths
#   - Prepares root_path and save_path for file operations
#   - Handles both temporary and final file storage locations
#
# Error Handling:
#   - Comprehensive try-catch block around entire job processing
#   - Detailed error logging with job identification
#   - Finally block ensures job completion notification
#   - Errors don't prevent completion notification (UI updates)
#
# Performance Considerations:
#   - Processes multiple coordinates in route vector sequentially
#   - Each coordinate creates a separate geographic area for processing
#   - Uses efficient data structures for configuration management
#   - Minimizes memory usage through streaming operations
#
# Parameters:
#   - params: Dictionary containing job configuration and parameters
#     Required keys: "job_id", "lat", "lon"
#     Optional keys: "radius", "size", "over", "server", "sdwn"
#
# Returns: Nothing (side effect: processes tiles and updates file system)
#
# Error Recovery:
#   - Individual coordinate processing failures don't stop entire job
#   - Errors are logged but job continues with next coordinate
#   - Completion notification sent regardless of success/failure
#
# Logging:
#   - Job start and completion logged with job ID
#   - Errors logged with full stack traces for debugging
#   - Progress information available through server logs
#
# Note: This function is called by the background worker and should
#       not be called directly from HTTP request handlers.


function launch_job_from_api(params::Dict)
    job_id = params["job_id"]
    @info "Starting job #$job_id in parallel task" job=params

    try
        # Normalizza le chiavi a stringa per un accesso sicuro
        p = Dict(string(k) => v for (k, v) in pairs(params))
        job_mode = get(p, "mode", "manual")
        home_path = @__DIR__

        # --- INIZIO BLOCCO DI SMISTAMENTO ---

        if job_mode == "manual" || job_mode == "daa"
            # --- PERCORSO LOGICO 1: JOB STANDARD (DAA O MANUALE) ---

            # 1. Costruisci la configurazione 'cfg' che richiede lat/lon
            sdwn_value = get(p, "sdwn", -1)
            if sdwn_value == -1 || sdwn_value === nothing; sdwn_value = 0; else sdwn_value = Int(sdwn_value); end

            cfg = Dict{String, Any}(
                "radius" => get(p, "radius", 10.0),
                "size"   => get(p, "size", 4),
                "over"   => get(p, "over", 1),
                "lat"    => p["lat"], # Qui è sicuro, perché questo job DEVE avere lat/lon
                "lon"    => p["lon"],
                "server" => get(p, "server", 1),
                "sdwn"   => sdwn_value,
                "mode"   => job_mode,
                )

            # 2. Prepara percorsi e server mappe
            route_vec, _, root_path, save_path = GeoEngine.prepare_paths_and_location(cfg, home_path)
            map_srv = Downloader.MapServer(get(cfg, "server", 1))

            # 3. Esegui il processo per ogni punto della rotta
            for (lat, lon) in route_vec
                area = Commons.MapCoordinates(lat, lon, Float64(cfg["radius"]))
                heading_deg = nothing
                alt_ft      = nothing
                if job_mode == "daa"
                    try
                        if FGFS_CONNECTION[] !== nothing && FGFS_CONNECTION[].actual !== nothing
                            heading_deg = FGFS_CONNECTION[].actual.directionDeg
                            alt_ft      = FGFS_CONNECTION[].actual.altitudeFt
                        end
                    catch
                        heading_deg, alt_ft = nothing, nothing
                    end
                end
                GeoEngine.process_target_area(area, cfg, map_srv, root_path, save_path, heading_deg, alt_ft)
            end

        elseif job_mode == "fill_holes"
            # 1. Estrai i dati specifici per questo job
            bounds = p["bounds"]
            settings = p["settings"]
            fill_cfg = Dict(string(k)=>v for (k,v) in pairs(settings))

            # 2. Abbiamo bisogno dei percorsi, ma non abbiamo un lat/lon.
            #    Chiamiamo prepare_paths_and_location con una config vuota
            #    per fargli usare la sua logica di ricerca automatica della cartella "Orthophotos".
            _, _, root_path, save_path = GeoEngine.prepare_paths_and_location(Dict{String, Any}(), home_path)
            tmp_dir = joinpath(save_path, "tmp")
            mkpath(tmp_dir)
            map_srv = Downloader.MapServer(get(fill_cfg, "server", 1))

            # 3. Chiama la funzione specializzata per il riempimento
            @async GeoEngine.process_fill_holes(bounds, fill_cfg, map_srv, root_path, save_path, tmp_dir)
        end
    catch e
        @error "GuiMode.launch_job_from_api: ❌ Job failed" exception=(e, catch_backtrace())
    finally
        @info "GuiMode.launch_job_from_api: Job #$job_id **always** completed"
    end
end


end # module
