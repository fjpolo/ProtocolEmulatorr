@echo off
rem =============================================================================
rem  OmniBus - Alias to run_alu_demo.bat
rem =============================================================================
call "%~dp0run_alu_demo.bat" %*
exit /b %ERRORLEVEL%
