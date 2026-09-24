@echo off
setlocal
rem =============================================================================
rem  Task 23 - Dedicated Hardware JTAG TAP Controller & ARM SWD Sequencer Demo
rem  Features IEEE 1149.1 16-State JTAG TAP FSM, autonomous TMS sequencer,
rem  ARM ADIv5 SWD packet engine (8-bit REQ, Trn, 3-bit ACK, 32-bit RD/WR),
rem  54-clock line reset, 0xE79E switching, and RISC-V DTM + ARM CoreSight support.
rem
rem  Usage:
rem    run_jtag_swd_demo.bat                  - Interactive terminal (RISC-V JTAG IDCODE demo)
rem    run_jtag_swd_demo.bat jtag             - Interactive terminal (RISC-V JTAG IDCODE demo)
rem    run_jtag_swd_demo.bat swd              - Interactive terminal (ARM SWD Debug demo)
rem    run_jtag_swd_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_jtag_swd_demo.bat test             - Alias for sim
rem    run_jtag_swd_demo.bat dump             - Dump IMEM from FPGA
rem    run_jtag_swd_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_jtag_swd_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_jtag_swd_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 23 - JTAG TAP Controller ^& ARM SWD Hardware Sequencer
echo   Supporting RISC-V DTM (v0.13/v1.0) ^& ARM CoreSight (ADIv5)
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=jtag
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="jtag" (
    set MODE=jtag
    shift
    goto :setup_args
)
if /I "%ARG1%"=="swd" (
    set MODE=swd
    shift
    goto :setup_args
)
if /I "%ARG1%"=="interactive" (
    set MODE=jtag
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
if "%MODE%"=="swd"     goto :do_swd
goto :do_jtag

:do_jtag
set ASM_FILE=%~dp0..\examples\jtag_riscv_idcode_demo.asm
echo [*] Mode: Interactive Terminal (RISC-V JTAG DTM IDCODE Scan Demo)
echo [*] Microcode: examples\jtag_riscv_idcode_demo.asm
echo [*] Pinout: Pin 0=TDI, Pin 1=TCK, Pin 2=TMS, Pin 3=TDO
echo [*] Features:
echo     - IEEE 1149.1 16-State JTAG TAP FSM
echo     - Autonomous multi-clock TMS Navigation (JTAG_NAV RESET, IDLE, SHIFT_DR)
echo     - 1-to-8 bit Data Register shifts with auto-Exit1-DR (JTAG_SHIFT)
echo     - Extended Conditional Branching (JMP JTAG_IDLE)
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_swd
set ASM_FILE=%~dp0..\examples\swd_arm_debug_demo.asm
echo [*] Mode: Interactive Terminal (ARM CoreSight / RP2350 SWD Probe Demo)
echo [*] Microcode: examples\swd_arm_debug_demo.asm
echo [*] Pinout: Pin 0=SWDIO (Bidirectional data), Pin 1=SWCLK (Clock out)
echo [*] Features:
echo     - Autonomous 54-clock Line Reset ^& 16-bit JTAG-to-SWD 0xE79E Switching
echo     - 8-bit Request Packet generation with Even Parity
echo     - Automatic Bus Turnaround (Trn) ^& 3-bit Target ACK Sampling
echo     - 32-bit Data Phase (SWD_RD32 / SWD_WR32) with Parity Verification
echo     - Extended Conditional Branching (JMP SWD_OK, JMP SWD_WAIT, JMP SWD_FAULT)
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump IMEM from FPGA
python "%~dp0..\python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run Cocotb Simulation Tests via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && TESTCASE=test_jtag_tap_reset_and_navigation,test_jtag_riscv_idcode_scan,test_swd_line_reset_and_switching,test_swd_request_and_ack_sampling python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming FPGA SRAM via Gowin Programmer...
call "%~dp0..\build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0..\build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
