"""
# Route Module

Handles route loading and airport location lookup for flight planning.

    Key Features:
    - Supports multiple route file formats (FGFS, GPX)
    - Airport database lookup by ICAO code
    - Route point interpolation
    - Distance calculations between waypoints
    - Comprehensive error handling

    Dependencies:
    - LightXML: XML file parsing
    - Geodesy: Geographical calculations
    - CSV/DataFrames: Airport database handling
    - StatusMonitor: Progress reporting
"""


module Route

using Unicode, LightXML, Geodesy, Printf, CSV, DataFrames, Serialization, JSON3, HTTP
using ..StatusMonitor, ..Connector, ..Commons, ..ScanDir

export loadRoute, selectIcao, search_by_name


"""
findFileOfRoute(fileName::String, idTypeOfFile::Int=0)

Locates and parses route files in supported formats.
- fileName: Route file name or pattern
- idTypeOfFile: Format selector (0=auto, 1=FGFS, 2=GPX)

Returns: (route_xml, file_path, format_name) or (nothing, nothing, nothing)
"""
function findFileOfRoute(fileName::String, idTypeOfFile::Int=0)
    typeOfFile = [("FGFS", "route"), ("GPX", "rte")]
    date = 0.0
    fileId = 0
    route = nothing

    # Commons.findFile returns a vector of FoundFile structs
    files = Commons.findFile(fileName)
    if isempty(files); return nothing, nothing, nothing; end

    # Create mapping from file ID to array index for safe access
    file_map = Dict(f.id => i for (i, f) in enumerate(files))

    typeOfFileSelected = nothing

    for file in files
        if file.mtime >= date
            try
                if idTypeOfFile > 0
                    route = get_elements_by_tagname(LightXML.root(parse_file(file.path)), typeOfFile[idTypeOfFile][2])
                    typeOfFileSelected = typeOfFile[idTypeOfFile][1]
                else
                    for (nameFormat, selector) in typeOfFile
                        route = get_elements_by_tagname(LightXML.root(parse_file(file.path)), selector)
                        typeOfFileSelected = nameFormat
                        if size(route)[1] > 0 break end
                    end
                end

                fileId = file.id
                date = file.mtime

                catch e
                # If XML parsing fails, skip the file
                @warn "Unable to parse route file: $(file.path). Error: $e"
            end
        end
    end

    if fileId > 0
        file_index = file_map[fileId]
        return route, files[file_index].path, typeOfFileSelected
    else
        return nothing, nothing, nothing
    end
end


