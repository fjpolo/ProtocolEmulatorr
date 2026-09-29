#!/usr/bin/env python3
"""
OmniBus Example 05: Python Host Driver Quickstart
Connects to OmniBus hardware, loads an Assembly program, and streams data.
"""

import os
import sys

# Ensure omnibus SDK is in python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from omnibus import OmniBus

def main():
    print("[*] OmniBus Python Host Driver Example")
    
    # 1. Connect to physical board (e.g. Tang Console 60K or Tang Nano 20K)
    # Automatically finds available serial port or pass port="COM3" / "/dev/ttyUSB0"
    try:
        bus = OmniBus(baudrate=115200)
        print(f"[+] Connected to OmniBus on {bus.port_name}")
    except Exception as e:
        print(f"[!] Warning: Hardware not connected ({e}). Running in offline assembly mode.")
        bus = None

    # 2. Path to microcode assembly file
    asm_path = os.path.join(os.path.dirname(__file__), "01_uart_hello.asm")

    # 3. Flash microcode into OmniBus silicon
    if bus and bus.is_connected():
        print(f"[*] Flashing '{asm_path}' into IMEM...")
        bus.load_microcode(asm_path)
        print("[+] Program running in silicon!")

        # 4. Stream data to TX FIFO and read response
        bus.stream.write("Hello OmniBus Silicon!\r\n")
        response = bus.stream.read(max_bytes=32, timeout=0.5)
        print(f"[+] Echoed bytes: {response}")

if __name__ == "__main__":
    main()
