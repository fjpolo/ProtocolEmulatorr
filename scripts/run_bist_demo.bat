@echo off
setlocal
rem =============================================================================
rem  Task 29 - On-Chip Self-Play & Virtual Crossbar (BIST Engine)
rem  Autonomous self-verification, internal virtual crossbar routing,
rem  hardware score telemetry, and real-time LED visualizer.
rem
rem  Usage:
rem    run_bist_demo.bat             - Assemble and run BIST self-play program on FPGA
rem    run_bist_demo.bat run         - Assemble and run BIST self-play program on FPGA
rem    run_bist_demo.bat sim         - Run Task 29 Cocotb testcases via WSL
rem    run_bist_demo.bat test        - Alias for sim
rem    run_bist_demo.bat direct      - Run Direct Virtual Crossbar test in WSL
rem    run_bist_demo.bat split       - Run Split Dual-Channel Crossbar test in WSL
rem    run_bist_demo.bat score       - Run BIST Error Scoring & Reset test in WSL
rem    run_bist_demo.bat wb          - Run Wishbone BIST Register test in WSL
rem    run_bist_demo.bat all         - Run complete ProtocolEmulator + Wishbone test suite (98 tests)
rem    run_bist_demo.bat flash       - Program bitstream into FPGA SRAM via Gowin
rem    run_bist_demo.bat build       - Synthesize and build bitstream via Gowin EDA
rem    run_bist_demo.bat --port COMx - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 29 - On-Chip Self-Play ^& Virtual Crossbar (BIST)
echo   Autonomous Silicon Self-Test ^& Real-Time LED Scoring
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=run
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="run" (
    set MODE=run
    shift
    goto :setup_args
)
if /I "%ARG1%"=="bist" (
    set MODE=run
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
if /I "%ARG1%"=="direct" (
    set MODE=direct
    shift
    goto :setup_args
)
if /I "%ARG1%"=="split" (
    set MODE=split
    shift
    goto :setup_args
)
if /I "%ARG1%"=="score" (
    set MODE=score
    shift
    goto :setup_args
)
if /I "%ARG1%"=="wb" (
    set MODE=wb
    shift
    goto :setup_args
)
if /I "%ARG1%"=="all" (
    set MODE=all
    shift
    goto :setup_args
)
if /I "%ARG1%"=="build" (
    set MODE=build
    shift
    goto :setup_args
)
if /I "%ARG1%"=="flash" (
    set MODE=flash
    shift
    goto :setup_args
)

:setup_args
set ROOT_DIR=%~dp0..
set SCRIPT_DIR=%~dp0
set ASM_SRC=%ROOT_DIR%\examples\bist_self_play.asm
set HEX_OUT=%ROOT_DIR%\examples\bist_self_play.hex

rem Mode-specific branches
if /I "%MODE%"=="sim" goto :run_sim
if /I "%MODE%"=="direct" goto :run_direct
if /I "%MODE%"=="split" goto :run_split
if /I "%MODE%"=="score" goto :run_score
if /I "%MODE%"=="wb" goto :run_wb
if /I "%MODE%"=="all" goto :run_all
if /I "%MODE%"=="build" goto :run_build
if /I "%MODE%"=="flash" goto :run_flash
if /I "%MODE%"=="run" goto :run_fpga

:run_sim
echo [*] Running Task 29 BIST Cocotb testcases via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && TESTCASE=test_bist_virtual_crossbar_direct,test_bist_channel_split_crossbar,test_bist_error_scoring_and_reset python3 testrunner_icarus.py"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo [*] Running Wishbone BIST register test...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && source ~/oss-cad-suite/environment && TESTCASE=test_wb_bist_registers python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_direct
echo [*] Running Direct Crossbar Loopback Cocotb test via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && TESTCASE=test_bist_virtual_crossbar_direct python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_split
echo [*] Running Split Dual-Channel Crossbar Cocotb test via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && TESTCASE=test_bist_channel_split_crossbar python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_score
echo [*] Running BIST Error Scoring & Reset Cocotb test via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && TESTCASE=test_bist_error_scoring_and_reset python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_wb
echo [*] Running Wishbone BIST Registers Cocotb test via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && source ~/oss-cad-suite/environment && TESTCASE=test_wb_bist_registers python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_all
echo [*] Running complete 98-test regression suite (ProtocolEmulator + Wishbone)...
echo [*] 1/2: ProtocolEmulator suite (84 tests)...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && python3 testrunner_icarus.py"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo.
echo [*] 2/2: Wishbone SoC suite (14 tests)...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && source ~/oss-cad-suite/environment && python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_build
echo [*] Building Tang Console 60K Bitstream via Gowin EDA...
call "%ROOT_DIR%\build_console60k.bat" -Target all
exit /b %ERRORLEVEL%

:run_flash
echo [*] Flashing bitstream to Tang Console 60K SRAM...
call "%ROOT_DIR%\build_console60k.bat" -Flash sram
exit /b %ERRORLEVEL%

:run_fpga
echo [*] Step 1: Assembling %ASM_SRC%...
python -m python.omnibus_asm "%ASM_SRC%" -o "%HEX_OUT%"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Assembly failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [*] Step 2: Uploading BIST Self-Play microcode into FPGA IMEM...
python python/omnibus_bootloader.py --hex "%HEX_OUT%" %*
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Upload failed! Check FPGA USB connection.
    exit /b %ERRORLEVEL%
)

echo.
echo ============================================================
echo   BIST Self-Play Active on Silicon!
echo   Observing real-time validation scoring on onboard LEDs:
echo     LED 7   : BIST Sticky Error Flag (Red / Fail)
echo     LED 6..4: Test Stage Index (1..4)
echo     LED 3   : BIST Engine Active (Running)
echo     LED 2..0: Virtual Crossbar Real-Time Activity
echo ============================================================
exit /b 0
