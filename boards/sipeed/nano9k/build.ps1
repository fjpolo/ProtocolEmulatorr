<#
.SYNOPSIS
    Build and flash script for Gowin FPGA (Sipeed Tang Nano 9K).
#>

[CmdletBinding()]
param (
    [ValidateSet("all", "syn", "pnr", "flash", "sram")]
    [string]$Target = "all",

    [switch]$Clean,

    [ValidateSet("sram", "flash")]
    [string]$FlashMode = "sram",

    [switch]$Flash,

    [string]$Cable = "",

    [int]$CableIndex = -1,

    [int]$ProgMode = -1,

    [switch]$NoBuild,

    [switch]$Scan,

    [string]$GowinPath = "",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

if ($Target -in @("sram", "flash")) {
    $FlashMode = $Target
    $Flash = $true
    $Target = "all"
}
if ($RemainingArgs) {
    foreach ($arg in $RemainingArgs) {
        if ($arg -in @("sram", "flash")) {
            $FlashMode = $arg
            $Flash = $true
        }
    }
}
if ($PSBoundParameters.ContainsKey('FlashMode')) {
    $Flash = $true
}

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Sipeed Tang Nano 9K - Gowin EDA Build Flow" -ForegroundColor Cyan
Write-Host "   Project: ProtocolEmulator" -ForegroundColor Cyan
Write-Host "   FPGA   : GW1NR-LV9QN88PC6/I5 (GW1NR-9C)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$SearchPaths = @()
if ($GowinPath) { $SearchPaths += $GowinPath }
if ($env:GOWIN_HOME) { $SearchPaths += $env:GOWIN_HOME }
$SearchPaths += @("C:\Gowin\Gowin_V1.9.12_x64", "C:\Gowin\Gowin_V1.9.11_x64", "C:\Gowin\Gowin_V1.9.10_x64", "C:\Gowin\Gowin_V1.9.9_x64", "C:\Gowin\*")

$GwSh = $null
$ProgCli = $null

$PathGwSh = Get-Command "gw_sh.exe" -ErrorAction SilentlyContinue
if ($PathGwSh) { $GwSh = $PathGwSh.Source }

if (-not $GwSh) {
    foreach ($path in $SearchPaths) {
        $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
        foreach ($r in $resolved) {
            $candidateGwSh = Join-Path $r.Path "IDE\bin\gw_sh.exe"
            if (Test-Path $candidateGwSh) {
                $GwSh = $candidateGwSh
                $candidateProg = Join-Path $r.Path "Programmer\bin\programmer_cli.exe"
                if (Test-Path $candidateProg) { $ProgCli = $candidateProg }
                break
            }
        }
        if ($GwSh) { break }
    }
}

if (-not $ProgCli -and $GwSh) {
    $GowinRoot = Split-Path (Split-Path (Split-Path $GwSh))
    $candidateProg = Join-Path $GowinRoot "Programmer\bin\programmer_cli.exe"
    if (Test-Path $candidateProg) { $ProgCli = $candidateProg }
}

if (-not $GwSh) {
    Write-Host "[ERROR] Could not find Gowin EDA installation (gw_sh.exe)!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Gowin Shell : $GwSh" -ForegroundColor Green
if ($ProgCli) { Write-Host "[OK] Programmer  : $ProgCli" -ForegroundColor Green }

if ($Scan) {
    if (-not $ProgCli) { Write-Host "[ERROR] programmer_cli.exe not found!" -ForegroundColor Red; exit 1 }
    & $ProgCli --scan-cables
    $CableArgs = @()
    if ($CableIndex -ge 0) { $CableArgs = @("--cable-index", $CableIndex) }
    elseif ($Cable) { $CableArgs = @("--cable", $Cable) }
    & $ProgCli @CableArgs --scan
    exit 0
}

if ($Clean) {
    Write-Host "`nCleaning build artifacts..." -ForegroundColor Yellow
    $ImplDir = Join-Path $ScriptDir "impl"
    if (Test-Path $ImplDir) { Remove-Item -Recurse -Force $ImplDir; Write-Host "[OK] Removed $ImplDir" -ForegroundColor Green }
    $UserFile = Join-Path $ScriptDir "nano9k.gprj.user"
    if (Test-Path $UserFile) { Remove-Item -Force $UserFile }
}

$BitstreamPath = Join-Path $ScriptDir "impl\pnr\nano9k.fs"

if (-not $NoBuild) {
    $TclScript = Join-Path $ScriptDir "build.tcl"
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n===> Starting Gowin Build Target: [$Target]..." -ForegroundColor Magenta
    & $GwSh $TclScript $Target
    if ($LASTEXITCODE -ne 0) { Write-Host "`n[ERROR] Gowin build failed with exit code $LASTEXITCODE!" -ForegroundColor Red; exit $LASTEXITCODE }
    $Stopwatch.Stop()
    $Duration = [math]::Round($Stopwatch.Elapsed.TotalSeconds, 1)

    if ($Target -eq "all") {
        if (Test-Path $BitstreamPath) {
            $FileSize = (Get-Item $BitstreamPath).Length
            $FileSizeKb = [math]::Round($FileSize / 1024, 1)
            Write-Host "`n============================================================" -ForegroundColor Green
            Write-Host "  BUILD SUCCESSFUL ($Duration s)" -ForegroundColor Green
            Write-Host "  Bitstream: $BitstreamPath ($FileSizeKb KB)" -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
        }
    } else {
        Write-Host "`n[OK] Target '$Target' completed successfully ($Duration s)." -ForegroundColor Green
    }
}

if ($Flash) {
    if (-not $ProgCli) { Write-Host "`n[ERROR] programmer_cli.exe not found for programming!" -ForegroundColor Red; exit 1 }
    if (-not (Test-Path $BitstreamPath)) { Write-Host "`n[ERROR] Bitstream not found at $BitstreamPath! Run full build first." -ForegroundColor Red; exit 1 }

    $CableArgs = @()
    if ($CableIndex -ge 0) { $CableArgs = @("--cable-index", $CableIndex) }
    elseif ($Cable) { $CableArgs = @("--cable", $Cable) }

    $OpCode = if ($ProgMode -ge 0) { $ProgMode } elseif ($FlashMode -eq "sram") { 2 } else { 53 }
    & $ProgCli @CableArgs --device "GW1NR-9C" --run $OpCode --fsFile "$BitstreamPath"
}
