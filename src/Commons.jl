#=
Module: Commons
Description: Functions common to various programs related to photoscenery files.
Author: Adriano Bassignana
License: GPL 2
Date Start Production: April 2021
=#
module Commons

using Printf
using FileIO
using ImageIO
using Dates
using FilePathsBase # Assuming walkdir comes from here or Base
using Base: getindex, length, iterate # Import these to extend them
using ..Connector

# --- Exports ---
export tileWidth, index, coordFromIndex, tile_dirs, tile_dest_dir, findFile, getFileExtension, getFileName
export getDDSSize, getPNGSize, getSizePixel, getSizeFromWidth, getSizeAndCols # <-- AGGIUNTA QUI
export FileFinder, CursorAnimator, MapCoordinates, TileMetadata, ChunkJob, chunk_pixel_size
export adaptive_size_id
export TileGroup, CHUNK_RE


# --- Constants and Definitions ---

# Latitude bands and corresponding tile widths (degrees)
const LATITUDE_BANDS = [90, 89, 86, 83, 76, 62, 22, -22]
const TILE_WIDTHS_DEG = [12.0, 4.0, 2.0, 1.0, 0.5, 0.25, 0.125]

const EARTH_RADIUS_KM = 6371.0
const KM_TO_NM = 0.53996 # Nautical miles per kilometer

const DDS_MAGIC = b"DDS "
const DDS_HEADER_SIZE = 124

const SIZE_ID_MAP = Dict{Int,Int}(
    512 => 0,
    1024 => 1,
    2048 => 2,
    4096 => 3,
    8192 => 4,
    16384 => 5,
    32768 => 6
)

const DEFAULT_SIZE_ID = 0 # Corresponds to width 512 or unknown

const PIXEL_SIZE_MAP = [
    (size=0, width=512, cols=1),
    (size=1, width=1024, cols=1),
    (size=2, width=2048, cols=1),
    (size=3, width=4096, cols=2),
    (size=4, width=8192, cols=4),
    (size=5, width=16384, cols=8),
    (size=6, width=32768, cols=8) # Assuming size 6 maps to 32768
]


"""
adaptive_size_id(k_max::Int, h::Real, d::Real, fov_deg::Real=30)::Int

Return the tile resolution ID (0…6) as a function of:
    - `k_max`   : Maximum resolution chosen by the operator (0..6)
    - `h`       : Aircraft AGL height in feet (Int or Float)
    - `d`       : Slant range to tile center in nautical miles (Int or Float)
    - `fov_deg` : Pilot’s horizontal field of view in degrees (default 30°)

    Method:
    1. Convert altitude to meters and NM to meters.
    2. Compute the target Ground Sample Distance (GSD) visible to the pilot,
    based on the field of view and a nominal display width (e.g., 1920 px).
    3. Compute the GSD of each available tile resolution (0..k_max).
    4. Select the smallest resolution ID whose GSD is still smaller than the target GSD.
    5. Apply an additional distance-based downscale: +1 level every ~10 NM from the aircraft.
    6. Clamp the result to [0, k_max].

    Returns:
    `Int` : Recommended tile resolution ID.
"""
function adaptive_size_id(k_max::Int, h::Real, d::Real, fov_deg::Real=60)::Int
    # --- Constants ---
    NM_TO_M  = 1852.0           # meters in 1 NM
    FT_TO_M  = 0.3048           # meters in 1 ft
    TILE_LAT_DEG = 1 / 8        # tile height in degrees
    EARTH_RADIUS_M = 6371000.0  # mean Earth radius in meters
    SCREEN_PX = 1920            # assumed display width in pixels
    KFOV = 1.0                  # Enhances the altitude effect on distance

    # --- 1. Convert altitude (feet) and distance (NM) to meters ---
    alt_m   = h * FT_TO_M
    dist_m  = d * NM_TO_M

    # --- 2. Compute visible ground width at given altitude (simple trig) ---
    fov_rad = deg2rad(fov_deg / 2.0)
    visible_ground_m = 2 * alt_m * tan(fov_rad / 2) * KFOV

    # --- 3. Compute target GSD (meters per pixel) ---
    target_gsd = visible_ground_m / SCREEN_PX

    # --- 4. Define tile resolutions (pixels) for IDs 0..6 ---
    tile_px = [512 << i for i in 0:6]

    # --- 5. Compute tile width in meters (at equator) ---
    tile_height_m = (TILE_LAT_DEG / 360.0) * 2π * EARTH_RADIUS_M
    tile_width_m = tile_height_m # approx equal at low latitudes

    # --- 6. Find smallest resolution ID that meets target GSD ---
    chosen_id = k_max
    for id in 0:k_max
        gsd_tile = tile_width_m / tile_px[id+1]
        if gsd_tile <= target_gsd
            chosen_id = id
            break
        end
    end

    # --- 7. Apply distance-based degradation ---
    dist_steps = Int(floor(dist_m / (10 * NM_TO_M)))
    chosen_id = max(0, chosen_id - dist_steps)

    # --- 8. Clamp to allowed range ---
    return clamp(chosen_id, 0, k_max)
