@echo off
setlocal
rem =============================================================================
rem  Task 10 - Full-Duplex SPI Master Transceiver (Simultaneous MOSI/MISO)
rem
rem  Usage:
rem    run_spi_full_duplex.bat                    - load spi_full_duplex.asm only
rem    run_spi_full_duplex.bat 0xA5               - load + send 0xA5
rem    run_spi_full_duplex.bat 0x3C 5000000       - load + 0x3C @ 5 MHz SPI
rem =============================================================================

echo ============================================================
echo   Task 10 - Full-Duplex SPI Master Transceiver
echo ============================================================

set ASM_FILE=%~dp0examples\spi_full_duplex.asm
set DATA_BYTE=%~1
set SPI_HZ=%~2

if "%DATA_BYTE%"=="" goto :no_data

if "%SPI_HZ%"=="" goto :with_byte

rem ---- 2 args: byte + SPI clock rate ----
echo [*] Loading spi_full_duplex.asm, SPI at %SPI_HZ% Hz, byte %DATA_BYTE%...
python "%~dp0python\omnibus_loader.py" --set-baud %SPI_HZ% --file "%ASM_FILE%" --spi-data %DATA_BYTE%
exit /b %ERRORLEVEL%

:with_byte
rem ---- 1 arg: byte only ----
echo [*] Loading spi_full_duplex.asm with default timing, byte %DATA_BYTE%...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" --spi-data %DATA_BYTE%
exit /b %ERRORLEVEL%

:no_data
rem ---- no args: program only ----
echo [*] Using default timing (i_baud_div=433, SCK half-period = 8.68 us
echo [*] Loading %ASM_FILE%...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%"
if %ERRORLEVEL% NEQ 0 (
    echo [FAIL] Upload failed.
    exit /b %ERRORLEVEL%
)
echo [OK] Full-duplex SPI microcode active.
exit /b 0
