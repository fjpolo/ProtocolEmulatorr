@echo off
setlocal
rem =============================================================================
rem  Task 18 - Asymmetric Single-Wire & Retro Physical Protocol Accelerators Demo
rem  Supports WS2812B NeoPixel LED strips, N64/GC Joybus, and NES/SNES Gamepads.
rem
rem  Usage:
rem    run_pulse_demo.bat                  - Interactive terminal (WS2812B NeoPixel demo)
rem    run_pulse_demo.bat interactive      - Same as above
rem    run_pulse_demo.bat nes              - Run NES Gamepad reader demo
rem    run_pulse_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_pulse_demo.bat test             - Alias for sim
rem    run_pulse_demo.bat formal           - Run SymbiYosys formal verification via WSL
rem    run_pulse_demo.bat dump             - Dump IMEM from FPGA
rem    run_pulse_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_pulse_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_pulse_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 18 - Asymmetric Pulse ^& Retro Protocol Accelerators
echo   WS2812B NeoPixel, N64 Joybus, ^& NES/SNES Gamepad Bus
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=interactive
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="interactive" (
    set MODE=interactive
    shift
    goto :setup_args
)
if /I "%ARG1%"=="neopixel" (
    set MODE=interactive
    shift
    goto :setup_args
)
if /I "%ARG1%"=="nes" (
    set MODE=nes
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
if /I "%ARG1%"=="formal" (
    set MODE=formal
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
set EXTRA_ARGS=
:collect_args
if "%~1"=="" goto :dispatch
set EXTRA_ARGS=%EXTRA_ARGS% %1
shift
goto :collect_args

:dispatch
if "%MODE%"=="flash"   goto :do_flash
if "%MODE%"=="build"   goto :do_build
if "%MODE%"=="dump"    goto :do_dump
if "%MODE%"=="sim"     goto :do_sim
if "%MODE%"=="formal"  goto :do_formal
if "%MODE%"=="nes"     goto :do_nes
goto :do_interactive

:do_interactive
set ASM_FILE=%~dp0examples\ws2812_rainbow_demo.asm
echo [*] Mode: Interactive Terminal (WS2812B NeoPixel Single-Wire Demo)
echo [*] Microcode: examples\ws2812_rainbow_demo.asm
echo [*] Hardware Features:
echo     - ASSIST PULSE_CFG, NEOPIXEL (800 kHz single-wire NRZ pulse accelerator)
echo     - MSB-first 24-bit GRB color packet serialization directly from OSR
echo     - Zero-overhead wire-speed timing (400ns/850ns bit 0, 800ns/450ns bit 1)
echo     - Hardware reset / latch generation (> 50us low)
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_nes
set ASM_FILE=%~dp0examples\nes_gamepad_reader.asm
echo [*] Mode: Interactive Terminal (NES Controller Reader Demo)
echo [*] Microcode: examples\nes_gamepad_reader.asm
echo [*] Hardware Features:
echo     - ASSIST GAMEPAD_CFG, ROLE=HOST, TYPE=NES
echo     - Autonomous LATCH pulse on Pin 2 (CS)
echo     - Autonomous 8-clock burst on Pin 1 (SCK)
echo     - Parallel button bit deserialization into ISR from Pin 0 (DATA)
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump IMEM from FPGA
python "%~dp0python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run Cocotb Simulation Tests via WSL...
call "%~dp0test_alu.bat" test
exit /b %ERRORLEVEL%

:do_formal
echo [*] Mode: Run SymbiYosys Formal Verification via WSL...
call "%~dp0test_alu.bat" formal
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming FPGA SRAM via Gowin Programmer...
call "%~dp0build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