end



"""
Represents a generic point of interest (waypoint).
Can be derived from a static route, a dynamic link to FGFS,
or a single coordinate/ICAO point.
"""
struct Waypoint
    lat::Float64
    lon::Float64
    alt_agl_ft::Union{Float64, Nothing}  # AGL altitude in feet, optional
    angle_deg::Union{Float64, Nothing}   # Route angle in degrees, optional
end


"""
Gets the nominal pixel width and column count for a given size ID from PIXEL_SIZE_MAP.
"""
function getSizeAndCols(size_id::Int)::Union{Tuple{Int, Int}, Nothing}
    for item in PIXEL_SIZE_MAP
        if item.size == size_id
            return item.width, item.cols
        end
    end
    return nothing
end

struct MapCoordinates
    lat::Float64
    lon::Float64
    radius::Float64
    latLL::Float64
    lonLL::Float64
    latUR::Float64
    lonUR::Float64
    isDeclarePolar::Bool
    positionRoute::Union{Connector.FGFSPositionRoute,Nothing}

    function MapCoordinates(lat::Float64,lon::Float64,radius::Float64)
        (latLL,lonLL,latUR,lonUR) = Commons.latDegByCentralPoint(lat,lon,radius)
        # Assume 'positionRoute' is not provided in this constructor, so 'nothing'
        return new(lat,lon,radius,latLL,lonLL,latUR,lonUR,true, nothing)
    end

    function MapCoordinates(latLL::Float64,lonLL::Float64,latUR::Float64,lonUR::Float64)
        lon = lonLL + (lonUR - lonLL) / 2.0
        lat = latLL + (latUR - latLL) / 2.0
        # Simplified radius calculation, your original version with LLA is correct
        # if Geodesy.jl or similar is available.
        radius = sqrt((lonUR - lonLL)^2 + (latUR - latLL)^2) # Simplification, use your original logic
        # Assume 'positionRoute' is not provided in this constructor, so 'nothing'
        return new(lat,lon,radius,latLL,lonLL,latUR,lonUR,false, nothing)
    end
end


"""
Encapsulates all necessary information to define, position, and process
a single geographic tile.
"""
struct TileMetadata
    # Identifiers
    id::Int            # sequential unique tile ID (per run/session)
    size_id::Int       # resolution class ID (e.g. 0=512, 1=1024)

    # Bounding box of the tile (lower-left and upper-right corners)
    lonLL::Float64     # longitude of lower-left corner
    latLL::Float64     # latitude of lower-left corner
    lonUR::Float64     # longitude of upper-right corner
    latUR::Float64     # latitude of upper-right corner

    # Logical grid indices (used in FG scenery naming)
    x::Int             # X index in the 1x1° grid
    y::Int             # Y index in the 1x1° grid

    # Geographical properties
    lonC::Float64      # longitude of tile center
    latC::Float64      # latitude of tile center
    lon_step::Float64  # longitudinal span of the tile in degrees

    # Output image properties
    width::Int         # width in pixels of the assembled tile
    cols::Int          # number of subtile columns (e.g. 8 → 8×8 subtiles)
end


