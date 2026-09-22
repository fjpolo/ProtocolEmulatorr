@echo off
rem =============================================================================
rem  OmniBus - Alias to run_imem_demo.bat (Task 16: 128-word IMEM & Banking)
rem =============================================================================
call "%~dp0run_imem_demo.bat" %*
exit /b %ERRORLEVEL%
