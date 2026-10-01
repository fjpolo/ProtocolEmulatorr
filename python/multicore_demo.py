#!/usr/bin/env python3
# =============================================================================
# File        : multicore_demo.py
# Description : Interactive OmniBus MP Multi-Core Micro-Engine Terminal & Visualizer
#               Demonstrates symmetric execution across 1, 2, and 4 cores,
#               hardware mailboxes, atomic spinlocks, and barrier rendezvous.
# License     : MIT License
# =============================================================================

import sys
import os
import subprocess
import argparse
import time

# ANSI Terminal Styling
RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
CYAN    = "\033[96m"
GREEN   = "\033[92m"
YELLOW  = "\033[93m"
RED     = "\033[91m"
MAGENTA = "\033[95m"
BLUE    = "\033[94m"
WHITE   = "\033[97m"
BG_BLUE = "\033[44m"
BG_DARK = "\033[40m"


def print_banner():
    print(f"{CYAN}{BOLD}")
    print(r"  ============================================================================")
    print(r"    ____                  _ ____             __  ______  ")
    print(r"   / __ \____ ___  ____  (_) __ )__  _______/  |/  / __ \ ")
    print(r"  / / / / __ `__ \/ __ \/ / __  / / / / ___/ /|_/ / /_/ / ")
    print(r" / /_/ / / / / / / / / / / /_/ / /_/ (__  ) /  / / ____/  ")
    print(r" \____/_/ /_/ /_/_/ /_/_/_____/\__,_/____/_/  /_/_/       ")
    print(r"                                                          ")
    print(r"    Symmetric Multi-Core Protocol Engine & Hardware Synchronization Fabric")
    print(r"    Configurable Topology: 1, 2, or 4 Autonomous Cores (NUM_CORES = 1, 2, 4)")
    print(r"  ============================================================================")
    print(f"{RESET}\n")


def compile_file(c_path, asm_path, hex_path):
    print(f"{YELLOW}[*] Compiling:{RESET} {c_path}")
    cmd = [sys.executable, os.path.join("python", "omnic.py"), c_path, "-o", asm_path, "--hex", hex_path]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"{RED}[!] Compilation Error:{RESET}\n{res.stderr or res.stdout}")
        return False
    print(f"{GREEN}[+] Generated:{RESET} {asm_path} -> {hex_path}")
    return True


def show_dual_core_bridge_demo():
    print(f"\n{MAGENTA}{BOLD}=== DEMONSTRATOR 1: Dual-Core Asymmetric UART-to-SPI Multi-Protocol Bridge ==={RESET}")
    print(f"{WHITE}Architecture: 2 Cores | Bank 0 (Core 0: UART Ingest) | Bank 1 (Core 1: SPI Master){RESET}")
    print(f"{CYAN}Synchronization: Spinlock 0 (Mutual Exclusion) + Mailbox 0 (Data Transfer){RESET}\n")

    c_file = os.path.join("examples", "omnic", "dual_core_bridge.c")
    asm_file = os.path.join("examples", "omnic", "dual_core_bridge.asm")
    hex_file = os.path.join("examples", "omnic", "dual_core_bridge.hex")

    if not compile_file(c_file, asm_file, hex_file):
        return

    print(f"\n{BOLD}{WHITE}+-------------------+-------------------+-----------------------------------+{RESET}")
    print(f"{BOLD}{WHITE}| Core 0 (Bank 0)   | Core 1 (Bank 1)   | Hardware Synchronization Fabric   |{RESET}")
    print(f"{BOLD}{WHITE}+-------------------+-------------------+-----------------------------------+{RESET}")
    print(f"| {GREEN}PINMAP 0,3,1,2{RESET}    | {CYAN}PINMAP 4,7,5,6{RESET}    | {YELLOW}SPINLOCK 0: Free [Unlocked]{RESET}       |")
    print(f"| {GREEN}WAIT rx, 0 (Start){RESET}| {CYAN}SPINLOCK_ACQ 0{RESET}    | {YELLOW}MAILBOX[0]: 0x00 [Empty]{RESET}          |")
    print(f"| {GREEN}IN $BAUD (0x5A){RESET}   | {CYAN}JMP NZ (Spin...){RESET}  | Core 0 acquires Lock 0...         |")
    print(f"| {GREEN}SPINLOCK_ACQ 0{RESET}    | {CYAN}Spinning...{RESET}       | {RED}SPINLOCK 0: HELD BY CORE 0{RESET}        |")
    print(f"| {GREEN}MB_WRITE 0 (0x5A){RESET} | {CYAN}Spinning...{RESET}       | {GREEN}MAILBOX[0] <= 0x5A{RESET}                 |")
    print(f"| {GREEN}SPINLOCK_REL 0{RESET}    | {CYAN}Lock Acquired!{RESET}    | {YELLOW}SPINLOCK 0: Released -> Core 1{RESET}    |")
    print(f"| {GREEN}Wait Next Frame{RESET}   | {CYAN}MB_READ 0 (0x5A){RESET}   | Core 1 receives 0x5A              |")
    print(f"| {GREEN}Listening...{RESET}      | {CYAN}OUT SCK 8 (SPI){RESET}   | {CYAN}SPI MOSI/SCK Transmission active{RESET}  |")
    print(f"{BOLD}{WHITE}+-------------------+-------------------+-----------------------------------+{RESET}\n")


