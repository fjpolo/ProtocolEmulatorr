@echo off
setlocal
rem =============================================================================
rem  Task 22 - 1-Bit Delta-Sigma Audio DAC & Chiptune PDM Synthesizer Engine Demo
rem  Features 50 MHz 1st-order Delta-Sigma (Σ-Δ) PDM modulator (OSR=1250x),
rem  4-voice chiptune APU synthesizer, hardware preset sound effects,
rem  and single-cycle direct PCM streaming (OUT AUDIO).
rem
rem  Usage:
rem    run_audio_demo.bat                  - Interactive terminal (chiptune audio demo)
rem    run_audio_demo.bat interactive      - Same as above
rem    run_audio_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_audio_demo.bat test             - Alias for sim
rem    run_audio_demo.bat dump             - Dump IMEM from FPGA
rem    run_audio_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_audio_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_audio_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 22 - 1-Bit Delta-Sigma Audio DAC ^& Chiptune PDM Engine
echo   50 MHz 1st-Order Modulator, 4-Voice APU ^& Hardware SFX
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
goto :do_interactive

:do_interactive
set ASM_FILE=%~dp0examples\chiptune_audio_demo.asm
echo [*] Mode: Interactive Terminal (Chiptune APU Synthesizer ^& PDM DAC Demo)
echo [*] Microcode: examples\chiptune_audio_demo.asm
echo [*] Hardware Audio Engine Features:
echo     - 50 MHz 1st-Order Delta-Sigma (Σ-Δ) PDM Modulator (OSR = 1250x)
echo     - Single-ended and differential BTL output on GPIO pins
echo     - 4-Voice APU Synthesizer (Pulse 1, Pulse 2, Triangle, LFSR Noise)
echo     - Hardware Sound Effects: BEEP, BLIP, ERROR, COIN, LASER, SIREN, NOISE
echo     - Direct PCM DAC Streaming via single-cycle OUT AUDIO / IN AUDIO
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump IMEM from FPGA
python "%~dp0python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run Cocotb Simulation Tests via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && source ~/oss-cad-suite/environment && TESTCASE=test_audio_pdm_linear_dac,test_audio_out_pcm_streaming,test_audio_chiptune_square_tone,test_audio_sound_effect_presets python3 testrunner_icarus.py"
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming FPGA SRAM via Gowin Programmer...
call "%~dp0build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