"""
selectIcao(icaoToSelect, centralPointRadiusDistance)

Looks up airport coordinates by ICAO code or name.
- icaoToSelect: Airport identifier or name
- centralPointRadiusDistance: Search radius in nautical miles

Returns: (latitude, longitude, errorCode)
"""
function selectIcao(icaoToSelect, centralPointRadiusDistance)
    StatusMonitor.log_message("selectIcao: Starting search for ICAO='$(icaoToSelect)' with radius=$(centralPointRadiusDistance) nm")

        centralPointLat = nothing
        centralPointLon = nothing
        errorCode = 0
        retryNumber = 0

    while retryNumber <= 1
        # Check if CSV database is newer than serialized version
        if stat("airports.csv").mtime > stat("airports.jls").mtime
            StatusMonitor.log_message("Converting airport database...")
            serialize("airports.jls", DataFrame(CSV.File("airports.csv")))
            StatusMonitor.log_message("Airport database converted to 'airports.jls'.")
            elseif stat("airports.jls").mtime == 0.0
            StatusMonitor.log_message("Error: Both airports.jls and airports.csv are unavailable.")
            errorCode = 403
            retryNumber = 9
        end

        if errorCode == 0
            try
                db = deserialize("airports.jls")
                searchString = Unicode.normalize(uppercase(icaoToSelect), stripmark=true)

                # Search by ICAO code
                foundDatas = filter(i -> (i.ident == searchString), db)

                # Fallback to municipality name
                if size(foundDatas)[1] == 0
                    foundDatas = filter(i -> occursin(searchString, Unicode.normalize(uppercase(i.municipality), stripmark=true)), dropmissing(db, :municipality))
                end

                # Fallback to airport name
                if size(foundDatas)[1] == 0
                    foundDatas = filter(i -> occursin(searchString, Unicode.normalize(uppercase(i.name), stripmark=true)), dropmissing(db, :name))
                end

                if size(foundDatas)[1] == 1
                    if centralPointRadiusDistance === nothing || centralPointRadiusDistance <= 1.0
                        centralPointRadiusDistance = 10.0
                    end
                    centralPointLat = foundDatas[1, :latitude_deg]
                    centralPointLon = foundDatas[1, :longitude_deg]

                    # Handle potential coordinate format issues
                    if !(Commons.inValue(centralPointLat, 90) && Commons.inValue(centralPointLon, 180))
                        if abs(centralPointLat) > 1000.0; centralPointLat /= 1000.0; end
                        if abs(centralPointLon) > 1000.0; centralPointLon /= 1000.0; end
                    end

                    StatusMonitor.log_message("Found ICAO: $(foundDatas[1,:ident]) - $(foundDatas[1,:name])")
                    StatusMonitor.log_message("Center: Lat $(round(centralPointLat,digits=4)), Lon $(round(centralPointLon,digits=4)), Radius: $centralPointRadiusDistance nm")
                else
                    if size(foundDatas)[1] > 1
                        errorCode = 401
                        StatusMonitor.log_message("Error: ICAO '$(icaoToSelect)' is ambiguous, found $(size(foundDatas)[1]) results.")
                        for i in 1:min(size(foundDatas)[1], 5)
                            StatusMonitor.log_message("  -> Id: $(foundDatas[i,:ident]), Name: $(foundDatas[i,:name]) ($(foundDatas[i,:municipality]))")
                        end
                    else
                        errorCode = 400
                        StatusMonitor.log_message("Error: ICAO '$(icaoToSelect)' not found in database.")
                    end
                end
                retryNumber = 9
                catch err
                if retryNumber == 0
                    retryNumber = 1
                    StatusMonitor.log_message("Error: airports.csv is corrupt or missing. Retrying.")
                    errorCode = 403
                else
                    StatusMonitor.log_message("CRITICAL ERROR: airports.csv is corrupt. Please check and restart. Error: $err")
                    errorCode = 404
                    retryNumber = 9
                end
            end
        end
        if retryNumber == 0; retryNumber = 9; end
    end

    StatusMonitor.log_message("selectIcao: Search completed. Lat=$(centralPointLat), Lon=$(centralPointLon), ErrorCode=$(errorCode)")

    return centralPointLat, centralPointLon, errorCode
end


"""
getRouteListFormatFGFS!(routeList, route, minDistance)

Processes FGFS format route waypoints with interpolation.
- routeList: Array to store waypoints
- route: XML route data
- minDistance: Minimum distance between interpolated points
"""
function getRouteListFormatFGFS!(routeList,route,minDistance)
    wps = LightXML.get_elements_by_tagname(route[1][1], "wp")
    centralPointLatPrec = nothing
    centralPointLonPrec = nothing
    for wp in wps
        foundData = false
        if wp != nothing
            if find_element(wp,"icao") != nothing
                icao = strip(content(find_element(wp,"icao")))
                (centralPointLat, centralPointLon, errorCode) = selectIcao(icao,minDistance)
                if errorCode == 0 foundData = true end
                elseif find_element(wp,"lon") != nothing
                centralPointLat = Base.parse(Float64, strip(content(find_element(wp,"lat"))))
                centralPointLon = Base.parse(Float64, strip(content(find_element(wp,"lon"))))
                foundData = true
            end
            if foundData
                # Calculate distance from previous point
                if centralPointLatPrec != nothing && centralPointLonPrec != nothing
                    posPrec = Geodesy.LLA(centralPointLatPrec,centralPointLonPrec, 0.0)
                    pos = Geodesy.LLA(centralPointLat,centralPointLon, 0.0)
                    distanceNm = euclidean_distance(pos,posPrec) / 1852.0
                else
                    distanceNm = 0.0
                end

                # Interpolate points if distance exceeds threshold
                if minDistance < distanceNm
                    numberTrunk = Int32(round(distanceNm / minDistance))
                    for i in 1:(numberTrunk - 1)
                        degLat = centralPointLatPrec + i * (centralPointLat - centralPointLatPrec) / numberTrunk
                        deglon = centralPointLonPrec + i * (centralPointLon - centralPointLonPrec) / numberTrunk
                        dist = euclidean_distance(Geodesy.LLA(degLat,deglon, 0.0),posPrec) / 1852.0
                        push!(routeList,(degLat, deglon, dist))
                        StatusMonitor.log_message(@sprintf("Route segment %d.%d -> Lat: %.4f, Lon: %.4f", size(routeList)[1], i, routeList[end][1], routeList[end][2]))
                    end
                end
                push!(routeList,(centralPointLat, centralPointLon, distanceNm))
                StatusMonitor.log_message(@sprintf("Waypoint %d -> Lat: %.4f, Lon: %.4f, Dist: %.1f nm", size(routeList)[1], routeList[end][1], routeList[end][2], distanceNm))
                centralPointLatPrec = centralPointLat
                centralPointLonPrec = centralPointLon
            end
        end
    end
    return routeList
