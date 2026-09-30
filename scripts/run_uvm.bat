@echo off
REM =============================================================================
REM OmniBus ProtocolEmulator — pyUVM Verification Runner (Windows)
REM =============================================================================
echo [OMNIBUS][pyUVM] Starting Universal Verification Methodology (UVM) Suite...
cd /d "%~dp0\..\test_rtl\uvm\pyuvm\ProtocolEmulator"

wsl bash -c "export PYTHONPATH=\"/mnt/c/Workspace/ASIC/ProtocolEmulator:$PYTHONPATH\"; python3 testrunner.py"
if %ERRORLEVEL% neq 0 (
    echo [OMNIBUS][pyUVM] ERROR: pyUVM verification failed!
    exit /b %ERRORLEVEL%
)

echo [OMNIBUS][pyUVM] SUCCESS: pyUVM verification completed 100%% successfully!
exit /b 0
