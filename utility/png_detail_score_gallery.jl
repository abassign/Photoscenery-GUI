#!/usr/bin/env julia

# caso base (non ricorsivo), mostra fino a 200 miniature
# julia --project=. png_detail_score_gallery.jl /percorso/alle/png
#
# ricorsivo, miniature più grandi e ordinamento per edge density
# julia --project=. png_detail_score_gallery.jl /percorso/alle/png --recursive --thumb=320 --sort=edge
#
# più sensibile (stride 1, soglia gradiente 20), mostra top 400
# julia --project=. png_detail_score_gallery.jl /percorso/alle/png --stride=1 --gedge=20 --max=400
#
# scrivi l’output con un altro nome
# julia --project=. png_detail_score_gallery.jl /percorso/alle/png --out=risultati.html

############# Dipendenze di I/O (leggere) #############
import Pkg
try
    @eval using FileIO
catch
    @warn "FileIO non trovato: lo aggiungo all'ambiente attivo…"
    Pkg.add("FileIO")
    @eval using FileIO
end
try
    @eval using ImageIO
catch
    @warn "ImageIO non trovato: lo aggiungo all'ambiente attivo…"
    Pkg.add("ImageIO")
    @eval using ImageIO
end

using Printf, Base.Threads, Dates
using ColorTypes
using FixedPointNumbers

############# Luminanza e normalizzazione #############
@inline function luma_u8(c::RGB{T}) where {T<:Union{N0f8,Float32,Float64}}
    r = UInt16(round(UInt8, 255 * float(c.r)))
    g = UInt16(round(UInt8, 255 * float(c.g)))
    b = UInt16(round(UInt8, 255 * float(c.b)))
    return UInt8((77 * r + 150 * g + 29 * b) >>> 8) # ~Rec.601
end
@inline luma_u8(c::Gray{T}) where {T<:Union{N0f8,Float32,Float64}} = UInt8(round(UInt8, 255 * float(c.val)))
@inline luma_u8(u::UInt8) = u

function to_gray_u8(img)
    if img isa AbstractArray{<:Colorant}
        H, W = size(img, 1), size(img, 2)
        out = Array{UInt8}(undef, H, W)
        @inbounds for y in 1:H, x in 1:W
            out[y, x] = luma_u8(img[y, x])
        end
        return out
    elseif img isa Array{UInt8,3}
        H, W, C = size(img)
        out = Array{UInt8}(undef, H, W)
        @inbounds for y in 1:H, x in 1:W
            if C >= 3
                r = img[y, x, 1]
                g = img[y, x, 2]
                b = img[y, x, 3]
                out[y, x] = UInt8((UInt16(77) * r + UInt16(150) * g + UInt16(29) * b) >>> 8)
            elseif C == 1
                out[y, x] = img[y, x, 1]
            else
                r = img[y, x, 1]
                g = img[y, x, 2]
                b = img[y, x, 3]
                out[y, x] = UInt8((UInt16(77) * r + UInt16(150) * g + UInt16(29) * b) >>> 8)
            end
        end
        return out
    else
        error("Formato immagine non supportato: $(typeof(img))")
    end
end

############# Metriche: Sobel + Laplaciano #############
const SOBEL_GX = Int16[-1 0 1; -2 0 2; -1 0 1]
const SOBEL_GY = Int16[1 2 1; 0 0 0; -1 -2 -1]
const MAX_LAP = 1020.0 # bound teorico |N+S+E+W - 4C|

function edge_density_sobel(gray::Array{UInt8,2}; stride::Int=2, gedge::Int=25)
    H, W = size(gray)
    count = 0
    edges = 0
    @inbounds for y in 2:stride:(H-1), x in 2:stride:(W-1)
        gxx = gray[y-1, x-1] * SOBEL_GX[1, 1] + gray[y-1, x] * SOBEL_GX[1, 2] + gray[y-1, x+1] * SOBEL_GX[1, 3] +
              gray[y, x-1] * SOBEL_GX[2, 1] + 0 + gray[y, x+1] * SOBEL_GX[2, 3] +
              gray[y+1, x-1] * SOBEL_GX[3, 1] + gray[y+1, x] * SOBEL_GX[3, 2] + gray[y+1, x+1] * SOBEL_GX[3, 3]
        gyy = gray[y-1, x-1] * SOBEL_GY[1, 1] + gray[y-1, x] * SOBEL_GY[1, 2] + gray[y-1, x+1] * SOBEL_GY[1, 3] +
              0 + 0 + 0 +
              gray[y+1, x-1] * SOBEL_GY[3, 1] + gray[y+1, x] * SOBEL_GY[3, 2] + gray[y+1, x+1] * SOBEL_GY[3, 3]
        mag = abs(gxx) + abs(gyy)
        edges += (mag > gedge) ? 1 : 0
        count += 1
    end
    return count == 0 ? 0.0 : edges / count
