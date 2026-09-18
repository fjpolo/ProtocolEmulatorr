@echo off
rem ============================================================================
rem Gowin EDA Windows Command Prompt Wrapper for Tang Nano 20K
rem ============================================================================

setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
exit /b %ERRORLEVEL%
