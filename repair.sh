#!/bin/bash

# =============================================================================
# REPAIR JULIA LIBRARIES (for Julia version upgrade)
# =============================================================================
# This script removes Manifest.toml and reinstalls all packages to fix
# compatibility issues that may occur when upgrading Julia to a new version.
# =============================================================================

read -p "This will remove Manifest.toml and reinstall all Julia packages. Continue? (y/n): " confirm
if [ "$confirm" = "y" ]; then
    # Ensure the Julia General registry is installed (needed on fresh systems)
    echo "Checking Julia registry..."
    julia -e 'import Pkg; Pkg.Registry.add("General")' 2>/dev/null || true

    rm -f Manifest.toml
    julia --project=. -e 'using Pkg; Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()'
fi