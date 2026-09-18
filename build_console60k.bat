@echo off
rem ============================================================================
rem Gowin Build Flow Launcher for Sipeed Tang Console 60K
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0boards\sipeed\console60k\build.ps1" %*
exit /b %ERRORLEVEL%