end

function laplacian_variance(gray::Array{UInt8,2}; stride::Int=2)
    H, W = size(gray)
    μ = 0.0
    n = 0
    # primo passaggio per la media
    @inbounds for y in 2:stride:(H-1), x in 2:stride:(W-1)
        r = gray[y-1, x] + gray[y+1, x] + gray[y, x-1] + gray[y, x+1] - 4 * gray[y, x]
        μ += r
        n += 1
    end
    n == 0 && return 0.0
    μ /= n
    # secondo passaggio per la varianza (non corretta)
    s = 0.0
    @inbounds for y in 2:stride:(H-1), x in 2:stride:(W-1)
        r = gray[y-1, x] + gray[y+1, x] + gray[y, x-1] + gray[y, x+1] - 4 * gray[y, x]
        dv = r - μ
        s += dv * dv
    end
    return s / n
end

############# CLI #############
struct Options
    dir::String
    recursive::Bool
    stride::Int
    gedge::Int
    maxshow::Int
    thumb_w::Int
    sortkey::Symbol   # :score | :edge | :lap | :laplog | :name
    outpath::String
end

function parse_args(args::Vector{String})
    isempty(args) && begin
        println("Uso: julia png_detail_gallery.jl <DIR> [--recursive] [--stride=2] [--gedge=25] [--max=200] [--thumb=256] [--sort=score|edge|lap|laplog|name] [--out=gallery.html]")
        exit(1)
    end
    dir = args[1]
    recursive = false
    stride = 2
    gedge = 25
    maxshow = 200
    thumb_w = 256
    sortkey = :score
    outpath = "gallery.html"
    for a in args[2:end]
        if a == "--recursive"
            recursive = true
        elseif startswith(a, "--stride=")
            stride = parse(Int, split(a, "=", limit=2)[2])
        elseif startswith(a, "--gedge=")
            gedge = parse(Int, split(a, "=", limit=2)[2])
        elseif startswith(a, "--max=")
            maxshow = parse(Int, split(a, "=", limit=2)[2])
        elseif startswith(a, "--thumb=")
            thumb_w = parse(Int, split(a, "=", limit=2)[2])
        elseif startswith(a, "--sort=")
            sortkey = Symbol(split(a, "=", limit=2)[2])
        elseif startswith(a, "--out=")
            outpath = split(a, "=", limit=2)[2]
        else
            @warn "Argomento sconosciuto: $a"
        end
    end
    return Options(dir, recursive, stride, gedge, maxshow, thumb_w, sortkey, outpath)
end

function list_pngs(dir::String; recursive::Bool=false)
    isdir(dir) || error("Directory non trovata: $dir")
    files = String[]
    if recursive
        for (root, _, fns) in walkdir(dir)
            for fn in fns
                endswith(lowercase(fn), ".png") && push!(files, joinpath(root, fn))
            end
        end
    else
        for fn in readdir(dir; join=true)
            endswith(lowercase(fn), ".png") && isfile(fn) && push!(files, fn)
        end
    end
    return sort(files)
end

