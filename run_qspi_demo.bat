@echo off
setlocal
rem =============================================================================
rem  Task 24 - Quad-SPI & Multi-Lane Flash/PSRAM Hardware Host Controller Demo
rem  Features autonomous command phase, 24/32-bit address serialization,
rem  configurable dummy cycles (0..15), high-speed stream read/write across
rem  Single (1-bit), Dual (2-bit), Quad (4-bit), and Octal (8-bit) bus lanes.
rem
rem  Usage:
rem    run_qspi_demo.bat                  - Interactive terminal (Quad Fast Read demo)
rem    run_qspi_demo.bat qspi             - Interactive terminal (Quad Fast Read demo)
rem    run_qspi_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_qspi_demo.bat test             - Alias for sim
rem    run_qspi_demo.bat dump             - Dump IMEM from FPGA
rem    run_qspi_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_qspi_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_qspi_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 24 - Quad-SPI ^& Multi-Lane Flash/PSRAM Host Controller
echo   Single (1b) / Dual (2b) / Quad (4b) / Octal (8b) Modes
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=qspi
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="qspi" (
    set MODE=qspi
    shift
    goto :setup_args
)
if /I "%ARG1%"=="interactive" (
    set MODE=qspi
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
set DEMO_HEX=%~dp0examples\qspi_flash_read_demo.hex
set DEMO_ASM=%~dp0examples\qspi_flash_read_demo.asm

if "%MODE%"=="sim" (
    echo [RUN] Running Task 24 QSPI Simulation Tests in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_qspi_quad_fast_read_w25q,test_qspi_dual_read,test_qspi_quad_write_stream,test_qspi_octal_transfer python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="build" (
    echo [RUN] Running Gowin bitstream synthesis and PnR...
    call "%~dp0build_gowin.bat"
    goto :done
)

if "%MODE%"=="flash" (
    echo [RUN] Programming FPGA SRAM with OmniBus bitstream...
    call "%~dp0flash_task06.bat"
    goto :done
)

if "%MODE%"=="dump" (
    echo [RUN] Dumping IMEM from device...
    call "%~dp0load_microcode.bat" --dump %EXTRA_ARGS%
    goto :done
)

if "%MODE%"=="qspi" (
    echo [ASM] Assembling %DEMO_ASM%...
    python "%~dp0python\omnibus_asm.py" "%DEMO_ASM%" -o "%DEMO_HEX%"
    if errorlevel 1 (
        echo [ERROR] Assembly failed!
        exit /b 1
    )
    echo [LOAD] Loading %DEMO_HEX% into OmniBus IMEM...
    call "%~dp0load_microcode.bat" "%DEMO_HEX%" %EXTRA_ARGS%
    goto :done
)

:done
endlocal
