@echo off
setlocal
rem =============================================================================
rem  Task 14 - Wishbone B4 Slave SoC Wrapper & FIFO Test Runner
rem
rem  Usage:
rem    test_wishbone.bat         - Run 5 Wishbone Cocotb simulation tests
rem    test_wishbone.bat formal  - Run FIFO formal verification (bound, prf, cvr)
rem    test_wishbone.bat all     - Run Wishbone simulation + FIFO formal
rem =============================================================================

echo ============================================================
echo   Task 14 - Wishbone B4 Slave Wrapper ^& FIFO Subsystem
echo ============================================================

set MODE=%~1

if /I "%MODE%"=="formal" goto :run_formal
if /I "%MODE%"=="all" goto :run_all

:run_sim
echo [*] Running Wishbone B4 Cocotb simulation suite via WSL...
echo     - test_wb_reg_access
echo     - test_wb_imem_programming
echo     - test_wb_tx_streaming
echo     - test_wb_rx_streaming
echo     - test_wb_irq_watermarks
echo.
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && source ~/oss-cad-suite/environment && python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_formal
echo [*] Running SymbiYosys FIFO formal verification (bound, prf, cvr) via WSL...
echo.
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/formal/FIFO && chmod +x run.sh && ./run.sh"
exit /b %ERRORLEVEL%

:run_all
echo [*] Step 1: Running Wishbone simulation tests...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && source ~/oss-cad-suite/environment && python3 testrunner_icarus.py"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo.
echo [*] Step 2: Running FIFO formal verification...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/formal/FIFO && chmod +x run.sh && ./run.sh"
exit /b %ERRORLEVEL%
