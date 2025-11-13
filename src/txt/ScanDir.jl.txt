"""
# ScanDir Module

Efficient directory scanning utilities with file type information.

Key Features:
- Low-level directory scanning using libuv
- File type detection without additional stat calls
- Recursive directory tree traversal
- Thread-safe channel-based operations

Dependencies:
- Base.Filesystem: Core filesystem operations
- Libc: Memory allocation utilities
"""


module ScanDir

export scandir, scandirtree, DirEntry

import Base.Filesystem: uv_dirent_t
import Base: uv_error, _sizeof_uv_fs


module PosixFileTypes
@enum PosixFileType Unknown File Directory Link FIFO Socket CharDev BlockDev
end
using .PosixFileTypes: PosixFileType

"""
DirEntry(name, path, type)

Represents a directory entry with:
- name: File/directory name
- path: Full path
- type: POSIX file type classification
"""
struct DirEntry
    name::String
    path::String
    type::PosixFileType
end

function Base.show(io::IO, ::MIME"text/plain", e::DirEntry)
    print(io, "<", lowercase(string(e.type)), " ", repr(e.path), ">")
end

# File type predicate functions
_islink(e::DirEntry) = e.type == PosixFileTypes.Link
for (i,s) in enumerate((:isfile, :isdir, :islink, :isfifo, :issocket, :ischardev, :isblockdev))
    @eval Base.Filesystem.$s(e::DirEntry) = e.type == PosixFileType($i) || _islink(e) && $s(e.path)
end

filename(e::DirEntry) = e.name

"""
scandir(dir::AbstractString="."; sort=true) -> Vector{DirEntry}

Scan a directory returning a vector of DirEntry objects.
- dir: Directory path (defaults to current directory)
- sort: Whether to sort entries alphabetically (default: true)
"""
function scandir(dir::AbstractString="."; sort=true)
    # Allocate space for uv_fs_t struct
    req = Libc.malloc(_sizeof_uv_fs)
    try
        # Call libuv's scandir function
        err = ccall(:uv_fs_scandir, Int32, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Cint, Ptr{Cvoid}),
                    C_NULL, req, dir, 0, C_NULL)
        err < 0 && uv_error("readdir($(repr(dir)))", err)

        # Iterate through directory entries
        entries = DirEntry[]
        ent = Ref{uv_dirent_t}()
        while Base.UV_EOF != ccall(:uv_fs_scandir_next, Cint, (Ptr{Cvoid}, Ptr{uv_dirent_t}), req, ent)
            ent_name = unsafe_string(ent[].name)
            ent_path = joinpath(dir, ent_name)
            push!(entries, DirEntry(ent_name, ent_path, PosixFileType(ent[].typ)))
        end

        # Clean up libuv request
        ccall(:uv_fs_req_cleanup, Cvoid, (Ptr{Cvoid},), req)

        # Sort entries unless opted out
        sort && sort!(entries; by=filename)

        return entries
    finally
        Libc.free(req)
    end
end

# Internal helper for channel-based error handling
_channel_try_io(f, channel, onerror) = try
    f()
    catch err
    isa(err, Base.IOError) || rethrow()
    try
        onerror(err)
        catch err2
        close(channel, err2)
    end
    return
end

"""
scandirtree(root="."; topdown=true, follow_symlinks=false, onerror=throw, prune=_->false)
-> Channel{NamedTuple}

Recursively scan directory tree yielding (root, dirs, files) tuples.
- root: Starting directory (default: current directory)
- topdown: Traversal order (true=top-down, false=bottom-up)
- follow_symlinks: Whether to follow symbolic links (default: false)
- onerror: Error handler function (default: throw)
- prune: Predicate function to skip directories (default: none)
"""
function scandirtree(root="."; topdown=true, follow_symlinks=false, onerror=throw, prune=_->false)
    function _scandirtree(chnl, root)
        isfilelike(e) = (!follow_symlinks && islink(e)) || !isdir(e)
        tryf(f, p) = _channel_try_io(()->f(p), chnl, onerror)

        content = tryf(scandir, root)
        content === nothing && return
        dirs = DirEntry[]
        files = DirEntry[]
        for entry in content
            prune(entry) && continue
            filelike = tryf(isfilelike, entry)
            filelike === nothing && return
            push!(filelike ? files : dirs, entry)
        end

        if topdown
            push!(chnl, (; root, dirs, files))
        end
        for dir in dirs
            _scandirtree(chnl, joinpath(root, dir.name))
        end
        if !topdown
            push!(chnl, (; root, dirs, files))
        end
        nothing
    end
    TreeEntry = NamedTuple{(:root, :dirs, :files), Tuple{String, Vector{DirEntry}, Vector{DirEntry}}}
    return Channel{TreeEntry}(chnl -> _scandirtree(chnl, root))
end

"""
walkdir(root="."; topdown=true, follow_symlinks=false, onerror=throw, prune=_->false)
-> Channel{NamedTuple}

Higher-level directory walker that returns only names (not DirEntry objects).
Parameters match scandirtree().
"""
function walkdir(root="."; topdown=true, follow_symlinks=false, onerror=throw, prune=_->false)
    scan_channel = scandirtree(root; topdown, follow_symlinks, onerror, prune)
    WalkdirEntry = NamedTuple{(:root, :dirs, :files), Tuple{String, Vector{String}, Vector{String}}}
    return Channel{WalkdirEntry}() do channel
        _channel_try_io(channel, onerror) do
        for (root, dirs, files) in scan_channel
            push!(channel, (; root, dirs = [e.name for e in dirs], files = [e.name for e in files]))
            end
            end
        end
    end

end # module
