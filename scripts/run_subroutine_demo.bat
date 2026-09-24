@echo off
REM ============================================================
REM  Run Subroutine Demo — Task 05 CALL/RET Demonstration
REM  Assembles and loads subroutine_demo.asm using CALL/RET
REM ============================================================
python python\omnibus_loader.py --port COM19 --file examples\subroutine_demo.asm --terminal
