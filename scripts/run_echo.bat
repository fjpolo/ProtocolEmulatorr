@echo off
setlocal
rem =============================================================================
rem  OmniBus Protocol Emulator - Load & Run 'Echo' Microcode
rem  Uploads examples\echo.asm to FPGA IMEM and opens the interactive terminal.
rem  Usage: run_echo.bat [--port COM19]
rem =============================================================================

python "%~dp0..\python\omnibus_loader.py" --file "%~dp0..\examples\echo.asm" --terminal %*
