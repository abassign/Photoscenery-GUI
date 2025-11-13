"""
# png2ddsDXT1 Module

High-performance PNG to DDS (DXT1 format) converter with:
- Multithreaded block compression
- Optimized RGB565 color space conversion
- Proper DDS header generation
- Performance metrics

Key Features:
- Two conversion interfaces (file path and direct image matrix)
- Automatic image padding to 4×4 block boundaries
- Detailed performance logging
- Thread-safe implementation

Dependencies:
- FileIO/ImageIO: Image loading
- Colors: Color space handling
- Base.Threads: Parallel processing
- FixedPointNumbers: Efficient color representation
"""

module png2ddsDXT1

using FileIO, ImageIO, Colors, Dates, Base.Threads, FixedPointNumbers

export convert


# -------------------------------
# Configuration
const debugLevel = 1  # Logging verbosity (0 = silent)

# -------------------------------
# Utility Functions

"""
time_conversion(f) -> (result, duration)

Times the execution of function f and returns both result and duration.
    Used for performance measurement.
"""
time_conversion(f) = (start = now(); res = f(); (res, now() - start))

# -------------------------------
# RGB565 Color Space Conversion (inlined for performance)

@inline rgba_to_rgb565(c::RGBA{N0f8}) =
    (round(UInt16, red(c) * 31) << 11) |
        (round(UInt16, green(c) * 63) << 5)  |
            round(UInt16, blue(c) * 31)

@inline dist565(a::UInt16, b::UInt16) = abs(Int(a) - Int(b))

@inline function distant_pair(c::NTuple{16,UInt16})
    best = (c[1], c[2], dist565(c[1], c[2]))
    @inbounds for i in 1:15, j in i+1:16
        d = dist565(c[i], c[j])
        d > best[3] && (best = (c[i], c[j], d))
    end
    best[1], best[2]
end

@inline function palette(c0::UInt16, c1::UInt16)
    r0 = (c0 >> 11) & 0x1f; g0 = (c0 >> 5) & 0x3f; b0 = c0 & 0x1f
    r1 = (c1 >> 11) & 0x1f; g1 = (c1 >> 5) & 0x3f; b1 = c1 & 0x1f
    c2 = UInt16((((r0 * 2 + r1) ÷ 3) << 11) | (((g0 * 2 + g1) ÷ 3) << 5) | ((b0 * 2 + b1) ÷ 3))
    c3 = UInt16((((r0 + r1 * 2) ÷ 3) << 11) | (((g0 + g1 * 2) ÷ 3) << 5) | ((b0 + b1 * 2) ÷ 3))
    (c0, c1, c2, c3)
end

@inline best_index(c::UInt16, pal::NTuple{4,UInt16}) =
let d = ntuple(i -> dist565(c, pal[i]), 4)
    argmin(d) - 1
end

@inline function pack(c0::UInt16, c1::UInt16, idx::UInt32)
    (UInt8(c0 & 0xff), UInt8(c0 >> 8),
        UInt8(c1 & 0xff), UInt8(c1 >> 8),
        UInt8(idx & 0xff), UInt8((idx >> 8) & 0xff),
        UInt8((idx >> 16) & 0xff), UInt8((idx >> 24) & 0xff))
end

# -------------------------------
# Core Compression Functions

"""
compress_block(pixels::NTuple{16,RGBA{N0f8}}) -> NTuple{8,UInt8}

Compresses a 4×4 pixel block into DXT1 format (8 bytes).
Uses RGB565 color space and selects optimal palette.
"""
function compress_block(pixels::NTuple{16,RGBA{N0f8}})
    colors565 = ntuple(i -> rgba_to_rgb565(pixels[i]), Val(16))
    c0, c1 = distant_pair(colors565)
    c0, c1 = c0 ≥ c1 ? (c0, c1) : (c1, c0)  # Ensure c0 >= c1 per DXT1 spec
    pal = palette(c0, c1)

    idx = UInt32(0)
    @inbounds for i in 0:15
        idx |= UInt32(best_index(colors565[i+1], pal)) << (2i)
    end
    return pack(c0, c1, idx)
end

