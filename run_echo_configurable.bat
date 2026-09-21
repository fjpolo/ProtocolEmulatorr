@echo off
setlocal
rem =============================================================================
rem  Task 06 - Run Configurable-Baud Echo on Tang Console 60K
rem  Loads echo_configurable.asm ($BAUD tokens) and optionally sets the
rem  runtime baud rate via OmniBootloader's 'B' (SetBaud) command.
rem
rem  Usage:
rem    run_echo_configurable.bat                    - Load at default 115200 baud
rem    run_echo_configurable.bat 57600              - Switch core to 57600 baud
rem    run_echo_configurable.bat 230400             - Switch core to 230400 baud
rem    run_echo_configurable.bat 9600               - Switch core to 9600 baud
rem
rem  Supported baud rates @ 50 MHz clock:
rem    921600  (div=53)   460800  (div=107)  230400  (div=216)
rem    115200  (div=433)   57600  (div=867)   38400 (div=1301)
rem     19200 (div=2603)    9600 (div=5207)
rem
rem  After loading, the interactive terminal opens at the HOST baud rate
rem  (always 115200 for the UART control link). The CORE echoes at the
rem  rate set by --set-baud, so reconnect your terminal app at that rate.
rem =============================================================================

echo ============================================================
echo   Task 06 - Configurable-Baud Echo Transceiver
echo ============================================================

set ASM_FILE=%~dp0examples\echo_configurable.asm
set BAUD_ARG=

if "%~1"=="" (
    echo [*] No baud rate specified — using default 115200 baud
    python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --terminal
) else (
    echo [*] Setting core to %~1 baud, then loading echo_configurable.asm...
    echo.
    echo NOTE: After the core is programmed, reconnect your terminal at %~1 baud.
    echo       The OmniBootloader control link remains at 115200 baud.
    echo.
    python "%~dp0python\omnibus_loader.py" --set-baud %~1 --file "%ASM_FILE%" --terminal
)

exit /b %ERRORLEVEL%
