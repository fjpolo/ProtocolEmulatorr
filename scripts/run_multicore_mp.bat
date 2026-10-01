@echo off
rem ============================================================================
rem Script Name: run_multicore_mp.bat
rem Description: Compiles and executes the OmniBus MP Multi-Core Test Suite
rem              (1, 2, and 4 Cores) using Cocotb and Icarus Verilog via WSL.
rem ============================================================================

echo ============================================================================
echo   OmniBus MP: Multi-Core Symmetric Protocol Engine Test Runner
echo   Targeting Configurable Core Topologies (NUM_CORES = 1, 2, 4)
echo ============================================================================
echo.

wsl -e bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator && python3 test_rtl/simulation/cocotb/Wishbone/testrunner_multicore_mp.py"

if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] OmniBus MP Multi-Core Simulation FAILED!
    exit /b %ERRORLEVEL%
)

echo.
echo ============================================================================
echo   OmniBus MP Multi-Core Verification PASSED! (100%% Success)
echo ============================================================================
