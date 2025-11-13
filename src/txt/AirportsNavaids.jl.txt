module AirportsNavaids

using Dates, HTTP, CSV, DataFrames, Serialization, Unicode, Printf
using LightXML: XMLDocument, XMLElement, parse_file, root, get_elements_by_tagname, content, set_content, save_file
using LightXML   # to read/write params.xml
using JSON3

# --- Lock with fallback: ReentrantRWLock if available, otherwise ReentrantLock ---
const RWLOCK = (isdefined(Base, :Threads) && isdefined(Base.Threads, :ReentrantRWLock)) ?
Base.Threads.ReentrantRWLock() : ReentrantLock()

const DEFAULT_PARAMS_PATH = "params.xml"

# --- In-memory state ----------------------------------------------------------
const AIRPORTS = Ref{Union{Nothing,DataFrame}}(nothing)
const NAVAIDS  = Ref{Union{Nothing,DataFrame}}(nothing)

# --- Configuration reading from params.xml ------------------------------------
struct ExtFileCfg
    url::String
    file_path::String
    date::Date
end

"""
_read_config_params(params_path=DEFAULT_PARAMS_PATH)
-> (days::Int, airports::ExtFileCfg, navaids::ExtFileCfg, doc::XMLDocument, nodeA::XMLElement, nodeN::XMLElement)
"""
function _read_config_params(params_path::AbstractString=DEFAULT_PARAMS_PATH)
    doc  = _load_or_create_params(params_path)
    rt   = root(doc)
    exts = first(get_elements_by_tagname(rt, "external_files"))

    days_node = first(get_elements_by_tagname(exts, "time_to_update_days"))
    days = parse(Int, String(content(days_node)))

    function pick(tag)
        node = first(get_elements_by_tagname(exts, tag))
        url  = String(content(first(get_elements_by_tagname(node, "url"))))
        fpth = String(content(first(get_elements_by_tagname(node, "file_path"))))
        dt   = Date(String(content(first(get_elements_by_tagname(node, "date")))))
        return ExtFileCfg(url, fpth, dt), node
    end
    (cfgA, nodeA) = pick("airports")
    (cfgN, nodeN) = pick("navaids")
    return days, cfgA, cfgN, doc, nodeA, nodeN
end


# --- Update Utilities ---------------------------------------------------------
function _download_to(url::String, dest::String)
    tmp = dest * ".downloading"
    open(tmp, "w") do io
        write(io, HTTP.get(url).body)
    end
    mv(tmp, dest; force=true)
end

function _update_if_expired!(cfg::ExtFileCfg, doc::XMLDocument, node::XMLElement, max_age_days::Int; label::String, params_path::AbstractString=DEFAULT_PARAMS_PATH)
    needs_update = !isfile(cfg.file_path) || (today() - cfg.date >= Day(max_age_days))
    if needs_update
        @info "[$label] Downloading from $(cfg.url)…"
        _download_to(cfg.url, cfg.file_path)

        # update <date> in the DOM and save atomically
        date_node = first(get_elements_by_tagname(node, "date"))
        set_content(date_node, Dates.format(today(), dateformat"yyyy-mm-dd"))
        _save_file_atomic(doc, params_path)

        @info "[$label] Updated data file and params.xml."
    end
end

function _load_or_create_params(params_path::AbstractString)
    if !isfile(params_path) || filesize(params_path) == 0
        doc = XMLDocument()
        rt = create_root(doc, "params")
        ext = XMLElement("external_files"); push!(rt, ext)
        # create base node time_to_update_days and structures for airports/navaids
        days = XMLElement("time_to_update_days"); set_content(days, "7"); push!(ext, days)
        for tag in ("airports","navaids")
            n = XMLElement(tag)
            push!(n, XMLElement("url"))
            push!(n, XMLElement("file_path"))
            d = XMLElement("date"); set_content(d, Dates.format(today(), dateformat"yyyy-mm-dd")); push!(n, d)
            push!(ext, n)
        end
        _save_file_atomic(doc, params_path)
        return doc
    else
        return parse_file(params_path)
    end
end

function _save_file_atomic(doc::XMLDocument, params_path::AbstractString)
    tmp = params_path * ".tmp"
    save_file(doc, tmp)
    mv(tmp, params_path; force=true)
end


