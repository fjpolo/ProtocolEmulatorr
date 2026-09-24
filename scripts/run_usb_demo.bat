@echo off
setlocal
rem =============================================================================
rem  Task 17 - Autonomous Stream Accelerators Demo (NRZI & Bit-Stuffer)
rem  Assembles and uploads USB 1.1 packet demo microcode via omnibus_loader.py,
rem  or runs Cocotb simulation and formal verification suites.
rem
rem  Usage:
rem    run_usb_demo.bat                  - Interactive terminal (USB stream accelerator demo)
rem    run_usb_demo.bat interactive      - Same as above
rem    run_usb_demo.bat sim              - Run 43 Cocotb simulation tests via WSL
rem    run_usb_demo.bat test             - Alias for sim
rem    run_usb_demo.bat formal           - Run SymbiYosys formal verification via WSL
rem    run_usb_demo.bat dump             - Dump IMEM from FPGA
rem    run_usb_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_usb_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_usb_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 17 - Autonomous Stream Accelerators Demo
echo   NRZI Encoding/Decoding ^& Hardware Bit-Stuffer/De-stuffer
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
if /I "%ARG1%"=="formal" (
    set MODE=formal
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
if "%MODE%"=="flash"   goto :do_flash
if "%MODE%"=="build"   goto :do_build
if "%MODE%"=="dump"    goto :do_dump
if "%MODE%"=="sim"     goto :do_sim
if "%MODE%"=="formal"  goto :do_formal
goto :do_interactive

:do_interactive
set ASM_FILE=%~dp0..\examples\usb_packet_demo.asm
echo [*] Mode: Interactive Terminal (USB 1.1 Autonomous Stream Demo)
echo [*] Microcode: examples\usb_packet_demo.asm
echo [*] Hardware Stream Features:
echo     - ASSIST CFG (Opcode 0xF): NRZI=1, STUFF=USB (Run of 6 ones stuffed with '0')
echo     - Autonomous SYNC field generation (0x80 -^> K-J-K-J-K-J-K-K NRZI waveform)
echo     - Autonomous PID field (DATA0: 0xC3)
echo     - Autonomous Bit-Stuffing on 0x7E payload byte
echo     - Hardware Bit-Stuff Violation Detection (JMP STUFF_ERR)
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump IMEM from FPGA
python "%~dp0..\python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run 43 Cocotb Simulation Tests via WSL...
call "%~dp0test_alu.bat" test
exit /b %ERRORLEVEL%

:do_formal
echo [*] Mode: Run SymbiYosys Formal Verification via WSL...
call "%~dp0test_alu.bat" formal
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming FPGA SRAM via Gowin Programmer...
call "%~dp0..\build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0..\build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
