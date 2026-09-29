@echo off
setlocal
rem =============================================================================
rem  Task 31 - OmniBus Web IDE & Silicon Emulator Launcher
rem =============================================================================

echo ============================================================
echo   OmniBus Studio: Web IDE ^& Silicon Emulator (Task 31)
echo   Opening interactive IDE in browser...
echo ============================================================
echo.

cd /d "%~dp0\..\web_ide"

start "" "http://localhost:8080/index.html"
python -m http.server 8080