# --- Public API ---------------------------------------------------------------
"""
start!(; async=true, params_path=DEFAULT_PARAMS_PATH)

- Checks/updates airports.csv and navaids.csv according to params.xml.
- Loads data into memory and creates/updates .jls cache files.
- If async=true, starts a maintenance task that re-checks for updates every hour.
"""
function start!(; async::Bool=true, params_path::AbstractString=DEFAULT_PARAMS_PATH)
    days, cfgA, cfgN, xdoc, nodeA, nodeN = _read_config_params(params_path)

    _update_if_expired!(cfgA, xdoc, nodeA, days; label="airports", params_path=params_path)
    _update_if_expired!(cfgN, xdoc, nodeN, days; label="navaids",  params_path=params_path)

    lock(RWLOCK) do
        _load_df!(AIRPORTS, cfgA.file_path, replace(cfgA.file_path, ".csv" => ".jls"); label="airports")
        _load_df!(NAVAIDS,  cfgN.file_path, replace(cfgN.file_path, ".csv" => ".jls"); label="navaids")
    end

    if async
        @async while true
            sleep(3600)
            try
                days, cfgA, cfgN, xdoc, nodeA, nodeN = _read_config_params(params_path)
                _update_if_expired!(cfgA, xdoc, nodeA, days; label="airports", params_path=params_path)
                _update_if_expired!(cfgN, xdoc, nodeN, days; label="navaids",  params_path=params_path)
                lock(RWLOCK) do
                    _load_df!(AIRPORTS, cfgA.file_path, replace(cfgA.file_path, ".csv" => ".jls"); label="airports")
                    _load_df!(NAVAIDS,  cfgN.file_path, replace(cfgN.file_path, ".csv" => ".jls"); label="navaids")
                end
                catch e
                @warn "[AirportsNavaids] Maintainer loop error: $e"
            end
        end
    end
    return nothing
end

function _load_df!(ref::Base.RefValue{Union{Nothing,DataFrame}}, csv_path::String, jls_path::String; label::String)
    # prefer fast bootstrap from .jls if it is at least as new as the .csv
    if isfile(jls_path) && isfile(csv_path) && stat(jls_path).mtime ≥ stat(csv_path).mtime
        ref[] = deserialize(jls_path)
        @info "[$label] Loaded from cache $(jls_path) ($(nrow(ref[])) rows)."
    else
        df = CSV.read(csv_path, DataFrame; normalizenames=true)
        ref[] = df
        serialize(jls_path, df)
        @info "[$label] Loaded from CSV ($(nrow(df)) rows) and wrote cache $(jls_path)."
    end
end

# --- Airport Search -----------------------------------------------------------
# typical OurAirports columns
const COL_ICAO = :ident
const COL_IATA = :iata_code
const COL_NAME = :name
const COL_MUNI = :municipality
const COL_LAT  = :latitude_deg
const COL_LON  = :longitude_deg
const COL_ELEV = :elevation_ft
const COL_KEYW = :keywords

norm(s) = Unicode.normalize(uppercase(String(s)), stripmark=true)

function _split_keywords(x)
    if x === missing || x === nothing; return String[]; end
    s = String(x); isempty(s) && return String[]
    s2 = replace(s, [';', '|'] => ',', '\t' => ' ')
    toks = split(s2, ',')
    out = String[]
    for t in toks
        t1 = strip(t); isempty(t1) && continue
        push!(out, t1); append!(out, filter(!isempty, split(t1)))
    end
    return unique(out)
end

