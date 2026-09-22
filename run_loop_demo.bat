@echo off
setlocal
rem =============================================================================
rem  Task 09 - Run Hardware Loop Counter Demo on Tang Console 60K
rem  Loads loop_countdown.asm to demonstrate zero-overhead hardware loop counters.
rem
rem  Usage:
rem    run_loop_demo.bat              - Load loop_countdown.asm
rem    run_loop_demo.bat burst        - Load spi_burst.asm
rem =============================================================================

echo ============================================================
echo   Task 09 - Hardware Loop Counter (LC0/LC1 + DJNZ)
echo ============================================================

set DEMO_MODE=%~1

if "%DEMO_MODE%"=="burst" goto :run_burst

:run_countdown
set ASM_FILE=%~dp0examples\loop_countdown.asm
echo [*] Loading loop_countdown.asm (Nested LC1/LC0 countdown demo)...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%"
exit /b %ERRORLEVEL%

:run_burst
set ASM_FILE=%~dp0examples\spi_burst.asm
echo [*] Loading spi_burst.asm (4-byte SPI burst demo)...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --spi-data 0x55
exit /b %ERRORLEVEL%
