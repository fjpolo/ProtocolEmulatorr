@echo off
setlocal
rem =============================================================================
rem  Task 15 - 8-bit Micro-ALU & Arithmetic Engine Test Runner
rem
rem  Usage:
rem    test_alu.bat         - Run 35 Cocotb simulation tests (including 4 ALU tests)
rem    test_alu.bat formal  - Run engine formal verification (bound, prf, cvr)
rem    test_alu.bat all     - Run both simulation and formal verification suites
rem =============================================================================

echo ============================================================
echo   Task 15 - 8-bit Micro-ALU ^& Arithmetic Engine (Opcode 0xB)
echo ============================================================

set MODE=%~1

if /I "%MODE%"=="formal" goto :run_formal
if /I "%MODE%"=="all" goto :run_all

:run_sim
echo [*] Running 35 Cocotb simulation tests (Tasks 01-15) via WSL...
echo     - test_alu_arithmetic_and_flags
echo     - test_alu_logic_and_shifts
echo     - test_alu_register_transfers
echo     - test_alu_packet_parser
echo.
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:run_formal
echo [*] Running SymbiYosys formal verification (bound, prf, cvr) via WSL...
echo.
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/formal/ProtocolEmulator && chmod +x run.sh && ./run.sh"
exit /b %ERRORLEVEL%

:run_all
echo [*] Step 1: Running Cocotb simulation suite (35 tests)...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && python3 testrunner_icarus.py"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo.
echo [*] Step 2: Running formal verification (bound, prf, cvr)...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/formal/ProtocolEmulator && chmod +x run.sh && ./run.sh"
exit /b %ERRORLEVEL%
