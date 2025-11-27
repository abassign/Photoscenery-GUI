# -------------------------------------------------------------------------------
# FileMover.jl
#
# Dedicated module for orchestrating the physical movement of Orthophotos tiles
# between directories, including disk space verification and status reporting.
# -------------------------------------------------------------------------------

module FileMover

using FilePathsBase
using Logging
using Printf
using Dates
using ..ddsFindScanner
using ..Commons
using ..StatusMonitor # To provide real-time feedback to the GUI

export move_orthophoto_directory

# State for transfer monitoring (for API polling)
const TRANSFER_STATE = Dict{Symbol, Any}(
    :is_active => false,
    :total_files => 0,
    :files_moved => 0,
    :total_bytes => 0,
    :bytes_moved => 0,
    :start_time => nothing,
    :current_speed_Bps => 0.0,
    :dest_free_space_MB => 0.0,
    :current_file => ""
)

# --------------------------
# Linux Disk Space Utility
# --------------------------
"""
    get_disk_free_space_bytes(path::String) -> Int64

Returns the free disk space in bytes for the volume containing 'path'.
Returns 0 on failure. (Linux-specific implementation using 'df').
"""
function get_disk_free_space_bytes(path::String)::Int64
    try
        # Execute 'df -P' to get information in 1K blocks
        output = read(`df -P $path`, String)
        lines = split(output, '\n')
        # We expect a header and at least one line of data
        if length(lines) < 2; return 0; end

        # Parse the line containing filesystem data (usually the second line)
        fields = split(lines[2])
        # The 4th field is usually the available space in 1K blocks
        if length(fields) >= 4
            # * 1024 to convert from 1K blocks to bytes
            return parse(Int64, fields[4]) * 1024
        end
    catch e
        @error "FileMover: Failed to determine free disk space for $path" exception=(e, catch_backtrace())
        return 0
    end
    return 0
end

# --------------------------
# Main Orchestration Function
# --------------------------
"""
    move_all_indexed_tiles(old_root::String, new_root::String, root_type::String) -> Bool

Performs the migration of all indexed tiles from old_root to new_root.
This is the core, blocking operation.
"""
function move_all_indexed_tiles(old_root::String, new_root::String, root_type::String)::Bool
    if !TRANSFER_STATE[:is_active]
        @warn "FileMover: Transfer requested, but not active. Aborting."
        return false
    end

    mkpath(new_root)

    # --- Step 1: Verification ---
    all_indexed_files = ddsFindScanner.get_all_indexed_records()

    # Filter only files that start with the old_root (for safety, though all should)
    files_to_move = filter(record -> startswith(record["path"], old_root), all_indexed_files)

    if isempty(files_to_move)
        @info "FileMover: No files found to move in $root_type."
        return true
    end

    required_bytes = sum(record -> get(record, "size", 0), files_to_move)
    free_bytes = get_disk_free_space_bytes(new_root)

    # Update state for reporting
    TRANSFER_STATE[:total_files] = length(files_to_move)
    TRANSFER_STATE[:total_bytes] = required_bytes

    if free_bytes < required_bytes
        @error "FileMover: Insufficient space on target disk for $new_root. Required: $(@sprintf("%.2f", required_bytes/1024^3)) GB, Free: $(@sprintf("%.2f", free_bytes/1024^3)) GB."
        # Correction
        StatusMonitor.log_message("FileMover: Insufficient space to move $root_type. Required: $(@sprintf("%.2f", required_bytes/1024^3)) GB, Free: $(@sprintf("%.2f", free_bytes/1024^3)) GB.")
        throw(ErrorException("Insufficient disk space for $root_type."))
    end

    @info "FileMover: Starting move of $(length(files_to_move)) files (Size: $(@sprintf("%.2f", required_bytes/1024^2)) MB) to $new_root."

    # --- Step 2: Move Execution ---
    TRANSFER_STATE[:start_time] = Dates.now()
    bytes_moved = 0
    files_moved = 0

    for record in files_to_move
        # Safety check: if cancelled by user in GUI polling
        if !TRANSFER_STATE[:is_active]
            @warn "FileMover: User requested abort. Stopping transfer."
            StatusMonitor.log_message("FileMover: Transfer aborted by user.")
            return false
        end

        old_path = record["path"]
        # The new path is calculated by substituting the old root with the new root
        new_path = replace(old_path, old_root => new_root)

        # Ensure the destination directory exists
        mkpath(dirname(new_path))

        try
            # Perform the move operation
            mv(old_path, new_path, force=true)

            # Update counters and statistics
            bytes_moved += get(record, "size", 0)
            files_moved += 1

            # --- Index Update ---
            # IMPORTANT: The ddsFindScanner index must be updated synchronously
            # to reflect the new path, otherwise the next job will fail to find the file.
            ddsFindScanner.update_path_in_index(old_path, new_path)

            # --- Status Update (for Polling) ---
            elapsed_s = (Dates.now() - TRANSFER_STATE[:start_time]).value / 1000
            current_speed_Bps = elapsed_s > 0 ? bytes_moved / elapsed_s : 0.0

            TRANSFER_STATE[:bytes_moved] = bytes_moved
            TRANSFER_STATE[:files_moved] = files_moved
            TRANSFER_STATE[:current_file] = basename(new_path)
            TRANSFER_STATE[:current_speed_Bps] = current_speed_Bps
            TRANSFER_STATE[:dest_free_space_MB] = get_disk_free_space_bytes(new_root) / 1024^2
        catch e
            @error "FileMover: Failed to move file $old_path to $new_path" exception=(e, catch_backtrace())
            # Correction
            StatusMonitor.log_message("FileMover: File move failed for $(basename(old_path)).")
            # Decide if to continue or abort on single file failure
        end
    end

    # --- Step 3: Cleanup ---
    # After all moves, attempt to remove the old root directory if empty
    try
        rm(old_root, recursive=true)
        @info "FileMover: Old root directory $old_root removed successfully."
    catch e
        @warn "FileMover: Could not remove old root directory $old_root (may not be empty)."
    end

    @info "FileMover: All files for $root_type successfully moved."
    return true
end

"""
    move_orthophoto_directory(old_path::String, new_path::String, is_save_path::Bool)

Entry point for moving Orthophotos or Orthophotos-saved directories.
"""
function move_orthophoto_directory(old_path::String, new_path::String, is_save_path::Bool)::Bool
    root_type = is_save_path ? "Orthophotos-saved" : "Orthophotos"

    if old_path == new_path
        @info "FileMover: Path for $root_type unchanged. Skipping move."
        return true
    end
    if isdir(new_path) && !isempty(readdir(new_path))
        @error "FileMover: Target directory $new_path is not empty. Aborting."
        throw(ErrorException("Target directory $new_path is not empty. Cannot overwrite."))
    end

    # 1. Prepare state
    TRANSFER_STATE[:is_active] = true
    TRANSFER_STATE[:files_moved] = 0
    TRANSFER_STATE[:bytes_moved] = 0

    try
        # 2. Execute the move
        success = move_all_indexed_tiles(old_path, new_path, root_type)

        # 3. Finalize state
        TRANSFER_STATE[:is_active] = false
        return success
    catch e
        TRANSFER_STATE[:is_active] = false
        @error "FileMover: Critical failure during move operation." exception=(e, catch_backtrace())
        return false
    end
end

# Function for polling status (for the GUI API)
get_transfer_status() = TRANSFER_STATE

end # module FileMover
