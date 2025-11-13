"""
# StatusMonitor Module

Real-time monitoring system for tile download and processing operations.

    Key Features:
    - Thread-safe progress tracking
    - Interactive terminal UI with multiple panels
    - Download speed and statistics calculation
    - Comprehensive logging system
    - Graceful start/stop functionality

    Dependencies:
    - Term.jl: Terminal UI rendering
    - ThreadSafeDicts: Thread-safe data structures
    - Commons: Shared utilities and constants
    - AppLogger: Application logging system
"""

module StatusMonitor

using Term; using Term.Layout; using Term.Progress
using Printf, Dates, ThreadSafeDicts, Base.Threads, Logging
using ..Commons, ..AppLogger

export start, stop, log_message, start_tile_download, finish_tile_download, update_chunk_state


# --- Global State (with IS_ACTIVE) ---
const MESSAGE_CHANNEL = Channel{String}(200)
const ACTIVE_DOWNLOADS = ThreadSafeDict{Int, Any}()
const UI_LOCK = ReentrantLock()
const IS_ACTIVE = Ref{Bool}(false)
const SHOULD_RUN = Ref{Bool}(true)
const SPINNER = Commons.CursorAnimator()
const TOTAL_FILES_DOWNLOADED = Ref{Int}(0)
const TOTAL_BYTES_DOWNLOADED = Ref{Int64}(0)

# --- Updated Data Structure ---
mutable struct DownloadState
    tileIndex::Int
    total_chunks::Int
    chunks_completed::Ref{Int} # Using Ref for thread-safety
    chunk_grid::Matrix{Int}    # 0:pending, 1:in_progress, 2:completed, -1:failed
    status::String
    start_time::DateTime
    downloaded_bytes::Ref{Int64}
    speed_kbs::Ref{Float64}
    lock::ReentrantLock
end

# --- Public API ---

"""
start() -> Task

Launches the monitor in an async task and returns it.
"""
function start()
    IS_ACTIVE[] = true
    SHOULD_RUN[] = true
    empty!(ACTIVE_DOWNLOADS) # Clear previous downloads on each start
    return @async run_status_monitor()
end

"""
stop(task::Task)

Cleanly stops the monitor started with `start()`.
"""
function stop(task::Task)
    IS_ACTIVE[] = false
    stop_status_monitor()      # closes channel and flag
    wait(task)                # waits for loop to finish
    return nothing
end

function add_to_session_stats(files_completed::Int, bytes_added::Int)
    IS_ACTIVE[] || return # <-- GUARD CLAUSE: do nothing if not active
    lock(UI_LOCK) do
        TOTAL_FILES_DOWNLOADED[] += files_completed
        TOTAL_BYTES_DOWNLOADED[] += bytes_added
    end
end

function log_message(msg::String)
    # This function always logs to file, but only sends to TUI if active
    @info msg
    IS_ACTIVE[] || return # <-- GUARD CLAUSE
    try
        if isopen(MESSAGE_CHANNEL)
            put!(MESSAGE_CHANNEL, msg)
        end
    catch
        # Ignore errors
    end
end

function start_tile_download(tileIndex::Int, total_chunks::Int)
    IS_ACTIVE[] || return
    side = round(Int, sqrt(total_chunks))
    state = DownloadState(tileIndex, total_chunks, Ref(0), zeros(Int, side, side),
                            "Downloading...", now(), Ref(0), Ref(0.0), ReentrantLock())
    ACTIVE_DOWNLOADS[tileIndex] = state
end

function update_chunk_state(tileIndex::Int, chunk_xy::Tuple{Int, Int}, status::Symbol, bytes::Int=0)
    IS_ACTIVE[] || return
    if haskey(ACTIVE_DOWNLOADS, tileIndex)
        state = ACTIVE_DOWNLOADS[tileIndex]
        lock(state.lock) do
            x, y = chunk_xy
            state_code = status == :in_progress ? 1 : (status == :completed ? 2 : -1)
            state.chunk_grid[y, x] = state_code

            if status == :completed
                state.chunks_completed[] += 1
                state.downloaded_bytes[] += bytes
                elapsed_seconds = max(0.001, (now() - state.start_time).value / 1000.0)
                state.speed_kbs[] = (state.downloaded_bytes[] / elapsed_seconds) / 1024.0
            end
        end
    end
end

function finish_tile_download(tileIndex::Int, final_status::String)
    IS_ACTIVE[] || return # <-- GUARD CLAUSE
    try
        state = get(ACTIVE_DOWNLOADS, tileIndex, nothing)
        if state === nothing
            log_message("Tile $tileIndex no longer present in ACTIVE_DOWNLOADS")
            return
        end

        # Atomic update: first acquire dict lock,
        # then modify state *outside* the rendering loop.
        lock(state.lock) do
            state.status = final_status
            if final_status in ("Completed", "Copied")
                state.completed_chunks = state.total_chunks
            end
        end
        catch e
        # Don't crash the entire session for a UI error.
        @error "finish_tile_download: error on tile $tileIndex - $e"
    end
