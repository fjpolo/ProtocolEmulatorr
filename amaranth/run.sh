# !/bin/bash

# Simulation and FV
source ~/oss-cad-suite/environment && python3 ProtocolEmulator.py gen && sby -f ProtocolEmulator.sby && deactivate
# cocoTB - Run this commands manually. Once env has been created and cocotb and pytest installed, only needs to be activated
# python3 -m venv cocotb_env && source cocotb_env/bin/activate && pip install cocotb && pip install pytest && make && deactivate