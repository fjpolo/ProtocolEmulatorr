@echo off
setlocal
rem =============================================================================
rem  OmniBus Protocol Emulator - Microcode Loader Wrapper
rem  Usage: load_microcode.bat [path\to\program.asm] [--terminal]
rem =============================================================================

if "%~1"=="" (
    echo Usage: load_microcode.bat path\to\program.asm [--terminal]
    echo Example: load_microcode.bat examples\hello.asm --terminal
    exit /b 1
)

python "%~dp0python\omnibus_loader.py" --file "%~1" %2 %3 %4
