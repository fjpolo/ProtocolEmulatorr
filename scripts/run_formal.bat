@echo off
setlocal
rem =============================================================================
rem  Task 30 - Formal Verification Suite (SymbiYosys / SVA) Runner
rem  Proves Section 7.1 of CONCEPT.md:
rem    1. FIFO Formal Invariants (bound, prf, cvr)
rem    2. Open-Drain Bus-Safety & No-Contention Invariants
rem    3. Wishbone B4 Slave Handshake & Liveness Invariants
rem    4. Deterministic Timing & Zero-Jitter Invariants
rem    5. Hardware Call Stack & Loop Counter Invariants
rem    6. Micro-ALU & CRC Accelerator Invariants
rem    7. Glitch Generator & MitM Pattern Matcher Invariants
rem    8. Virtual Crossbar & Autonomous BIST Invariants
rem =============================================================================

echo ============================================================
echo   Task 30 - SymbiYosys Formal Verification Suite
echo   Mathematical Proofs of Zero-Jitter ^& Silicon Safety
echo ============================================================
echo.

set SUITE=%~1
if "%SUITE%"=="" set SUITE=all

wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/formal && chmod +x run_all.sh && ./run_all.sh %SUITE%"
exit /b %ERRORLEVEL%
