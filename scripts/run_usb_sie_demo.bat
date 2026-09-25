@echo off
setlocal
rem =============================================================================
rem  Task 28 - USB 1.1 Autonomous Serial Interface Engine (SIE)
rem  Autonomous packet validation, SYNC/PID check, address & endpoint filtering,
rem  hardware CRC-5 and CRC-16 calculation, automatic ACK/NAK/STALL handshaking,
rem  and bus reset detection.
rem
rem  Usage:
rem    run_usb_sie_demo.bat             - Interactive terminal on FPGA (USB SIE demo)
rem    run_usb_sie_demo.bat sie         - Interactive terminal on FPGA (USB SIE demo)
rem    run_usb_sie_demo.bat interactive - Interactive terminal on FPGA (USB SIE demo)
rem    run_usb_sie_demo.bat sim         - Run Task 28 Cocotb testcases via WSL
rem    run_usb_sie_demo.bat test        - Alias for sim
rem    run_usb_sie_demo.bat token       - Run Token RX test in WSL
rem    run_usb_sie_demo.bat ack         - Run Auto-ACK test in WSL
rem    run_usb_sie_demo.bat reset       - Run Bus Reset test in WSL
rem    run_usb_sie_demo.bat wb          - Run Wishbone USB Register test in WSL
rem    run_usb_sie_demo.bat all         - Run complete ProtocolEmulator + Wishbone test suite
rem    run_usb_sie_demo.bat dump        - Dump IMEM from FPGA
rem    run_usb_sie_demo.bat flash       - Program bitstream into FPGA SRAM via Gowin
rem    run_usb_sie_demo.bat build       - Synthesize and build bitstream via Gowin EDA
rem    run_usb_sie_demo.bat --port COMx - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 28 - USB 1.1 Autonomous Serial Interface Engine
echo   Autonomous Packet Filter, CRC Checker ^& Handshake Engine
echo   Target: Sipeed Tang Console 60K (GW5AT-LV60PG484AC1)
echo ============================================================

set MODE=sie
set "ARG1=%~1"

if "%ARG1%"=="" goto :setup_args
if "%ARG1:~0,1%"=="-" goto :setup_args

if /I "%ARG1%"=="sie" (
    set MODE=sie
    shift
    goto :setup_args
)
if /I "%ARG1%"=="usb" (
    set MODE=sie
    shift
    goto :setup_args
)
if /I "%ARG1%"=="interactive" (
    set MODE=sie
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
if /I "%ARG1%"=="token" (
    set MODE=token
    shift
    goto :setup_args
)
if /I "%ARG1%"=="ack" (
    set MODE=ack
    shift
    goto :setup_args
)
if /I "%ARG1%"=="reset" (
    set MODE=reset
    shift
    goto :setup_args
)
if /I "%ARG1%"=="wb" (
    set MODE=wb
    shift
    goto :setup_args
)
if /I "%ARG1%"=="all" (
    set MODE=all
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
set ROOT_DIR=%~dp0..\
set DEMO_ASM=%ROOT_DIR%examples\usb_sie_demo.asm
set DEMO_HEX=%ROOT_DIR%examples\usb_sie_demo.hex

set EXTRA_ARGS=
:parse_flags
if "%~1"=="" goto :execute
if /I "%~1"=="--port" (
    set "EXTRA_ARGS=%EXTRA_ARGS% --port %~2"
    shift
    shift
    goto :parse_flags
)
if /I "%~1"=="-p" (
    set "EXTRA_ARGS=%EXTRA_ARGS% -p %~2"
    shift
    shift
    goto :parse_flags
)
if /I "%~1"=="--baud" (
    set "EXTRA_ARGS=%EXTRA_ARGS% --baud %~2"
    shift
    shift
    goto :parse_flags
)
if /I "%~1"=="-b" (
    set "EXTRA_ARGS=%EXTRA_ARGS% -b %~2"
    shift
    shift
    goto :parse_flags
)
set "EXTRA_ARGS=%EXTRA_ARGS% %~1"
shift
goto :parse_flags

:execute
if "%MODE%"=="token" (
    echo [RUN] Running USB SIE Token Reception Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_usb_sie_token_rx python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="ack" (
    echo [RUN] Running USB SIE Auto-ACK Handshake Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_usb_sie_auto_ack python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="reset" (
    echo [RUN] Running USB Bus Reset Detection Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_usb_sie_bus_reset python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="wb" (
    echo [RUN] Running Wishbone USB SIE Register Test in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_usb_sie_registers python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="all" (
    echo [RUN] Running Full ProtocolEmulator and Wishbone Test Suites...
    call "%~dp0test_alu.bat"
    call "%~dp0test_wishbone.bat"
    goto :done
)

if "%MODE%"=="sim" (
    echo [RUN] Running Task 28 USB SIE Testcases in WSL...
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && TESTCASE=test_usb_sie_token_rx,test_usb_sie_auto_ack,test_usb_sie_bus_reset python3 testrunner_icarus.py"
    wsl bash -c "source /home/fpolo/oss-cad-suite/environment && cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/Wishbone && TESTCASE=test_wb_usb_sie_registers python3 testrunner_icarus.py"
    goto :done
)

if "%MODE%"=="build" (
    echo [RUN] Running Gowin bitstream synthesis and PnR...
    call "%ROOT_DIR%build_console60k.bat"
    goto :done
)

if "%MODE%"=="flash" (
    echo [RUN] Programming FPGA SRAM with OmniBus bitstream...
    call "%ROOT_DIR%flash_task06.bat"
    goto :done
)

if "%MODE%"=="dump" (
    echo [RUN] Dumping IMEM from device...
    call "%ROOT_DIR%load_microcode.bat" --dump %EXTRA_ARGS%
    goto :done
)

if "%MODE%"=="sie" (
    echo [ASM] Assembling %DEMO_ASM%...
    python "%ROOT_DIR%python\omnibus_asm.py" "%DEMO_ASM%" -o "%DEMO_HEX%"
    if errorlevel 1 (
        echo [ERROR] Assembly failed!
        exit /b 1
    )
    echo [LOAD] Loading %DEMO_ASM% into OmniBus IMEM and launching Interactive Console Terminal...
    echo [*] Interactive Terminal Instructions:
    echo     - Pin 0 = USB D+ (Full-Speed 12 Mbps / Low-Speed 1.5 Mbps)
    echo     - Pin 1 = USB D-
    echo     - The SIE autonomously detects bus reset, SYNC, validates PID complement,
    echo       filters tokens matching Device Address 5, and verifies CRC-5 and CRC-16.
    echo     - Autonomous ACK/NAK/STALL handshakes are generated with microsecond response.
    echo.
    python "%ROOT_DIR%python\omnibus_loader.py" --file "%DEMO_ASM%" --terminal %EXTRA_ARGS%
    goto :done
)

:done
endlocal
