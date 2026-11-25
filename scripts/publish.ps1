<#
.SYNOPSIS
Releases a new version of the extension to GitHub Releases, the VS Code Marketplace and Open VSX.

.DESCRIPTION
Sets the version, moves the CHANGELOG.md "Unreleased" notes under it, builds the .vsix,
commits and tags vX.Y.Z, pushes, then publishes to GitHub Releases, the VS Code
Marketplace and Open VSX. Each publish target is tried even if an earlier one fails.

Credentials (see RELEASING.md):
  GitHub       gh CLI login ("gh auth login") or GH_TOKEN
  Marketplace  trusted publishing (OIDC) when run by the Release workflow on GitHub,
               otherwise VSCE_PAT (global Azure DevOps PATs stop working on 1 Dec 2026)
  Open VSX     OVSX_PAT, or trusted publishing when run by the Release workflow
Tokens are read from the environment, or from a .env file next to package.json.

.PARAMETER Version
patch | minor | major  Bump the version in package.json (1.2.3 -> 1.2.4 / 1.3.0 / 2.0.0)
X.Y.Z                  Use this exact version
current                Release the version already in package.json, e.g. to finish a release
                       whose publish step failed (already-published targets are skipped)

.PARAMETER PreRelease
Publish as a pre-release on all targets.

.PARAMETER SkipGitHub
Don't create a GitHub release (the commit and tag are still pushed).

.PARAMETER SkipMarketplace
Don't publish to the VS Code Marketplace.

.PARAMETER SkipOpenVsx
Don't publish to Open VSX.

.PARAMETER DryRun
Build the .vsix for the new version, then put the files back; publish nothing.

.PARAMETER Yes
Don't ask for confirmation (required when not run in a terminal).

.EXAMPLE
./scripts/publish.ps1 minor

.EXAMPLE
./scripts/publish.ps1 patch -DryRun

.EXAMPLE
./scripts/publish.ps1 current -SkipGitHub
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Version,
    [switch] $PreRelease,
    [switch] $SkipGitHub,
    [switch] $SkipMarketplace,
    [switch] $SkipOpenVsx,
    [switch] $DryRun,
    [switch] $Yes,
    [switch] $Help
)

$ErrorActionPreference = 'Stop'

if ($Help -or -not $Version) {
    Get-Help $PSCommandPath -Detailed
    if (-not $Help) { exit 1 }
    exit 0
}

$onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
$npm = if ($onWindows) { 'npm.cmd' } else { 'npm' }
$npx = if ($onWindows) { 'npx.cmd' } else { 'npx' }

function Write-Step([string] $Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Warn([string] $Text) { Write-Host "warning: $Text" -ForegroundColor Yellow }

# Runs a native command with its output shown; throws if it fails.
function Invoke-Native {
    param([string] $Exe, [string[]] $Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed with exit code $LASTEXITCODE"
    }
}

# Runs a native command quietly; returns $true if it succeeded.
function Test-Native {
    param([string] $Exe, [string[]] $Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # Windows PowerShell turns redirected stderr into errors
    try { & $Exe @Arguments *> $null } finally { $ErrorActionPreference = $previous }
    return ($LASTEXITCODE -eq 0)
}

# Runs a native command and returns its trimmed stdout; throws if it fails.
function Get-NativeOutput {
    param([string] $Exe, [string[]] $Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @Arguments 2> $null } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed with exit code $LASTEXITCODE"
    }
    return (($out | Out-String).Trim())
}

# Reads KEY=VALUE lines from .env. Variables already set in the environment win.
function Import-EnvFile([string] $Path) {
    if (-not (Test-Path $Path)) { return }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            if (-not [System.Environment]::GetEnvironmentVariable($key)) {
                [System.Environment]::SetEnvironmentVariable($key, $value)
            }
        }
    }
}

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

$filesChanged = $false
$committed = $false
$tagCreated = $false
$trackedFiles = @()
$notesFile = $null

function Restore-Files {
    if ($script:filesChanged -and -not $script:committed) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $files = $script:trackedFiles
        try { & git checkout --quiet -- @files } finally { $ErrorActionPreference = $previous }
        $script:filesChanged = $false
        Write-Host "Put back: $($script:trackedFiles -join ', ')"
    }
}

function Get-ResumeCommand {
    $cmd = './scripts/publish.ps1 current'
    if ($PreRelease) { $cmd += ' -PreRelease' }
    if ($script:SkipGitHub) { $cmd += ' -SkipGitHub' }
    if ($script:SkipMarketplace) { $cmd += ' -SkipMarketplace' }
    if ($script:SkipOpenVsx) { $cmd += ' -SkipOpenVsx' }
    return $cmd
}

