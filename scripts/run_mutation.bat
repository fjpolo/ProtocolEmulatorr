@echo off
REM =============================================================================
REM OmniBus ProtocolEmulator — RTL Mutation Testing Runner (Windows)
REM =============================================================================
echo [OMNIBUS][MUTATION] Starting RTL Mutation Testing Campaign & Fault Injector...
cd /d "%~dp0\..\test_rtl\mutation\ProtocolEmulator"

python mutation_runner.py
if %ERRORLEVEL% neq 0 (
    echo [OMNIBUS][MUTATION] ERROR: Mutation testing failed or kill-rate below 100%%!
    exit /b %ERRORLEVEL%
)

echo [OMNIBUS][MUTATION] SUCCESS: Mutation testing campaign completed with 100%% kill-rate!
exit /b 0
