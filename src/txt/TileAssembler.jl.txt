"""
# TileAssembler Module

Responsible for assembling individual PNG chunks into final DDS tile files.

    Key Responsibilities:
    1. Parses chunk coordinates from filenames
    2. Validates and filters corrupt PNG chunks
    3. Assembles valid chunks into complete tiles using multithreading
    4. Converts assembled images to DDS format
    5. Handles final file placement and cleanup

    Dependencies:
    - Commons: Core functionality and metadata handling
    - png2ddsDXT1: DDS conversion utilities
    - ddsFindScanner: Tile placement and indexing
    - FileIO/Images: Image loading and processing
    - Base.Threads: Parallel processing
"""


module TileAssembler

using ..Commons, ..png2ddsDXT1, ..ddsFindScanner
using FileIO, Images, FilePathsBase
using Base.Threads: @threads

export assemble_tile_to_dds

"""
parse_coords(fname::String) -> (row, col)

Extracts 1-based row and column coordinates from chunk filenames.
Filename format: [tile_id]_[size_id]_[total_chunks]_[row]_[col].png
"""
function parse_coords(fname::String)
    parts = split(basename(fname), '_')
    length(parts) == 5 || throw(ArgumentError("Malformed chunk filename: $(basename(fname))"))
    row_str = parts[4]  # 4th part is row
    col_str = split(parts[5], '.')[1]  # 5th part is "col.png"
    row = parse(Int, row_str)
    col = parse(Int, col_str)
    return row, col  # 1-based
end

"""
collect_valid_chunks(chunk_files, expected_count::Int) -> Vector{String}

Filters out corrupt or invalid PNG chunks:
1. Verifies files can be loaded as valid images
2. Checks filename format is correct
3. Returns only valid files if count matches expected
"""
function collect_valid_chunks(chunk_files, expected_count::Int)
    valid = String[]
    for f in chunk_files
        try
            img = FileIO.load(f)
            size(img, 1) > 0 || continue
            parse_coords(f)  # will throw if malformed
            push!(valid, f)
            catch e
            @warn "TileAssembler: skipping malformed or corrupt PNG $f" exception=e
            rm(f, force=true)
        end
    end
    return length(valid) == expected_count ? valid : String[]
end

"""
assemble_tile_to_dds(tile_id::Int, size_id::Int, chunk_files::Vector{String},
cfg::Dict, root_path::String, root_path_saved::String) -> Bool

Main assembly function that:
    1. Validates input chunks
    2. Creates composite image from chunks (parallelized)
    3. Converts to DDS format
    4. Places final tile in correct location
    5. Cleans up temporary files

    Returns true if assembly succeeded, false otherwise.
"""
function assemble_tile_to_dds(tile_id::Int, size_id::Int,
                                chunk_files::Vector{String},
                                cfg::Dict,
                                root_path::String,
                                root_path_saved::String)
    valid_files = collect_valid_chunks(chunk_files, length(chunk_files))
    isempty(valid_files) && return false

    # Get dimensions from first valid PNG
    img0       = FileIO.load(valid_files[1])
    ch_h, ch_w = size(img0)
    rows, cols = maximum(parse_coords.(valid_files))
    canvas_h   = rows * ch_h
    canvas_w   = cols * ch_w

    # 1. Get temporary directory from one of the chunks
    tmp_dir = dirname(valid_files[1])

    # 2. Temporary DDS file is our intermediate target
    tmp_dds = joinpath(tmp_dir, "$(tile_id).dds")

    # Composite image assembly
    padded_h = (canvas_h + 3) & ~3  # Round up to multiple of 4 for DXT
    padded_w = (canvas_w + 3) & ~3
    canvas   = zeros(RGBA{N0f8}, padded_h, padded_w)

    @threads for f in valid_files
        img       = FileIO.load(f)
        row, col  = parse_coords(f)
        y = (row - 1) * ch_h + 1
        x = (col - 1) * ch_w + 1
        canvas[y:y+ch_h-1, x:x+ch_w-1] .= img
    end

    # Convert canvas to temporary DDS file
    png2ddsDXT1.convert(canvas, tmp_dds, Threads.nthreads())

    # Create minimal TileMetadata object needed for placement
    _, _, lon_base, lat_base, _, _, _, _ = Commons.coordFromIndex(tile_id)
    meta = Commons.TileMetadata(
        tile_id, size_id,
        lon_base, lat_base, 0.0, 0.0,
        0, 0, 0.0, 0.0, 0.0,
        canvas_w, cols
        )

    # Use place_tile! to move temporary file and update index
    ok = ddsFindScanner.place_tile!(tmp_dds, meta, root_path, root_path_saved, cfg)

    # Clean up only source PNG chunks (tmp_dds has already been moved)
    foreach(f -> rm(f, force=true), valid_files)

    return ok
end

end  # module
