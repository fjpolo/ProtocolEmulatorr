@echo off
setlocal
rem =============================================================================
rem  Task 06 - Build Bitstream (Gowin Synthesis + PnR)
rem  Synthesizes the Task 06 RTL (ProtocolEmulator + OmniBootloader with
rem  runtime-configurable baud rate) for the Sipeed Tang Console 60K.
rem
rem  Usage:
rem    build_task06.bat              - Synthesize and generate bitstream
rem    build_task06.bat --clean      - Clean build first, then synthesize
rem
rem  Output: boards\sipeed\console60k\impl\pnr\console60k.fs
rem =============================================================================

echo ============================================================
echo   Task 06 Build - Runtime Baud Rate (Gowin / Console 60K)
echo ============================================================

if /i "%~1"=="--clean" (
    echo [*] Cleaning previous build...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0boards\sipeed\console60k\build.ps1" -Clean -Target all
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0boards\sipeed\console60k\build.ps1" -Target all
)

exit /b %ERRORLEVEL%
