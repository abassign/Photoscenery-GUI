using Pkg
using Dates

# Activate project environment
println("\nStarting Photoscenery...")

if isdir("src") && isfile("src/Photoscenery.jl")
    # Local development mode
    using Pkg
    Pkg.activate(".")
    include("src/Photoscenery.jl")
    using .Photoscenery
else
    # Package installation mode
    # Assume Photoscenery is installed in the active environment
    using Photoscenery
end

# Launch the GUI
Photoscenery.GuiMode.run()
