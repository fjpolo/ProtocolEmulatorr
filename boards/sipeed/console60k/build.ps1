<#
.SYNOPSIS
    Build and flash script for Gowin FPGA (Sipeed Tang Console 60K).

.DESCRIPTION
    Automates logic synthesis, place & route, bitstream (.fs) generation,
    and board programming for the ProtocolEmulator on the Sipeed Tang Console 60K (GW5AT-LV60PG484AC1/I0).

.PARAMETER Target
    Build target: 'all' (default: synthesis + PnR + bitstream), 'syn' (synthesis only), or 'pnr' (PnR only).

.PARAMETER Clean
    Cleans the 'impl/' build directory and temporary project files before building.

.PARAMETER FlashMode
    Flash mode: 'sram' (fast volatile SRAM load, mode 2) or 'flash' (persistent external SPI Flash programming, mode 53).

.PARAMETER Flash
    Switch flag to enable board programming after building (or standalone if -NoBuild specified).
    Also accepts: -Flash sram or -Flash flash directly.

.PARAMETER NoBuild
    Skips synthesis and PnR, flashing the existing bitstream directly.

.PARAMETER Cable
    JTAG programmer cable name (e.g. 'Gowin USB Cable(FT2CH)', 'USB Debugger A', 'Gowin USB Cable(WINUSB)', 'Gowin USB Cable(GWU2X)').

.PARAMETER CableIndex
    Programmer cable index (0: GWU2X, 1: FT2CH, 4: USB Debugger A, 5: WINUSB).

.PARAMETER ProgMode
    Custom operation number override for programmer_cli (default: 2 for sram, 53 for flash).

.PARAMETER Scan
    Scans for connected Gowin USB cables and FPGA JTAG devices.

.PARAMETER GowinPath
    Custom path to Gowin EDA installation directory.

.EXAMPLE
    .\build.ps1
    # Full build: synthesis, placement, routing, bitstream generation

.EXAMPLE
    .\build.ps1 -Clean
    # Clean build directory and rebuild everything

.EXAMPLE
    .\build.ps1 -Target syn
    # Run logic synthesis only

.EXAMPLE
    .\build.ps1 -FlashMode flash -Flash
    # Build and write bitstream to Tang Console 60K persistent SPI Flash

.EXAMPLE
    .\build.ps1 -Flash sram
    # Build and load bitstream directly into Tang Console 60K SRAM

.EXAMPLE
    .\build.ps1 -NoBuild -Flash sram
    # Flash existing bitstream to SRAM without rebuilding

.EXAMPLE
    .\build.ps1 -Scan
    # Detect connected Tang Console 60K board and cables
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

# Flexible handling of -Flash and -FlashMode
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
Write-Host "   Sipeed Tang Console 60K - Gowin EDA Build Flow" -ForegroundColor Cyan
Write-Host "   Project: ProtocolEmulator" -ForegroundColor Cyan
Write-Host "   FPGA   : GW5AT-LV60PG484AC1/I0 (Arora V GW5AT-60B)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. Locate Gowin Installation
# -----------------------------------------------------------------------------
$SearchPaths = @()
if ($GowinPath) { $SearchPaths += $GowinPath }
if ($env:GOWIN_HOME) { $SearchPaths += $env:GOWIN_HOME }

# Common installation locations on Windows
$SearchPaths += @(
    "C:\Gowin\Gowin_V1.9.12_x64",
    "C:\Gowin\Gowin_V1.9.11_x64",
    "C:\Gowin\Gowin_V1.9.10_x64",
    "C:\Gowin\Gowin_V1.9.9_x64",
    "C:\Gowin\*"
)

$GwSh = $null
$ProgCli = $null

# Check PATH first
$PathGwSh = Get-Command "gw_sh.exe" -ErrorAction SilentlyContinue
if ($PathGwSh) {
    $GwSh = $PathGwSh.Source
}

if (-not $GwSh) {
    foreach ($path in $SearchPaths) {
        $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
        foreach ($r in $resolved) {
            $candidateGwSh = Join-Path $r.Path "IDE\bin\gw_sh.exe"
            if (Test-Path $candidateGwSh) {
                $GwSh = $candidateGwSh
                $candidateProg = Join-Path $r.Path "Programmer\bin\programmer_cli.exe"
                if (Test-Path $candidateProg) {
                    $ProgCli = $candidateProg
                }
                break
            }
        }
        if ($GwSh) { break }
    }
}

if (-not $ProgCli -and $GwSh) {
    $GowinRoot = Split-Path (Split-Path (Split-Path $GwSh))
    $candidateProg = Join-Path $GowinRoot "Programmer\bin\programmer_cli.exe"
    if (Test-Path $candidateProg) {
        $ProgCli = $candidateProg
    }
}

