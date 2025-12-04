using Pkg
using Dates

# Function to check for updates
function check_for_updates()
    try
        println("Checking for updates...")
        # Fetch latest changes from remote without merging
        run(`git fetch`)

        # Check if we are behind
        # git status -uno checks status ignoring untracked files
        status_output = read(`git status -uno`, String)

        if occursin("Your branch is behind", status_output)
            println("\nUpdate available!")
            print("Do you want to update now? (y/n): ")
            answer = readline()

            if lowercase(strip(answer)) == "y"
                println("Updating...")
                run(`git pull`)
                println("Update complete. Restarting recommended if core files changed.")
                println("Continuing launch...")
            else
                println("Skipping update.")
            end
        else
            println("Application is up to date.")
        end
    catch e
        println("Warning: Could not check for updates (Git might not be installed or configured).")
        println("Error: ", e)
    end
end

# Run update check
check_for_updates()

# Activate project environment
println("\nStarting Photoscenery...")

if isdir("src") && isfile("src/Photoscenary.jl")
    println("Local source detected. Activating local environment...")
    Pkg.activate(".")
    # Load the application from source
    include("src/Photoscenary.jl")
    using .Photoscenary
else
    println("Local source not found. Attempting to load installed package...")
    # Assume Photoscenary is installed in the active environment
    using Photoscenary
end

# Launch the GUI
Photoscenary.GuiMode.run()
