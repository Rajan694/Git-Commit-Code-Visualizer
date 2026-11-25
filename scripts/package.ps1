<#
.SYNOPSIS
Builds the extension and packages it as releases/<name>-<version>.vsix.

.DESCRIPTION
The version comes from package.json; this script never changes it.
"vsce package" runs the vscode:prepublish script first: type-check, lint, production bundle.

.PARAMETER PreRelease
Mark the package as a pre-release (VS Code Marketplace / Open VSX).

.PARAMETER Install
Run "npm ci" first, even if node_modules already exists.

.EXAMPLE
./scripts/package.ps1

.EXAMPLE
./scripts/package.ps1 -PreRelease
#>
[CmdletBinding()]
param(
    [switch] $PreRelease,
    [switch] $Install
)

$ErrorActionPreference = 'Stop'

$onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
$npm = if ($onWindows) { 'npm.cmd' } else { 'npm' }
$npx = if ($onWindows) { 'npx.cmd' } else { 'npx' }

function Invoke-Native {
    param([string] $Exe, [string[]] $Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed with exit code $LASTEXITCODE"
    }
}

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw 'node is not installed (https://nodejs.org)'
    }

    if ($Install -or -not (Test-Path node_modules)) {
        Write-Host '==> Installing dependencies (npm ci)' -ForegroundColor Cyan
        Invoke-Native $npm @('ci', '--no-audit', '--no-fund')
    }

    $pkg = Get-Content package.json -Raw | ConvertFrom-Json
    $vsix = "releases/$($pkg.name)-$($pkg.version).vsix"
    New-Item -ItemType Directory -Force -Path releases | Out-Null
    if (Test-Path $vsix) { Remove-Item $vsix -Force }

    $vsceArgs = @('--no', '--', 'vsce', 'package', '--out', $vsix)
    if ($PreRelease) { $vsceArgs += '--pre-release' }

    $label = if ($PreRelease) { ' (pre-release)' } else { '' }
    Write-Host "==> Packaging $($pkg.name) $($pkg.version)$label" -ForegroundColor Cyan
    Invoke-Native $npx $vsceArgs

    Write-Host "==> Created $vsix" -ForegroundColor Green
}
finally {
    Pop-Location
}
