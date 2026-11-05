# Set this tool up on a fresh Windows machine.
#
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
#
# Does, in order: find or install Python, install/upgrade architrice, build the
# launcher shortcuts, then run a first sync. Safe to re-run.
#
# It does NOT pin anything to the taskbar -- that is done by hand through
# right-click -> Pin to taskbar. See README.md for why.

[CmdletBinding()]
param(
    # Skip the launcher shortcuts (sync from the command line only).
    [switch]$NoLauncher,
    # Skip the first sync.
    [switch]$NoSync
)

$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Python {
    if ($env:MTG_SYNC_PYTHON -and (Test-Path -LiteralPath $env:MTG_SYNC_PYTHON)) {
        return $env:MTG_SYNC_PYTHON
    }
    foreach ($v in 316, 315, 314, 313, 312, 311) {
        foreach ($root in @(
            (Join-Path $env:LOCALAPPDATA "Programs\Python\Python$v"),
            (Join-Path $env:ProgramFiles "Python$v"),
            (Join-Path ${env:ProgramFiles(x86)} "Python$v")
        )) {
            $exe = Join-Path $root 'python.exe'
            if ($root -and (Test-Path -LiteralPath $exe)) { return $exe }
        }
    }
    return $null
}

# --- 1. Python ------------------------------------------------------------
# Note: "python" on PATH is often the Microsoft Store redirector stub, which
# launches the Store rather than an interpreter. Ignore PATH and look for a
# real install; install one if there is none.
$python = Find-Python
if (-not $python) {
    Write-Host 'No Python found. Installing Python 3.13 (user scope) via winget...'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is unavailable. Install Python 3.11+ manually, then re-run.'
    }
    winget install --id Python.Python.3.13 --scope user --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $python = Find-Python
    if (-not $python) { throw 'Python install finished but no interpreter was found.' }
}
Write-Host "Python: $python"
& $python --version

# --- 2. architrice -------------------------------------------------------
Write-Host 'Installing/upgrading architrice...'
& $python -m pip install -q -U pip architrice
if ($LASTEXITCODE -ne 0) { throw 'pip install failed.' }

# --- 3. Launcher shortcuts ----------------------------------------------
if (-not $NoLauncher) {
    Write-Host 'Building launcher shortcuts...'
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
        -File (Join-Path $Base 'setup-launcher.ps1')
}

# --- 4. First sync ------------------------------------------------------
if (-not $NoSync) {
    Write-Host 'Running first sync (this downloads the Scryfall card list once)...'
    & cmd.exe /c (Join-Path $Base 'sync-decks.cmd') sync
}

Write-Host ''
Write-Host 'Done. To put Cockatrice on the taskbar, pin it YOURSELF:'
Write-Host '  Start -> All apps -> "Cockatrice (Deck Sync)" -> right-click -> Pin to taskbar'
Write-Host 'Then unpin any pre-existing Cockatrice icon.'
