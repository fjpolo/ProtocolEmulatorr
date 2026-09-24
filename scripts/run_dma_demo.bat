@echo off
setlocal
rem =============================================================================
rem  Task 26 - OmniBus DMA Scatter-Gather Controller & Host Memory Streamer
rem  Features 32-bit Wishbone B4 Master interface, Dual-Channel TX/RX engines,
rem  16-byte Scatter-Gather linked-list descriptor parser & write-back telemetry,
rem  arbitrated memory streaming, and host interrupt signaling.
rem
rem  Usage:
rem    run_dma_demo.bat                  - Run all DMA Cocotb testcases via WSL
rem    run_dma_demo.bat sim              - Run DMA Cocotb testcases via WSL
rem    run_dma_demo.bat test             - Alias for sim
rem    run_dma_demo.bat tx               - Run DMA Linear TX simulation test
rem    run_dma_demo.bat rx               - Run DMA Linear RX simulation test
rem    run_dma_demo.bat sg               - Run DMA Scatter-Gather chain simulation test
rem    run_dma_demo.bat irq              - Run DMA Interrupt & Abort simulation test
rem    run_dma_demo.bat all              - Run complete Wishbone + DMA test suite
rem =============================================================================

echo ============================================================
echo   Task 26 - OmniBus DMA Scatter-Gather Controller
echo   32-bit Wishbone B4 Master Host Memory Streamer
echo   Target: Dual-Channel High-Throughput Memory Subsystem
echo ============================================================

set MODE=sim
set "ARG1=%~1"

if "%ARG1%"=="" goto :run
if /I "%ARG1%"=="sim" ( set MODE=sim & goto :run )
if /I "%ARG1%"=="test" ( set MODE=sim & goto :run )
if /I "%ARG1%"=="tx" ( set MODE=tx & goto :run )
if /I "%ARG1%"=="rx" ( set MODE=rx & goto :run )
if /I "%ARG1%"=="sg" ( set MODE=sg & goto :run )
if /I "%ARG1%"=="irq" ( set MODE=irq & goto :run )
if /I "%ARG1%"=="all" ( set MODE=all & goto :run )

:run
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

echo [RUN] Running Task 26 DMA Testcases in WSL...
wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_dma_linear_tx,test_wb_dma_linear_rx,test_wb_dma_scatter_gather_chain,test_wb_dma_irq_and_abort python3 testrunner_icarus.py"

:done
endlocal
