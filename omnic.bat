@echo off
REM =============================================================================
REM Omni-C High-Level Protocol Compiler CLI Wrapper
REM Usage: omnic <source.c> [options]
REM Example: omnic examples\omnic\i2c_eeprom.c -o i2c.asm --hex i2c.hex
REM =============================================================================

python "%~dp0python\omnic.py" %*
exit /b %ERRORLEVEL%