"""
compress_image_blocks(padded_img::Matrix{RGBA{N0f8}}, padded_w::Int, padded_h::Int, num_threads::Int) -> Vector{UInt8}

Compresses a padded RGBA image into DXT1 format using multi-threaded processing.

The image is divided into 4×4 blocks, and each block is compressed independently
using the `compress_block` function. The compressed output is a vector of bytes
    containing all DXT1 blocks, suitable for writing to a .dds file after the header.

    Key Features:
    -------------
    - Fully thread-safe and parallelized: all threads write to independent buffers
    - Accurate work division: ensures all blocks are processed exactly once, regardless of thread count
    - Supports any image size (as long as padded to multiples of 4)
    - No block duplication or loss, even when the number of blocks is not divisible by the number of threads

    Threading Strategy:
    -------------------
    We compute the total number of 4×4 blocks as (width / 4) × (height / 4).
    Then we divide this range evenly among `num_threads`, using a rounded linear partition
    (via `range(..., length = num_threads + 1)`), ensuring every block is processed once.

    Each thread receives a distinct range of block indices, compresses its share,
    and returns a buffer of compressed 8-byte DXT1 blocks.

    Finally, all thread results are concatenated into a single vector using `reduce(vcat, ...)`.

    Arguments:
    ----------
    - padded_img: The RGBA image (already padded to multiple of 4)
    - padded_w: Width of the padded image
    - padded_h: Height of the padded image
    - num_threads: Number of parallel threads to use

    Returns:
    --------
    - A single `Vector{UInt8}` containing the compressed DXT1 blocks in raster order.
"""
function compress_image_blocks(padded_img, padded_w, padded_h, num_threads::Int)
    blocks_x = padded_w ÷ 4
    blocks_y = padded_h ÷ 4
    total_blocks = blocks_x * blocks_y

    # Calcola start/stop per ogni thread in modo da coprire tutto
    splits = round.(Int, range(0, stop=total_blocks, length=num_threads+1))

    tasks = Vector{Task}(undef, num_threads)

    for t in 1:num_threads
        start_b = splits[t] + 1
        stop_b = splits[t+1]
        tasks[t] = Threads.@spawn begin
            out = Vector{UInt8}(undef, (stop_b - start_b + 1) * 8)
            pos = 1
            for b in start_b:stop_b
                y = 4 * ((b - 1) ÷ blocks_x) + 1
                x = 4 * ((b - 1) % blocks_x) + 1
                pixels = ntuple(i -> padded_img[y + ((i-1) >> 2), x + ((i-1) & 3)], Val(16))
                for byte in compress_block(pixels)
                    out[pos] = byte
                    pos += 1
                end
            end
            out
        end
    end

    return reduce(vcat, fetch.(tasks))
end

# -------------------------------
# DDS File Handling

"""
create_dds_header(w::UInt32, h::UInt32, mipmaps::UInt32 = UInt32(1)) -> Vector{UInt8}

Generates a 128-byte DDS file header with:
- Correct magic numbers
- Proper dimension and format flags
- DXT1 compression marker
"""
function create_dds_header(w::UInt32, h::UInt32, mipmaps::UInt32 = UInt32(1))
    header = zeros(UInt8, 128)

    # Magic number (DDS )
    header[1:4] = [0x44, 0x44, 0x53, 0x20]  # "DDS "

    # Header size (124 bytes)
    header[5:8] = [0x7C, 0x00, 0x00, 0x00]

    # Flags
    flags = 0x00001007  # DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT
    flags |= 0x00080000 # DDSD_LINEARSIZE
    header[9:12] = [
        (flags >> 0) & 0xFF,
        (flags >> 8) & 0xFF,
        (flags >> 16) & 0xFF,
        (flags >> 24) & 0xFF
        ]

    # Height
    header[13:16] = [
        (h >> 0) & 0xFF,
        (h >> 8) & 0xFF,
        (h >> 16) & 0xFF,
        (h >> 24) & 0xFF
        ]

    # Width
    header[17:20] = [
        (w >> 0) & 0xFF,
        (w >> 8) & 0xFF,
        (w >> 16) & 0xFF,
        (w >> 24) & 0xFF
        ]

    # Pitch/Linear size
    pitch = (w * h) ÷ 2  # For DXT1 compressed texture
    header[21:24] = [
        (pitch >> 0) & 0xFF,
        (pitch >> 8) & 0xFF,
        (pitch >> 16) & 0xFF,
        (pitch >> 24) & 0xFF
        ]

    # Pixel format (32 bytes)
    header[77:80] = [0x20, 0x00, 0x00, 0x00]  # dwSize
    header[81:84] = [0x04, 0x00, 0x00, 0x00]  # dwFlags = DDPF_FOURCC
    header[85:88] = [0x44, 0x58, 0x54, 0x31]  # dwFourCC = "DXT1"

    # Caps
    header[109:112] = [0x00, 0x10, 0x00, 0x00]  # DDSCAPS_TEXTURE

    return header