end

# --- Private Rendering Functions ---
function _format_bytes(bytes::Integer)
    if bytes < 1024
        return "$bytes B"
    end
    kb = bytes / 1024
    if kb < 1024
        return @sprintf("%.2f KB", kb)
    end
    mb = kb / 1024
    if mb < 1024
        return @sprintf("%.2f MB", mb)
    end
    gb = mb / 1024
    return @sprintf("%.2f GB", gb)
end

function _create_summary_panel()
    local files, bytes
    lock(UI_LOCK) do
        files = TOTAL_FILES_DOWNLOADED[]
        bytes = TOTAL_BYTES_DOWNLOADED[]
    end
    formatted_bytes = _format_bytes(bytes)
    summary_text = "Downloaded Files: {bold green}$files{/bold green}  |  Total Data: {bold cyan}$formatted_bytes{/bold cyan}"

    return Panel(
        RenderableText(summary_text, justify=:center),
        width=80,
        height=3,
        title="Session Statistics",
        style="white dim",
        box=:ROUNDED
        )
end

function _create_log_panel(latest_logs::Vector{String})
    return Panel(
        join(latest_logs, "\n"),
        width=80,
        height=8,
        title="Event Log",
        style="white dim",
        box=:ROUNDED
        )
end

function _create_download_panel(state::DownloadState)
    lock(state.lock) do
        # --- Grid rendering logic ---
        grid_text = ""
        side, _ = size(state.chunk_grid)
        for y in 1:side
            row_str = ""
            for x in 1:side
                s = state.chunk_grid[y, x]
                char = if s == 0; "{dim}⋅{/dim}" # Pending
                    elseif s == 1; "{yellow}$(Commons.next_symbol!(SPINNER)){/yellow}" # In progress
                    elseif s == 2; "{green}■{/green}" # Completed
                    else; "{red}✖{/red}" # Failed
                end
                row_str *= char * " "
            end
            grid_text *= rstrip(row_str) * "\n"
        end

        # --- Statistics calculations (using Refs) ---
        percentage = state.total_chunks > 0 ? round(Int, (state.chunks_completed[] / state.total_chunks) * 100) : 0
        elapsed_str = Dates.format(Time(0) + (now() - state.start_time), "MM:SS")
        formatted_size = _format_bytes(state.downloaded_bytes[])
        formatted_speed = @sprintf("%.1f KB/s", state.speed_kbs[])

        # --- Panel assembly ---
        stats_line = "{gray}Tile: $(state.tileIndex) | {white bold}$(lpad(percentage, 3))%{/white bold} | {cyan}$(formatted_size){/cyan} @ {orange bold}$(formatted_speed){/orange bold} | Status: {bold}$(state.status){/bold} | T: $(elapsed_str){/gray}"

        content = vstack(
            RenderableText(grid_text, justify=:center),
            stats_line
            )

        return Panel(content;
                        width=80,
                        title="Downloading Tile $(state.tileIndex)",
                        style="default",
                        box=:ROUNDED
                        )
    end
end

# --- Main Monitor Loop ---
function run_status_monitor()
    latest_logs = String[]
    max_logs = 5
    print("\033[2J")  # Clear screen

    while SHOULD_RUN[]
        # Process messages
        while isready(MESSAGE_CHANNEL)
            msg = take!(MESSAGE_CHANNEL)
            push!(latest_logs, msg)
            if length(latest_logs) > max_logs
                popfirst!(latest_logs)
            end
        end

        # Build UI panels
        all_panels = Term.AbstractRenderable[]
        push!(all_panels, _create_log_panel(latest_logs))
        push!(all_panels, _create_summary_panel())

        # Add download panels
        active_keys = sort(collect(keys(ACTIVE_DOWNLOADS.d)))
        for key in active_keys
            state = ACTIVE_DOWNLOADS[key]
            push!(all_panels, _create_download_panel(state))
            if state.status != "Downloading" && (now() - state.start_time).value > 5000
                delete!(ACTIVE_DOWNLOADS, key)
            end
        end

        # Render UI
        lock(UI_LOCK) do
            print("\033[H")  # Move cursor to home position
            header = Panel(
                "{bold green}Photoscenary.jl Monitor{/bold green} $(Commons.next_symbol!(SPINNER)) [bold]Active[/bold]",
                width=80, justify=:center, style="green", box=:DOUBLE
                )
            print(vstack(header, all_panels...))
            print("\033[J")  # Clear to end of screen
        end

        sleep(0.1)  # Control refresh rate
    end
    println("Monitor UI terminated.")
end

function stop_status_monitor()
    SHOULD_RUN[] = false
    close(MESSAGE_CHANNEL)
    log_message("Monitor UI shutting down...")
end

end  # module
