@echo off
rem ============================================================================
rem Gowin Build Flow Launcher (Bypasses PowerShell execution policy)
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_gowin_nano20k.ps1" %*
exit /b %ERRORLEVEL%
