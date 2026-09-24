@echo off
setlocal
rem =============================================================================
rem  Task 26 - OmniBus DMA Scatter-Gather Controller & Host Memory Streamer Demo
rem  Features 32-bit Wishbone B4 Master interface, Dual-Channel TX/RX engines,
rem  16-byte Scatter-Gather linked-list descriptor parser & write-back telemetry,
rem  arbitrated memory streaming, and host interrupt signaling.
rem
rem  Usage:
rem    run_dma_demo.bat                  - Interactive terminal on FPGA (DMA Stream demo)
rem    run_dma_demo.bat dma              - Interactive terminal on FPGA (DMA Stream demo)
rem    run_dma_demo.bat interactive      - Interactive terminal on FPGA (DMA Stream demo)
rem    run_dma_demo.bat sim              - Run all DMA Cocotb testcases via WSL
rem    run_dma_demo.bat test             - Alias for sim
rem    run_dma_demo.bat tx               - Run DMA Linear TX simulation test
rem    run_dma_demo.bat rx               - Run DMA Linear RX simulation test
rem    run_dma_demo.bat sg               - Run DMA Scatter-Gather chain simulation test
rem    run_dma_demo.bat irq              - Run DMA Interrupt & Abort simulation test
rem    run_dma_demo.bat all              - Run complete Wishbone + DMA test suite
rem    run_dma_demo.bat dump             - Dump IMEM from FPGA
rem    run_dma_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_dma_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_dma_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 26 - OmniBus DMA Scatter-Gather Controller
echo   32-bit Wishbone B4 Master Host Memory Streamer
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=dma
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="dma" (
    set MODE=dma
    shift
    goto :setup_args
)
if /I "%ARG1%"=="stream" (
    set MODE=dma
    shift
    goto :setup_args
)
if /I "%ARG1%"=="interactive" (
    set MODE=dma
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
if /I "%ARG1%"=="tx" (
    set MODE=tx
    shift
    goto :setup_args
)
if /I "%ARG1%"=="rx" (
    set MODE=rx
    shift
    goto :setup_args
)
if /I "%ARG1%"=="sg" (
    set MODE=sg
    shift
    goto :setup_args
)
if /I "%ARG1%"=="irq" (
    set MODE=irq
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
set DEMO_HEX=%ROOT_DIR%examples\dma_stream_demo.hex
set DEMO_ASM=%ROOT_DIR%examples\dma_stream_demo.asm

if "%MODE%"=="tx" (
    echo [RUN] Running DMA Linear TX Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_dma_linear_tx python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="rx" (
    echo [RUN] Running DMA Linear RX Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_dma_linear_rx python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="sg" (
    echo [RUN] Running DMA Scatter-Gather Linked-List Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_dma_scatter_gather_chain python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="irq" (
    echo [RUN] Running DMA Interrupt and Abort Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_dma_irq_and_abort python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="all" (
    echo [RUN] Running All 11 Wishbone and DMA Tests in WSL...
    call "%~dp0test_wishbone.bat"
    goto :done
)

if "%MODE%"=="sim" (
    echo [RUN] Running Task 26 DMA Testcases in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_dma_linear_tx,test_wb_dma_linear_rx,test_wb_dma_scatter_gather_chain,test_wb_dma_irq_and_abort python3 testrunner_icarus.py"
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

if "%MODE%"=="dma" (
    echo [ASM] Assembling %DEMO_ASM%...
    python "%ROOT_DIR%python\omnibus_asm.py" "%DEMO_ASM%" -o "%DEMO_HEX%"
    if errorlevel 1 (
        echo [ERROR] Assembly failed!
        exit /b 1
    )
    echo [LOAD] Loading %DEMO_ASM% into OmniBus IMEM and launching Interactive Console Terminal...
    echo [*] Interactive Terminal Instructions:
    echo     - Type any text: characters stream through FIFO and echo back over UART.
    echo     - Press Enter: core confirms packet transfer with ' [DMA OK]'.
    echo     - Press '!': core generates a continuous high-speed burst pattern.
    echo.
    python "%ROOT_DIR%python\omnibus_loader.py" --file "%DEMO_ASM%" --terminal %EXTRA_ARGS%
    goto :done
)

:done
endlocal
