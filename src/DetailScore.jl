module DetailScore

export detail_score_file, detail_score_png, detail_score_dds, montecarlo_detail_score

using FileIO, ImageIO      # dependencies declared globally in the project
using Random

# --- Filter Kernels (3x3) ---
const SOBEL_GX = Int16[-1 0 1; -2 0 2; -1 0 1]
const SOBEL_GY = Int16[ 1 2 1;  0 0 0; -1 -2 -1]

@inline function sobel_mag(getgray, x::Int, y::Int)
    gxx =  getgray(x-1,y-1)*SOBEL_GX[1,1] + getgray(x,y-1)*SOBEL_GX[1,2] + getgray(x+1,y-1)*SOBEL_GX[1,3] +
        getgray(x-1,y  )*SOBEL_GX[2,1] + 0                            + getgray(x+1,y  )*SOBEL_GX[2,3] +
            getgray(x-1,y+1)*SOBEL_GX[3,1] + getgray(x,y+1)*SOBEL_GX[3,2] + getgray(x+1,y+1)*SOBEL_GX[3,3]
        gyy =  getgray(x-1,y-1)*SOBEL_GY[1,1] + getgray(x,y-1)*SOBEL_GY[1,2] + getgray(x+1,y-1)*SOBEL_GY[1,3] +
            0 + 0 + 0 +
                getgray(x-1,y+1)*SOBEL_GY[3,1] + getgray(x,y+1)*SOBEL_GY[3,2] + getgray(x+1,y+1)*SOBEL_GY[3,3]
            return abs(gxx) + abs(gyy)
end

@inline laplacian3(getgray, x::Int, y::Int) =
    getgray(x,y-1) + getgray(x,y+1) + getgray(x-1,y) + getgray(x+1,y) - 4*getgray(x,y)

# --- PNG Utils ---
@inline _rgb_to_gray_u8(r::UInt8, g::UInt8, b::UInt8)::Int16 =
    Int16((UInt16(77)*r + UInt16(150)*g + UInt16(29)*b) >>> 8)

function _png_getter(path::AbstractString)
    img = FileIO.load(path)  # Colorant array or Array{UInt8,3}
    if img isa Array{UInt8,3}
        H, W, C = size(img)
        getgray = function (x::Int, y::Int)
            @inbounds begin
                if C >= 3
                    r = img[y,x,1]; g = img[y,x,2]; b = img[y,x,3]
                    return _rgb_to_gray_u8(r,g,b)
                else
                    return Int16(img[y,x,1])
                end
            end
        end
        return (H, W, getgray)
    else
        H, W = size(img,1), size(img,2)
        getgray = function (x::Int, y::Int)
            @inbounds begin
                c = img[y,x]
                r = hasproperty(c,:r) ? c.r : c.val
                g = hasproperty(c,:g) ? c.g : c.val
                b = hasproperty(c,:b) ? c.b : c.val
                return _rgb_to_gray_u8(
                    UInt8(round(UInt8, 255*float(r))),
                    UInt8(round(UInt8, 255*float(g))),
                    UInt8(round(UInt8, 255*float(b))),
                    )
            end
        end
        return (H, W, getgray)
    end
end

# --- DDS DXT1 Utils (point decoding) ---
struct _DDSDXT1Ctx
    W::Int
    H::Int
    data::Vector{UInt8}  # after header (128B)
end

@inline function _rgb565_to_rgb888(c::UInt16)
    r = UInt8(((c >>> 11) & 0x1f) * 255 ÷ 31)
    g = UInt8(((c >>> 5)  & 0x3f) * 255 ÷ 63)
    b = UInt8(( c         & 0x1f) * 255 ÷ 31)
    return r,g,b
end