try {
    Import-EnvFile (Join-Path $root '.env')

    # GitHub Actions provides an OIDC ID token when the job has "permissions: id-token: write".
    $oidc = [bool]$env:ACTIONS_ID_TOKEN_REQUEST_URL

    # -----------------------------------------------------------------------
    # Checks
    # -----------------------------------------------------------------------
    foreach ($tool in 'git', 'node', 'npm') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not installed" }
    }
    if (-not (Test-Native git @('rev-parse', '--is-inside-work-tree'))) { throw "$root is not a git repository" }
    if (-not (Test-Native git @('rev-parse', '--verify', '--quiet', 'HEAD'))) { throw 'the repository has no commits yet' }
    if (Get-NativeOutput git @('status', '--porcelain')) {
        throw 'the working tree has uncommitted changes; commit or stash them first'
    }
    if (-not (Test-Native git @('symbolic-ref', '--quiet', 'HEAD'))) { throw 'HEAD is detached; check out a branch first' }
    $branch = Get-NativeOutput git @('symbolic-ref', '--quiet', '--short', 'HEAD')

    $hasOrigin = Test-Native git @('remote', 'get-url', 'origin')
    if ($hasOrigin) {
        Invoke-Native git @('fetch', '--quiet', '--tags', 'origin')
        if (Test-Native git @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$branch")) {
            $behind = Get-NativeOutput git @('rev-list', '--count', "HEAD..origin/$branch")
            if ($behind -ne '0') { throw "$branch is $behind commit(s) behind origin/$branch; pull first" }
        }
    }

    $pkg = Get-Content package.json -Raw | ConvertFrom-Json
    $name = $pkg.name
    $publisher = $pkg.publisher
    $current = $pkg.version

    switch -Regex ($Version) {
        '^(patch|minor|major)$' {
            if ($current -notmatch '^(\d+)\.(\d+)\.(\d+)') { throw "cannot read version '$current' in package.json" }
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
            switch ($Version) {
                'major' { $major++; $minor = 0; $patch = 0 }
                'minor' { $minor++; $patch = 0 }
                'patch' { $patch++ }
            }
            $newVersion = "$major.$minor.$patch"
            break
        }
        '^current$' { $newVersion = $current; break }
        default {
            $newVersion = $Version -replace '^v', ''
            if ($newVersion -notmatch '^\d+\.\d+\.\d+$') {
                throw "invalid version '$Version': use patch, minor, major, current or X.Y.Z (the Marketplace rejects suffixes like -beta; use -PreRelease instead)"
            }
        }
    }

    $tag = "v$newVersion"
    $vsix = "releases/$name-$newVersion.vsix"
    $bumped = $newVersion -ne $current

    $tagExists = Test-Native git @('rev-parse', '--verify', '--quiet', "refs/tags/$tag")
    if ($tagExists) {
        if ($bumped) { throw "tag $tag already exists; pick another version" }
        $tagCommit = Get-NativeOutput git @('rev-list', '-n', '1', $tag)
        $headCommit = Get-NativeOutput git @('rev-parse', 'HEAD')
        if ($tagCommit -ne $headCommit) {
            throw "tag $tag already exists on another commit; release a new version (patch, minor or major) instead"
        }
    }

    if ($branch -ne 'main' -and $branch -ne 'master') {
        Write-Warn "you are releasing from branch '$branch', not main"
    }

    $problems = @()
    if (-not $SkipGitHub) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            $problems += 'gh (GitHub CLI) is not installed: https://cli.github.com (or pass -SkipGitHub)'
        }
        elseif (-not (Test-Native gh @('auth', 'status', '--hostname', 'github.com'))) {
            $problems += "gh is not logged in: run 'gh auth login' or set GH_TOKEN (or pass -SkipGitHub)"
        }
        if (-not $hasOrigin) {
            $problems += "no 'origin' remote: create the GitHub repository and add it as origin (or pass -SkipGitHub)"
        }
    }
    if (-not $SkipMarketplace -and -not $oidc -and -not $env:VSCE_PAT) {
        $problems += 'no VS Code Marketplace credentials: run the Release workflow on GitHub, or set VSCE_PAT; see RELEASING.md (or pass -SkipMarketplace)'
    }
    if (-not $SkipOpenVsx -and -not $oidc -and -not $env:OVSX_PAT) {
        $problems += 'OVSX_PAT is not set; see RELEASING.md (or pass -SkipOpenVsx)'
    }
    if ($problems.Count -gt 0) {
        Write-Host 'Release prerequisites are missing:' -ForegroundColor Yellow
        foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Yellow }
        if ($DryRun) { Write-Warn 'continuing because this is a dry run' }
        else { throw 'fix the problems above first' }
    }

    $targets = @()
    if (-not $SkipGitHub) { $targets += 'GitHub release' }
    if (-not $SkipMarketplace) {
        $targets += $(if ($oidc) { 'VS Code Marketplace (trusted publishing)' } else { 'VS Code Marketplace (VSCE_PAT)' })
    }
    if (-not $SkipOpenVsx) {
        $targets += $(if (-not $env:OVSX_PAT -and $oidc) { 'Open VSX (trusted publishing)' } else { 'Open VSX (OVSX_PAT)' })
    }
    $targetText = if ($targets.Count -gt 0) { $targets -join ', ' } else { 'nothing (all targets skipped)' }
    $preLabel = if ($PreRelease) { ', pre-release' } else { '' }

    Write-Host ("Release plan" + $(if ($DryRun) { ' (dry run)' } else { '' }))
    Write-Host "  extension:  $publisher.$name"
    if ($bumped) { Write-Host "  version:    $current -> $newVersion (tag $tag)$preLabel" }
    else { Write-Host "  version:    $newVersion, unchanged (tag $tag)$preLabel" }
    Write-Host ("  branch:     $branch" + $(if ($hasOrigin) { '' } else { ' (no origin remote: nothing is pushed)' }))
    Write-Host "  publish to: $targetText"

    if (-not $DryRun -and -not $Yes) {
        if ([Console]::IsInputRedirected) { throw 'not running in a terminal: pass -Yes to confirm' }
        $answer = Read-Host 'Continue? [y/N]'
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; exit 1 }
    }

    foreach ($f in 'package.json', 'package-lock.json', 'CHANGELOG.md') {
        if (Test-Native git @('ls-files', '--error-unmatch', $f)) { $trackedFiles += $f }
    }

    # -----------------------------------------------------------------------
    # Version, changelog, build
    # -----------------------------------------------------------------------
    Write-Step 'Installing dependencies (npm ci)'
    Invoke-Native $npm @('ci', '--no-audit', '--no-fund')

    $changelogPath = Join-Path $root 'CHANGELOG.md'
    if ($bumped) {
        Write-Step "Setting version $newVersion"
        $filesChanged = $true
        Invoke-Native $npm @('version', $newVersion, '--no-git-tag-version') | Out-Null

        if (Test-Path $changelogPath) {
            $changelog = [System.IO.File]::ReadAllText($changelogPath)
            $nl = if ($changelog.Contains("`r`n")) { "`r`n" } else { "`n" }
            $unreleased = [regex]'(?m)^## \[Unreleased\][^\r\n]*'
            if ($unreleased.IsMatch($changelog)) {
                # "## [Unreleased]" stays on top (empty); its notes move under "## [X.Y.Z] - date".
                $heading = "## [$newVersion] - $(Get-Date -Format 'yyyy-MM-dd')"
                $changelog = $unreleased.Replace($changelog, "`$0$nl$nl$heading", 1)
                [System.IO.File]::WriteAllText($changelogPath, $changelog)
            }
            else { Write-Warn "CHANGELOG.md has no '## [Unreleased]' heading; leaving it unchanged" }
        }
    }

    # Notes for this version: the lines under "## [X.Y.Z]" up to the next "## " heading.
    $notes = ''
    if (Test-Path $changelogPath) {
        $changelog = [System.IO.File]::ReadAllText($changelogPath)
        $section = [regex]::Match($changelog, '(?ms)^## \[' + [regex]::Escape($newVersion) + '\][^\r\n]*\r?\n(.*?)(?=^## |\z)')
        if ($section.Success) { $notes = $section.Groups[1].Value.Trim() }
    }
    if (-not $notes) { Write-Warn "CHANGELOG.md has no notes for $newVersion; the GitHub release will use generated notes" }

    Write-Step "Building $vsix"
    & (Join-Path $PSScriptRoot 'package.ps1') -PreRelease:$PreRelease

    if ($DryRun) {
        Restore-Files
        Write-Host ''
        Write-Host "Dry run finished: built $vsix. package.json and CHANGELOG.md are back at $current."
        Write-Host "A real run would now commit, tag $tag, push, and publish to: $targetText"
        exit 0
    }

    # -----------------------------------------------------------------------
    # Commit, tag, push
    # -----------------------------------------------------------------------
    if ($bumped) {
        Write-Step "Committing release $tag"
        Invoke-Native git (@('add', '--') + $trackedFiles)
        Invoke-Native git @('commit', '--quiet', '-m', "chore(release): $tag")
        $committed = $true
    }
    if (-not $tagExists) {
        Invoke-Native git @('tag', '-a', $tag, '-m', "$name $tag")
        $tagCreated = $true
    }

    if ($hasOrigin) {
        Write-Step "Pushing $branch and $tag to origin"
        Invoke-Native git @('push', '--quiet', '-u', 'origin', $branch)
        Invoke-Native git @('push', '--quiet', 'origin', "refs/tags/$tag")
    }
    else {
        Write-Warn "no 'origin' remote: the commit and tag $tag stay local"
    }

    # -----------------------------------------------------------------------
    # Publish. Each target is tried even if an earlier one fails.
    # -----------------------------------------------------------------------
    $failed = @()
    $succeeded = @()

    if (-not $SkipGitHub) {
        Write-Step "GitHub release $tag"
        try {
            if (Test-Native gh @('release', 'view', $tag)) {
                Invoke-Native gh @('release', 'upload', $tag, $vsix, '--clobber')
            }
            else {
                $ghArgs = @('release', 'create', $tag, $vsix, '--verify-tag', '--title', $tag)
                if ($PreRelease) { $ghArgs += '--prerelease' }
                if ($notes) {
                    $notesFile = [System.IO.Path]::GetTempFileName()
                    [System.IO.File]::WriteAllText($notesFile, $notes)
                    $ghArgs += @('--notes-file', $notesFile)
                }
                else { $ghArgs += '--generate-notes' }
                Invoke-Native gh $ghArgs
            }
            $succeeded += 'github'
        }
        catch { Write-Host $_ -ForegroundColor Red; $failed += 'github' }
    }

    if (-not $SkipMarketplace) {
        Write-Step 'VS Code Marketplace'
        try {
            $vsceArgs = @('--no', '--', 'vsce', 'publish', '--packagePath', $vsix, '--skip-duplicate')
            if ($PreRelease) { $vsceArgs += '--pre-release' }
            # Without --oidc, vsce reads VSCE_PAT from the environment.
            if ($oidc) { $vsceArgs += '--oidc' }
            Invoke-Native $npx $vsceArgs
            $succeeded += 'marketplace'
        }
        catch { Write-Host $_ -ForegroundColor Red; $failed += 'marketplace' }
    }

    if (-not $SkipOpenVsx) {
        Write-Step 'Open VSX'
        try {
            # ovsx reads OVSX_PAT from the environment, or uses trusted publishing on GitHub Actions
            # when no token is set. The pre-release flag is already inside the .vsix.
            Invoke-Native $npx @('--no', '--', 'ovsx', 'publish', $vsix, '--skip-duplicate')
            $succeeded += 'openvsx'
        }
        catch { Write-Host $_ -ForegroundColor Red; $failed += 'openvsx' }
    }

    Write-Host ''
    if ($succeeded -contains 'github') {
        $url = "release $tag"
        try { $url = Get-NativeOutput gh @('release', 'view', $tag, '--json', 'url', '--jq', '.url') } catch { }
        Write-Host "GitHub:      $url"
    }
    if ($succeeded -contains 'marketplace') {
        Write-Host "Marketplace: https://marketplace.visualstudio.com/items?itemName=$publisher.$name (can take a few minutes to update)"
    }
    if ($succeeded -contains 'openvsx') {
        Write-Host "Open VSX:    https://open-vsx.org/extension/$publisher/$name"
    }

    if ($failed.Count -gt 0) {
        # Skip what already worked when retrying.
        if ($succeeded -contains 'github') { $SkipGitHub = [switch]$true }
        if ($succeeded -contains 'marketplace') { $SkipMarketplace = [switch]$true }
        if ($succeeded -contains 'openvsx') { $SkipOpenVsx = [switch]$true }
        Write-Host ''
        Write-Host "Failed: $($failed -join ', '). Fix the problem above, then finish with:" -ForegroundColor Red
        Write-Host "  $(Get-ResumeCommand)"
        exit 1
    }

    Write-Host ''
    Write-Host "Released $name $newVersion." -ForegroundColor Green
}
catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    Restore-Files
    if ($committed -or $tagCreated) {
        Write-Host ''
        Write-Host "The release commit/tag for $tag exists locally. Fix the problem above, then finish with:"
        Write-Host "  $(Get-ResumeCommand)"
    }
    exit 1
}
finally {
    if ($notesFile -and (Test-Path $notesFile)) { Remove-Item $notesFile -Force }
    Pop-Location
}
