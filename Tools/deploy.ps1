<#
    deploy.ps1 - Deploy Stakeout (and optionally the throwaway API probe) into
    the WoW: Forever AddOns folder.

    The repo keeps `## Version: @project-version@` because the CurseForge/BigWigs
    packager substitutes it at release time. The client would display that literal
    string, so the deployed copy gets `## Version: dev` instead. The repo copy is
    never modified.

    Usage:
        pwsh Tools/deploy.ps1                # addon only
        pwsh Tools/deploy.ps1 -Probe         # addon + StakeoutProbe
        pwsh Tools/deploy.ps1 -ProbeOnly     # just StakeoutProbe
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\...\_classic_beta_\Interface\AddOns"
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

if (-not $ProbeOnly) {
    # An unported manifest would load against the wrong client and muddy any
    # measurement taken alongside it.
    if ((Get-Content -LiteralPath (Join-Path $RepoRoot "Stakeout.toc") -Raw) -notmatch '(?m)^## Interface: 16001\s*$') {
        Write-Error "Stakeout.toc is not '## Interface: 16001' yet (not ported, #4). Use -ProbeOnly."
        exit 1
    }
    Deploy-Folder "Stakeout" $RepoRoot (Get-TocFiles $RepoRoot)
}
if ($ProbeOnly -and (Test-Path (Join-Path $AddOnsPath "Stakeout"))) {
    Write-Warning "An installed Stakeout is still in AddOns. Disable it in the AddOn list so it cannot affect the probe."
}
if ($Probe -or $ProbeOnly) {
    $src = Join-Path $RepoRoot "Tools\StakeoutProbe"
    Deploy-Folder "StakeoutProbe" $src (Get-TocFiles $src)
}

Write-Host ""
Write-Host "Done. In game:  /console scriptErrors 1  then  /reload" -ForegroundColor Green
Write-Host "Check the AddOn list: enabled AND not flagged out of date." -ForegroundColor Green
