@echo off
setlocal
rem =============================================================================
rem  Task 16 - Run 128-Word IMEM & Bank Switching Demo on Tang Console 60K FPGA
rem  Assembles and uploads 4-Bank, 128-word microcode via omnibus_loader.py,
rem  or builds/programs the FPGA bitstream via Gowin EDA.
rem
rem  Usage:
rem    run_imem_demo.bat                  - Interactive terminal (4-bank service demo)
rem    run_imem_demo.bat interactive      - Same as above
rem    run_imem_demo.bat dump             - Dump all 128 IMEM words (Banks 0..3) from FPGA
rem    run_imem_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_imem_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_imem_demo.bat sim              - Run 38 Cocotb simulation tests via WSL
rem    run_imem_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 16 - OmniBus 128-Word IMEM ^& 4-Bank Switching Demo
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
if /I "%ARG1%"=="sim" (
    set MODE=sim
    shift
    goto :setup_args
)
if /I "%ARG1%"=="test" (
    set MODE=sim
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
if "%MODE%"=="sim"   goto :do_sim
goto :do_interactive

:do_interactive
set ASM_FILE=%~dp0..\examples\imem_128_demo.asm
echo [*] Mode: Interactive Terminal (4-Bank Multi-Service Protocol Demo)
echo [*] Microcode: examples\imem_128_demo.asm (48 instructions across 4 banks)
echo [*] Memory Partitioning:
echo     - Bank 0 (0x00..0x1F): Command Dispatcher ^& UART Master Loop
echo     - Bank 1 (0x20..0x3F): Uppercase Converter Service (Micro-ALU)
echo     - Bank 2 (0x40..0x5F): Dallas CRC-8 Verification Service (Polynomial 0x31)
echo     - Bank 3 (0x60..0x7F): Telemetry ^& Status Output Service ('OK\n')
echo [*] Assembling and uploading to FPGA IMEM over UART...
echo [*] Type commands in the terminal:
echo     - '1' + character: Calls Bank 1 service (converts lowercase to uppercase)
echo     - '2' + character: Calls Bank 2 service (computes and echoes Dallas CRC-8)
echo     - Any other key:   Calls Bank 3 service (transmits 'OK\n')
echo [*] Press Ctrl+C or Ctrl+] to exit terminal.
echo.
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump 128-word IMEM across all 4 Banks
python "%~dp0..\python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run 38 Cocotb Simulation Tests via WSL...
call "%~dp0test_alu.bat" test
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming Tang Console 60K SRAM via Gowin Programmer...
call "%~dp0..\build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0..\build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
