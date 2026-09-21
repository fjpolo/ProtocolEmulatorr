@echo off
setlocal
rem =============================================================================
rem  Task 07 - Run SPI Mode 0 Loopback on Tang Console 60K
rem  Loads spi_loopback.asm and optionally sets the SPI clock rate.
rem
rem  Usage:
rem    run_spi_loopback.bat                   - SPI at ~216 kHz (div=433/$HBAUD)
rem    run_spi_loopback.bat 1000000           - SPI at ~1 MHz (div=49)
rem    run_spi_loopback.bat 5000000           - SPI at ~5 MHz (div=9)
rem    run_spi_loopback.bat 10000000          - SPI at ~10 MHz (div=4)
rem
rem  SPI clock rate (baud_div controls SCK half-period):
rem    SCK_Hz = 50_000_000 / (2 * (baud_div + 1))
rem
rem  After loading, o_data on LEDs [4:0] should show 0b00101 (= 0xA5 & 0x1F = 5).
rem  LED[7] = CS_n active (flashes during each SPI frame)
rem  LED[6] = SCK toggling (LED blinks at SPI clock rate)
rem
rem  For an external SPI slave device connection:
rem    MOSI: FPGA PMOD2 pin for spi_mosi
rem    SCK:  FPGA PMOD2 pin for spi_sck
rem    CS_n: FPGA PMOD2 pin for spi_cs_n
rem    MISO: Currently looped internally - edit top.v to wire an external input.
rem =============================================================================

echo ============================================================
echo   Task 07 - SPI Mode 0 Loopback
echo ============================================================

set ASM_FILE=%~dp0examples\spi_loopback.asm

if "%~1"=="" (
    echo [*] Using default timing (i_baud_div=433, SCK half-period = 8.68 us)
    python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%"
) else (
    echo [*] Setting SPI clock to approximately %~1 Hz...
    python "%~dp0python\omnibus_loader.py" --set-baud %~1 --file "%ASM_FILE%"
)

exit /b %ERRORLEVEL%
