@echo off
setlocal
rem =============================================================================
rem  OmniBus Protocol Emulator - Load & Run 'Hello' Microcode
rem  Uploads examples\hello.asm to FPGA IMEM and opens the interactive terminal.
rem  Usage: run_hello.bat [--port COM19]
rem =============================================================================

python "%~dp0python\omnibus_loader.py" --file "%~dp0examples\hello.asm" --terminal %*
