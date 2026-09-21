@echo off
setlocal
rem =============================================================================
rem  Task 06 - Flash Bitstream to Tang Console 60K
rem  Programs the Task 06 bitstream to external SPI Flash (persistent across
rem  power cycles) via Gowin Programmer.
rem
rem  Usage:
rem    flash_task06.bat              - Flash existing bitstream (persistent SPI Flash)
rem    flash_task06.bat --sram       - Load to SRAM only (fast, volatile)
rem    flash_task06.bat --build      - Build first, then flash
rem
rem  Requires: Gowin IDE (programmer) to be installed and USB cable connected.
rem =============================================================================

echo ============================================================
echo   Task 06 Flash - Runtime Baud Rate (Console 60K)
echo ============================================================

set FLASH_MODE=flash

if /i "%~1"=="--sram" (
    set FLASH_MODE=sram
    shift
)

if /i "%~1"=="--build" (
    echo [*] Building first...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0boards\sipeed\console60k\build.ps1" -Target all
    if errorlevel 1 (
        echo [ERROR] Build failed. Aborting flash.
        exit /b 1
    )
)

echo [*] Flashing to Tang Console 60K (mode: %FLASH_MODE%)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0boards\sipeed\console60k\build.ps1" -Flash -FlashMode %FLASH_MODE% -NoBuild

exit /b %ERRORLEVEL%
