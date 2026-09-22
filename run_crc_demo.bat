@echo off
setlocal
rem =============================================================================
rem  Task 13 - Run Hardware CRC Frame Demo on Tang Console 60K
rem  Loads examples\crc_frame_demo.asm into FPGA IMEM via omnibus_loader.py.
rem
rem  Usage:
rem    run_crc_demo.bat              - Load crc_frame_demo.asm
rem    run_crc_demo.bat --port COMx  - Specify COM port
rem =============================================================================

echo ============================================================
echo   Task 13 - Hardware CRC-8 Frame Demo (Dallas 1-Wire)
echo ============================================================

set ASM_FILE=%~dp0examples\crc_frame_demo.asm
echo [*] Loading crc_frame_demo.asm into FPGA IMEM...
python "%~dp0python\omnibus_loader.py" --file "%ASM_FILE%" %*
exit /b %ERRORLEVEL%