"""
search_airports(q; limit=10) -> Vector{NamedTuple}
Searches on keywords (priority), IATA/ICAO, name, and municipality. Case/accent insensitive.
Returns a vector of (icao, name, lat, lon, elev_ft).
"""
function search_airports(q::AbstractString; limit::Integer=10)
    qn = norm(strip(q))
    A = AIRPORTS[]; A === nothing && error("AIRPORTS not initialized: call AirportsNavaids.start!() first")

    results = NamedTuple{(:icao,:name,:lat,:lon,:elev_ft,:municipality,:iata_code,:_score)}[]
    @inbounds for i in 1:nrow(A)
        icao = A[i, COL_ICAO]; icao = icao === missing ? "" : String(icao)
        iata = A[i, COL_IATA]; iata = iata === missing ? "" : String(iata)
        name = A[i, COL_NAME]; name = name === missing ? "" : String(name)
        muni = A[i, COL_MUNI]; muni = muni === missing ? "" : String(muni)
        keyw = A[i, COL_KEYW]
        nkw  = map(norm, _split_keywords(keyw))

        sc = 0
        # exact codes
        if !isempty(iata) && qn == norm(iata); sc = max(sc, 100); end
        if !isempty(icao) && qn == norm(icao); sc = max(sc, 100); end
        # keywords
        if any(k -> qn == k, nkw);           sc = max(sc, 90); end
        if any(k -> startswith(k, qn), nkw); sc = max(sc, 80); end
        # name/Municipality
        nm = norm(name); mu = norm(muni)
        if startswith(nm, qn) || startswith(mu, qn); sc = max(sc, 70); end
        if occursin(qn, nm) || occursin(qn, mu);     sc = max(sc, 60); end
        # keywords contains
        if any(k -> occursin(qn, k), nkw); sc = max(sc, 50); end
        # residual code contains
        if (!isempty(iata) && occursin(qn, norm(iata))) || (!isempty(icao) && occursin(qn, norm(icao)))
            sc = max(sc, 10)
        end
        sc == 0 && continue

        lat = try Float64(A[i, COL_LAT]) catch; NaN end
        lon = try Float64(A[i, COL_LON]) catch; NaN end
        elev = A[i, COL_ELEV]
        push!(results, (icao=icao, name=name, lat=lat, lon=lon, elev_ft=elev, municipality=muni, iata_code=iata, _score=sc))
    end

    sorted = sort(results, by = r -> (-r._score, r.name))
    out = NamedTuple{(:icao,:name,:lat,:lon,:elev_ft,:municipality,:iata_code)}[]
    for r in Iterators.take(sorted, limit)
        push!(out, (icao=r.icao, name=r.name, lat=r.lat, lon=r.lon, elev_ft=r.elev_ft, municipality=r.municipality, iata_code=r.iata_code))
    end
    return out
end

"""
get_airport_by_icao(icao) -> NamedTuple or nothing
"""
function get_airport_by_icao(icao::AbstractString)
    A = AIRPORTS[]; A === nothing && error("AIRPORTS not initialized")
    q = norm(icao)
    for i in 1:nrow(A)
        idt = A[i, COL_ICAO]; idt = idt === missing ? "" : String(idt)
        if norm(idt) == q
            return (icao=String(idt),
                    name=String(A[i, COL_NAME]),
                    lat=Float64(A[i, COL_LAT]),
                    lon=Float64(A[i, COL_LON]),
                    elev_ft=A[i, COL_ELEV])
        end
    end
    return nothing
end

