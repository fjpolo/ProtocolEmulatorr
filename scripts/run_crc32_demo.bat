@echo off
setlocal
rem =============================================================================
rem  Task 20 - Hardware CRC-32 (Ethernet FCS) & CRC-5 (USB Token) Engine Demo
rem  Supports IEEE 802.3 10BASE-T Ethernet FCS, USB 1.1 Token CRC-5, 4-byte readout,
rem  and residue verification.
rem
rem  Usage:
rem    run_crc32_demo.bat                  - Interactive terminal (Ethernet FCS demo)
rem    run_crc32_demo.bat interactive      - Same as above
rem    run_crc32_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_crc32_demo.bat test             - Alias for sim
rem    run_crc32_demo.bat dump             - Dump IMEM from FPGA
rem    run_crc32_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_crc32_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_crc32_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 20 - Hardware CRC-32 (Ethernet FCS) ^& CRC-5 Engine
echo   IEEE 802.3 FCS (0xEDB88320), USB 1.1 Token CRC-5 (0x14)
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
if /I "%ARG1%"=="ethernet" (
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
set ASM_FILE=%~dp0..\examples\ethernet_fcs_demo.asm
echo [*] Mode: Interactive Terminal (10BASE-T Ethernet Packet with Hardware FCS Demo)
echo [*] Microcode: examples\ethernet_fcs_demo.asm
echo [*] Hardware Features:
echo     - CRC_INIT ETHERNET (IEEE 802.3 32-bit FCS, reflected 0xEDB88320)
echo     - Single-cycle parallel 8-bit XOR tree calculation
echo     - CRC_READ_B0, B1, B2, B3 (4-byte readout into OSR and o_data)
echo     - 10BASE-T Manchester stream serialization (ASSIST MANCH, IEEE)
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump IMEM from FPGA
python "%~dp0..\python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run Cocotb Simulation Tests via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && cp ../../../../rtl/ProtocolEmulator.v . && source ~/oss-cad-suite/environment && TESTCASE=test_crc32_ethernet_calculation,test_crc32_ethernet_residue_check,test_crc5_usb_token_calculation,test_ethernet_packet_fcs_integration python3 testrunner_icarus.py && rm -f ProtocolEmulator.v"
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming FPGA SRAM via Gowin Programmer...
call "%~dp0..\build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0..\build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
