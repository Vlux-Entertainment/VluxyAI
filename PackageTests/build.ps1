$ErrorActionPreference = 'Stop'

# Purpose:
# Creates the packaged Wally archive for the current project state: the same
# tar.gz payload `wally publish` would upload, so it can be inspected or handed
# to another script. Builds only; unpack.ps1 extracts it.
# Run from the repo root with .\PackageTests\build.ps1

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$archivePath = Join-Path $PSScriptRoot 'vluxyai.tar.gz'

Push-Location $workspaceRoot
try {
    wally package --output $archivePath
}
finally {
    Pop-Location
}