# --- (Optional) Navaids search with a similar pattern -------------------------
"""
search_navaids(q; limit=20) -> Vector{NamedTuple}
Searches navaids by ident/name/type (accent/case-insensitive) and returns rich fields
including frequencies for the NAVAID and DME (if present).
Returned fields per row:
ident::String, name::String, type::String,
lat::Float64, lon::Float64, elev_ft::Union{Missing,Int},
frequency_khz::Union{Missing,Float64}, frequency_mhz::Union{Missing,Float64},
dme_frequency_khz::Union{Missing,Float64}, dme_frequency_mhz::Union{Missing,Float64},
dme_channel::Union{Missing,String},
usage_type::Union{Missing,String}, power::Union{Missing,String},
associated_airport::Union{Missing,String}
"""
function search_navaids(q::AbstractString; limit::Integer=20)
    N = NAVAIDS[]; N === nothing && error("NAVAIDS not initialized")

    # ---- column resolution with aliases and fallbacks ----
    names_sym = Symbol.(names(N))
    col_ident = :ident in names_sym ? :ident : (:name in names_sym ? :name : nothing)
    col_name  = :name  in names_sym ? :name  : (col_ident === :name ? :name : nothing)
    col_type  = :type  in names_sym ? :type  : (:class in names_sym ? :class : nothing)
    col_lat   = :latitude_deg
    col_lon   = :longitude_deg
    col_elev  = :elevation_ft in names_sym ? :elevation_ft :
        (:elevation_m in names_sym ? :elevation_m : nothing)

    col_freq      = :frequency_khz in names_sym ? :frequency_khz : nothing
    col_dme_freq  = :dme_frequency_khz in names_sym ? :dme_frequency_khz : nothing
    col_dme_chan  = :dme_channel in names_sym ? :dme_channel : nothing
    col_usage     = :usageType in names_sym ? :usageType : (:usage_type in names_sym ? :usage_type : nothing)
    col_power     = :power in names_sym ? :power : nothing
    col_assoc_ap  = :associated_airport in names_sym ? :associated_airport : nothing

    col_ident === nothing && error("Navaids: no 'ident' or 'name' column found in the CSV")
    col_name  === nothing && error("Navaids: no 'name' column found in the CSV")
    col_type  === nothing && error("Navaids: no 'type' or 'class' column found in the CSV")

    # ---- query normalization ----
    qn = norm(strip(q))
    (isempty(qn) || limit <= 0) && return NamedTuple{(:ident,:name,:type,:lat,:lon,:elev_ft,
                                                        :frequency_khz,:frequency_mhz,
                                                        :dme_frequency_khz,:dme_frequency_mhz,
                                                        :dme_channel,:usage_type,:power,:associated_airport)}[]

    # ---- helpers ----
    parse_float_or_missing(x) = try
        ismissing(x) ? missing : Float64(parse(Float64, String(x)))
    catch
        try Float64(x) catch; missing end
    end

    to_string_or_missing(x) = (ismissing(x) || x === nothing) ? missing : String(x)

    # ---- search + scoring ----
    ResNT = NamedTuple{
        (:ident,:name,:type,:lat,:lon,:elev_ft,
            :frequency_khz,:frequency_mhz,
            :dme_frequency_khz,:dme_frequency_mhz,
            :dme_channel,:usage_type,:power,:associated_airport),
        Tuple{String,String,String,Float64,Float64,Union{Missing,Int},
                Union{Missing,Float64},Union{Missing,Float64},
                Union{Missing,Float64},Union{Missing,Float64},
                Union{Missing,String},Union{Missing,String},Union{Missing,String},Union{Missing,String}}
        }

        res = ResNT[]

        for row in eachrow(N)
            ident = row[col_ident]; ident = ismissing(ident) ? "" : String(ident)
            name  = row[col_name];  name  = ismissing(name)  ? "" : String(name)
            typ   = row[col_type];  typ   = ismissing(typ)   ? "" : String(typ)

            idn = norm(ident)
            nn  = norm(name)
            tn  = norm(typ)

            sc = 0
            if idn == qn; sc = 100 end                    # exact ident match
            if sc < 100 && startswith(idn, qn); sc = max(sc, 85) end
            if startswith(nn, qn); sc = max(sc, 70) end
            if occursin(qn, nn);   sc = max(sc, 60) end
            if occursin(qn, tn);   sc = max(sc, 55) end
            sc == 0 && continue

            lat = try Float64(row[col_lat]) catch; NaN end
            lon = try Float64(row[col_lon]) catch; NaN end

            elev_val = missing
            if col_elev !== nothing
                v = row[col_elev]
                if !ismissing(v)
                    elev_val = try
                        Int(floor(parse(Float64, String(v))))
                    catch
                        try Int(floor(Float64(v))) catch; missing end
                    end
                end
            end

            # frequencies
            fk  = col_freq     === nothing ? missing : parse_float_or_missing(row[col_freq])            # kHz
            fkm = isnothing(fk) || fk === missing ? missing : fk / 1000.0                              # MHz
            dfk = col_dme_freq === nothing ? missing : parse_float_or_missing(row[col_dme_freq])       # kHz
            dfm = isnothing(dfk) || dfk === missing ? missing : dfk / 1000.0                           # MHz

            dchan = col_dme_chan === nothing ? missing : to_string_or_missing(row[col_dme_chan])
            usg   = col_usage    === nothing ? missing : to_string_or_missing(row[col_usage])
            pwr   = col_power    === nothing ? missing : to_string_or_missing(row[col_power])
            aapt  = col_assoc_ap === nothing ? missing : to_string_or_missing(row[col_assoc_ap])

            push!(res, (ident=ident, name=name, type=typ,
                        lat=lat, lon=lon, elev_ft=elev_val,
                        frequency_khz=fk, frequency_mhz=fkm,
                        dme_frequency_khz=dfk, dme_frequency_mhz=dfm,
                        dme_channel=dchan, usage_type=usg, power=pwr, associated_airport=aapt))
        end

        sort!(res, by = r -> (- (ismissing(getfield(r, :frequency_khz)) ? 0 : 1),  # prefer with freq
                                - (r.name == "" ? 0 : 1),                            # then with name
                                r.name))
        return length(res) > limit ? res[1:limit] : res
end

"""
get_navaid_by_ident(ident) -> NamedTuple or nothing
Returns the same fields as search_navaids but for an exact ident match.
"""
function get_navaid_by_ident(ident::AbstractString)
    rows = search_navaids(ident; limit=1)
    if !isempty(rows) && uppercase(rows[1].ident) == uppercase(String(ident))
        return rows[1]
    end
    return nothing
end

# ---------------------------
# Bounding-box & circle query
# ---------------------------

