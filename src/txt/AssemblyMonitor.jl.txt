# Salva come: src/AssemblyMonitor.jl

module AssemblyMonitor

using Logging
using Base.Threads: @spawn
using ..Commons
using ..TileProcessor
using ..StatusMonitor
using ..ddsFindScanner

const MONITOR_DEBUG = Ref(false)


function collect_complete_groups(tmp_dir::AbstractString)::Vector{Commons.TileGroup}
    # La chiave del dizionario ora include anche over_mode
    d = Dict{Tuple{Int,Int,Int,Int}, Vector{String}}()
    try
        for f in readdir(tmp_dir; join=true)
            endswith(f, ".png") || continue
            name = basename(f)

            # Usiamo la Regex globale definita in Commons.jl
            m = match(Commons.CHUNK_RE, name)
            m === nothing && continue

            tile_id  = parse(Int, m.captures[1])
            size_id  = parse(Int, m.captures[2])
            total    = parse(Int, m.captures[3])

            # Estrai over_mode (il 6° gruppo catturato), con un default di 0
            # se non è presente (per retrocompatibilità con vecchi file)
            over_str = m.captures[6]
            over_mode = over_str === nothing ? 0 : parse(Int, over_str)

            # La chiave di raggruppamento ora è a 4 elementi
            key = (tile_id, size_id, total, over_mode)
            push!(get!(d, key, String[]), f)
        end
    catch e
        if !(e isa SystemError && e.errnum == 2)
             @warn "[MONITOR] Errore durante la lettura della cartella tmp" exception=(e, catch_backtrace())
        end
        return Commons.TileGroup[]
    end

    groups = Commons.TileGroup[]
    # Destruttura la nuova chiave a 4 elementi
    for ((tile_id, size_id, total, over_mode), paths) in d
        if length(paths) == total
            # Chiama il costruttore di TileGroup con i 5 argomenti corretti
            push!(groups, Commons.TileGroup(tile_id, size_id, total, over_mode, sort(paths)))
        end
    end
    return groups
end


"""
    monitor_and_assemble(root, save, tmp, cfg; check_interval=2)

Servizio continuo che orchestra l'assemblaggio.
1. Trova gruppi completi.
2. Chiama TileProcessor per assemblarli.
3. Se l'assemblaggio ha successo, orchestra il posizionamento e la pulizia.
"""
function monitor_and_assemble(root_path::String, save_path::String, tmp_dir::String,
                              cfg::Dict; check_interval::Int=2)

    @info "▶️  [MONITOR] Servizio di assemblaggio AVVIATO (Architettura Corretta). In ascolto su: $tmp_dir"

    seen = Set{Tuple{Int,Int}}()
    claimed = Set{Tuple{Int,Int,Int,Int}}()
    min_bytes = get(cfg, "min_chunk_bytes", 64)
    interval  = get(cfg, "monitor_interval", check_interval)

    while true
        try
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
                        # 1. Chiama l'officina per assemblare il tile
                        final_temp_path = TileProcessor.assemble_group_from_group(g, tmp_dir, cfg)

                        if final_temp_path === nothing
                            @warn "⚠️ [MONITOR] Assemblaggio FALLITO per tile $(g.tile_id)."
                        else
                            # 2. Assemblaggio OK. Ora orchestra il posizionamento.
                            lonC, latC, lonLL, latLL, xidx, yidx, _, _ = Commons.coordFromIndex(g.tile_id)
                            width, cols = Commons.getSizeAndCols(g.size_id)
                            lon_step = Commons.tileWidth(latC)
                            tile_meta = Commons.TileMetadata(g.tile_id, g.size_id, lonLL, latLL, lonLL + lon_step, latLL + 0.125, xidx, yidx, lonC, latC, lon_step, width, cols)

                            # A. Crea una copia della config globale
                            placement_cfg = copy(cfg)
                            # B. Inserisci il valore di 'over' letto dal nome del file. QUESTA È LA CHIAVE.
                            placement_cfg["over"] = g.over_mode

                            # C. Chiama ddsFindScanner con la configurazione SPECIFICA del job
                            success = ddsFindScanner.place_tile!(final_temp_path, tile_meta, root_path, save_path, placement_cfg)

                            if success
                                @info "✅ [MONITOR] Posizionamento COMPLETATO per tile $(g.tile_id) con over_mode=$(g.over_mode)."
                                push!(seen, key_seen)
                                for f_chunk in g.files; rm(f_chunk; force=true); end
                            else
                                @warn "⚠️ [MONITOR] Posizionamento FALLITO per tile $(g.tile_id)."
                            end
                            rm(final_temp_path; force=true)
                        end
                    catch e
                        @error "💥 [MONITOR] Eccezione critica durante l'orchestrazione" tile_id=g.tile_id exception=(e, catch_backtrace())
                    finally
                        delete!(claimed, key_claim)
                    end
                end # fine @spawn
            end # fine for
        catch e
            @error "💥 [MONITOR] Errore nel ciclo principale del monitor" exception=(e, catch_backtrace())
        end
        sleep(interval)
    end
end


end # module

