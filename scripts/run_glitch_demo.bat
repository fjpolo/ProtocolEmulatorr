@echo off
setlocal
rem =============================================================================
rem  Task 25 - Hardware Glitch / Fault Injection & Wire-Speed MitM Fuzzing Engine Demo
rem  Features sub-cycle precision crowbar pulse generation (1..255 cycles),
rem  16-bit countdown delay (0..65535 cycles), selectable pin & polarity,
rem  autonomous wire-speed pattern matching & payload substitution.
rem
rem  Usage:
rem    run_glitch_demo.bat                  - Interactive terminal (Glitch & MitM demo)
rem    run_glitch_demo.bat glitch           - Interactive terminal (Glitch & MitM demo)
rem    run_glitch_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_glitch_demo.bat test             - Alias for sim
rem    run_glitch_demo.bat dump             - Dump IMEM from FPGA
rem    run_glitch_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_glitch_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_glitch_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 25 - Hardware Glitch / Fault Injection ^& MitM Engine
echo   Sub-Cycle Precision Crowbar Pulse ^& Wire Fuzzing
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=glitch
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="glitch" (
    set MODE=glitch
    shift
    goto :setup_args
)
if /I "%ARG1%"=="mitm" (
    set MODE=glitch
    shift
    goto :setup_args
)
if /I "%ARG1%"=="interactive" (
    set MODE=glitch
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
set "EXTRA_ARGS="
:collect_args
if "%~1"=="" goto :dispatch
set "EXTRA_ARGS=%EXTRA_ARGS% %1"
shift
goto :collect_args

:dispatch
set DEMO_HEX=%~dp0..\examples\glitch_fault_demo.hex
set DEMO_ASM=%~dp0..\examples\glitch_fault_demo.asm

if "%MODE%"=="sim" (
    echo [RUN] Running Task 25 Glitch ^& MitM Simulation Tests in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_glitch_pattern_match_trigger,test_glitch_manual_software_trigger,test_mitm_wire_speed_byte_substitution python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="build" (
    echo [RUN] Running Gowin bitstream synthesis and PnR...
    call "%~dp0..\build_console60k.bat"
    goto :done
)

if "%MODE%"=="flash" (
    echo [RUN] Programming FPGA SRAM with OmniBus bitstream...
    call "%~dp0..\flash_task06.bat"
    goto :done
)

if "%MODE%"=="dump" (
    echo [RUN] Dumping IMEM from device...
    call "%~dp0..\load_microcode.bat" --dump %EXTRA_ARGS%
    goto :done
)

if "%MODE%"=="glitch" (
    echo [ASM] Assembling %DEMO_ASM%...
    python "%~dp0..\python\omnibus_asm.py" "%DEMO_ASM%" -o "%DEMO_HEX%"
    if errorlevel 1 (
        echo [ERROR] Assembly failed!
        exit /b 1
    )
    echo [LOAD] Loading %DEMO_ASM% into OmniBus IMEM and launching Interactive Console Terminal...
    echo [*] Interactive Terminal Instructions:
    echo     - Type any text: characters are echoed back over UART.
    echo     - Type '!': character is MUTATED to '*' on-the-fly!
    echo     - A 5-clock-cycle [100 ns] crowbar glitch pulse fires on GPIO 4!
    echo     - Core prints ' [G]' to confirm hardware glitch execution.
    echo.
    python "%~dp0..\python\omnibus_loader.py" --file "%DEMO_ASM%" --terminal %EXTRA_ARGS%
    goto :done
)

:done
endlocal
