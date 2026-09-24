@echo off
setlocal
rem =============================================================================
rem  Task 13 - Hardware CRC Generator & Checksum Accelerator Test Runner
rem  Runs the Cocotb simulation suite in WSL with Icarus Verilog.
rem
rem  Usage:
rem    test_crc.bat         - Run 4 Hardware CRC tests (fast, ~0.15s)
rem    test_crc.bat all     - Run complete 31-test regression suite
rem    test_crc.bat formal  - Run SymbiYosys formal verification (bound, prf, cvr)
rem =============================================================================

echo ============================================================
echo   Task 13 - Hardware CRC Generator ^& Checksum Accelerator
echo ============================================================

set MODE=%~1

if /I "%MODE%"=="formal" goto :run_formal
if /I "%MODE%"=="all" goto :run_all

:run_crc_only
echo [*] Running 4 Hardware CRC accelerator testcases via WSL...
echo     - test_crc8_dallas_calculation
echo     - test_crc8_smbus_pec
echo     - test_crc16_modbus_and_ccitt
echo     - test_crc_jmp_conditional
echo.
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && cp ../../../../rtl/ProtocolEmulator.v . && source ~/oss-cad-suite/environment && TESTCASE=test_crc8_dallas_calculation,test_crc8_smbus_pec,test_crc16_modbus_and_ccitt,test_crc_jmp_conditional python3 testrunner_icarus.py && rm -f ProtocolEmulator.v"
exit /b %ERRORLEVEL%

:run_all
echo [*] Running all 31 regression testcases via WSL...
echo.
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && cp ../../../../rtl/ProtocolEmulator.v . && source ~/oss-cad-suite/environment && python3 testrunner_icarus.py && rm -f ProtocolEmulator.v"
exit /b %ERRORLEVEL%

:run_formal
echo [*] Running SymbiYosys formal verification (bound, prf, cvr) via WSL...
echo.
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/formal/ProtocolEmulator && source ~/oss-cad-suite/environment && ./run.sh"
exit /b %ERRORLEVEL%