end


"""
getRouteListFormatGPX!(routeList, route, minDistance)

Processes GPX format route waypoints with interpolation.
- routeList: Array to store waypoints (modified in-place)
- route: XML route data from GPX file
- minDistance: Minimum distance between interpolated points (in nautical miles)

Handles GPX route points (<rtept> elements) with lat/lon attributes.
Automatically interpolates additional points when distance between
waypoints exceeds minDistance.
"""
function getRouteListFormatGPX!(routeList, route, minDistance)
    wps = LightXML.get_elements_by_tagname(route[1][1], "rtept")
    centralPointLatPrec = nothing
    centralPointLonPrec = nothing

    for wp in wps
        if wp != nothing
            if attribute(wp,"lon") != nothing && attribute(wp,"lat") != nothing
                centralPointLat = Base.parse(Float64, strip(attribute(wp,"lat")))
                centralPointLon = Base.parse(Float64, strip(attribute(wp,"lon")))

                # Calculate distance from previous point
                if centralPointLatPrec != nothing && centralPointLonPrec != nothing
                    posPrec = Geodesy.LLA(centralPointLatPrec, centralPointLonPrec, 0.0)
                    pos = Geodesy.LLA(centralPointLat, centralPointLon, 0.0)
                    distanceNm = euclidean_distance(pos, posPrec) / 1852.0
                else
                    distanceNm = 0.0
                end

                # Interpolate additional points if needed
                if minDistance < distanceNm
                    numberTrunk = Int32(round(distanceNm / minDistance))
                    for i in 1:(numberTrunk - 1)
                        degLat = centralPointLatPrec + i * (centralPointLat - centralPointLatPrec) / numberTrunk
                        deglon = centralPointLonPrec + i * (centralPointLon - centralPointLonPrec) / numberTrunk
                        dist = euclidean_distance(Geodesy.LLA(degLat, deglon, 0.0), posPrec) / 1852.0
                        push!(routeList, (degLat, deglon, dist))
                        StatusMonitor.log_message(@sprintf("Route segment %d.%d -> Lat: %.4f, Lon: %.4f",
                                                            size(routeList)[1], i, routeList[end][1], routeList[end][2]))
                    end
                end

                # Add the main waypoint
                push!(routeList, (centralPointLat, centralPointLon, distanceNm))
                StatusMonitor.log_message(@sprintf("Waypoint %d -> Lat: %.4f, Lon: %.4f, Dist: %.1f nm",
                                                    size(routeList)[1], routeList[end][1], routeList[end][2], distanceNm))

                # Update previous point reference
                centralPointLatPrec = centralPointLat
                centralPointLonPrec = centralPointLon
            end
        end
    end
    return routeList
end


