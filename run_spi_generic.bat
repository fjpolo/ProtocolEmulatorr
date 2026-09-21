@echo off
setlocal
rem =============================================================================
rem  Task 07B - Generic SPI Loopback using OUT SCK + PULL + 'D' data command
rem
rem  Usage:
rem    run_spi_generic.bat                    - load spi_generic.asm only
rem    run_spi_generic.bat 0xA5               - load + send byte 0xA5
rem    run_spi_generic.bat 0x3C 5000000       - load + 0x3C at 5 MHz SPI
rem    run_spi_generic.bat 0xFF 1000000       - load + 0xFF at 1 MHz SPI
rem
rem  After loading, repeatedly call:
rem    python python\omnibus_loader.py --spi-data 0xA5
rem  to push new bytes without reloading the program.
rem
rem  LED mapping (after each SPI transfer):
rem    LED[7]   = CS_n active indicator (flashes during transfer)
rem    LED[6]   = SCK visible
rem    LED[4:0] = received byte[4:0] (loopback = sent byte[4:0])
rem
rem  SPI clock rate: 50MHz / (2*(baud_div+1))
rem    Default:  115200 baud equiv -> SCK ~8.64 us period
rem    1 MHz:    --set-baud 1000000  -> SCK 1 us period
rem    5 MHz:    --set-baud 5000000  -> SCK 200 ns period
rem =============================================================================

echo ============================================================
echo   Task 07B - Generic SPI Loopback (OUT SCK + PULL)
echo ============================================================

set ASM_FILE=%~dp0examples\spi_generic.asm
set DATA_BYTE=%~1
set SPI_HZ=%~2

if "%DATA_BYTE%"=="" (
    echo [*] Loading spi_generic.asm (no data byte specified)
    python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%"
) else if "%SPI_HZ%"=="" (
    echo [*] Loading spi_generic.asm and sending byte %DATA_BYTE%...
    python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --spi-data %DATA_BYTE%
) else (
    echo [*] Loading spi_generic.asm, SPI at %SPI_HZ% Hz, byte %DATA_BYTE%...
    python "%~dp0python\omnibus_loader.py" --set-baud %SPI_HZ% --file "%ASM_FILE%" --spi-data %DATA_BYTE%
)

exit /b %ERRORLEVEL%
