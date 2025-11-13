# BatchMode.jl – Command-Line Processor
#
# Workflow:
#   1. Parse CLI arguments (radius, coordinates, resolution, etc.)
#   2. Initialize logger and background monitor
#   3. Scan for existing tiles (ddsFindScanner)
#   4. Process target areas sequentially
#   5. Download/convert tiles via GeoEngine
#
# Usage Example:
#   julia photoscenary.jl -i LOWI -s 4 -r 20 --over 1
#   (Downloads 8K tiles within 20nm of Innsbruck Airport)

module BatchMode

export run

using ..AppConfig, ..GeoEngine, ..StatusMonitor, ..ddsFindScanner, ..Downloader
using Logging

# This was previously the run_batch_mode function, now the main function of this module
function run(args::Vector{String}=ARGS)
    # 1. Parse batch mode specific arguments
    cfg = AppConfig.parse_args(args)
    get(cfg, :action, nothing) == :rm && return

    # 2. Logger setup
    min_level = [Logging.Error, Logging.Warn, Logging.Info, Logging.Debug][min(get(cfg,"debug",0) + 1, 4)]
    AppLogger.init_logger("photoscenary.log"; logger_mode=get(cfg,"logger",1), min_level=min_level)
    @info "Starting in Batch mode (command line)..."

    ddsFindScanner.startFind()

    # 3. Start Background Task
    mon_task = get(cfg,"logger",1) == 0 ? StatusMonitor.start() : nothing

    try
        home_path  = @__DIR__
        route_vec, _, root_path, save_path = GeoEngine.prepare_paths_and_location(cfg, home_path)
        map_srv = Downloader.MapServer(cfg["server"])

        @info "Starting processing for defined route..."
            for (lat, lon) in route_vec
                area = Commons.MapCoordinates(lat, lon, Float64(cfg["radius"]))
                GeoEngine.process_target_area(area, cfg, map_srv, root_path, save_path)
            end
            @info "All waypoints processed successfully."
            catch err
            @error "Fatal error in Batch mode:" exception=(err, catch_backtrace())
        finally
            @info "Closing background task..."
            mon_task !== nothing && StatusMonitor.stop(mon_task)
            @info "Photoscenary generator terminated."
        end
    end

end # module BatchMode