"""
loadRoute(fileOfRoute, centralPointRadiusDistance) -> (routeList, pointCount)

Main function to load and process route files in supported formats (FGFS/GPX).

    Arguments:
    - fileOfRoute: Path or name of the route file to load
    - centralPointRadiusDistance: Base radius distance in nautical miles that determines waypoint density

    Returns:
    - Tuple containing:
    - routeList: Array of waypoints as (latitude, longitude, distance) tuples
    - pointCount: Number of waypoints in the route

    Behavior:
    1. Automatically detects file format (FGFS or GPX)
    2. Calculates minimum distance between points as half the input radius
    3. Loads and processes the route file using appropriate parser
    4. Returns empty list if file cannot be found/parsed
    5. Provides detailed logging through StatusMonitor
"""
function loadRoute(fileOfRoute, centralPointRadiusDistance)
    # Calculate minimum distance between waypoints as fraction of input radius
    centralPointRadiusDistanceFactor = 0.5
    minDistance = centralPointRadiusDistance * centralPointRadiusDistanceFactor

    # Locate and parse the route file
    route = findFileOfRoute(fileOfRoute)
    routeList = Any[]

    if route != nothing
        StatusMonitor.log_message("Loading route from file: $(basename(route[2])) in $(route[3]) format")

        # Dispatch to appropriate format handler
        if route[3] == "FGFS"
            getRouteListFormatFGFS!(routeList, route, minDistance)
            elseif route[3] == "GPX"
            getRouteListFormatGPX!(routeList, route, minDistance)
        end
    else
        StatusMonitor.log_message("Error: Unable to find or load route file: $fileOfRoute")
    end

    return routeList, size(routeList)[1]
end


############################################################
# --- GPX Save / Export Support (added 2025-10-19) ---
############################################################

using Dates

Base.@kwdef struct WP
    name::String
    lat::Float64
    lon::Float64
    alt_m::Union{Nothing,Float64} = nothing
end

_xml_esc(s) = replace(string(s), "&"=>"&amp;", "<"=>"&lt;", ">"=>"&gt;", "\""=>"&quot;", "'" => "&apos;")

function _to_wp(x; default_name="WP")
    lat = hasproperty(x, :lat) ? getproperty(x, :lat) : (x isa AbstractDict ? x["lat"] : nothing)
    lon = hasproperty(x, :lon) ? getproperty(x, :lon) : (x isa AbstractDict ? x["lon"] : nothing)
    lat === nothing && error("Waypoint missing 'lat'")
    lon === nothing && error("Waypoint missing 'lon'")
    nm = hasproperty(x, :name) ? getproperty(x, :name) :
        (x isa AbstractDict && haskey(x,"name") ? x["name"] : default_name)
    alt_m = nothing
    if hasproperty(x, :alt_m)
        alt_m = getproperty(x, :alt_m)
        elseif x isa AbstractDict && haskey(x,"alt_m")
        alt_m = x["alt_m"]
        elseif hasproperty(x, :alt_ft)
        alt_m = getproperty(x, :alt_ft) * 0.3048
        elseif x isa AbstractDict && haskey(x,"alt_ft")
        alt_m = x["alt_ft"] * 0.3048
    end
    return WP(name=string(nm), lat=float(lat), lon=float(lon), alt_m=(alt_m === nothing ? nothing : float(alt_m)))
end

function _print_wpt(io, wp::WP)
    print(io, """  <wpt lat="$(wp.lat)" lon="$(wp.lon)">""")
    print(io, "<name>$(_xml_esc(wp.name))</name>")
    if wp.alt_m !== nothing
        @printf(io, "<ele>%.2f</ele>", wp.alt_m)
    end
    println(io, "</wpt>")
end

function _print_rte(io, name::String, wps::Vector{WP})
    println(io, "  <rte>")
    println(io, "    <name>$(_xml_esc(name))</name>")
    for wp in wps
        print(io, """    <rtept lat="$(wp.lat)" lon="$(wp.lon)">""")
        print(io, "<name>$(_xml_esc(wp.name))</name>")
        if wp.alt_m !== nothing
            @printf(io, "<ele>%.2f</ele>", wp.alt_m)
        end
        println(io, "</rtept>")
    end
    println(io, "  </rte>")
end


export search_by_name  # ensure it is in the exports above

