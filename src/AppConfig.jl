# Salva come: AppConfig.jl
module AppConfig

export initialize_and_parse_args, parse_args
export get_current_orthophotos_path, get_current_saves_path, update_paths!, set_active_orthophotos_path, set_active_saves_path

using ArgParse, LightXML

const GLOBAL_CONFIG = Dict{String, Any}()
const PARAMS_PATH = Ref(joinpath(@__DIR__, "..", "params.xml"))


# Private function to handle params.xml
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
            println("Warning: params.xml corrupt. It will be recreated. Error: $e")
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

Ensures that `params.xml` exists and contains a `<presets>` node.
Returns a dictionary id => options-string and the open XML document
(for potential future saves).
"""
function _load_or_init_presets()
    # create minimal file if needed
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

    # --- build Dict id => token-string
    presets = Dict{String,String}()
    for idnode in LightXML.child_elements(pres)
        LightXML.name(idnode) == "id" || continue

        # extract the name attribute WITHOUT using filter/haskey
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

Updates (overwriting) the `<presets>` node and rewrites `params.xml`.
"""
function _save_presets!(presets::Dict{String,String}, doc::LightXML.XMLDocument)
    root = LightXML.root(doc)
    # wipe old <presets> node
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

Wrapper that intercepts `--gt/--rm`, expands or updates presets, and then calls
ArgParse. Returns the configuration Dict, or a Dict with `:action => :rm`
in case of removal (and the program can terminate immediately).
"""
function parse_args(vec::Vector{String}=ARGS)
    # 1. Load/create params.xml + presets dictionary
    presets, doc = _load_or_init_presets()

    # ----- handle --rm -----------------------------------------------
    if (idx = findfirst(==("--rm"), vec)) !== nothing
        id = get(vec, idx+1, nothing)
        id === nothing && error("--rm requires an id")

        if haskey(presets, id)
            delete!(presets, id)
            _save_presets!(presets, doc)
            println("Preset '$id' removed.")
        else
            println("No preset named '$id'.")
        end
        return Dict(:action => :rm, :id => id)   # the caller can exit
    end

    # ----- handle --gt -----------------------------------------------
    pending_create = nothing         # (id,string) to save after parse
    if (idx = findfirst(==("--gt"), vec)) !== nothing
        id = get(vec, idx+1, nothing)
        id === nothing && error("--gt requires an id")

        extra = vec[(idx+2):end]     # tokens following the id
        # strip --gt id
        vec  = vec[1:idx-1]

        if haskey(presets, id)
            vec = vcat(split(presets[id]), extra)   # preset + override
            println("Used preset '$id'")
        else
            pending_create = (id, join(extra, " "))
            vec = extra
            println("New preset '$id' coming...")
        end
    end

    # ----- delegate to ArgParse via private function -----------------
    cfg = _parse_commandline(vec)    # builds settings and parses

    # ----- save potential new preset ---------------------------------
    if pending_create !== nothing
        (id, body) = pending_create
        presets[id] = body
        _save_presets!(presets, doc)
        println("Preset '$id' saved in params.xml (\"$body\")")
    end

    return cfg
end


"""
    _read_path_from_xml(tag::String) -> Union{String, Nothing}

Reads the value of a specific tag (e.g., "path" or "save") from the settings section of params.xml.
"""
function _read_path_from_xml(tag::String)::Union{String, Nothing}
    # Uses the file path relative to the runtime environment, not the package root.
    target_path = "params.xml"
    !isfile(target_path) && return nothing
    try
        xdoc = LightXML.parse_file(target_path)
        xroot = LightXML.root(xdoc)
        settings = LightXML.find_element(xroot, "settings")

        if settings !== nothing
            tag_node = LightXML.find_element(settings, tag)
            if tag_node !== nothing
                return strip(LightXML.content(tag_node))
            end
        end
    catch e
        @warn "AppConfig: Error reading $tag from params.xml." exception=(e, catch_backtrace())
    end
    return nothing
end

"""
    _write_path_to_xml!(tag::String, value::String)

