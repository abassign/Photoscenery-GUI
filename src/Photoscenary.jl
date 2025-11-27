# ───────────────────────────────────────────────────────────────────────────────
#  Photoscenary – Root Module
# ───────────────────────────────────────────────────────────────────────────────
#  Responsibilities:
#    • CLI argument parsing (delegated to AppConfig)
#    • Logger initialization (delegated to AppLogger)
#    • TUI status monitoring (StatusMonitor)
#    • Geographical data preparation (GeoEngine)
#    • Tile processing dispatch (TileProcessor via GeoEngine)
#    • Background task management
# ───────────────────────────────────────────────────────────────────────────────

module Photoscenary

# -----------------------------------------------------------------------------
# 1. Moduli Base e di Utilità (più indipendenti possibile)
# -----------------------------------------------------------------------------
include("png2ddsDXT1.jl")
include("dds2pngDXT1.jl")
include("Geodesics.jl")
include("AppLogger.jl")
include("ScanDir.jl") # <-- Dipendenza mancante, aggiunta qui

# Connector è una dipendenza di Commons
include("Connector.jl")

# Commons è usato da quasi tutti, quindi va caricato subito dopo le sue dipendenze
include("Commons.jl")
using .Commons

# -----------------------------------------------------------------------------
# 2. Moduli Funzionali (dipendono dai moduli base)
# -----------------------------------------------------------------------------

include("DetailScore.jl")
using .DetailScore  # rende disponibili le API pubbliche

include("ddsFindScanner.jl") # Ora può trovare ScanDir
include("StatusMonitor.jl")
include("JobFactory.jl")
include("TileProcessor.jl")
include("Route.jl")

# AssemblyMonitor ha bisogno di TileProcessor
include("AssemblyMonitor.jl")
using .AssemblyMonitor

include("FileMover.jl")
using .FileMover # Rende le funzioni disponibili

# -----------------------------------------------------------------------------
# 3. Moduli di Orchestrazione e Logica Principale
# -----------------------------------------------------------------------------
include("Downloader.jl")
include("AirportsNavaids.jl")
using .AirportsNavaids
include("GeoEngine.jl")
using .GeoEngine

# -----------------------------------------------------------------------------
# 4. Startup and Interface Modules (use everything else)
# -----------------------------------------------------------------------------
include("AppConfig.jl")

include("BatchMode.jl")
include("GuiMode.jl")

# Esporta i punti di ingresso principali
export BatchMode, GuiMode, GeoEngine, run_cli

# Funzione di avvio unificata
function run_cli(args=ARGS)
    cfg = AppConfig.parse_args(args)
    # Controlla se l'opzione --http è stata fornita
    is_gui_mode = false
    if haskey(cfg, "http") && cfg["http"] !== nothing
        is_gui_mode = true
    end

    if is_gui_mode
        GuiMode.run(args)
    else
        BatchMode.run(args)
    end
end

end # module Photoscenary

