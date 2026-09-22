@echo off
setlocal
rem =============================================================================
rem  Task 15 - Run Hardware Micro-ALU Demo on Tang Console 60K FPGA
rem  Loads ALU microcode programs into FPGA IMEM via omnibus_loader.py
rem  or builds/programs the FPGA bitstream via Gowin EDA.
rem
rem  Usage:
rem    run_alu_demo.bat                  - Interactive terminal (echo & uppercase conversion)
rem    run_alu_demo.bat interactive      - Same as above
rem    run_alu_demo.bat selftest         - Autonomous on-chip ALU arithmetic self-test
rem    run_alu_demo.bat packet           - Packet parser & validator microcode demo
rem    run_alu_demo.bat dump             - Dump 32-word IMEM contents from FPGA
rem    run_alu_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_alu_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_alu_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 15 - OmniBus 8-bit Micro-ALU Hardware Test
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=interactive
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="interactive" (
    set MODE=interactive
    shift
    goto :setup_args
)
if /I "%ARG1%"=="selftest" (
    set MODE=selftest
    shift
    goto :setup_args
)
if /I "%ARG1%"=="self" (
    set MODE=selftest
    shift
    goto :setup_args
)
if /I "%ARG1%"=="packet" (
    set MODE=packet
    shift
    goto :setup_args
)
if /I "%ARG1%"=="dump" (
    set MODE=dump
    shift
    goto :setup_args
)
if /I "%ARG1%"=="flash" (
    set MODE=flash
    shift
    goto :setup_args
)
if /I "%ARG1%"=="build" (
    set MODE=build
    shift
    goto :setup_args
)

:setup_args
set EXTRA_ARGS=
:collect_args
if "%~1"=="" goto :dispatch
set EXTRA_ARGS=%EXTRA_ARGS% %1
shift
goto :collect_args

:dispatch
if "%MODE%"=="flash" goto :do_flash
if "%MODE%"=="build" goto :do_build
if "%MODE%"=="dump"  goto :do_dump
if "%MODE%"=="packet" goto :do_packet
if "%MODE%"=="selftest" goto :do_selftest
goto :do_interactive

:do_interactive
set ASM_FILE=%~dp0examples\alu_interactive.asm
echo [*] Mode: Interactive Terminal (Echo ^& Micro-ALU Uppercase Conversion)
echo [*] Microcode: examples\alu_interactive.asm
echo [*] Assembling and uploading to FPGA IMEM over UART...
echo [*] Type text in the terminal:
echo     - 'a'..'z' are converted in hardware to 'A'..'Z' via CMP + SUB acc, 0x20
echo     - Digits and symbols are echoed as-is
echo [*] Press Ctrl+C or Ctrl+] to exit terminal.
echo.
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_selftest
set ASM_FILE=%~dp0examples\alu_selftest.asm
echo [*] Mode: Autonomous Hardware ALU Self-Test
echo [*] Microcode: examples\alu_selftest.asm
echo [*] Exercises Micro-ALU: ADD, SUB, AND, INC, SHL, CMP, Flags
echo [*] Assembling and uploading to FPGA IMEM over UART...
echo [*] Launching monitor terminal:
echo     - Continuous 'OK' stream indicates all ALU tests PASS
echo     - 'E' stream indicates test failure
echo [*] Press Ctrl+C or Ctrl+] to exit terminal.
echo.
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_packet
set ASM_FILE=%~dp0examples\packet_parser_demo.asm
echo [*] Mode: Autonomous Packet Parser ^& Validator
echo [*] Microcode: examples\packet_parser_demo.asm
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump FPGA IMEM (32 words)
python "%~dp0python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming Tang Console 60K SRAM via Gowin Programmer...
call "%~dp0build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
