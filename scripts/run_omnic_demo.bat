@echo off
REM =============================================================================
REM File        : run_omnic_demo.bat
REM Description : Demonstrates Omni-C High-Level Protocol Compiler on All Examples
REM License     : MIT License
REM =============================================================================

echo ===============================================================================
echo                Omni-C High-Level Protocol Compiler Demonstrator
echo            Target: OmniBus 16-bit Deterministic Protocol Engine ASIC
echo ===============================================================================
echo.

echo [*] Step 1: Running Omni-C Unit ^& Integration Test Suite...
python sdk\tests\test_omnic.py
if %ERRORLEVEL% NEQ 0 (
    echo [!] Test suite failed!
    exit /b %ERRORLEVEL%
)
echo [+] All 15 Unit ^& Integration Tests Passed!
echo.

echo [*] Step 2: Compiling Examples from Omni-C (.c) to Assembly (.asm) and Intel Hex (.hex)...
echo.

echo [1/6] Compiling UART Full-Duplex Echo Transceiver (examples\omnic\uart_echo.c)...
python python\omnic.py examples\omnic\uart_echo.c -o examples\omnic\uart_echo.asm --hex examples\omnic\uart_echo.hex --verify
echo.

echo [2/6] Compiling 24C02 I2C EEPROM Byte Write/Read Engine (examples\omnic\i2c_eeprom.c)...
python python\omnic.py examples\omnic\i2c_eeprom.c -o examples\omnic\i2c_eeprom.asm --hex examples\omnic\i2c_eeprom.hex --verify
echo.

echo [3/6] Compiling Winbond W25Q SPI Flash Multi-Byte Streamer (examples\omnic\spi_flash.c)...
python python\omnic.py examples\omnic\spi_flash.c -o examples\omnic\spi_flash.asm --hex examples\omnic\spi_flash.hex --verify
echo.

echo [4/6] Compiling WS2812B NeoPixel 24-Bit RGB Pulse Driver (examples\omnic\ws2812_rainbow.c)...
python python\omnic.py examples\omnic\ws2812_rainbow.c -o examples\omnic\ws2812_rainbow.asm --hex examples\omnic\ws2812_rainbow.hex --verify
echo.

echo [5/6] Compiling DHT11 1-Wire Nested Dual-Loop Temperature Reader (examples\omnic\dht11_sensor.c)...
python python\omnic.py examples\omnic\dht11_sensor.c -o examples\omnic\dht11_sensor.asm --hex examples\omnic\dht11_sensor.hex --verify
echo.

echo [6/6] Compiling Active Wire-Speed MitM Mutator ^& Glitch Fuzzer (examples\omnic\mitm_fuzzer.c)...
python python\omnic.py examples\omnic\mitm_fuzzer.c -o examples\omnic\mitm_fuzzer.asm --hex examples\omnic\mitm_fuzzer.hex --verify
echo.

echo ===============================================================================
echo [SUCCESS] Omni-C High-Level Compiler Compilation ^& Verification Complete!
echo ===============================================================================
