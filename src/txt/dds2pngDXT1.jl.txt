#!/usr/bin/env julia
# dds2pngDXT1.jl
# Julia-only decoder: DDS (DXT1) → PNG
# MIT © KIMI 2025

module dds2pngDXT1

using FileIO, ImageIO, Colors, Dates, FixedPointNumbers
using Images

export convert, decode, is_valid_dds

# -------------------------------
# DDS header constants
const DDS_HEADER_SIZE = 128
const DDS_MAGIC = b"DDS "

# -------------------------------
# RGB565 helpers (shared with png2ddsDXT1)
@inline rgb565_to_rgba(c::UInt16) =
    RGBA((c >> 11 & 0x1f) / 31f0,
         (c >> 5  & 0x3f) / 63f0,
         (c       & 0x1f) / 31f0,
         1f0)

# -------------------------------
# Decode one 4×4 DXT1 block
function decode_block(block::Vector{UInt8})::Matrix{RGBA{N0f8}}
    @assert length(block) == 8  # 8 bytes per DXT1 block
    c0 = UInt16(block[1]) | (UInt16(block[2]) << 8)
    c1 = UInt16(block[3]) | (UInt16(block[4]) << 8)
    idx = UInt32(block[5]) | (UInt32(block[6]) << 8) |
          (UInt32(block[7]) << 16) | (UInt32(block[8]) << 24)

    # Build 4-color palette
    col0 = rgb565_to_rgba(c0)
    col1 = rgb565_to_rgba(c1)
    col2 = c0 > c1 ?
    RGBA((2*col0.r + col1.r)/3, (2*col0.g + col1.g)/3, (2*col0.b + col1.b)/3, 1) :
        RGBA((col0.r + col1.r)/2, (col0.g + col1.g)/2, (col0.b + col1.b)/2, 1)
    col3 = c0 > c1 ?
    RGBA((col0.r + 2*col1.r)/3, (col0.g + 2*col1.g)/3, (col0.b + 2*col1.b)/3, 1) :
        RGBA(0, 0, 0, 0)
    palette = [col0, col1, col2, col3]

    # Decode 4×4 pixels
    img = Matrix{RGBA{N0f8}}(undef, 4, 4)
    for i in 0:15
        px = (idx >> (2*i)) & 0x3
        img[(i >> 2) + 1, (i & 0x3) + 1] = palette[px + 1]
    end
    img
end

# -------------------------------
# Decompress entire DDS
function decode(file::String)::Matrix{RGBA{N0f8}}
    open(file, "r") do io
        magic = read(io, 4)
        magic != DDS_MAGIC && error("Not a DDS file")

        skip(io, 8)  # skip header size & flags
        h = read(io, UInt32) |> Int
        w = read(io, UInt32) |> Int
        skip(io, 20) # skip pitch, depth, mip-map count
        skip(io, 44) # skip pixel format until FourCC
        fourcc = read(io, 4)
        fourcc != b"DXT1" && error("Only DXT1 supported")

        skip(io, DDS_HEADER_SIZE - 88) # skip to pixel data
        blocks_x = w ÷ 4
        blocks_y = h ÷ 4
        img = Matrix{RGBA{N0f8}}(undef, h, w)

        for by in 1:blocks_y, bx in 1:blocks_x
            block = read(io, 8)
            pixels = decode_block(block)
            y0 = (by - 1) * 4 + 1
            x0 = (bx - 1) * 4 + 1
            img[y0:y0+3, x0:x0+3] .= pixels
        end
        img
    end
end


"""
is_valid_dds(path::String) -> Bool

Performs a structural validity check on a DDS file encoded in DXT1 format.

This function verifies that:
    1. The file exists and is at least 128 bytes (DDS header size).
    2. The file starts with the "DDS " magic number (offset 0).
    3. The width and height are read from the correct header position (offset 12).
    4. The expected number of 4×4 DXT1 blocks is computed from the image size.
    5. The actual file size matches the expected size:
    - Each block is 8 bytes.
    - Total size should be: 128 (header) + num_blocks × 8 bytes.

    This is especially useful to detect malformed or incomplete DDS files,
    such as those missing trailing blocks due to interrupted I/O or threading bugs.

    Arguments:
    ----------
    - path: Path to the `.dds` file to be validated.

    Returns:
    --------
    - `true` if the file is structurally valid and complete;
    - `false` if the file is missing, too small, has incorrect header,
        or if the block count and size do not match.

    Warnings:
    ---------
    - Logs helpful warnings on failure to assist debugging:
    - Missing file
    - Invalid header
    - Size mismatch (with expected vs actual size)
"""
function is_valid_dds(path::String)::Bool
    if !isfile(path)
        @warn "File does not exist: $path"
        return false
    end

    open(path, "r") do io
        if filesize(io) < 128
            @warn "File too small to be DDS: $path"
            return false
        end

        magic = read(io, 4)
        magic != b"DDS " && (@warn "Not a DDS file: $path"; return false)

        seek(io, 12)  # height at offset 12
        h = read(io, UInt32) |> Int
        w = read(io, UInt32) |> Int

        blocks = (w ÷ 4) * (h ÷ 4)
        expected_size = 128 + blocks * 8
        actual_size = filesize(io)

        if actual_size != expected_size
            @warn "DDS file size mismatch" file=path height=h width=w expected=expected_size actual=actual_size
            return false
        end
    end
    return true
end


# -------------------------------
# Entry point
function convert(input_dds::String, output_png::String, width::Int = 0)::bool
    if is_valid_dds(input_dds)
        img = decode(input_dds)
        if width > 0
            h = size(img, 1)
            w = size(img, 2)
            h_new = round(Int, h * width / w)
            img = imresize(img, (h_new, width))
        end
        FileIO.save(output_png, img)
        @info "Decompressed $input_dds → $output_png"
    else
        @warn "Error file decompressed $input_dds"
    end
end


"""
convert(path_dds, width=0) -> Vector{UInt8}

Return *PNG bytes* (no file) for the given DDS tile.
    If `width > 0` the image is resized while keeping aspect ratio.
"""
function convert(path_dds::String, width::Int = 0)
    img = decode(path_dds)
    w_nat = size(img, 2)            # larghezza originale
    h_nat = size(img, 1)
    if width > 0 && width < w_nat   # riduci solo se richiesto
        h = round(Int, h_nat * width / w_nat)
        img = imresize(img, (h, width))
    else
        width = w_nat               # usa nativa
    end
    io = IOBuffer()
    FileIO.save(Stream{format"PNG"}(io), img)
    take!(io)
end

end # module