"""
search_by_name(q::AbstractString, limit::Integer=10)

Search airports by:
- keywords (highest priority)
- IATA / ICAO (exact match or prefix)
- name
- municipality

Matching case- and accent-insensitive (Unicode.normalize(..., stripmark=true)).
Returns a vector of NamedTuple: (icao, name, lat, lon, elev_ft) sorted by descending score.
"""
function search_by_name(q::AbstractString, limit::Integer=10)
    # Ensure DB is ready (same logic as selectIcao)
    if isfile("airports.csv") && (!isfile("airports.jls") || stat("airports.csv").mtime > stat("airports.jls").mtime)
        StatusMonitor.log_message("Converting airport database...")
        serialize("airports.jls", DataFrame(CSV.File("airports.csv")))
        StatusMonitor.log_message("Airport database converted to 'airports.jls'.")
    end

    db = deserialize("airports.jls")
    # Some databases have slightly different column names: align here
    # ident        -> ICAO
    # gps_code     -> (often same as ICAO)
    # iata_code    -> IATA
    # municipality -> municipality
    # keywords     -> string with keywords separated by commas/semicolons/spaces
    hascol(sym) = hasproperty(db, sym) || (sym in names(db))
    getcol(sym, default=nothing) = hascol(sym) ? db[!, sym] : (hascol(Symbol(sym)) ? db[!, Symbol(sym)] : fill(default, nrow(db)))

    icao_col  = hascol(:ident) ? :ident : (hascol(:gps_code) ? :gps_code : :ident)
    iata_col  = :iata_code
    name_col  = :name
    muni_col  = :municipality
    keyw_col  = :keywords
    lat_col   = :latitude_deg
    lon_col   = :longitude_deg
    elev_col  = :elevation_ft

    # Normalization
    norm(s) = Unicode.normalize(uppercase(String(s)), stripmark=true)
    qn = norm(strip(q))

    # Keyword tokenizer: split on comma/semicolon/pipe or multiple spaces
    function split_keywords(x)
        if x === missing || x === nothing
            return String[]
        end
        s = String(x)
        isempty(s) && return String[]
        # replace delimiters with comma and split
        s2 = replace(s, [';', '|'] => ',', '\t' => ' ')
        toks = split(s2, ',')
        # further split on whitespace for useful single words (optional)
        toks2 = String[]
        for t in toks
            t1 = strip(t)
            isempty(t1) && continue
            # keep also the whole token and subtokens (e.g. "Milan Bergamo" -> ["Milan Bergamo","Milan","Bergamo"])
            push!(toks2, t1)
            append!(toks2, filter(!isempty, split(t1)))
        end
        return unique(toks2)
    end

    # Scoring
    # 100: IATA/ICAO exact
    # 90 : keywords exact
    # 80 : keywords startswith
    # 70 : name startswith / municipality startswith
    # 60 : name contains / municipality contains
    # 50 : keywords contains
    # 10 : ICAO/IATA contains
    function compute_score(qn::String; icao::String, iata::String, name::String, muni::String, keyws::Vector{String})
        s = 0
        # exact matches on codes
        if !isempty(iata) && qn == iata; s = max(s, 100); end
        if !isempty(icao) && qn == icao; s = max(s, 100); end

        # keywords (normalized)
        nkw = map(norm, keyws)
        if any(k -> qn == k, nkw);                 s = max(s, 90);  end
        if any(k -> startswith(k, qn), nkw);       s = max(s, 80);  end

        # name / municipality
        nm = norm(name)
        mu = norm(muni)
        if startswith(nm, qn) || startswith(mu, qn); s = max(s, 70); end
        if occursin(qn, nm) || occursin(qn, mu);     s = max(s, 60); end

        # keywords contains (after name/muni)
        if any(k -> occursin(qn, k), nkw);          s = max(s, 50); end

        # codes contains (residual case)
        if (!isempty(iata) && occursin(qn, iata)) || (!isempty(icao) && occursin(qn, icao))
            s = max(s, 10)
        end

        return s
    end

    results = NamedTuple{(:icao,:name,:lat,:lon,:elev_ft,:_score)}[]

    @inbounds @simd for i in 1:nrow(db)
        icao = db[i, icao_col];    icao = icao === missing ? "" : String(icao)
        iata = db[i, iata_col];    iata = iata === missing ? "" : String(iata)
        name = db[i, name_col];    name = name === missing ? "" : String(name)
        muni = db[i, muni_col];    muni = muni === missing ? "" : String(muni)
        keyw = hascol(keyw_col) ? db[i, keyw_col] : ""
        keyws = split_keywords(keyw)

        score = compute_score(qn; icao=norm(icao), iata=norm(iata), name=name, muni=muni, keyws=keyws)

        if score != 0
            lat  = try Float64(db[i, lat_col])  catch; NaN end
            lon  = try Float64(db[i, lon_col])  catch; NaN end
            elev = db[i, elev_col]
            push!(results, (icao=icao, name=name, lat=lat, lon=lon, elev_ft=elev, _score=score))
        end
    end

    # sort by score, then by name as tie-breaker
    sorted = sort(results, by = r -> (-r._score, r.name))

    # project and limit
    out = NamedTuple{(:icao,:name,:lat,:lon,:elev_ft)}[]
    for r in Iterators.take(sorted, limit)
        push!(out, (icao=r.icao, name=r.name, lat=r.lat, lon=r.lon, elev_ft=r.elev_ft))
    end
    return out
