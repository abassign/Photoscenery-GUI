# Salva come: AppConfig.jl
module AppConfig

export initialize_and_parse_args, parse_args

using ArgParse, LightXML


const PARAMS_PATH = Ref(joinpath(@__DIR__, "..", "params.xml"))


# Funzione privata per gestire params.xml
function _initialize_params(versionProgram::String)
    paramsXml = nothing
    if isfile("params.xml")
        try
            paramsXml = parse_file("params.xml")
            if "params" == lowercase(name(LightXML.root(paramsXml)))
                xroot = LightXML.root(paramsXml)
                ces = get_elements_by_tagname(xroot, "versioning")
                if ces != nothing && find_element(ces[1], "version") != nothing
                    set_content(find_element(ces[1], "version"), versionProgram)
                end
            end
        catch e
            println("Attenzione: params.xml corrotto. Verrà ricreato. Errore: $e")
            paramsXml = nothing
        end
    end

    if paramsXml === nothing
        paramsXml = parse_string("<params><versioning><version>$versionProgram</version><autor>Adriano Bassignana</autor><year>2021</year><licence>GPL 2</licence></versioning></params>")
    end
    save_file(paramsXml, "params.xml")
end


"""
_load_or_init_presets() -> (Dict{String,String}, XMLDocument)

Garantisce che `params.xml` esista e contenga un nodo `<presets>`.
Ritorna un dizionario id ⇒ stringa-opzioni e il documento XML aperto
(per eventuali salvataggi successivi).
"""
function _load_or_init_presets()
    # crea file minimale se serve
    if !isfile(PARAMS_PATH[])
        doc  = XMLDocument()
        root = LightXML.create_root(doc, "params")
        LightXML.new_child(root, "presets")
        open(PARAMS_PATH[], "w") do io; print(io, doc) end   # write-mode
    end

    doc  = LightXML.parse_file(PARAMS_PATH[])
    root = LightXML.root(doc)
    pres = let lst = LightXML.get_elements_by_tagname(root, "presets")
        isempty(lst) ? LightXML.new_child(root, "presets") : lst[1]
    end

    # --- build Dict id ⇒ stringa-token
    presets = Dict{String,String}()
    for idnode in LightXML.child_elements(pres)
        LightXML.name(idnode) == "id" || continue

        # estrai l’attributo name SENZA usare filter/haskey
        key = nothing
        for a in LightXML.attributes(idnode)
            if LightXML.name(a) == "name"
                key = String(LightXML.value(a)); break
            end
        end
        key === nothing && continue
        presets[key] = strip(String(LightXML.content(idnode)))
    end
    return presets, doc
end


"""
_save_presets!(presets, doc)

Aggiorna (sovrascrivendo) il nodo `<presets>` e riscrive `params.xml`.
"""
function _save_presets!(presets::Dict{String,String}, doc::LightXML.XMLDocument)
    root = LightXML.root(doc)
    # wipe vecchio nodo <presets>
    for old in LightXML.get_elements_by_tagname(root, "presets")
        LightXML.unlink(old)
    end
    # rebuild
    pres = LightXML.new_child(root, "presets")
    for (k,v) in presets
        idn = LightXML.new_child(pres, "id")
        LightXML.set_attribute(idn, "name", k)
        LightXML.add_text(idn, v)
    end
    open(PARAMS_PATH[], "w") do io; print(io, doc) end        # write-mode
end


"""
parse_args(vec::Vector{String}=ARGS) -> Dict

Wrapper che intercetta `--gt/--rm`, espande o aggiorna i preset e poi chiama
ArgParse.  Ritorna il Dict di configurazione, o un Dict con `:action => :rm`
in caso di rimozione (e il programma può terminare subito).
"""
function parse_args(vec::Vector{String}=ARGS)
    # 1. Carica/crea params.xml  + dizionario preset
    presets, doc = _load_or_init_presets()

    # ----- gestisci --rm -----------------------------------------------
    if (idx = findfirst(==("--rm"), vec)) !== nothing
        id = get(vec, idx+1, nothing)
        id === nothing && error("--rm richiede un id")

        if haskey(presets, id)
            delete!(presets, id)
            _save_presets!(presets, doc)
            println("Preset '$id' rimosso.")
        else
            println("Nessun preset chiamato '$id'.")
        end
        return Dict(:action => :rm, :id => id)   # il caller potrà uscire
    end

    # ----- gestisci --gt -----------------------------------------------
    pending_create = nothing         # (id,stringa) da salvare dopo il parse
    if (idx = findfirst(==("--gt"), vec)) !== nothing
        id = get(vec, idx+1, nothing)
        id === nothing && error("--gt richiede un id")

        extra = vec[(idx+2):end]     # token che seguono l'id
        # strip --gt id
        vec  = vec[1:idx-1]

        if haskey(presets, id)
            vec = vcat(split(presets[id]), extra)   # preset + override
            println("Usato preset '$id'")
        else
            pending_create = (id, join(extra, " "))
            vec = extra
            println("Nuovo preset '$id' in arrivo…")
        end
    end

    # ----- delega ad ArgParse via la tua funzione privata --------------
    cfg = _parse_commandline(vec)    # costruisce lo settings e fa il parse

    # ----- salva eventuale nuovo preset --------------------------------
    if pending_create !== nothing
        (id, body) = pending_create
        presets[id] = body
        _save_presets!(presets, doc)
        println("Preset '$id' salvato in params.xml (\"$body\")")
    end

    return cfg