############# Main #############
function main()
    opts = parse_args(ARGS)
    files = list_pngs(opts.dir; recursive=opts.recursive)
    println("Trovati $(length(files)) file PNG. Threads: $(nthreads()). Avvio…")

    Results = NamedTuple{(:name, :edge, :lap, :laplog, :score)}
    results = Vector{Results}(undef, length(files))

    @threads for i in eachindex(files)
        f = files[i]
        ed = NaN
        lv = NaN
        lvlog = NaN
        sc = NaN
        try
            img = load(f)
            gray = to_gray_u8(img)
            ed = edge_density_sobel(gray; stride=opts.stride, gedge=opts.gedge)
            lv = laplacian_variance(gray; stride=opts.stride)
            lvlog = log1p(lv)                         # compressione
            sc = ed + 0.2 * lvlog                   # score robusto
        catch err
            @warn "Errore su $f: $err"
        end
        results[i] = (name=f, edge=ed, lap=lv, laplog=lvlog, score=sc)
    end

    # ordina
    byfun = r -> begin
        if opts.sortkey == :name
            lowercase(r.name)
        elseif opts.sortkey == :edge
            isfinite(r.edge) ? r.edge : -Inf
        elseif opts.sortkey == :lap
            isfinite(r.lap) ? r.lap : -Inf
        elseif opts.sortkey == :laplog
            isfinite(r.laplog) ? r.laplog : -Inf
        else
            isfinite(r.score) ? r.score : -Inf
        end
    end
    results = sort(results, by=byfun, rev=(opts.sortkey != :name))

    # limita numero mostrato
    shown = first(results, min(opts.maxshow, length(results)))

    # HTML semplice con miniature
    open(opts.outpath, "w") do io
        write(
            io,
            """
        <!doctype html>
        <html lang="it">
        <head>
        <meta charset="utf-8"/>
        <title>Photoscenery Detail Gallery</title>
        <style>
        body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;background:#0b0f14;color:#eaf0f6;margin:16px}
        .header{display:flex;align-items:center;gap:12px;margin-bottom:16px;flex-wrap:wrap}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px}
        .card{background:#121821;border:1px solid #1e2633;border-radius:14px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.25)}
        .thumb{width:100%;display:block;object-fit:cover}
        .meta{padding:10px 12px;font-size:14px;line-height:1.35}
        .meta b{font-size:15px}
        .badge{display:inline-block;padding:2px 8px;border-radius:999px;font-weight:600;font-size:12px;margin-left:6px}
        .low{background:#2b3a4d;color:#9fb6cd}
        .mid{background:#3d3a1a;color:#f0e68c}
        .high{background:#203a24;color:#9ff2a1}
        .small{color:#98a6b5;font-size:12px;margin-top:4px}
        .code{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,monospace}
        a{color:#9ad0ff;text-decoration:none}
        a:hover{text-decoration:underline}
        </style>
        </head>
        <body>
        <div class="header">
        <h1 style="margin:0;">Detail Gallery</h1>
        <div class="small">Dir: <span class="code">$(escapehtml(opts.dir))</span></div>
        <div class="small">Ordine: <span class="code">$(String(opts.sortkey))</span>, stride=$(opts.stride), gedge=$(opts.gedge), max=$(opts.maxshow)</div>
        <div class="small">Generato: $(Dates.format(now(), "yyyy-mm-dd HH:MM"))</div>
        </div>
        <div class="grid">
        """
        )
        for r in shown
            cls = if !isfinite(r.score)
                "low"
            elseif r.score < 0.8
                "low"
            elseif r.score < 1.6
                "mid"
            else
                "high"
            end
            # path assoluto → URL file://
            url = "file://" * replace(r.name, " " => "%20")
            @printf(io,
                """
                <div class="card">
                <a href="%s" target="_blank"><img class="thumb" src="%s" style="max-height:200px;"/></a>
                <div class="meta">
                <b title="%s">%s</b>
                <span class="badge %s">score=%.3f</span>
                <div class="small">edge=%.4f · lap=%.2f · lap_log=%.2f</div>
                <div class="small"><a href="%s" target="_blank">Apri originale</a></div>
                </div>
                </div>
                """,
                url, url, r.name, basename(r.name), cls, r.score, r.edge, r.lap, r.laplog, url)
        end
        write(
            io,
            """
        </div>
        </body>
        </html>
        """
        )
    end

    println("✅ Galleria scritta in: $(opts.outpath)")
    println("Apri il file con un browser.")
end

# util
basename(p::AbstractString) = splitdir(p)[2]
escapehtml(s::AbstractString) = replace(string(s),
    "<" => "&lt;", ">" => "&gt;", "&" => "&amp;", "\"" => "&quot;", "'" => "&#39;")

isinteractive() || main()