function _dds_dxt1_getter(path::AbstractString)
    io = open(path, "r")
    hdr = read(io, 128)
    (hdr[1]==0x44 && hdr[2]==0x44 && hdr[3]==0x53 && hdr[4]==0x20) || (close(io); error("Incorrect DDS magic"))
    H = reinterpret(UInt32, hdr[13:16])[1] |> Int
    W = reinterpret(UInt32, hdr[17:20])[1] |> Int
    fourCC = String(Char.(hdr[85:88]))
    fourCC == "DXT1" || (close(io); error("DDS not DXT1 ($fourCC)"))
    data = read(io); close(io)
    ctx = _DDSDXT1Ctx(W,H,data)

    getgray = function (x::Int, y::Int)
        x = clamp(x, 1, ctx.W); y = clamp(y, 1, ctx.H)
        bx = (x-1) >>> 2;  by = (y-1) >>> 2
        blocks_x = (ctx.W + 3) >>> 2
        off = (by*blocks_x + bx)*8 + 1
        color0 = reinterpret(UInt16, ctx.data[off:off+1])[1]
        color1 = reinterpret(UInt16, ctx.data[off+2:off+3])[1]
        idxs   = reinterpret(UInt32, ctx.data[off+4:off+7])[1]
        r0,g0,b0 = _rgb565_to_rgb888(color0)
        r1,g1,b1 = _rgb565_to_rgb888(color1)
        p = if color0 > color1
            ((r0,g0,b0),
             (r1,g1,b1),
             (UInt8((2*Int(r0)+Int(r1))÷3), UInt8((2*Int(g0)+Int(g1))÷3), UInt8((2*Int(b0)+Int(b1))÷3)),
             (UInt8((Int(r0)+2*Int(r1))÷3), UInt8((Int(g0)+2*Int(g1))÷3), UInt8((Int(b0)+2*Int(b1))÷3)))
        else
            ((r0,g0,b0),
             (r1,g1,b1),
             (UInt8((Int(r0)+Int(r1))>>>1), UInt8((Int(g0)+Int(g1))>>>1), UInt8((Int(b0)+Int(b1))>>>1)),
             (UInt8(0),UInt8(0),UInt8(0)))
        end
        lx = (x-1) & 0x3; ly = (y-1) & 0x3
        sel = UInt32((idxs >>> (2*(ly*4 + lx))) & 0x3)
        r,g,b = p[Int(sel)+1]
        return Int16((UInt16(77)*r + UInt16(150)*g + UInt16(29)*b) >>> 8)
    end
    return (H, W, getgray)
end

# --- Adaptive Monte Carlo ---
"""
montecarlo_detail_score(H, W, getgray; max_samples=3000, min_samples=200,
batch=100, gedge=25, tol_rel=0.05, seed::Integer=0)

Returns (score, edge_density, lap_log, samples, H, W).
score = edge_density + 0.2 * log1p(var(Laplacian)).
Early stop when score stabilizes or exceeds 1 with margin.
"""
function montecarlo_detail_score(H::Int, W::Int, getgray;
                                 max_samples::Int=3000, min_samples::Int=200, batch::Int=100,
                                 gedge::Int=25, tol_rel::Float64=0.05, seed::Integer=0)

    rng = seed == 0 ? Random.default_rng() : MersenneTwister(seed)

    samples = 0
    edge_hits = 0
    mean_lap = 0.0; M2 = 0.0
    last_score = -1.0; stable_hits = 0; over1_hits = 0

    xmin, xmax = 2, W-1; ymin, ymax = 2, H-1
    (xmin > xmax || ymin > ymax) && return (score=0.0, edge_density=0.0, lap_log=0.0, samples=0, H=H, W=W)

    while samples < max_samples
        for _ in 1:batch
            x = xmin + rand(rng, 0:(xmax-xmin))
            y = ymin + rand(rng, 0:(ymax-ymin))
            mag = sobel_mag(getgray, x, y)
            edge_hits += (mag > gedge) ? 1 : 0
            l = laplacian3(getgray, x, y) |> float
            samples += 1
            δ = l - mean_lap
            mean_lap += δ / samples
            M2 += δ * (l - mean_lap)
        end

        ed = edge_hits / samples
        lap_var = samples > 1 ? (M2 / samples) : 0.0
        lap_log = log1p(lap_var)
        score = ed + 0.2 * lap_log

        if last_score >= 0
            rel = abs(score - last_score) / max(1e-6, abs(last_score))
            stable_hits = (rel < tol_rel) ? (stable_hits + 1) : 0
        end
        last_score = score
        if score > 1.05
            over1_hits += 1
        else
            over1_hits = 0
        end

        if samples >= min_samples && (stable_hits >= 2 || over1_hits >= 2)
            break
        end
    end

    ed = edge_hits / max(1, samples)
    lap_var = samples > 1 ? (M2 / samples) : 0.0
    lap_log = log1p(lap_var)
    score = ed + 0.2 * lap_log
    return (score=score, edge_density=ed, lap_log=lap_log, samples=samples, H=H, W=W)
end

# --- File Entry Points ---
function detail_score_png(path::AbstractString; kwargs...)
    H,W,getgray = _png_getter(path)
    return montecarlo_detail_score(H,W,getgray; kwargs...)
end

function detail_score_dds(path::AbstractString; kwargs...)
    H,W,getgray = _dds_dxt1_getter(path)
    return montecarlo_detail_score(H,W,getgray; kwargs...)
end

"""
detail_score_file(path; kwargs...)
Auto-detect: .png → PNG, .dds → DDS DXT1
"""
function detail_score_file(path::AbstractString; kwargs...)
    lp = lowercase(path)
    if endswith(lp, ".png")
        return detail_score_png(path; kwargs...)
        elseif endswith(lp, ".dds")
        return detail_score_dds(path; kwargs...)
    else
        error("Unsupported format (expected .png or .dds): $path")
    end
end

end # module
