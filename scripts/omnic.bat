@echo off
REM =============================================================================
REM Omni-C High-Level Protocol Compiler CLI Wrapper
REM Usage: .\scripts\omnic.bat <source.c> [options]
REM Example: .\scripts\omnic.bat examples\omnic\i2c_eeprom.c -o i2c.asm --hex i2c.hex
REM =============================================================================

python "%~dp0..\python\omnic.py" %*
exit /b %ERRORLEVEL%
