$ErrorActionPreference = 'Stop'

# Purpose:
# The full package check: rebuilds the archive and unpacks it, so
# PackageTests/unpacked always reflects the current project state.
# Run from the repo root with .\PackageTests\refresh.ps1

$scriptRoot = $PSScriptRoot

& (Join-Path $scriptRoot 'build.ps1')
& (Join-Path $scriptRoot 'unpack.ps1')
