# Photoscenery-GUI (Julia)

A modern web GUI to download and assemble orthophotos (photoscenery) from external map servers for use in FlightGear.  
This version adds an interactive interface, parallel chunk downloading, an assembly monitor, and a PNG↔DDS converter written entirely in Julia.

## ✨ Key Features

- **Web GUI**:  
  Interactive map (select by ICAO/city or by clicking the map), radius in NM, resolution 0–6, distance-based downsampling (`--sdwn`) with pre-coverage option, tile preview, date filter, queue management, overlay opacity, and FGFS connection status.

- **Batch/CLI Compatibility**:  
  The GUI accepts the same options as the console version.  

- **Multi-threaded Downloading**:  
  Parallel chunk downloading and automatic assembly into complete tiles.  

- **DDS Management**:  
  Imports existing DDS files without re-downloading.  
  High-performance `png2ddsDXT1` / `dds2pngDXT1` conversions.  

- **FlightGear Integration**:  
  Download around the aircraft in flight via FGFS telnet; output path ready as a Scenery source.  

- **Performance**:  
  Faster directory scanning and chunk verification to prevent black or artifact-filled tiles.  

## 📦 Requirements

- Julia **≥ 1.11.x** (a project environment is provided)  
- System: Linux, Windows, macOS  
- Main Julia Packages:  
  `ArgParse, HTTP, JSON3, LightXML, Downloads, Images, ImageIO, FileIO, PNGFiles, Dates, Logging, FilePathsBase, Colors, Printf`

## ⚙️ Installation

```bash
# Clone or download the repository
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## 🚀 Quick Start

To launch the web interface, run from the project root:

```bash
julia --project=. -e 'using Photoscenery; Photoscenery.GuiMode.run(["--http"])'
```

If you want to specify one of the four map servers, you can select it using the --map n command.
This command can assume the following values: 1, 2, 3, or 4.
For example, the US is --map 2.

```bash
julia --project=. -e 'using Photoscenery; Photoscenery.GuiMode.run(["--http", "--map=2"])'
```

Then open your browser at:  
👉 [http://127.0.0.1:8000/](http://127.0.0.1:8000/)

**Tips**:  
- Use **Firefox** for faster map rendering.  
- Set `--path` to your FlightGear Scenery folder (or let the program find it automatically).  

## 🖥️ GUI Workflow

1. **Location**: Enter ICAO (e.g., `LIME`) or click crosshair to select on map.  
2. **Radius & Resolution**: Set Radius (nm) and Resolution (0–6).  
3. **Distance Reduction**: Choose `--sdwn` level (0 = none, 1–4 = lighter previews). Enable *Pre-coverage* for approach coverage.  
4. **Overwrite**:  
   - `--over 0` = never  
   - `--over 1` = only if higher resolution  
   - `--over 2` = always  
5. **Launch**: Create area (orange circle), then Confirm (✓) to add to queue.  
6. **FlightGear**: Set telnet port (e.g., `5000`) and connect to follow aircraft.  

## 🔑 Main CLI Options

| Option | Description |
|--------|-------------|
| `--size s` | Max resolution: 0→512 … 6→32768 px |
| `--radius r` | Radius in NM |
| `--over n` | Overwrite: 0 never, 1 only if better, 2 always |
| `--sdwn n` | Distance-based downsampling |
| `--map n` | ID of map server |
| `--icao CODE` | Resolves LAT/LON from airport code |
| `--route file.xml` | Downloads along a route/waypoint |
| `--connect host:port` | Connect FGFS telnet |
| `--path PATH` | Output directory (Scenery) |
| `--save PATH` | Archive removed files |
| `--png` | Save as PNG (otherwise DDS) |
| `--lat --lon` | Area center (decimal degrees) |
| `--latll --lonll --latur --lonur` | Explicit bounding box |
| `--tile n` | Work on a specific tile |
| `--attempts n` | Retry attempts per chunk |
| `--timeout s` | Timeout per chunk |
| `--logger n` | Logging: 0 console, 1 file+console, 2 file only |
| `--debug n` | Debug level |
| `--http[=port]` | Start local web server (default 8000) |

👉 For the complete list, see the **project wiki**.

## 🏗️ Architecture & Modules

- **Photoscenery (root)**: Bootstrapping, logging, CLI parsing (AppConfig), launching GUI/Batch.  
- **AppConfig**: Params handling (`params.xml`), options & presets parsing.  
- **Commons**: Shared types/utilities (e.g., `MapCoordinates`, `ChunkJob`).  
- **GeoEngine**: Orchestration (tile calculation, jobs, paths).  
- **Downloader**: Job queue, parallel downloading, validation.  
- **AssemblyMonitor**: Detects complete groups and assembles tiles.  
- **TileProcessor**: Mosaics chunks → final image, PNG→DDS conversion.  
- **GuiMode**: Local HTTP server, REST API, session/queue state, previews.  
- **png2ddsDXT1 / dds2pngDXT1**: Pure Julia codecs.  

**Pipeline:**  
Area → Tile List → Chunk Subdivision → Parallel Download → Monitor → Assembly → (Conversion) → Placement in Scenery Folder

## ✈️ FlightGear Integration

1. Launch FG with telnet enabled: `--telnet=5000`  
2. In the GUI, set the port and connect.  
3. Set `--path` to your Downloads/TerraSync/Orthophotos folder (or equivalent).  
4. In FlightGear 2020.3.x, enable *Satellite Photoscenery* in rendering options.  

## 💡 Practical Tips

- **sdwn+pre-coverage Strategy**: Cover large areas in low resolution for context, then download high resolution near your route/destination.  
- **Overwrite 1** is a good default: improves scenery without redoing everything.  
- **Connection**: For large areas, use a stable, high-bandwidth network.  
- **Performance**: Set Julia threads with `julia -t auto`.  

## 📂 Directory Structure (Output)

```
photoscenery/
├── Orthophotos/
│   └── e000n00/ ...  # Final .dds tiles (or .png if requested)
└── Orthophotos-saved/
    └── tmp/          # .png chunks awaiting assembly
```

## 🛣️ Roadmap (Short-Term)

- Improvements to ICAO input and multi-circle/route selection.  
- Full feature parity with all batch mode options.  
- UI and internal state refinements.  

## 📜 License

GPL-2.0. See the LICENSE file in the repository.

## 🙌 Credits

- Original project and community documentation on the FlightGear Wiki.  
- Contributors and testers from the FlightGear community.  