if (-not $GwSh) {
    Write-Host "[ERROR] Could not find Gowin EDA installation (gw_sh.exe)!" -ForegroundColor Red
    Write-Host "Please install Gowin EDA or specify -GowinPath <path_to_gowin>" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] Gowin Shell : $GwSh" -ForegroundColor Green
if ($ProgCli) {
    Write-Host "[OK] Programmer  : $ProgCli" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 2. Handle Scan Option
# -----------------------------------------------------------------------------
if ($Scan) {
    if (-not $ProgCli) {
        Write-Host "[ERROR] programmer_cli.exe not found!" -ForegroundColor Red
        exit 1
    }
    Write-Host "`nScanning for connected Gowin USB cables and devices..." -ForegroundColor Yellow
    & $ProgCli --scan-cables
    $CableArgs = @()
    if ($CableIndex -ge 0) { $CableArgs = @("--cable-index", $CableIndex) }
    elseif ($Cable) { $CableArgs = @("--cable", $Cable) }
    & $ProgCli @CableArgs --scan
    exit 0
}

# -----------------------------------------------------------------------------
# 3. Clean Build Artifacts
# -----------------------------------------------------------------------------
if ($Clean) {
    Write-Host "`nCleaning build artifacts..." -ForegroundColor Yellow
    $ImplDir = Join-Path $ScriptDir "impl"
    if (Test-Path $ImplDir) {
        Remove-Item -Recurse -Force $ImplDir
        Write-Host "[OK] Removed $ImplDir" -ForegroundColor Green
    }
    $UserFile = Join-Path $ScriptDir "console60k.gprj.user"
    if (Test-Path $UserFile) {
        Remove-Item -Force $UserFile
    }
}

# -----------------------------------------------------------------------------
# 4. Run Build Process
# -----------------------------------------------------------------------------
$BitstreamPath = Join-Path $ScriptDir "impl\pnr\console60k.fs"

if (-not $NoBuild) {
    $TclScript = Join-Path $ScriptDir "build.tcl"
    if (-not (Test-Path $TclScript)) {
        Write-Host "[ERROR] build.tcl not found at $TclScript" -ForegroundColor Red
        exit 1
    }

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "`n===> Starting Gowin Build Target: [$Target]..." -ForegroundColor Magenta
    & $GwSh $TclScript $Target

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[ERROR] Gowin build failed with exit code $LASTEXITCODE!" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    $Stopwatch.Stop()
    $Duration = [math]::Round($Stopwatch.Elapsed.TotalSeconds, 1)

    # -----------------------------------------------------------------------------
    # 5. Check Output Bitstream
    # -----------------------------------------------------------------------------
    if ($Target -eq "all") {
        if (Test-Path $BitstreamPath) {
            $FileSize = (Get-Item $BitstreamPath).Length
            $FileSizeKb = [math]::Round($FileSize / 1024, 1)
            Write-Host "`n============================================================" -ForegroundColor Green
            Write-Host "  BUILD SUCCESSFUL ($Duration s)" -ForegroundColor Green
            Write-Host "  Bitstream: $BitstreamPath ($FileSizeKb KB)" -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
        } else {
            Write-Host "`n[WARNING] Build finished but bitstream was not found at $BitstreamPath" -ForegroundColor Yellow
        }
    } else {
        Write-Host "`n[OK] Target '$Target' completed successfully ($Duration s)." -ForegroundColor Green
    }
} else {
    Write-Host "`n[INFO] Skipping build step (-NoBuild specified). Using existing bitstream." -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# 6. Flash Board (if requested)
# -----------------------------------------------------------------------------
if ($Flash) {
    if (-not $ProgCli) {
        Write-Host "`n[ERROR] programmer_cli.exe not found for programming!" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $BitstreamPath)) {
        Write-Host "`n[ERROR] Bitstream not found at $BitstreamPath! Run full build first." -ForegroundColor Red
        exit 1
    }

    $CableArgs = @()
    if ($CableIndex -ge 0) {
        $CableArgs = @("--cable-index", $CableIndex)
    } elseif ($Cable) {
        $CableArgs = @("--cable", $Cable)
    }

    $OpCode = 2
    if ($ProgMode -ge 0) {
        $OpCode = $ProgMode
    } elseif ($FlashMode -eq "sram") {
        # Mode 2: SRAM Program (volatile, instantaneous testing)
        $OpCode = 2
    } elseif ($FlashMode -eq "flash") {
        # Mode 53: exFlash Erase,Program Arora V (non-volatile, persistent SPI Flash)
        $OpCode = 53
    }

    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  Flashing Tang Console 60K (Mode: $FlashMode, OpCode: $OpCode)..." -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    & $ProgCli @CableArgs --device "GW5AT-60B" --run $OpCode --fsFile "$BitstreamPath"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n[SUCCESS] Tang Console 60K successfully programmed!" -ForegroundColor Green
    } else {
        Write-Host "`n[ERROR] Programming failed with code $LASTEXITCODE." -ForegroundColor Red
        exit $LASTEXITCODE
    }
}
