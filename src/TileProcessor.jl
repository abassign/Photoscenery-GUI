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


module TileProcessor

using FileIO, Images, Colors
using ..Commons
using ..png2ddsDXT1
using ..ddsFindScanner

export assemble_group_from_tmp, output_path_for


"""
output_path_for(tile_id, size_id, root_path, save_path) -> String

Ritorna il path finale dove salvare il tile assemblato.
Modifica liberamente la struttura cartelle per allinearla al tuo progetto.
"""
function output_path_for(tile_id::Int, size_id::Int, root_path::String, save_path::String)::String
    # Esempio semplice e auto-contenuto:
    out_dir = joinpath(save_path, "assembled", string(size_id))
    mkpath(out_dir)
    return joinpath(out_dir, string(tile_id) * ".png")
end


function assemble_group_from_tmp(
    tile_id::Int, size_id::Int, total_chunks::Int, files::Vector{String},
    root_path::String, save_path::String, tmp_dir::String, cfg::Dict
    )::Bool

    isempty(files) && return false

    # 0) parametri di robustezza
    cols = Int(round(sqrt(total_chunks)))
    (cols * cols == total_chunks) || return false
    min_bytes = get(cfg, "min_chunk_bytes", 64)

    # 1) indicizza SOLO i file validi presenti
    byyx = Dict{Tuple{Int,Int},String}()
    for f in files
        if !(isfile(f) && filesize(f) >= min_bytes); return false; end
        name = basename(f)
        m = match(r"^(\d+)_(\d+)_([1-9]\d*)_([1-9]\d*)_([1-9]\d*)\.png$", name)
        m === nothing && return false
        parse(Int, m.captures[1]) == tile_id    || return false
        parse(Int, m.captures[2]) == size_id    || return false
        parse(Int, m.captures[3]) == total_chunks || return false
        y = parse(Int, m.captures[4]); x = parse(Int, m.captures[5])
        (1 <= x <= cols && 1 <= y <= cols) || return false
        byyx[(y,x)] = f
    end
    length(byyx) == total_chunks || return false

    # 2) misura dal primo file esistente
    first_path = first(values(byyx))
    if !(isfile(first_path) && filesize(first_path) >= get(cfg, "min_chunk_bytes", 64)); return false; end
    first_img = try Images.load(first_path) catch; return false; end
    chunk_h, chunk_w = size(first_img)
    total_h = chunk_h * cols
    total_w = chunk_w * cols
    final_image = fill(colorant"black", total_h, total_w)

    # 3) & 4) copia tutti i chunk
    for y in 1:cols, x in 1:cols
        f = get(byyx, (y,x), "")
        !isempty(f) || return false
        isfile(f) || return false
        img = try Images.load(f) catch; return false; end
        (size(img,1) == chunk_h && size(img,2) == chunk_w) || return false
        row = y - 1
        col = x - 1
        row_start = row * chunk_h + 1
        col_start = col * chunk_w + 1
        final_image[row_start:row_start+chunk_h-1, col_start:col_start+chunk_w-1] .= img
    end

    # 5) TileMetadata minimale per "move"
    lonC, latC, lonLL, latLL, xidx, yidx, _, _ = Commons.coordFromIndex(tile_id)
    width, _ = Commons.getSizeAndCols(size_id)
    lon_step = Commons.tileWidth(latC)
    tile_meta = Commons.TileMetadata(
        tile_id, size_id,
        lonLL, latLL, lonLL + lon_step, latLL + 0.125,
        xidx, yidx,
        lonC, latC, lon_step,
        width, cols
    )

    # --- INIZIO BLOCCO LOGICO CORRETTO ---

    # 6) Logica di salvataggio e posizionamento
    if !get(cfg, "png", false)
        # Percorso DDS
        temp_png = joinpath(tmp_dir, "$(tile_id)_$(size_id)_assembled.png")
        temp_dds = joinpath(tmp_dir, "$(tile_id)_$(size_id).dds")
        final_staging = joinpath(tmp_dir, string(tile_id) * ".dds")
        try
            Images.save(temp_png, final_image)
            png2ddsDXT1.convert(temp_png, temp_dds)
            rm(temp_png; force=true)
            mv(temp_dds, final_staging; force=true)

            if !ddsFindScanner.place_tile!(final_staging, tile_meta, root_path, save_path, cfg)
                return false # Propaga il fallimento
            end
            rm(final_staging; force=true) # Cleanup
        catch
            return false # Errore in conversione/salvataggio
        end
    else
        # Percorso PNG
        final_staging = joinpath(tmp_dir, string(tile_id) * ".png")
        try
            Images.save(final_staging, final_image)
            if !ddsFindScanner.place_tile!(final_staging, tile_meta, root_path, save_path, cfg)
                return false # Propaga il fallimento
            end
            rm(final_staging; force=true) # Cleanup
        catch
            return false # Errore in salvataggio
        end
    end

    # 7) Cleanup finale dei chunk e successo
    for f in values(byyx)
        rm(f; force=true)
    end

    return true # <-- Restituisce SEMPRE e SOLO 'true' in caso di successo
end



end # module TileProcessor