end


"""
save_route_gpx(waypoints; dep_icao, arr_icao, lookup_icao, outdir, include_ele, route_name)

Generates and saves a GPX 1.1 file with <rte>/<rtept> and optionally <wpt> for departure and arrival.
Returns (filename, gpx_string).
"""
function save_route_gpx(waypoints;
                        dep_icao::Union{Nothing,String}=nothing,
                        arr_icao::Union{Nothing,String}=nothing,
                        lookup_icao::Union{Nothing,Function}=nothing,
                        outdir::AbstractString="routes",
                        include_ele::Bool=false,
                        route_name::Union{Nothing,String}=nothing,
                        )
    length(waypoints) ≥ 2 || error("At least 2 waypoints are needed for a GPX route")

    wps = Vector{WP}(undef, length(waypoints))
    for (i, raw) in pairs(waypoints)
        wps[i] = _to_wp(raw; default_name="WP$(i)")
        if !include_ele
            wps[i] = WP(name=wps[i].name, lat=wps[i].lat, lon=wps[i].lon, alt_m=nothing)
        end
    end

    dep_wpt = nothing
    arr_wpt = nothing
    if dep_icao !== nothing && !isempty(dep_icao) && lookup_icao !== nothing
        dep = lookup_icao(dep_icao)
        dep_wpt = WP(name=dep_icao, lat=float(dep.lat), lon=float(dep.lon))
    end
    if arr_icao !== nothing && !isempty(arr_icao) && lookup_icao !== nothing
        arr = lookup_icao(arr_icao)
        arr_wpt = WP(name=arr_icao, lat=float(arr.lat), lon=float(arr.lon))
    end

    rname = route_name !== nothing ? route_name :
        ((dep_icao !== nothing && arr_icao !== nothing && !isempty(dep_icao) && !isempty(arr_icao)) ?
         "$(dep_icao)-$(arr_icao)" : "Flight-Route")

        buf = IOBuffer()
        println(buf, """<?xml version="1.0" encoding="UTF-8"?>""")
        println(buf, """<gpx version="1.1" creator="Photoscenary" xmlns="http://www.topografix.com/GPX/1/1">""")
        println(buf, "  <metadata>")
        println(buf, "    <name>$(_xml_esc(rname))</name>")
        println(buf, "    <time>", Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS"), "Z</time>")
        println(buf, "  </metadata>")
        if dep_wpt !== nothing; _print_wpt(buf, dep_wpt); end
        if arr_wpt !== nothing; _print_wpt(buf, arr_wpt); end
        _print_rte(buf, rname, wps)
        println(buf, "</gpx>")
        gpx = String(take!(buf))

        isdir(outdir) || mkpath(outdir)
        ts = Dates.format(now(), dateformat"yyyy-mm-dd-HHMMSS")
        base = (dep_icao !== nothing && arr_icao !== nothing && !isempty(dep_icao) && !isempty(arr_icao)) ?
        "$(dep_icao)-$(arr_icao)-$(ts).gpx" :
            "route-$(ts).gpx"
        fname = joinpath(outdir, base)
        open(fname, "w") do io; write(io, gpx); end
        return (base, gpx)
end


end # module
