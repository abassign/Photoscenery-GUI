# Save as: src/AssemblyMonitor.jl

module AssemblyMonitor

using Logging
using Base.Threads: @spawn
using ..Commons
using ..TileProcessor
using ..StatusMonitor
using ..ddsFindScanner

const MONITOR_DEBUG = Ref(false)


function collect_complete_groups(tmp_dir::AbstractString)::Vector{Commons.TileGroup}
    d = Dict{Tuple{Int,Int,Int,Int}, Vector{String}}()
    try
        # --- ROBUSTNESS FIX: Existence check ---
        if !isdir(tmp_dir)
            return Commons.TileGroup[]
        end
        # --------------------------------------------------

        for f in readdir(tmp_dir; join=true)
            endswith(f, ".png") || continue
            name = basename(f)

            m = match(Commons.CHUNK_RE, name)
            m === nothing && continue

            tile_id  = parse(Int, m.captures[1])
            size_id  = parse(Int, m.captures[2])
            total    = parse(Int, m.captures[3])

            over_str = m.captures[6]
            over_mode = over_str === nothing ? 0 : parse(Int, over_str)

            key = (tile_id, size_id, total, over_mode)
            push!(get!(d, key, String[]), f)
        end
    catch e
        # More specific error handling
        if e isa SystemError || e isa Base.IOError
             @warn "[MONITOR] Error accessing tmp folder (retrying next cycle): $(e.msg)"
        else
             @warn "[MONITOR] Unexpected error reading tmp" exception=(e, catch_backtrace())
        end
        return Commons.TileGroup[]
    end

    groups = Commons.TileGroup[]
    for ((tile_id, size_id, total, over_mode), paths) in d
        if length(paths) == total
            push!(groups, Commons.TileGroup(tile_id, size_id, total, over_mode, sort(paths)))
        end
    end
    return groups
end


"""
    monitor_and_assemble(root, save, tmp, cfg; check_interval=2)

Continuous service that orchestrates assembly.
Robust against deletion of the tmp folder.
"""
function monitor_and_assemble(root_path::String, save_path::String, tmp_dir::String,
                              cfg::Dict; check_interval::Int=2)

    @info "▶️  [MONITOR] Assembly service STARTED (Robust Architecture). Listening on: $tmp_dir"

    seen = Set{Tuple{Int,Int}}()
    claimed = Set{Tuple{Int,Int,Int,Int}}()
    min_bytes = get(cfg, "min_chunk_bytes", 64)
    interval  = get(cfg, "monitor_interval", check_interval)

    while true
        try
            # --- ROBUSTNESS FIX ---
            # If the tmp folder disappears (e.g. deleted by user), recreate it on the fly.
            if !isdir(tmp_dir)
                # @warn "[MONITOR] Tmp folder not found. Attempting recreation..."
                mkpath(tmp_dir)
            end
            # -----------------------------

            groups = collect_complete_groups(tmp_dir)

            for g in groups
                key_claim = (g.tile_id, g.size_id, g.total_chunks, g.over_mode)
                key_seen = (g.tile_id, g.size_id)

                if key_seen in seen || key_claim in claimed
                    continue
                end

                present = [f for f in g.files if isfile(f) && filesize(f) >= min_bytes]
                if length(present) != g.total_chunks
                    continue
                end

                push!(claimed, key_claim)
                @spawn begin
                    try
                        final_temp_path = TileProcessor.assemble_group_from_group(g, tmp_dir, cfg)

                        if final_temp_path === nothing
                            @warn "⚠️ [MONITOR] Assembly FAILED for tile $(g.tile_id)."
                        else
                            lonC, latC, lonLL, latLL, xidx, yidx, _, _ = Commons.coordFromIndex(g.tile_id)
                            width, cols = Commons.getSizeAndCols(g.size_id)
                            lon_step = Commons.tileWidth(latC)
                            tile_meta = Commons.TileMetadata(g.tile_id, g.size_id, lonLL, latLL, lonLL + lon_step, latLL + 0.125, xidx, yidx, lonC, latC, lon_step, width, cols)

                            placement_cfg = copy(cfg)
                            placement_cfg["over"] = g.over_mode

                            success = ddsFindScanner.place_tile!(final_temp_path, tile_meta, root_path, save_path, placement_cfg)

                            if success
                                @info "✅ [MONITOR] Placement COMPLETED for tile $(g.tile_id) with over_mode=$(g.over_mode)."
                                push!(seen, key_seen)
                                for f_chunk in g.files; rm(f_chunk; force=true); end
                            else
                                @warn "⚠️ [MONITOR] Placement FAILED for tile $(g.tile_id)."
                            end
                            rm(final_temp_path; force=true)
                        end
                    catch e
                        @error "💥 [MONITOR] Critical exception during orchestration" tile_id=g.tile_id exception=(e, catch_backtrace())
                    finally
                        delete!(claimed, key_claim)
                    end
                end
            end
        catch e
            if isa(e, Base.IOError)
                # Ignore temporary I/O errors (e.g. file lock)
            else
                @error "💥 [MONITOR] Error in main monitor loop" exception=(e, catch_backtrace())
            end
        end
        sleep(interval)
    end
end

end # module

