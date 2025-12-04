# This script is executed when the package is built (e.g., after Pkg.add)

using Dates

function install_launchers()
    # 1. Identify source files in the package directory
    #    build.jl runs in <Package>/deps/
    package_root = joinpath(@__DIR__, "..")

    files_to_copy = ["go.jl", "go.bat", "go.sh", "params.xml"]

    # 2. Define target directory
    #    We use a visible folder in the user's home directory to avoid writing to random places
    target_dir = joinpath(homedir(), "Photoscenery_Start")

    if !isdir(target_dir)
        mkpath(target_dir)
    end

    println("----------------------------------------------------------------")
    println("  Photoscenery Post-Install Setup")
    println("----------------------------------------------------------------")
    println("  Copying launcher scripts to: $target_dir")

    for filename in files_to_copy
        src_path = joinpath(package_root, filename)
        dst_path = joinpath(target_dir, filename)

        if isfile(src_path)
            # Read and write to ensure permissions are handled (simple copy)
            cp(src_path, dst_path; force=true)
            println("  [OK] Copied $filename")

            # Make shell scripts executable
            if endswith(filename, ".sh")
                try
                    chmod(dst_path, 0o755)
                    println("  [OK] Made $filename executable")
                catch e
                    println("  [WARN] Could not set executable permission on $filename: $e")
                end
            end
        else
            println("  [WARN] Source file not found: $src_path")
        end
    end

    println("----------------------------------------------------------------")
    println("  Installation Complete!")
    println("  To start the application, go to $target_dir and run:")
    println("    ./go.sh  (Linux/Mac)")
    println("    go.bat   (Windows)")
    println("----------------------------------------------------------------")
end

try
    install_launchers()
catch e
    println("Error during post-install setup: $e")
    # Do not fail the build, just log the error
end
