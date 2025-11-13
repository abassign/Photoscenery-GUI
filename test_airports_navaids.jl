#!/usr/bin/env julia

# Standalone test script for AirportsNavaids.jl
# Usage:
#   julia --project=. test_airports_navaids.jl --init --query "Bergamo" --limit 5
#   julia --project=. test_airports_navaids.jl --init --icao LIME
#   julia --project=. test_airports_navaids.jl --init --navaid "Milan" --limit 10
#
# Notes:
# - --init starts the bootstrap process (download/update + cache creation + load into RAM)
# - By default, it uses start!(async=false) for deterministic tests;
#   you can pass --async to enable the maintainer loop.
#
# julia --project=. -e 'using Pkg; Pkg.add.(["HTTP","CSV","DataFrames","LightXML","Serialization"])'


using Dates
using Printf

# === super-lightweight argument parsing ===
const OPT = Dict{String,Union{String,Bool,Int}}(
    "--init"  => false,
    "--async" => false,
    "--query" => "",
    "--icao"  => "",
    "--navaid"=> "",
    "--limit" => 10,
    )

function parse_args!()
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if haskey(OPT, a)
            if a in ("--init","--async")
                OPT[a] = true
                i += 1
                elseif a == "--limit"
                if i == length(ARGS)
                    error("Option $a requires a value")
                end
                OPT[a] = parse(Int, ARGS[i+1])
                i += 2
            else
                if i == length(ARGS)
                    error("Option $a requires a value")
                end
                OPT[a] = ARGS[i+1]  # the others remain strings
                i += 2
            end
        else
            error("Unknown option: $a")
        end
    end
end

parse_args!()

# === include the service module ===
# Expects AirportsNavaids.jl to be in ./src
include(joinpath(@__DIR__, "src", "AirportsNavaids.jl"))
using .AirportsNavaids

# === print helpers ===
function print_header(title)
    println()
    println("=", "^", 78)
    println("=  ", title)
    println("=", "^", 78)
end

function print_airports(rows)
    if isempty(rows)
        println("No airports found.")
        return
    end
    for (k, r) in enumerate(rows)
        @printf("%2d) %-6s  %-48s  (%.6f, %.6f)  elev=%s\n",
                k, r.icao, r.name[1:min(end,48)], r.lat, r.lon, string(r.elev_ft))
    end
end

function print_navaids(rows)
    if isempty(rows)
        println("No navaids found.")
        return
    end

    # small helpers for safe formatting
    sf(x) = (ismissing(x) || x === nothing) ? "—" : string(x)
    sff(x, ndigits::Int) = (ismissing(x) || x === nothing) ? "—" : string(round(Float64(x); digits=ndigits))

    for (k, r) in enumerate(rows)
        # required floats are safe:
        lat = r.lat
        lon = r.lon

        # optionals -> stringify first
        elev_s   = sf(r.elev_ft)
        fk_s     = sff(get(r, :frequency_khz, missing), 1)   # kHz
        fkm_s    = sff(get(r, :frequency_mhz, missing), 3)   # MHz
        dfk_s    = sff(get(r, :dme_frequency_khz, missing), 1)
        dfm_s    = sff(get(r, :dme_frequency_mhz, missing), 3)
        dchan_s  = sf(get(r, :dme_channel, missing))
        usage_s  = sf(get(r, :usage_type, missing))
        power_s  = sf(get(r, :power, missing))
        ap_s     = sf(get(r, :associated_airport, missing))

        @printf("%2d) %-8s %-28s %-8s  %8.3f %9.3f  elev=%-6s  FREQ=%-9s kHz (%-8s MHz)  DME=%-9s kHz (%-8s MHz)  CH=%-6s  USG=%-6s  PWR=%-6s  AP=%s\n",
                k, r.ident, r.name[1:min(end,28)], r.type, lat, lon,
                elev_s, fk_s, fkm_s, dfk_s, dfm_s, dchan_s, usage_s, power_s, ap_s)
    end
end

# === optional bootstrap ===
if OPT["--init"] == true
    print_header("Initializing AirportsNavaids Service")
    # For deterministic testing, we use async=false; if you want the maintainer loop, pass --async
    AirportsNavaids.start!(; async = Bool(OPT["--async"]))
    println("Bootstrap complete. (async=$(OPT["--async"]))")
end

# === requested actions ===
lim = OPT["--limit"] isa Int ? OPT["--limit"] : parse(Int, String(OPT["--limit"]))

if String(OPT["--query"]) != ""
    q = String(OPT["--query"])
    print_header("Airport search: \"$q\" (limit=$lim)")
    rows = AirportsNavaids.search_airports(q; limit=lim)
    print_airports(rows)
end

if String(OPT["--icao"]) != ""
    icao = String(OPT["--icao"])
    print_header("ICAO Lookup: $icao")
    info = AirportsNavaids.get_airport_by_icao(icao)
    if info === nothing
        println("ICAO not found.")
    else
        @printf("ICAO: %s\nName: %s\nLat/Lon: %.6f, %.6f\nElev(ft): %s\n",
                info.icao, info.name, info.lat, info.lon, string(info.elev_ft))
    end
end

if String(OPT["--navaid"]) != ""
    q = String(OPT["--navaid"])
    print_header("Navaid search: \"$q\" (limit=$lim)")
    rows = AirportsNavaids.search_navaids(q; limit=lim)
    # Use the safe printer that handles `missing` values
    print_navaids(rows)
end

if (String(OPT["--query"]) == "" &&
    String(OPT["--icao"])  == "" &&
        String(OPT["--navaid"])== "")
    println("\nNothing to do. Usage examples:")
        println("  julia --project=. test_airports_navaids.jl --init --query \"Bergamo\" --limit 5")
        println("  julia --project=. test_airports_navaids.jl --init --icao LIME")
        println("  julia --project=. test_airports_navaids.jl --init --navaid \"Milan\" --limit 10")
end
