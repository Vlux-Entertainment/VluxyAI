$ErrorActionPreference = 'Stop'

# Purpose:
# Prints the exact file list Wally would include if the package were published
# right now, so the include/exclude rules in wally.toml can be checked without
# building. The fastest check before a publish.
# Run from the repo root with .\PackageTests\list.ps1

$workspaceRoot = Split-Path -Parent $PSScriptRoot
# Wally requires an output path even with --list.
$archivePath = Join-Path $PSScriptRoot 'vluxyai.tar.gz'

Push-Location $workspaceRoot
try {
    wally package --list --output $archivePath
}
finally {
    Pop-Location
}
