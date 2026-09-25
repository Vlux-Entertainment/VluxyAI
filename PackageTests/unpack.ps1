$ErrorActionPreference = 'Stop'

# Purpose:
# Extracts the most recently built archive into a clean PackageTests/unpacked
# folder, so the layout a consumer receives can be inspected. The previous
# extraction is deleted first so stale files cannot mislead.
# Run from the repo root with .\PackageTests\unpack.ps1

$archivePath = Join-Path $PSScriptRoot 'vluxyai.tar.gz'
$unpackPath = Join-Path $PSScriptRoot 'unpacked'

if (-not (Test-Path $archivePath)) {
    throw "Package archive not found at $archivePath. Run build.ps1 first."
}

if (Test-Path $unpackPath) {
    Remove-Item $unpackPath -Recurse -Force
}

New-Item -ItemType Directory -Path $unpackPath -Force | Out-Null
tar -xf $archivePath -C $unpackPath
