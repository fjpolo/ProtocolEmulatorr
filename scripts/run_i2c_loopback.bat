@echo off
setlocal
rem =============================================================================
rem  Task 08 - Run I2C Master Mode 0 Loopback on Tang Console 60K
rem  Loads i2c_write.asm and sends an I2C write transaction to internal I2CSlaveStub.
rem
rem  Usage:
rem    run_i2c_loopback.bat                   - Send byte 0xA0 at ~216 kHz
rem    run_i2c_loopback.bat 0xD0              - Send byte 0xD0 at ~216 kHz
rem    run_i2c_loopback.bat 0xA0 200000       - Send 0xA0 at ~100 kHz standard mode
rem    run_i2c_loopback.bat 0xA0 800000       - Send 0xA0 at ~400 kHz fast mode
rem =============================================================================

echo ============================================================
echo   Task 08 - I2C Master Loopback (Internal Auto-ACK Slave)
echo ============================================================

set ASM_FILE=%~dp0..\examples\i2c_write.asm
set DATA_BYTE=%~1
set I2C_HZ=%~2

if "%DATA_BYTE%"=="" set DATA_BYTE=0xA0

if "%I2C_HZ%"=="" goto :with_byte

rem ---- 2 args: byte + I2C clock rate ----
echo [*] Loading i2c_write.asm, setting I2C clock to %I2C_HZ% Hz, sending byte %DATA_BYTE%...
python "%~dp0..\python\omnibus_loader.py" --set-baud %I2C_HZ% --file "%ASM_FILE%" --spi-data %DATA_BYTE%
exit /b %ERRORLEVEL%

:with_byte
rem ---- 1 arg: byte only (default ~216 kHz) ----
echo [*] Loading i2c_write.asm and sending address byte %DATA_BYTE%...
python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%" --spi-data %DATA_BYTE%
exit /b %ERRORLEVEL%