"""
bbox_from_center(lat::Real, lon::Real, radius_km::Real) -> (nw_lat, nw_lon, se_lat, se_lon)

Builds a latitude/longitude bounding box around a center with the given radius in kilometers.
Assumes WGS84 approximation for degrees/km. Handles longitude wrap-around.
"""
function bbox_from_center(lat::Real, lon::Real, radius_km::Real)
    lat = Float64(lat); lon = Float64(lon); r = Float64(radius_km)
    deg_lat = r / 110.574  # ~ km per degree latitude
    deg_lon = r / (111.320 * max(1e-6, cosd(lat)))

    nw_lat = lat + deg_lat
    se_lat = lat - deg_lat
    nw_lon = lon - deg_lon
    se_lon = lon + deg_lon

    # normalize longitudes to [-180, 180]
    normlon(x) = x > 180 ? x - 360 : (x < -180 ? x + 360 : x)
    return (nw_lat, normlon(nw_lon), se_lat, normlon(se_lon))
end

# test if (lat,lon) is inside bbox. Supports anti-meridian crossing.
@inline function _in_bbox(lat::Real, lon::Real, nw_lat::Real, nw_lon::Real, se_lat::Real, se_lon::Real)
    lat_ok = (se_lat <= lat <= nw_lat)
    if nw_lon <= se_lon
        lon_ok = (nw_lon <= lon <= se_lon)
    else
        # box crosses anti-meridian: [-180, se_lon] U [nw_lon, 180]
        lon_ok = (lon >= nw_lon) || (lon <= se_lon)
    end
    return lat_ok & lon_ok
end

