<#
.SYNOPSIS
    Universal Gowin EDA build and flash launcher across supported boards.

.DESCRIPTION
    Launches the Gowin EDA synthesis, place-and-route, bitstream generation,
    and programming flow for the specified target board.

.PARAMETER Board
    Target board: 'console60k' (default), 'nano20k', or 'nano9k'.

.EXAMPLE
    .\build_gowin.ps1 -Board console60k
    .\build_gowin.ps1 -Board console60k -Clean -Target syn
    .\build_gowin.ps1 -Board nano20k -Flash sram
    .\build_gowin.ps1 -Board nano9k -Scan
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [ValidateSet("console60k", "nano20k", "nano9k")]
    [string]$Board = "console60k",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$BoardDir = Join-Path $PSScriptRoot "boards\sipeed\$Board"
$ScriptPath = Join-Path $BoardDir "build.ps1"

if (-not (Test-Path $ScriptPath)) {
    Write-Host "[ERROR] Build script for board '$Board' not found at $ScriptPath" -ForegroundColor Red
    exit 1
}

if ($RemainingArgs) {
    powershell -NoProfile -ExecutionPolicy Bypass -File "$ScriptPath" @RemainingArgs
} else {
    powershell -NoProfile -ExecutionPolicy Bypass -File "$ScriptPath"
}
exit $LASTEXITCODE