end

# -------------------------------
# Write DDS file (MOVED BEFORE CONVERT FUNCTIONS)
function write_dds(file::String, img, num_threads::Int)
    h, w = size(img)
    padded_h = (h + 3) & ~3
    padded_w = (w + 3) & ~3

    # Creiamo un'immagine di background bianco opaco
    padded_img = fill(RGBA{N0f8}(1,1,1,1), padded_h, padded_w)

    # Copiamo l'immagine originale sul background
    padded_img[1:h, 1:w] .= img

    header = create_dds_header(UInt32(w), UInt32(h), UInt32(1))
    blocks = compress_image_blocks(padded_img, padded_w, padded_h, num_threads)

    open(file, "w") do io
        write(io, header)
        write(io, blocks)
    end
    debugLevel > 0 && println("Saved: $file")
end

# -------------------------------
# Aggiungi questa funzione di conversione sicura
function ensure_rgba_format(img::Matrix{<:Colorant})
    # Crea una nuova matrice con tipo garantito
    h, w = size(img)
    new_img = Matrix{RGBA{N0f8}}(undef, h, w)

    for y in 1:h, x in 1:w
        c = img[y, x]
        # Converti esplicitamente in RGBA{N0f8}
        new_img[y, x] = RGBA{N0f8}(red(c), green(c), blue(c), alpha(c))
    end
    return new_img
end

# -------------------------------
# Public Interface

"""
convert(input_png::String, output_dds::String, num_threads::Int=1)

Main conversion function for file paths.
    - input_png: Source PNG file path
    - output_dds: Destination DDS file path
    - num_threads: Maximum threads to use (capped at 3 for legacy reasons)
"""
function convert(input_png::String, output_dds::String, num_threads::Int=1)
    img = FileIO.load(input_png)
    h, w = size(img)
    megapixels = (h * w) / 1_000_000.0

    num_threads = min(num_threads, 3)   # Legacy thread cap
    result, elapsed = time_conversion(() -> write_dds(output_dds, img, num_threads))
    elapsed_sec = elapsed.value / 1000.0
    debugLevel > 0 && println("Total time: $(round(elapsed_sec, digits=3)) s")
    debugLevel > 0 && println("MP/s: $(round(megapixels / elapsed_sec, digits=2))")
    return result
end

"""
convert(img::Matrix{ColorTypes.RGBA{N0f8}}, output_dds::String, num_threads::Int=1)

Direct image matrix conversion interface.
- img: RGBA image matrix
- output_dds: Destination DDS file path
- num_threads: Maximum threads to use
"""
function convert(img::Matrix{<:Colorant}, output_dds::String, num_threads::Int=1)
    # Converti in formato garantito
    img_conv = ensure_rgba_format(img)
    h, w = size(img_conv)
    megapixels = (h * w) / 1_000_000.0
    num_threads = min(num_threads, 3)
    result, elapsed = time_conversion(() -> write_dds(output_dds, img_conv, num_threads))
    # @info "is_valid_dds: $(is_valid_dds(output_dds))"
    elapsed_sec = elapsed.value / 1000.0
    debugLevel > 0 && println("Total time: $(round(elapsed_sec, digits=3)) s")
    debugLevel > 0 && println("MP/s: $(round(megapixels / elapsed_sec, digits=2))")
    return result
end


end # module