end


# Funzione privata per il parsing degli argomenti
function _parse_commandline(args)
    s = ArgParseSettings(description="Photoscenary.jl - Tile downloader for flight simulators.")
    @add_arg_table! s begin
        "--gt"
        help     = "Get (or create) a named preset of CLI options stored in params.xml"
        arg_type = String
        nargs    = 1
        "--rm"
        help     = "Remove a preset from params.xml and exit"
        arg_type = String
        nargs    = 1
        "--args", "-g"
        help = "The arguments files in txt format"
        arg_type = String
        default = nothing
        "--map"
        help = "The map server id"
        arg_type = Int64
        default = 1
        dest_name = "server"
        "--latll"
        help = "Lower left area lat"
        arg_type = Float64
        default = 0.0
        "--lonll"
        help = "Lower left area lon"
        arg_type = Float64
        default = 0.0
        "--latur"
        help = "Upper right area lat"
        arg_type = Float64
        default = 0.0
        "--lonur"
        help = "Upper right area lon"
        arg_type = Float64
        default = 0.0
        "--lat", "-a"
        help = "Latitude in deg of central point"
        arg_type = Float64
        default = nothing
        "--lon", "-o"
        help = "Longitude in deg of central point"
        arg_type = Float64
        default = nothing
        "--sexagesimal", "-x"
        help = "Set the sexagesimal unit degree.minutes"
        action = :store_true
        "--png"
        help = "Set the only png format files"
        action = :store_true
        "--icao", "-i"
        help = "ICAO airport code for extract LAT and LON"
        arg_type = String
        default = nothing
        "--route"
        help = "Route XML for extract route LAT and LON"
        arg_type = String
        default = nothing
        "--tile", "-t"
        help = "Tile index es coordinate reference"
        arg_type = Int64
        default = nothing
        "--radius", "-r"
        help = "Distance Radius around the center point (nm)"
        arg_type = Float64
        default = 0.0
        "--size", "-s"
        help = "Max size of image 0->512 1->1024 2->2048 3->4096 4->8192 5->16384 6->32768"
        arg_type = Int64
        default = 2
        "--sdwn"
        help = "Down size with distance"
        arg_type = Int64
        default = 0
        "--over"
        help = "|0| no overwriting, |1| Overwrite if bigger, |2| Overwrite"
        arg_type = Int64
        default = 0
        "--search"
        help = "Search the DDS or PNG files in the specific path"
        arg_type = String
        default = nothing
        "--path", "-p"
        help = "Path to store the dds images"
        arg_type = String
        default = nothing
        "--save"
        help = "Save the remove files in the specific path"
        arg_type = String
        default = nothing
        "--nosave"
        help = "Not save the DDS/PNG files"
        action = :store_true
        "--connect"
        help = "IP and port FGFS program, default value and format: \"127.0.0.1:5000\""
        arg_type = String
        default = nothing
        "--proxy"
        help = "Proxy string ipv4:port for example: \"192.168.0.1:8080\""
        default = nothing
        "--min_chunk_bytes"
        help = "Minimum png file size for chunks (64 byte)"
        arg_type = Int64
        default = 64
        "--attemps"
        help = "Number of download attempts (def 5)"
        arg_type = Int64
        default = 5
        "--timeout"
        help = "Base download timeout in seconds for each chunk (60)"
        arg_type = Int
        default = nothing
        "--retry_timeout_factor"
        help = "retry timeout factor (def 1.6)"
        arg_type = Float64
        default = nothing
        "--retry_timeout_cap"
        help = "Retry timeout cap (def 300)"
        arg_type = Float64
        default = nothing
        "--debug", "-d"
        help = "Debug level"
        arg_type = Int64
        default = 0
        "--logger", "-l"
        help = "0 = console only (default), 1 = file + console, 2 = only file log"
        arg_type = Int64
        default = 0
        "--version"
        help = "Program version"
        action = :store_true
        "--http"
        help = "Starts a local web server. Used as a flag, it uses port 8000; otherwise, it uses the specified port (es. --webserver 8081)."
        arg_type = Int
        nargs = '?'         # Accetta zero o più valori (restituirà un array)
        constant = 8000
        default = nothing   # Se non presente, il valore è nothing
        "--low-detail-threshold"
        help = "Detail score threshold below which a tile is marked as low-info (default 1.0)"
        arg_type = Float64
        default = 0.8
        dest_name = "low_detail_threshold" # Nome pulito per il dizionario cfg
    end

    # parse_args gestisce automaticamente gli argomenti passati
    return ArgParse.parse_args(args, s)
end


# Unica funzione pubblica del modulo
function initialize_and_parse_args(args, versionProgram, versionProgramDate)
    println("\nPhotoscenary.jl ver: $versionProgram date: $versionProgramDate - System prerequisite test")

    # Chiama le due funzioni private
    _initialize_params(versionProgram)
    parsedArgs = _parse_commandline(args)

    println("\n--- Parametri di Esecuzione ---")
    for (key, val) in parsedArgs
        if val !== nothing
             println("  $key => $val")
        end
    end
    println("-----------------------------\n")

    return parsedArgs
end

end # fine del modulo AppConfig
