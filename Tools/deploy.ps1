<#
    deploy.ps1 - Deploy Stakeout into the WoW: Forever AddOns folder.

    The repo keeps `## Version: @project-version@` because the CurseForge/BigWigs
    packager substitutes it at release time. The client would display that literal
    string, so the deployed copy gets `## Version: dev` instead. The repo copy is
    never modified.

    Usage:
        pwsh Tools/deploy.ps1               # Stakeout
        pwsh Tools/deploy.ps1 -Probe        # ...and StakeoutProbe
        pwsh Tools/deploy.ps1 -ProbeOnly    # just StakeoutProbe
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\...\_classic_beta_\Interface\AddOns"

    StakeoutProbe is a ForeverProbe module, so -Probe and -ProbeOnly deploy the
    ForeverProbe checkout first ($env:FOREVERPROBE, else ..\ForeverProbe).
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns",
    [switch]$Probe,
    [switch]$ProbeOnly
)

$ErrorActionPreference = "Stop"

# Repo root = parent of this script's folder.
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $AddOnsPath)) {
    Write-Error "AddOns path not found: $AddOnsPath"
    exit 1
}

function Copy-AddonFile {
    param([string]$Source, [string]$Destination)

    if ($Source -like "*.toc") {
        # Substitute the packager token so the client shows something sane.
        (Get-Content -LiteralPath $Source -Raw) `
            -replace '## Version: @project-version@', '## Version: dev' |
            Set-Content -LiteralPath $Destination -NoNewline
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function Deploy-Folder {
    param([string]$Name, [string]$Source, [string[]]$Files)

    $dest = Join-Path $AddOnsPath $Name
    Write-Host "Deploying $Name -> $dest" -ForegroundColor Cyan
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

    foreach ($f in $Files) {
        Copy-AddonFile -Source (Join-Path $Source $f) -Destination (Join-Path $dest $f)
        Write-Host "  $f"
    }

    # Purge files that no longer exist in the repo, which the client would
    # otherwise still find.
    Get-ChildItem -LiteralPath $dest -File | Where-Object { $Files -notcontains $_.Name } |
        ForEach-Object {
            Write-Host "  removing stale $($_.Name)" -ForegroundColor DarkYellow
            Remove-Item -LiteralPath $_.FullName -Force
        }
}

function Get-TocFiles {
    param([string]$Folder)
    return @(Get-ChildItem -LiteralPath $Folder -File |
        Where-Object { $_.Extension -in ".toc", ".lua" } |
        Select-Object -ExpandProperty Name)
}

# A manifest for another client would load against the wrong API here.
if ((Get-Content -LiteralPath (Join-Path $RepoRoot "Stakeout.toc") -Raw) -notmatch '(?m)^## Interface: 16001\s*$') {
    Write-Error "Stakeout.toc is not '## Interface: 16001'; this script deploys to WoW: Forever."
    exit 1
}
$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path (Split-Path -Parent $RepoRoot) "ForeverProbe" }

function Deploy-Probe {
    # The host first: StakeoutProbe has ## Dependencies: ForeverProbe, so
    # without it the client loads no StakeoutProbe at all.
    if (-not (Test-Path -LiteralPath (Join-Path $ForeverProbe "Tools\deploy.ps1"))) {
        Write-Error "ForeverProbe checkout not found at $ForeverProbe (clone github.com/Spotnick2/ForeverProbe there, or set `$env:FOREVERPROBE)"
        exit 1
    }
    & pwsh -NoProfile -File (Join-Path $ForeverProbe "Tools\deploy.ps1") -AddOnsPath $AddOnsPath
    if ($LASTEXITCODE -ne 0) { Write-Error "ForeverProbe deploy refused; StakeoutProbe was not touched"; exit 1 }
    $source = Join-Path $RepoRoot "Tools\StakeoutProbe"
    Deploy-Folder "StakeoutProbe" $source (Get-TocFiles $source)
}

if (-not $ProbeOnly) { Deploy-Folder "Stakeout" $RepoRoot (Get-TocFiles $RepoRoot) }
if ($Probe -or $ProbeOnly) { Deploy-Probe }

Write-Host ""
Write-Host "Done. In game:  /console scriptErrors 1  then  /reload (a brand-new addon folder included)" -ForegroundColor Green
Write-Host "Check the AddOn list: enabled AND not flagged out of date." -ForegroundColor Green
if ($Probe -or $ProbeOnly) {
    Write-Host "The probe: /fp so for its commands, /fp steps for its procedures." -ForegroundColor Green
}
