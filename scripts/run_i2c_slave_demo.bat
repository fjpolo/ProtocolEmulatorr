@echo off
setlocal
rem =============================================================================
rem  Task 21 - Dedicated Hardware I2C / SMBus Slave Engine Demo
rem  Supports autonomous address match & auto-ACK, clock stretching,
rem  and microcode slave receive/transmit.
rem
rem  Usage:
rem    run_i2c_slave_demo.bat                  - Interactive terminal (EEPROM slave demo)
rem    run_i2c_slave_demo.bat interactive      - Same as above
rem    run_i2c_slave_demo.bat sim              - Run Cocotb simulation tests via WSL
rem    run_i2c_slave_demo.bat test             - Alias for sim
rem    run_i2c_slave_demo.bat dump             - Dump IMEM from FPGA
rem    run_i2c_slave_demo.bat flash            - Program bitstream into FPGA SRAM via Gowin
rem    run_i2c_slave_demo.bat build            - Synthesize and build bitstream via Gowin EDA
rem    run_i2c_slave_demo.bat --port COMx      - Specify custom COM port
rem =============================================================================

echo ============================================================
echo   Task 21 - Dedicated Hardware I2C / SMBus Slave Engine
echo   Autonomous Address Recognition, Auto-ACK ^& Clock Stretch
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
set ASM_FILE=%~dp0..\examples\i2c_slave_eeprom_demo.asm
echo [*] Mode: Interactive Terminal (24C02 I2C Slave EEPROM Emulator Demo)
echo [*] Microcode: examples\i2c_slave_eeprom_demo.asm
echo [*] Hardware Features:
echo     - I2C_SLAVE_CFG 0x50, STRETCH=1 (7-bit address match, auto-ACK)
echo     - IN SLAVE (8-bit data reception on SCL, auto-ACK on 9th clock)
echo     - OUT SLAVE (8-bit data transmission from OSR, samples master ACK)
echo     - Hardware clock stretching (holding SCL low until I2C_RELEASE_SCL)
echo     - Extended JMP condition codes (I2C_MATCH, I2C_READ, I2C_WRITE, I2C_ACK)
echo [*] Assembling and uploading to FPGA IMEM over UART...
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --terminal %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_dump
echo [*] Mode: Readback and Dump IMEM from FPGA
python "%~dp0..\python\omnibus_loader.py" --dump %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_sim
echo [*] Mode: Run Cocotb Simulation Tests via WSL...
wsl bash -c "cd /mnt/c/Workspace/ASIC/ProtocolEmulator/test_rtl/simulation/cocotb/ProtocolEmulator && cp ../../../../rtl/ProtocolEmulator.v . && source ~/oss-cad-suite/environment && TESTCASE=test_i2c_slave_address_match_and_auto_ack,test_i2c_slave_address_nack_on_mismatch,test_i2c_slave_write_receive_flow,test_i2c_slave_read_transmit_and_clock_stretch python3 testrunner_icarus.py && rm -f ProtocolEmulator.v"
exit /b %ERRORLEVEL%

:do_flash
echo [*] Programming FPGA SRAM via Gowin Programmer...
call "%~dp0..\build_console60k.bat" -Flash sram %EXTRA_ARGS%
exit /b %ERRORLEVEL%

:do_build
echo [*] Running full Gowin synthesis ^& place-and-route build flow...
call "%~dp0..\build_console60k.bat" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