Writes or updates a specific tag (e.g., "path" or "save") in the settings section of params.xml.
"""
function _write_path_to_xml!(tag::String, value::String)
    target_path = "params.xml"

    # 1. Load or initialize the document
    if isfile(target_path)
        xdoc = LightXML.parse_file(target_path)
        xroot = LightXML.root(xdoc)
    else
        xdoc = LightXML.XMLDocument()
        xroot = LightXML.create_root(xdoc, "params")
    end

    # 2. Find or create <settings> node
    settings = LightXML.find_element(xroot, "settings")
    if settings === nothing
        settings = LightXML.new_child(xroot, "settings")
    end

    # 3. Find or create <path/save> node
    tag_node = LightXML.find_element(settings, tag)
    if tag_node === nothing
        tag_node = LightXML.new_child(settings, tag)
    end

    # 4. Set new content
    LightXML.set_content(tag_node, value)

    # 5. Save file
    try
        LightXML.save_file(xdoc, target_path)
        @info "AppConfig: Wrote '$tag' to params.xml: $value"
    catch e
        @error "AppConfig: Failed to write to params.xml." exception=(e, catch_backtrace())
    end
end

"""
    get_current_orthophotos_path() -> String
Retrieves the *currently active* Orthophotos path from the runtime configuration.
"""
function get_current_orthophotos_path()::String
    # Reads the active path from the global configuration dictionary (APP_CONFIG[])
    return get(GLOBAL_CONFIG, "path", "")
end

"""
    get_current_saves_path() -> String
Retrieves the *currently active* Orthophotos-saved path from the runtime configuration.
"""
function get_current_saves_path()::String
    # Reads the active path from the global configuration dictionary (APP_CONFIG[])
    return get(GLOBAL_CONFIG, "save", "")
end


"""
    update_paths!(new_path::String, new_save::String)

Updates the 'path' and 'save' tags in params.xml and updates the runtime configuration with the new paths.
This is the function called from the GUI on button press.
"""
function update_paths!(new_path::String, new_save::String)
    # Write to the persistent file
    _write_path_to_xml!("path", new_path)
    _write_path_to_xml!("save", new_save)

    # NOTE: The active config is updated ONLY AFTER the move in GuiMode.jl,
    # but we update the runtime dictionary here temporarily to reflect the new desired state.
    # We rely on GuiMode.jl to correctly call set_active_* only after FileMover confirms success.
end


"""
    set_active_orthophotos_path(path::String)
Updates the runtime config after a successful migration.
"""
function set_active_orthophotos_path(path::String)
    GLOBAL_CONFIG["path"] = path
    # NOTE: GeoEngine.jl's prepare_paths_and_location needs to be updated
    # to read these from the config dict if they exist.
end

"""
    set_active_saves_path(path::String)
Updates the runtime config after a successful migration.
"""
function set_active_saves_path(path::String)
    GLOBAL_CONFIG["save"] = path
end


# Private function for argument parsing
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
        nargs = '?'         # Accepts zero or more values (will return an array)
        constant = 8000
        default = nothing   # If not present, value is nothing
        "--low-detail-threshold"
        help = "Detail score threshold below which a tile is marked as low-info (default 1.0)"
        arg_type = Float64
        default = 0.8
        dest_name = "low_detail_threshold" # Clean name for cfg dictionary
    end

    # parse_args automatically handles passed arguments
    return ArgParse.parse_args(args, s)
end


# Only public function of the module
function initialize_and_parse_args(args, versionProgram, versionProgramDate)
    println("\nPhotoscenary.jl ver: $versionProgram date: $versionProgramDate - System prerequisite test")

    # Call the two private functions
    _initialize_params(versionProgram)
    parsedArgs = _parse_commandline(args)

    println("\n--- Execution Parameters ---")
    for (key, val) in parsedArgs
        if val !== nothing
             println("  $key => $val")
        end
    end
    println("-----------------------------\n")

    return parsedArgs
end

end # end of module AppConfig
