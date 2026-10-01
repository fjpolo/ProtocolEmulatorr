@echo off
setlocal
rem =============================================================================
rem  Task 35 - OmniBus MP: Multi-Core Symmetric Protocol Engine Demonstrator
rem  Configurable Core Topologies (NUM_CORES = 1, 2, 4)
rem  Shared Mailboxes, Atomic Spinlocks, Barrier Rendezvous, and Cascade Streaming.
rem
rem  Usage:
rem    run_multicore_demo.bat         - Run interactive full multi-core demonstrator
rem    run_multicore_demo.bat bridge  - Run Dual-Core UART-to-SPI Bridge demo
rem    run_multicore_demo.bat sync    - Run Dual-Core Mailbox & Barrier Sync demo
rem    run_multicore_demo.bat quad    - Run Quad-Core Pipelined Grid demo
rem    run_multicore_demo.bat sim     - Run Cocotb Multi-Core simulation test suite in WSL
rem    run_multicore_demo.bat compile - Compile all Omni-C Multi-Core examples
rem =============================================================================

echo ============================================================================
echo   OmniBus MP: Multi-Core Symmetric Protocol Engine Demonstrator
echo   Target: Configurable 1, 2, or 4 Autonomous Execution Slices
echo ============================================================================
echo.

set TARGET=%~1
if "%TARGET%"=="" set TARGET=all

if /I "%TARGET%"=="bridge" (
    python python\multicore_demo.py --demo bridge
    goto :end
)
if /I "%TARGET%"=="sync" (
    python python\multicore_demo.py --demo sync
    goto :end
)
if /I "%TARGET%"=="quad" (
    python python\multicore_demo.py --demo quad
    goto :end
)
if /I "%TARGET%"=="sim" (
    python python\multicore_demo.py --demo sim
    goto :end
)
if /I "%TARGET%"=="test" (
    python python\multicore_demo.py --demo sim
    goto :end
)
if /I "%TARGET%"=="compile" (
    echo [*] Compiling all Omni-C and Assembly Multi-Core Targets...
    python python\omnic.py examples\omnic\dual_core_bridge.c -o examples\omnic\dual_core_bridge.asm --hex examples\omnic\dual_core_bridge.hex
    python python\omnic.py examples\omnic\dual_core_mailbox_sync.c -o examples\omnic\dual_core_mailbox_sync.asm --hex examples\omnic\dual_core_mailbox_sync.hex
    python python\omnic.py examples\omnic\quad_core_grid.c -o examples\omnic\quad_core_grid.asm --hex examples\omnic\quad_core_grid.hex
    python python\omnibus_asm.py examples\multicore_uart_spi_bridge.asm -o examples\multicore_uart_spi_bridge.hex
    python python\omnibus_asm.py examples\multicore_mailbox_sync.asm -o examples\multicore_mailbox_sync.hex
    python python\omnibus_asm.py examples\multicore_quad_grid.asm -o examples\multicore_quad_grid.hex
    echo [+] All Multi-Core Targets Compiled Successfully!
    goto :end
)

rem Default: Run full demonstrator
python python\multicore_demo.py --demo all

:end
echo.
echo ============================================================================
echo   Demonstration Complete!
echo ============================================================================
