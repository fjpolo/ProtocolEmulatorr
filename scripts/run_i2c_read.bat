@echo off
setlocal
rem =============================================================================
rem  Task 10 - I2C Master Byte Read with ACK Generation (IN SDA)
rem
rem  Usage:
rem    run_i2c_read.bat                    - load i2c_read.asm (default ~216 kHz)
rem    run_i2c_read.bat 400000             - load @ 400 kHz Fast-Mode
rem    run_i2c_read.bat 100000             - load @ 100 kHz Standard-Mode
rem =============================================================================

echo ============================================================
echo   Task 10 - I2C Master Byte Read with ACK (IN SDA)
echo ============================================================

set ASM_FILE=%~dp0..\examples\i2c_read.asm
set I2C_HZ=%~1

if "%I2C_HZ%"=="" (
    echo [*] Loading %ASM_FILE% with default timing...
    python "%~dp0..\python\omnibus_loader.py" --file "%ASM_FILE%"
) else (
    echo [*] Loading %ASM_FILE% at %I2C_HZ% Hz...
    python "%~dp0..\python\omnibus_loader.py" --set-baud %I2C_HZ% --file "%ASM_FILE%"
)

if %ERRORLEVEL% NEQ 0 (
    echo [FAIL] Upload failed.
    exit /b %ERRORLEVEL%
)

echo [OK] I2C Master Read microcode active.
exit /b 0
