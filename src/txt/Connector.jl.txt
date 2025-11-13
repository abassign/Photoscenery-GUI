# Filename: src/Connector.jl
# Description: This module handles the real-time data connection to a FlightGear instance
#              via its telnet interface. It is responsible for establishing the connection,
#              fetching raw aircraft position data, parsing it, and calculating derived
#              values like speed and heading.
#
# Key Architectural Decisions & Critical Points:
#   - Data Source: It uses the `dump /position` telnet command. This was chosen over
#     multiple `get` commands because it provides a single, self-contained XML block,
#     simplifying the I/O logic.
#   - Parsing Strategy: The primary challenge was that the FGFS telnet server appends
#     its command prompt (`/>`) to the XML data, which breaks standard XML parsers.
#     The critical fix involves cleaning this raw string before parsing.
#   - Data Calculation: Speed and heading are not fetched directly. Instead, they are
#     calculated by comparing the current position with the previous one, using
#     the functions provided by the `Geodesics.jl` module.
#
# Dependencies:
#   - Sockets: For low-level TCP communication.
#   - EzXML: For parsing the XML data block received from FGFS.
#   - Geodesics.jl: For calculating azimuth (heading) and surface distance between coordinates.

module Connector

export FGFSPosition, FGFSPositionRoute, getFGFSPositionSetTask

using Sockets, EzXML, Dates
using ..Geodesics

# --- Data Structures ---

"""
Represents the telnet connection state.
"""
mutable struct TelnetConnection
    ipAddress::IPv4
    ipPort::Int
    sock::Union{TCPSocket,Nothing}
    function TelnetConnection(address::String, port::Int) new(IPv4(address), port, nothing) end
end

"""
Holds a complete snapshot of the aircraft's state at a single point in time.
"""
struct FGFSPosition
    latitudeDeg :: Float64
    longitudeDeg:: Float64
    altitudeFt  :: Float64
    directionDeg:: Float64
    speedMph    :: Float64
end

"""
Manages the overall state of the FGFS connection, including the most recent data point.
"""
mutable struct FGFSPositionRoute
    marks::Vector{FGFSPosition}
    actual::Union{FGFSPosition,Nothing}
    telnet::Union{TelnetConnection,Nothing}
    stepTime::Float64
    function FGFSPositionRoute(stepTime=2.0) new([], nothing, nothing, stepTime) end
end


function fetch_and_clean_xml(sock::TCPSocket, command::String, debugLevel::Int)
    try
        # Invia il comando a FGFS
        write(sock, command)
        sleep(0.3)  # Attendere la risposta

        # Leggi tutti i byte disponibili dal buffer della socket
        raw_data = readavailable(sock)
        xml_data_string = String(raw_data)

        # Trova la posizione della chiusura del tag XML
        end_tag = "</PropertyList>"
        end_pos = findfirst(end_tag, xml_data_string)

        if end_pos === nothing
            debugLevel > 0 && @warn "Connector: Dati incompleti da FGFS (tag di chiusura non trovato)."
            return nothing
        end

        # Crea una sottostringa valida XML
        clean_xml = xml_data_string[1:end_pos.stop]
        return clean_xml
    catch e
        debugLevel > 0 && @warn "Connector: Errore durante la lettura o il parsing dei dati." exception=(e, Base.catch_backtrace())
        return nothing
    end
end


"""
getFGFSPositionSetTask(host, port, _a, _b, debugLevel)

The main function of the module. It starts a background task (`@async`) that runs an
    infinite loop to connect to FGFS and continuously fetch and process aircraft data.
"""
function getFGFSPositionSetTask(host::String, port::Int, _a, _b, debugLevel::Int)
    positionRoute = FGFSPositionRoute()
    positionRoute.telnet = TelnetConnection(host, port)

    @async while true
        # --- Connection Loop ---
        if positionRoute.telnet.sock === nothing || !isopen(positionRoute.telnet.sock)
            try
                debugLevel > 0 && @info "Connector: Connessione a $host:$port..."
                positionRoute.telnet.sock = connect(positionRoute.telnet.ipAddress, positionRoute.telnet.ipPort)
                debugLevel > 0 && @info "Connector: Connesso! ✅"
                catch e
                debugLevel > 0 && @warn "Connector: Connessione fallita. Ritento in 5s."
                positionRoute.telnet.sock = nothing
                positionRoute.actual = nothing
                sleep(5); continue
            end
        end

        # --- Data Acquisition Loop ---
        while isopen(positionRoute.telnet.sock)
            try
                # Usa la nuova funzione per ottenere la stringa XML pulita
                isRecived = 0
                lat = lon = alt = gnd = heading_deg = speed_mph = 0.0
                # Parse the cleaned XML string
                pos_doc = fetch_and_clean_xml(positionRoute.telnet.sock, "dump /position\r\n", debugLevel)
                if pos_doc !== nothing
                    root = EzXML.root(EzXML.parsexml(pos_doc))
                    lat = parse(Float64, nodecontent(findfirst("//latitude-deg", root)))
                    lon = parse(Float64, nodecontent(findfirst("//longitude-deg", root)))
                    alt = parse(Float64, nodecontent(findfirst("//altitude-ft", root)))
                    gnd = parse(Float64, nodecontent(findfirst("//ground-elev-ft", root)))
                    isRecived = 4
                end

                ori_doc = fetch_and_clean_xml(positionRoute.telnet.sock, "dump /orientation\r\n", debugLevel)
                if ori_doc !== nothing
                    root = EzXML.root(EzXML.parsexml(ori_doc))
                    node = findfirst("//true-heading-deg", root)
                    if node !== nothing
                        heading_deg = parse(Float64, nodecontent(node))
                        isRecived += 1
                    end
                end

                vel_doc = fetch_and_clean_xml(positionRoute.telnet.sock, "dump /velocities\r\n", debugLevel)
                if vel_doc !== nothing
                    root = EzXML.root(EzXML.parsexml(vel_doc))
                    node = findfirst("//uBody-fps", root)
                    if node !== nothing
                        speed_mph = 1.15078 * parse(Float64, nodecontent(node)) / 1.68781
                        isRecived += 1
                    end
                end

                if isRecived === 0
                    @warn "Connector.getFGFSPositionSetTask: no valid data from FGFS connection" lat lon alt heading_deg speed_mph
                    sleep(1)
                    continue
                else
                    debugLevel >= 2 && @info "Connector.getFGFSPositionSetTask: " lat lon alt heading_deg speed_mph
                end
                alt_agl = alt - gnd
                if alt_agl < 0.0 alt_agl = 0 end
                positionRoute.actual = pos = FGFSPosition(lat, lon, alt_agl,heading_deg, speed_mph)
                # Create a new FGFSPosition object
                # Update the global state
            catch e
                @warn "Connector.getFGFSPositionSetTask: Critic parsing error .. retray to reconnect" exception=(e, Base.catch_backtrace())
                if positionRoute.telnet.sock !== nothing; close(positionRoute.telnet.sock); end
            end
            sleep(positionRoute.stepTime)
        end

        debugLevel > 0 && @info "Connector: Connessione persa. In attesa di riconnessione..."
        positionRoute.actual = nothing
        sleep(2)
    end
    return positionRoute
end

end # module Connector
