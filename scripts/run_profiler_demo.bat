@echo off
setlocal
rem =============================================================================
rem  Task 27 - The Protocol Detective: Autonomous Waveform Profiler ^& Auto-Baud
rem  Features 16-bit transition timer (20 ns resolution @ 50 MHz), minimum pulse
rem  width discovery (t_min_high, t_min_low, t_min baud divisor), idle polarity
rem  detector, clock symmetry discriminator, and framing signature recognition.
rem
rem  Usage:
rem    run_profiler_demo.bat             - Interactive terminal on FPGA (Auto-Baud / Profiler demo)
rem    run_profiler_demo.bat profiler    - Interactive terminal on FPGA (Auto-Baud / Profiler demo)
rem    run_profiler_demo.bat interactive - Interactive terminal on FPGA (Auto-Baud / Profiler demo)
rem    run_profiler_demo.bat sim         - Run Task 27 Cocotb testcases via WSL
rem    run_profiler_demo.bat test        - Alias for sim
rem    run_profiler_demo.bat uart        - Run UART Auto-Baud test in WSL
rem    run_profiler_demo.bat clock       - Run Clock vs Data Discrimination test in WSL
rem    run_profiler_demo.bat i2c         - Run I2C Framing Signature test in WSL
rem    run_profiler_demo.bat wb          - Run Wishbone Profiler Register test in WSL
rem    run_profiler_demo.bat all         - Run complete ProtocolEmulator + Wishbone test suite
rem    run_profiler_demo.bat dump        - Dump IMEM from FPGA
rem    run_profiler_demo.bat flash       - Program bitstream into FPGA SRAM via Gowin
rem    run_profiler_demo.bat build       - Synthesize and build bitstream via Gowin EDA
rem    run_profiler_demo.bat --port COMx - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 27 - The Protocol Detective
echo   Autonomous Waveform Profiler ^& Auto-Baud Engine
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=profiler
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="profiler" (
    set MODE=profiler
    shift
    goto :setup_args
)
if /I "%ARG1%"=="autobaud" (
    set MODE=profiler
    shift
    goto :setup_args
)
if /I "%ARG1%"=="interactive" (
    set MODE=profiler
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
if /I "%ARG1%"=="uart" (
    set MODE=uart
    shift
    goto :setup_args
)
if /I "%ARG1%"=="clock" (
    set MODE=clock
    shift
    goto :setup_args
)
if /I "%ARG1%"=="i2c" (
    set MODE=i2c
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
if exist "%~dp0python\omnibus_asm.py" (
    set "ROOT_DIR=%~dp0"
) else (
    set "ROOT_DIR=%~dp0..\"
)
set DEMO_HEX=%ROOT_DIR%examples\profiler_autobaud_demo.hex
set DEMO_ASM=%ROOT_DIR%examples\profiler_autobaud_demo.asm

if "%MODE%"=="uart" (
    echo [RUN] Running UART Auto-Baud Profiler Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_profiler_autobaud_uart python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="clock" (
    echo [RUN] Running Clock vs Data Discrimination Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_profiler_clock_discrimination python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="i2c" (
    echo [RUN] Running I2C Framing Signature Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_profiler_i2c_signature python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="wb" (
    echo [RUN] Running Wishbone Profiler Register Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_profiler_registers python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="all" (
    echo [RUN] Running Full ProtocolEmulator and Wishbone Test Suites...
    call "%~dp0test_alu.bat"
    call "%~dp0test_wishbone.bat"
    goto :done
)

if "%MODE%"=="sim" (
    echo [RUN] Running Task 27 Profiler Testcases in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_profiler_autobaud_uart,test_profiler_clock_discrimination,test_profiler_i2c_signature python3 testrunner_icarus.py"
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_profiler_registers python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="build" (
    echo [RUN] Running Gowin bitstream synthesis and PnR...
    call "%ROOT_DIR%build_console60k.bat"
    goto :done
)

if "%MODE%"=="flash" (
    echo [RUN] Programming FPGA SRAM with OmniBus bitstream...
    call "%ROOT_DIR%flash_task06.bat"
    goto :done
)

if "%MODE%"=="dump" (
    echo [RUN] Dumping IMEM from device...
    call "%ROOT_DIR%load_microcode.bat" --dump %EXTRA_ARGS%
    goto :done
)

if "%MODE%"=="profiler" (
    echo [ASM] Assembling %DEMO_ASM%...
    python "%ROOT_DIR%python\omnibus_asm.py" "%DEMO_ASM%" -o "%DEMO_HEX%"
    if errorlevel 1 (
        echo [ERROR] Assembly failed!
        exit /b 1
    )
    echo [LOAD] Loading %DEMO_ASM% into OmniBus IMEM and launching Interactive Console Terminal...
    echo [*] Interactive Terminal Instructions:
    echo     - Send characters or unknown serial traffic on Pin 0 (UART RX).
    echo     - Profiler autonomously measures t_min, idle polarity, and checks for periodic clock.
    echo     - Once converged, prints [DATA] / [CLOCK], status byte, t_min baud divisor, and edge count.
    echo     - Microcode then enters real-time echo loop using the discovered baud timing.
    echo.
    python "%ROOT_DIR%python\omnibus_loader.py" --file "%DEMO_ASM%" --terminal %EXTRA_ARGS%
    goto :done
)

:done
endlocal