struct ChunkJob
    tile_id::Int
    size_id::Int
    chunk_xy::Tuple{Int, Int}
    bbox::NamedTuple{(:lonLL, :latLL, :lonUR, :latUR), NTuple{4, Float64}}
    pixel_size::NamedTuple{(:width, :height), NTuple{2, Int}}
    temp_path::String
    retries_left::Int
end


"""
Extends Base.getindex to allow accessing TileMetadata fields by integer index,
matching the exact order expected by the legacy Downloader.jl function.
"""
function Base.getindex(t::TileMetadata, i::Int)
    # This mapping is arbitrary but matches what Downloader.jl expects.
    if i == 1; return t.id;
    elseif i == 2; return t.size_id;
    elseif i == 3; return t.lonLL;
    elseif i == 4; return t.latLL;
    elseif i == 5; return t.lonUR;
    elseif i == 6; return t.latUR;
    elseif i == 7; return t.x;
    elseif i == 8; return t.y;
    elseif i == 9; return t.lonC;
    elseif i == 10; return t.latC;
    elseif i == 11; return t.lon_step;
    elseif i == 12; return t.width;
    elseif i == 13; return t.cols;
    else
        throw(BoundsError(t, i))
    end
end

""" Reports the number of fields in TileMetadata. """
Base.length(::TileMetadata) = 13

""" Allows TileMetadata to be used in loops and with destructuring. """
Base.iterate(t::TileMetadata, state=1) = state > length(t) ? nothing : (t[state], state + 1)

m = LATITUDE_BANDS
n = TILE_WIDTHS_DEG

tileWidth(lat) = reduce(+,map((x,y,z)->z * (abs(lat) < x) * (abs(lat) >= y),m,m[begin+1:end],n))

baseX(lat,lon) = floor(floor(lon / tileWidth(lat)) * tileWidth(lat))
x(lat,lon) = floor(Int,(lon - baseX(lat,lon)) / tileWidth(lat))
baseY(lat) = floor(lat)
y(lat) = floor(Int,(lat - baseY(lat)) * 8)