"""
collect_bbox(nw_lat, nw_lon, se_lat, se_lon;
include_airports::Bool=true,
include_navaids::Bool=true,
max_airports::Int=10_000,
max_navaids::Int=10_000) -> Dict

Returns a Dict ready to be JSON-encoded with all airports and/or navaids inside the bbox.
"""
function collect_bbox(nw_lat::Real, nw_lon::Real, se_lat::Real, se_lon::Real;
                        include_airports::Bool=true,
                        include_navaids::Bool=true,
                        max_airports::Int=10_000,
                        max_navaids::Int=10_000)

    result = Dict(
        "bbox" => Dict(
            "nw" => Dict("lat"=>Float64(nw_lat), "lon"=>Float64(nw_lon)),
            "se" => Dict("lat"=>Float64(se_lat), "lon"=>Float64(se_lon)),
            ),
        "counts" => Dict("airports"=>0, "navaids"=>0),
        "airports" => Any[],
        "navaids"  => Any[]
        )

    function _make_hascol_fn(names_vec::Vector{String})
        names_set = Set(Symbol.(names_vec))
        return (sym::Symbol) -> (sym in names_set)
    end

    # Airports
    if include_airports
        A = AIRPORTS[]
        if A !== nothing && nrow(A) > 0
            # standard OurAirports columns
            nm = names(A)
            hascol = _make_hascol_fn(nm)
            col = Dict(
                :ident=> :ident,
                :iata => hascol(:iata_code) ? :iata_code : :iata,
                :type => :type,
                :name => :name,
                :municipality => :municipality,
                :iso_country  => :iso_country,
                :lat  => :latitude_deg,
                :lon  => :longitude_deg,
                :elev => hascol(:elevation_ft) ? :elevation_ft : :elevation_m,
                )

            cnt = 0
            for r in eachrow(A)
                lat = try Float64(r[col[:lat]]) catch; continue end
                lon = try Float64(r[col[:lon]]) catch; continue end
                _in_bbox(lat, lon, nw_lat, nw_lon, se_lat, se_lon) || continue

                push!(result["airports"], Dict(
                    "kind" => "airport",
                    "icao" => (ismissing(r[col[:ident]]) ? nothing : String(r[col[:ident]])),
                    "type" => (ismissing(r[col[:type]]) ? nothing : String(r[col[:type]])),
                    "iata" => (ismissing(r[col[:iata]])  ? nothing : String(r[col[:iata]])),
                    "name" => (ismissing(r[col[:name]])  ? ""      : String(r[col[:name]])),
                    "municipality" => (ismissing(r[col[:municipality]]) ? nothing : String(r[col[:municipality]])),
                    "country"      => (ismissing(r[col[:iso_country]])  ? nothing : String(r[col[:iso_country]])),
                    "lat" => lat,
                    "lon" => lon,
                    "elev_ft" => (col[:elev] == :elevation_ft ? r[col[:elev]] : missing),
                    ))
                cnt += 1
                cnt >= max_airports && break
            end
            result["counts"]["airports"] = cnt
        end
    end

    # Navaids
    if include_navaids
        N = NAVAIDS[]
        if N !== nothing && nrow(N) > 0
            nm = names(N)
            hascol = _make_hascol_fn(nm)
            col = Dict(
                :ident => (hascol(:ident) ? :ident : :name),
                :name  => :name,
                :type  => (hascol(:type) ? :type : :class),
                :lat   => :latitude_deg,
                :lon   => :longitude_deg,
                :elev  => hascol(:elevation_ft) ? :elevation_ft : (hascol(:elevation_m) ? :elevation_m : nothing),
                :freq_khz     => (hascol(:frequency_khz)     ? :frequency_khz     : nothing),
                :dme_khz      => (hascol(:dme_frequency_khz) ? :dme_frequency_khz : nothing),
                :dme_channel  => (hascol(:dme_channel)       ? :dme_channel       : nothing),
                :usage        => (hascol(:usageType) ? :usageType : (hascol(:usage_type) ? :usage_type : nothing)),
                :power        => (hascol(:power) ? :power : nothing),
                :assoc_ap     => (hascol(:associated_airport) ? :associated_airport : nothing),
                )

            cnt = 0
            for r in eachrow(N)
                lat = try Float64(r[col[:lat]]) catch; continue end
                lon = try Float64(r[col[:lon]]) catch; continue end
                _in_bbox(lat, lon, nw_lat, nw_lon, se_lat, se_lon) || continue

                fk  = (col[:freq_khz] === nothing || ismissing(r[col[:freq_khz]])) ? missing : try Float64(r[col[:freq_khz]]) catch; missing end
                dfk = (col[:dme_khz]  === nothing || ismissing(r[col[:dme_khz]]))  ? missing : try Float64(r[col[:dme_khz]])  catch; missing end

                push!(result["navaids"], Dict(
                    "kind" => "navaid",
                    "ident" => (ismissing(r[col[:ident]]) ? "" : String(r[col[:ident]])),
                    "name"  => (ismissing(r[col[:name]])  ? "" : String(r[col[:name]])),
                    "type"  => (ismissing(r[col[:type]])  ? "" : String(r[col[:type]])),
                    "lat" => lat,
                    "lon" => lon,
                    "elev_ft" => (col[:elev] === nothing || ismissing(r[col[:elev]]) ? missing : r[col[:elev]]),
                    "frequency_khz"      => fk,
                    "frequency_mhz"      => (fk === missing ? missing : fk/1000),
                    "dme_frequency_khz"  => dfk,
                    "dme_frequency_mhz"  => (dfk === missing ? missing : dfk/1000),
                    "dme_channel"        => (col[:dme_channel] === nothing || ismissing(r[col[:dme_channel]]) ? missing : String(r[col[:dme_channel]])),
                    "usage_type"         => (col[:usage] === nothing || ismissing(r[col[:usage]]) ? missing : String(r[col[:usage]])),
                    "power"              => (col[:power] === nothing || ismissing(r[col[:power]]) ? missing : String(r[col[:power]])),
                    "associated_airport" => (col[:assoc_ap] === nothing || ismissing(r[col[:assoc_ap]]) ? missing : String(r[col[:assoc_ap]])),
                    ))
                cnt += 1
                cnt >= max_navaids && break
            end
            result["counts"]["navaids"] = cnt
        end
    end

    return result
end

"""
bbox_json(nw_lat, nw_lon, se_lat, se_lon; kwargs...) -> String
Same as `collect_bbox`, but returns a JSON string.
"""
function bbox_json(nw_lat::Real, nw_lon::Real, se_lat::Real, se_lon::Real; kwargs...)
    data = collect_bbox(nw_lat, nw_lon, se_lat, se_lon; kwargs...)
    return String(JSON3.write(data))
end

"""
circle_json(lat, lon, radius_km; kwargs...) -> String
Helper: builds a bbox around a circle and returns JSON string from `collect_bbox`.
"""
function circle_json(lat::Real, lon::Real, radius_km::Real; kwargs...)
    nw_lat, nw_lon, se_lat, se_lon = bbox_from_center(lat, lon, radius_km)
    return bbox_json(nw_lat, nw_lon, se_lat, se_lon; kwargs...)
end

export start!, search_airports, get_airport_by_icao, search_navaids, get_navaid_by_ident
export bbox_from_center, collect_bbox, bbox_json, circle_json

end
