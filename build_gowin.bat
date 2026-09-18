@echo off
rem ============================================================================
rem Gowin Build Flow Launcher (Bypasses PowerShell execution policy)
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_gowin.ps1" %*
exit /b %ERRORLEVEL%