def show_dual_core_sync_demo():
    print(f"\n{MAGENTA}{BOLD}=== DEMONSTRATOR 2: Dual-Core Mailbox Ping-Pong & Barrier Rendezvous ==={RESET}")
    print(f"{WHITE}Architecture: 2 Cores | Core 0 (Producer) | Core 1 (Transformer +0x11){RESET}")
    print(f"{CYAN}Synchronization: Hardware BARRIER_WAIT + Mailbox 0 & 1 + Spinlock 0 & 1{RESET}\n")

    c_file = os.path.join("examples", "omnic", "dual_core_mailbox_sync.c")
    asm_file = os.path.join("examples", "omnic", "dual_core_mailbox_sync.asm")
    hex_file = os.path.join("examples", "omnic", "dual_core_mailbox_sync.hex")

    if not compile_file(c_file, asm_file, hex_file):
        return

    print(f"\n{BOLD}{WHITE}Phase 1: Hardware Barrier Rendezvous{RESET}")
    print(f"  - Core 0 executes {YELLOW}BARRIER_WAIT{RESET} -> Enters zero-overhead stall state")
    print(f"  - Core 1 executes {YELLOW}BARRIER_WAIT{RESET} -> All cores arrived!")
    print(f"  - {GREEN}Barrier Engine fires simultaneous release pulse -> Both cores resume in lockstep!{RESET}\n")

    print(f"{BOLD}{WHITE}Phase 2: Ping-Pong Token Transformation{RESET}")
    tokens = [0x10, 0x25, 0x4A, 0x7E]
    for idx, token in enumerate(tokens):
        resp = (token + 0x11) & 0xFF
        print(f"  Frame {idx+1}: Core 0 writes {CYAN}0x{token:02X}{RESET} to MB[0] -> Core 1 adds 0x11 -> Core 1 writes {GREEN}0x{resp:02X}{RESET} to MB[1] -> Host FIFO")
        time.sleep(0.05)


def show_quad_core_grid_demo():
    print(f"\n{MAGENTA}{BOLD}=== DEMONSTRATOR 3: Quad-Core (4-Core) Symmetric Pipelined Accelerator ==={RESET}")
    print(f"{WHITE}Architecture: 4 Cores (NUM_CORES = 4) | 4-Stage Streaming Crossbar Pipeline{RESET}")
    print(f"{CYAN}Core 0 (Ingress) -> Core 1 (Crypto XOR) -> Core 2 (CRC Engine) -> Core 3 (SPI Egress){RESET}\n")

    c_file = os.path.join("examples", "omnic", "quad_core_grid.c")
    asm_file = os.path.join("examples", "omnic", "quad_core_grid.asm")
    hex_file = os.path.join("examples", "omnic", "quad_core_grid.hex")

    if not compile_file(c_file, asm_file, hex_file):
        return

    print(f"\n{BOLD}{WHITE}+-----------------------------------------------------------------------------------+{RESET}")
    print(f"{BOLD}{WHITE}| Core 0: Ingress   | Core 1: Crypto    | Core 2: CRC Check | Core 3: SPI Master & Egress   |{RESET}")
    print(f"{BOLD}{WHITE}+-----------------------------------------------------------------------------------+{RESET}")
    print(f"| Host TX Stream    | Cascade FIFO      | Shared MB 2 (0xFD)| Shared MB 3 (0xFE)            |")
    print(f"| PULL Host Byte    | XOR 0xAA Mask     | Invert / Checksum | SPI MOSI / SCK Shift          |")
    print(f"| PUSH Cascade FIFO | MB_WRITE 2        | MB_WRITE 3        | PUSH Host RX Return           |")
    print(f"{BOLD}{WHITE}+-----------------------------------------------------------------------------------+{RESET}\n")

    sample_inputs = [0x12, 0x34, 0x56, 0x78]
    print(f"{BOLD}Live Pipeline Flow Trace:{RESET}")
    for val in sample_inputs:
        stage1 = val ^ 0xAA
        stage2 = (~stage1) & 0xFF
        print(f"  Input: {CYAN}0x{val:02X}{RESET} -> [Core 0: PULL] -> [Core 1: XOR 0xAA = {YELLOW}0x{stage1:02X}{RESET}] -> [Core 2: INV = {MAGENTA}0x{stage2:02X}{RESET}] -> [Core 3: SPI TX & Host RX = {GREEN}0x{stage2:02X}{RESET}]")
        time.sleep(0.05)


def run_wsl_tests():
    print(f"\n{CYAN}{BOLD}=== Running OmniBus MP Multi-Core Simulation Test Suite via WSL ==={RESET}\n")
    cmd = ["wsl", "-e", "bash", "-c", "cd /mnt/c/Workspace/ASIC/ProtocolEmulator && python3 test_rtl/simulation/cocotb/Wishbone/testrunner_multicore_mp.py"]
    res = subprocess.run(cmd)
    return res.returncode == 0


def main():
    print_banner()

    parser = argparse.ArgumentParser(description="OmniBus MP Multi-Core Interactive Demonstrator")
    parser.add_argument("--demo", choices=["bridge", "sync", "quad", "all", "compile", "sim"], default="all",
                        help="Select demonstration target (bridge, sync, quad, all, compile, sim)")
    args = parser.parse_args()

    if args.demo in ("bridge", "all"):
        show_dual_core_bridge_demo()

    if args.demo in ("sync", "all"):
        show_dual_core_sync_demo()

    if args.demo in ("quad", "all"):
        show_quad_core_grid_demo()

    if args.demo in ("sim", "all"):
        run_wsl_tests()


if __name__ == "__main__":
    main()
