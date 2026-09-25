$ErrorActionPreference = 'Stop'

# Purpose:
# The pre-commit check, in one command: formatting, lint, the Lune test suite
# and the Luau type check of lib/ and examples/. Exits non-zero on the first
# failure so it can gate CI. Pass -Fix to let StyLua rewrite files in place.
# Run from the repo root with .\Commands\Verify.ps1

param(
    [switch]$Fix
)

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$globalTypes = Join-Path $workspaceRoot '.luau-analyze\globalTypes.d.luau'
$globalTypesUrl = 'https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau'

function Step($name, $script) {
    Write-Host "== $name" -ForegroundColor Cyan
    & $script
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $name" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

Push-Location $workspaceRoot
try {
    if ($Fix) {
        Step 'stylua' { stylua lib examples tests }
    } else {
        Step 'stylua --check' { stylua --check lib examples tests }
    }

    Step 'selene' { selene lib examples tests }

    Step 'lune tests' { lune run tests/runner }

    if (-not (Test-Path $globalTypes)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $globalTypes) | Out-Null
        Invoke-WebRequest -Uri $globalTypesUrl -OutFile $globalTypes
    }

    Step 'rojo sourcemap' { rojo sourcemap test-place.project.json --output sourcemap.json }

    Step 'luau-lsp analyze' {
        luau-lsp analyze `
            --sourcemap=sourcemap.json `
            --defs=$globalTypes `
            --platform=roblox `
            --ignore='**/_Index/**' `
            --ignore='Packages/**' `
            lib examples
    }

    Write-Host 'All checks passed.' -ForegroundColor Green
}
finally {
    Pop-Location
}
