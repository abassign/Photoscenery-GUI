# Salva come: src/JobFactory.jl
"""
# JobFactory Module

Responsible for creating lists of chunk-based processing jobs from tile metadata.
This module acts as a factory for generating the necessary download tasks.
"""
module JobFactory

using ..Commons
using ..StatusMonitor

export create_chunk_jobs


"""
create_chunk_jobs(
    tiles::Vector{TileMetadata},
    cfg::Dict,
    tmp_dir::String
    )::Vector{ChunkJob}

    Generates the list of `ChunkJob` tasks corresponding to image chunks that must be downloaded
    in order to assemble the final orthophoto tiles.

    Each tile is subdivided into smaller chunks based on its internal layout (typically 2×2 or 4×4)
    and each chunk is represented as a `ChunkJob` that knows how to compute its bounding box,
    its target filename, and its position within the full tile.

    # Arguments
    - `tiles::Vector{TileMetadata}`: List of tiles to be assembled.
    - `cfg::Dict`: Configuration dictionary that may include zoom level, overlap, and other download parameters.
    - `tmp_dir::String`: Path to the temporary directory where chunk PNGs will be saved.

    # Returns
    - `Vector{ChunkJob}`: A flat list of jobs that can be processed independently and in parallel.

    # Notes
    - Each chunk job is independent and suitable for parallel download.
    - The output of this function is typically fed into a job queue for download processing.

    # Example
    jobs = create_chunk_jobs(tiles, cfg, "/path/to/tmp")
"""
function create_chunk_jobs(tiles::Vector{TileMetadata}, cfg::Dict, tmp_dir::String)
    jobs = Vector{ChunkJob}()
    retries = haskey(cfg, "attemps") ? cfg["attemps"] : 5

    for tile in tiles
        ΔLon_deg = (tile.lonUR - tile.lonLL) / tile.cols
        ΔLat_deg = (tile.latUR - tile.latLL) / tile.cols
        chunk_pixel_width = Int(tile.width / tile.cols)

        if abs(ΔLon_deg) < 1e-9; continue; end
        aspect_ratio = abs(ΔLat_deg / ΔLon_deg)
        chunk_pixel_height = round(Int, chunk_pixel_width * aspect_ratio)
        if chunk_pixel_height <= 0; continue; end
        total_chunks = tile.cols * tile.cols

        for y in 1:tile.cols, x in 1:tile.cols
            chunk_xy = (x, y)
            # Crea il nome del chunk che sarà elemento della matrice di costruzione del dile completo
            y_flipped = tile.cols - y + 1
            temp_filename = "$(tile.id)_$(tile.size_id)_$(total_chunks)_$(y_flipped)_$(x).png"
            temp_path = joinpath(tmp_dir, temp_filename)

            if isfile(temp_path) && filesize(temp_path) > 1024
                StatusMonitor.update_chunk_state(tile.id, chunk_xy, :completed, filesize(temp_path))
                continue
            end

            chunk_lonLL = tile.lonLL + (x - 1) * ΔLon_deg
            chunk_latLL = tile.latLL + (y - 1) * ΔLat_deg
            chunk_lonUR = chunk_lonLL + ΔLon_deg
            chunk_latUR = chunk_latLL + ΔLat_deg

            bbox = (lonLL=chunk_lonLL, latLL=chunk_latLL, lonUR=chunk_lonUR, latUR=chunk_latUR)
            pixel_size = (width=chunk_pixel_width, height=chunk_pixel_height)

            # Crea un ChunkJob (da Commons) senza URL
            push!(jobs, ChunkJob(tile.id, tile.size_id, chunk_xy, bbox, pixel_size, temp_path, retries))
        end
    end
    return jobs
end


end # module JobFactory
