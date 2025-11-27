"""
# TileProcessor Module

Core module responsible for assembling individual tile chunks into complete image files.

    Key Responsibilities:
    1. Assembles multiple PNG chunks into a single composite image
    2. Handles both DDS and PNG output formats
    3. Manages temporary files and cleanup
    4. Coordinates with tile placement system

    Dependencies:
    - Commons: Core functionality and metadata types
    - StatusMonitor: Progress tracking and logging
    - png2ddsDXT1: DDS conversion utilities
    - ddsFindScanner: Final tile placement
    - Images/FileIO: Image processing
    - SharedArrays: Thread-safe image assembly
"""
# Save as: src/TileProcessor.jl (Refactored Version)
module TileProcessor

using FileIO, Images, Colors
using ..Commons
using ..png2ddsDXT1

export assemble_group_from_group

"""
    assemble_group_from_group(group, tmp_dir, cfg) -> Union{String, Nothing}

"Pure" assembly function. Takes a TileGroup object, assembles chunks,
converts to DDS (if requested) and returns the path of the final temporary file.
Does not handle placement or cleanup of source chunks.
"""
function assemble_group_from_group(
    group::Commons.TileGroup, # Receives the entire struct
    tmp_dir::String,
    cfg::Dict
    )::Union{String, Nothing}

    # 1. Basic validation and image setup
    try
        first_img = Images.load(group.files[1])
        chunk_h, chunk_w = size(first_img)
        cols = Int(round(sqrt(group.total_chunks)))
        final_image = fill(colorant"black", chunk_h * cols, chunk_w * cols)

        # 2. Assemble the final image
        for f in group.files
            name = basename(f)
            m = match(Commons.CHUNK_RE, name) # Uses regex from Commons
            y_flipped = parse(Int, m.captures[4])
            x = parse(Int, m.captures[5])

            row = y_flipped - 1
            col = x - 1
            row_start = row * chunk_h + 1
            col_start = col * chunk_w + 1
            final_image[row_start:row_start+chunk_h-1, col_start:col_start+chunk_w-1] .= Images.load(f)
        end

        # 3. Save in the requested format (DDS or PNG)
        if !get(cfg, "png", false)
            # DDS Path
            temp_png = joinpath(tmp_dir, "$(group.tile_id)_$(group.size_id)_assembled.png")
            Images.save(temp_png, final_image)

            final_temp_path = joinpath(tmp_dir, "$(group.tile_id)_$(group.size_id)_final.dds")
            png2ddsDXT1.convert(temp_png, final_temp_path)
            rm(temp_png; force=true)
            return final_temp_path
        else
            # PNG Path
            final_temp_path = joinpath(tmp_dir, "$(group.tile_id)_$(group.size_id)_final.png")
            Images.save(final_temp_path, final_image)
            return final_temp_path
        end

    catch e
        @error "TileProcessor: Error during assembly of tile $(group.tile_id)" exception=(e, catch_backtrace())
        return nothing # In case of any error, returns nothing
    end
end

end # module TileProcessor