minLat(lat) = baseY(lat) + 1.0 * (y(lat) // 8)
maxLat(lat) = baseY(lat) + 1.0 * ((1 + y(lat)) // 8)

minLon(lat,lon) = baseX(lat,lon) + x(lat,lon) * tileWidth(lat)
maxLon(lat,lon) = minLon(lat,lon) + tileWidth(lat)

centerLat(lat) = minLat(lat) + (maxLat(lat) - minLat(lat)) / 2.0
centerLon(lat,lon) = minLon(lat,lon) + (maxLon(lat,lon) - minLon(lat,lon)) / 2.0

longDegOnLatitudeNm(lat) = 2 * pi * 6371.0 * 0.53996 * cosd(lat) / 360.0
longDegOnLongitudeNm() = pi * 6378.0 * 0.53996 / 180

latDegByCentralPoint(lat,lon,radius) = (
    round((lat -  mod(lat,0.125)) - (radius/longDegOnLongitudeNm()),digits=1),
    round((lon -  mod(lon,tileWidth(lat))) - (radius/longDegOnLatitudeNm(lat)),digits=1),
    round((lat - mod(lat,0.125) + 0.125) + (radius/longDegOnLongitudeNm()),digits=1),
    round((lon - mod(lon,tileWidth(lat)) + tileWidth(lat))+ (radius/longDegOnLatitudeNm(lat)),digits=1))

sizeHight(sizeWidth,lat) = Int(sizeWidth / (8 * tileWidth(lat)))
inValue(value,extrem) = abs(value) <= extrem

"""
Calculates the longitudinal width of a tile in degrees based on latitude.
"""
function tileWidth(lat::Real)::Float64
    abs_lat = abs(lat)
    for i in 1:length(TILE_WIDTHS_DEG)
        if abs_lat >= LATITUDE_BANDS[i+1] && abs_lat < LATITUDE_BANDS[i]
            return TILE_WIDTHS_DEG[i]
        end
    end
    return TILE_WIDTHS_DEG[end] # Default for lowest latitude band
end

""" Calculates the base longitude for the tile grid. """
function baseX(lat::Real, lon::Real)::Float64
    tw = tileWidth(lat)
    return floor(lon / tw) * tw
end

""" Calculates the x-index within the latitude band. """
function x_index(lat::Real, lon::Real)::Int
    return floor(Int, (lon - baseX(lat, lon)) / tileWidth(lat))
end

""" Calculates the base latitude for the tile grid. """
baseY(lat::Real)::Float64 = floor(lat)

""" Calculates the y-index within the degree band. """
function y_index(lat::Real)::Int
    # Assuming 8 subdivisions per degree latitude
    return floor(Int, (lat - baseY(lat)) * 8)
end

"""
Calculates a unique index for a given latitude and longitude.
"""

function index(lat::Float64, lon::Float64)
    lon_shifted = floor(Int, lon + 180)
    lat_shifted = floor(Int, lat + 90)

    lon_base = lon_shifted - 180
    lat_base = lat_shifted - 90

    # Sub-grid steps
    y_idx = floor(Int, (lat - lat_base) / 0.125)
    x_idx = floor(Int, (lon - lon_base) / tileWidth(lat))

    return (lon_shifted << 14) | (lat_shifted << 6) | (y_idx << 3) | x_idx
end

# --- Coordinate Conversion and Utility Functions ---

function coordFromIndex(index)
    lon = (index >> 14) - 180
    lat = ((index - ((lon + 180) << 14)) >> 6) - 90
    y = (index - (((lon + 180) << 14) + ((lat + 90) << 6))) >> 3
    x = index - ((((lon + 180) << 14) + ((lat + 90) << 6)) + (y << 3))
    a = string(lon >= 0.0 ? "e" : "w", lon >= 0.0 ? @sprintf("%03d",floor(abs(lon),digits=-1)) : @sprintf("%03d",ceil(abs(lon),digits=-1)),
               lat >= 0.0 ? "n" : "s", lat >= 0.0 ? @sprintf("%02d",floor(abs(lat),digits=-1)) : @sprintf("%02d",ceil(abs(lat),digits=-1)))
    b = string(lon >= 0.0 ? "e" : "w", lon >= 0.0 ? @sprintf("%03d",floor(Int,abs(lon))) : @sprintf("%03d",ceil(Int,abs(lon))),
               lat >= 0.0 ? "n" : "s", lat >= 0.0 ? @sprintf("%02d",floor(Int,abs(lat))) : @sprintf("%02d",ceil(Int,abs(lat))))
    return lon + (tileWidth(lat) / 2.0 + x * tileWidth(lat)) / 2.0, lat + (0.125 / 2 + y * 0.125) / 2.0, lon, lat, x, y, a, b
end

"""
tile_dirs(lat::Real, lon::Real) -> (first_lvl, second_lvl)

Returns:
first_lvl  - 10×10° string  (e.g. "e020n60")
second_lvl - 1×1° string    (e.g. "e026n68")
"""
function tile_dirs(lat::Real, lon::Real)
    # --- 10° block ---------------------------------------------------------
    lon10 = floor(Int, lon ÷ 10) * 10        # 26.5 → 20
    lat10 = floor(Int, lat ÷ 10) * 10        # 68.6 → 60
    first = @sprintf("%c%03d%c%02d",
                     lon ≥ 0 ? 'e' : 'w', abs(lon10),
                     lat ≥ 0 ? 'n' : 's',  abs(lat10))

    # --- 1° block ----------------------------------------------------------
    lon1 = floor(Int, lon)                   # 26
    lat1 = floor(Int, lat)                   # 68
    second = @sprintf("%c%03d%c%02d",
                      lon ≥ 0 ? 'e' : 'w', abs(lon1),
                      lat ≥ 0 ? 'n' : 's',  abs(lat1))

    return first, second
end

"""
tile_dest_dir(tile_id::Int, width::Int, root::AbstractString)

Returns the final directory where to save a PNG/DDS file
(e.g.: root/8192/e020n60/e026n68).
"""
function tile_dest_dir(tile_id::Int, width::Int, root::AbstractString)
    _, _, _, _, _, _, dir10, dir1 = coordFromIndex(tile_id)  # grid_str_a, grid_str_b
    return joinpath(root, string(width), dir10, dir1)
end


""" Returns the filename extension. """
function getFileExtension(filename::AbstractString)::Union{String, Nothing}
    try
        return lowercase(splitext(filename)[2])
    catch
        return nothing
    end
end

""" Returns the filename without the extension. """
function getFileName(filename::AbstractString)::Union{String, Nothing}
     try
        return splitext(filename)[1]
    catch
        return nothing
    end
end


# --- File Dimension Getters ---

"""
Reads the DDS header to get image dimensions.
Returns: (success::Bool, width::Int64, height::Int64)
"""
function getDDSSize(file_path::AbstractString)::Tuple{Bool, Int64, Int64}
    !isfile(file_path) && return false, 0, 0
    # Simple check, could be more robust
    !endswith(lowercase(file_path), ".dds") && return false, 0, 0

    width::UInt32 = 0
    height::UInt32 = 0
    success = false

    try
        open(file_path, "r") do io
            magic = read(io, 4)
            magic != DDS_MAGIC && error("Not a DDS file (magic number mismatch)")

            header_size = read(io, UInt32)
            header_size != DDS_HEADER_SIZE && error("Invalid DDS header size")

            # Skip flags (4 bytes)
            skip(io, 4)

            # Read dimensions
            height = read(io, UInt32)
            width = read(io, UInt32)

            # No need to read the rest of the header for dimensions
            success = true
        end
    catch e
        # println("Error reading DDS header for $file_path: $e") # Optional: log error
        return false, 0, 0
    end

    return success, Int64(width), Int64(height)
end

"""
Uses ImageIO to get PNG image dimensions.
Returns: (success::Bool, width::Int64, height::Int64)
"""
function getPNGSize(file_path::AbstractString)::Tuple{Bool, Int64, Int64}
    !isfile(file_path) && return false, 0, 0
     # Simple check
    !endswith(lowercase(file_path), ".png") && return false, 0, 0

    try
        # Using ImageIO's query function is often faster than loading the whole image
        img_size = PngFiles.query(file_path) # Or use FileIO.query if more general
        # size returns height, width for historical reasons in Julia Images
        height, width = img_size.height, img_size.width # Adjust based on query output if needed
        return true, Int64(width), Int64(height)
    catch e
        # println("Error reading PNG dimensions for $file_path: $e") # Optional: log error
        return false, 0, 0
    end
end

# --- Size ID and Pixel Mapping ---

"""
Determines the Size ID (0-5+) based on image width.
"""
function getSizeFromWidth(width::Int)::Int
    return get(SIZE_ID_MAP, width, nothing)
end

"""
Gets nominal pixel width and column count for a given size ID (0-6).
"""
function getSizePixel(size_id::Int)::Tuple{Int, Int}
    for item in PIXEL_SIZE_MAP
        if item.size == size_id
            return item.width, item.cols
        end
    end
    # Default or fallback for sizes outside the defined map (e.g., size 6+)
    # Assuming size 6 continues the pattern or has a specific definition
    size_id >= 6 && return (32768, 8) # Example for size 6
    return (512, 1) # Default for size 0 or unknown smaller sizes
end


# --- Stateful Objects (Refactored from Closures) ---

""" Mutable struct to count directory scanning errors. """
mutable struct DirErrorCounter
    count::Int
    DirErrorCounter() = new(0) # Constructor
end

""" Increments the error count. """
add_error!(counter::DirErrorCounter) = counter.count += 1

""" Gets the current error count. """
get_count(counter::DirErrorCounter)::Int = counter.count


""" Mutable struct for animating a cursor. """
mutable struct CursorAnimator
    index::Int
    const symbols::Vector{Char}
    CursorAnimator() = new(1, ['\U2190','\U2196','\U2191','\U2197','\U2192','\U2198','\U2193','\U2199'])
end

""" Gets the next cursor symbol in the animation sequence. """
function next_symbol!(animator::CursorAnimator)::Char
    current_symbol = animator.symbols[animator.index]
    animator.index = animator.index % length(animator.symbols) + 1 # Cycle through 1 to 8
    return current_symbol
end

# --- File Finding ---

""" Struct to hold simplified findFile results """
struct FoundFile
    id::Int
    path::String
    mtime::Float64
    size::Int64
end

"""
Finds files matching `fileName` starting from `startPath`.
*(Replaces the original findFile which depended on unavailable ScanDir.jl)*
"""
function findFile(fileName::String; startPath::Union{String,Nothing}=nothing)::Vector{FoundFile}
    search_path = startPath
    target_name = fileName

    if search_path === nothing
        if isdir(dirname(fileName)) && !isempty(dirname(fileName))
            search_path = dirname(fileName)
            target_name = basename(fileName)
        else
             search_path = homedir() # Default search location
             target_name = basename(fileName)
        end
    end

    foundFiles = FoundFile[]
    file_id_counter = 0

    # Check if the exact path is given and exists
    exact_path = joinpath(search_path, target_name)
    if isfile(exact_path)
         try
            st = stat(exact_path)
            push!(foundFiles, FoundFile(1, exact_path, st.mtime, st.size))
            return foundFiles # Found the exact file, no need to search further
         catch e
             println("Warning: Could not stat file '$exact_path': $e")
         end
    end

    # Walk the directory if the exact file wasn't found or path was just a directory
    if isdir(search_path)
        error_counter = DirErrorCounter()
        try
            for (root, dirs, files) in walkdir(search_path; onerror= e->(add_error!(error_counter); println("Error walking directory: $e")))
                for file in files
                    if file == target_name
                        full_path = joinpath(root, file)
                        try
                            st = stat(full_path)
                            file_id_counter += 1
                            push!(foundFiles, FoundFile(file_id_counter, full_path, st.mtime, st.size))
                        catch e
                            println("Warning: Could not stat file '$full_path': $e")
                            add_error!(error_counter) # Count stat errors too
                        end
                    end
                end
            end
        catch e
             println("Error during directory walk starting at '$search_path': $e")
        end
        num_errors = get_count(error_counter)
        # if num_errors > 0
        #     println("Note: $num_errors errors occurred during directory scan.")
        # end
    # else # search_path was specified but wasn't the file and isn't a directory
    #    println("Warning: Specified search path '$search_path' is not a directory or the target file.")
    end


    return foundFiles
end


"""
chunk_pixel_size(tile::TileMetadata) :: NamedTuple{(:width,:height),Tuple{Int,Int}}
Returns the pixel dimensions of the *chunk* consistent with the tile aspect ratio:
- Width  = floor(width / cols)
- Height = round(width * |Δlat/Δlon|)
"""
@inline function chunk_pixel_size(tile::TileMetadata)::NamedTuple{(:width,:height),Tuple{Int,Int}}
    @assert tile.cols > 0
    w::Int = fld(tile.width, tile.cols)   # floor(width/cols), avoids double rounding
    Δlon::Float64 = tile.lonUR - tile.lonLL
    Δlat::Float64 = tile.latUR - tile.latLL
    aspect::Float64 = (abs(Δlon) < 1e-12) ? 1.0 : abs(Δlat/Δlon)
    h::Int = max(1, Int(round(w * aspect)))
    return (width = w, height = h)
end

"""
chunk_pixel_size(width::Integer, cols::Integer, Δlat::Real, Δlon::Real)
Variant for cases where width/cols do not match those in TileMetadata (e.g. pre-coverage).
"""
@inline function chunk_pixel_size(width::Integer, cols::Integer, Δlat::Real, Δlon::Real)::NamedTuple{(:width,:height),Tuple{Int,Int}}
    @assert cols > 0
    w::Int = fld(Int(width), Int(cols))
    aspect::Float64 = (abs(float(Δlon)) < 1e-12) ? 1.0 : abs(float(Δlat)/float(Δlon))
    h::Int = max(1, Int(round(w * aspect)))
    return (width = w, height = h)
end


# Regex for file: tileId_sizeId_total_y_x_overMODE.png
# Made the `_over` group optional with (?:...)? and captures the digit with ([0-2])
const CHUNK_RE = r"^(\d+)_(\d+)_([1-9]\d*)_([1-9]\d*)_([1-9]\d*)(?:_over([0-2]))?\.png$"

# Structure for a group of chunks ready for assembly
struct TileGroup
    tile_id::Int
    size_id::Int
    total_chunks::Int
    over_mode::Int
    files::Vector{String}
end


end # module Commons
