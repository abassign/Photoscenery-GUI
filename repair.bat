@echo off

:: =============================================================================
:: REPAIR JULIA LIBRARIES (for Julia version upgrade)
:: =============================================================================
:: This script removes Manifest.toml and reinstalls all packages to fix
:: compatibility issues that may occur when upgrading Julia to a new version.
:: =============================================================================

set /p confirm="This will remove Manifest.toml and reinstall all Julia packages. Continue? (y/n): "
if "%confirm%"=="y" (
    del Manifest.toml
    julia --project=. -e "using Pkg; Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()"
)

pause