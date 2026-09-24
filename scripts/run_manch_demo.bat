@echo off
setlocal
rem =============================================================================
rem  Task 19 - Autonomous Manchester / Biphase Mark Stream Accelerator Demo
rem  Supports 10BASE-T Ethernet (IEEE 802.3), Thomas, BMC / FM0 / FM1, S/PDIF, DALI.
rem
rem  Usage:
rem    run_manch_demo.bat                  - Interactive terminal (10BASE-T Ethernet demo)
rem    run_manch_demo.bat interactive      - Same as above
rem    run_manch_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_manch_demo.bat test             - Alias for sim
rem    run_manch_demo.bat formal           - Run SymbiYosys formal verification via WSL
rem    run_manch_demo.bat dump             - Dump IMEM from FPGA
rem    run_manch_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_manch_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_manch_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 19 - Autonomous Manchester / BMC Stream Accelerator
echo   10BASE-T Ethernet, Thomas, BMC, FM0/FM1, S/PDIF ^& DALI
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
if /I "%ARG1%"=="ethernet" (
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
set ASM_FILE=%~dp0..\examples\ethernet_10baset_demo.asm
echo [*] Mode: Interactive Terminal (10BASE-T Ethernet Packet Demo)
echo [*] Microcode: examples\ethernet_10baset_demo.asm
echo [*] Hardware Features:
echo     - ASSIST MANCH, IEEE (10BASE-T Manchester stream accelerator)
echo     - Autonomous 2-phase serialization with center transition
echo     - Half-bit clock delay resolution (eff_hdelay = eff_delay ^>^> 1)
echo     - Code violation detection and JMP MANCH_ERR branching
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump IMEM from FPGA
python "%~dp0..\python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run Cocotb Simulation Tests via WSL...
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
