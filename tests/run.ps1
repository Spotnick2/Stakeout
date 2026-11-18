<#
    run.ps1 - Syntax-check the Lua, then run every tests\test_*.lua under
    Lua 5.1 through WowTestKit at the commit tests\kit.pin names (its
    scripts\run.ps1).

    The tests are plain Lua 5.1 scripts that load the addon against
    tests/wow_stubs.lua (on the kit). WoW uses Lua 5.1, so the tests do too,
    not the newer Lua that may be first on PATH.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
        pwsh tests/run.ps1 -KitDev      # the ..\WowTestKit working copy, not the pin
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$KitDev
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Lua)) {
    Write-Error "Lua 5.1 interpreter not found at: $Lua  (pass -Lua <path>)"
    exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot

# Run from the repo root so the tests can dofile('tests/...') and read
# Stakeout.toc with paths relative to the project.
Push-Location $RepoRoot
try {
    # Syntax-check everything that ships, and any Lua under Tools.
    # A missing luac must fail the run: no test loads every file, so skipping
    # this would let a syntax error through behind a green result. (The kit's
    # runner only warns, so it is not given the files: this is the check.)
    $luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
    if (-not (Test-Path $luac)) {
        Write-Error "luac.exe not found next to $Lua; the syntax check cannot run."
        exit 1
    }
    # Every Lua file the TOC loads (what ships), then any Lua under Tools.
    $sources = @(Get-Content -LiteralPath "Stakeout.toc" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch "^#" -and $_ -match "[.]lua$" })
    if ($sources.Count -eq 0) {
        Write-Error "Stakeout.toc lists no Lua file; the syntax check would check nothing."
        exit 1
    }
    if (Test-Path "Tools") {
        $sources += Get-ChildItem "Tools" -Recurse -Filter "*.lua" |
            ForEach-Object { Resolve-Path -Relative $_.FullName }
    }
    & $luac -p @sources
    if ($LASTEXITCODE -ne 0) {
        Write-Host "luac -p FAILED" -ForegroundColor Red
        exit 1
    }
    Remove-Item -LiteralPath (Join-Path $RepoRoot "luac.out") -ErrorAction SilentlyContinue
    Write-Host "luac -p: ok" -ForegroundColor DarkGray
}
finally {
    Pop-Location
}

. (Join-Path $PSScriptRoot "kit.ps1")
$kit = Get-WowTestKit -RepoRoot $RepoRoot -KitDev:$KitDev
& (Join-Path $kit "scripts\run.ps1") -RepoRoot $RepoRoot -Lua $Lua
exit $LASTEXITCODE
