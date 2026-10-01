# =============================================================================
# File        : cli.py
# Module      : omnibus.cli
# Description : Command-line interface utilities for the OmniBus SDK.
# License     : MIT License
# =============================================================================

import argparse
import sys
from .core import OmniBus
from .assembler import assemble_file


def load_cli():
    parser = argparse.ArgumentParser(description="OmniBus In-System Microcode Loader")
    parser.add_argument("program", help="Path to microcode source file (.asm)")
    parser.add_argument("-p", "--port", help="Serial port (e.g. COM3 or /dev/ttyUSB0)")
    parser.add_argument("-b", "--baud", type=int, default=115200, help="UART baud rate (default: 115200)")
    args = parser.parse_args()

    print(f"[*] Connecting to OmniBus on {args.port or 'auto-detect'} @ {args.baud} baud...")
    with OmniBus(port=args.port, baudrate=args.baud) as bus:
        print(f"[*] Assembling and flashing '{args.program}'...")
        bus.load_microcode(args.program)
        print("[+] Microcode loaded and executing in real silicon!")


def profiler_cli():
    parser = argparse.ArgumentParser(description="OmniBus Hardware Waveform Profiler & Protocol Detective")
    parser.add_argument("-p", "--port", help="Serial port")
    args = parser.parse_args()

    print("[*] Probing target physical bus transitions...")
    with OmniBus(port=args.port) as bus:
        res = bus.profiler.detect()
        print(f"[+] Detected Protocol : {res.inferred_protocol}")
        print(f"[+] Estimated Baud Rate: {res.detected_baud:,} baud")
        print(f"[+] Min Pulse Width    : {res.tmin_cycles} cycles")
        print(f"[+] Idle Bus Level     : {res.idle_state}")
        print(f"[+] Confidence Score   : {res.confidence * 100:.1f}%")


def fuzz_cli():
    parser = argparse.ArgumentParser(description="OmniBus Glitch & Active MitM Fuzzer")
    parser.add_argument("-p", "--port", help="Serial port")
    parser.add_argument("--glitch-pin", type=int, default=5, help="Target glitch output pin")
    parser.add_argument("--glitch-width", type=int, default=5, help="Glitch pulse width in cycles")
    args = parser.parse_args()

    print(f"[*] Arming Hardware Glitch Pulse Generator (Pin {args.glitch_pin}, Width {args.glitch_width} cyc)...")
    with OmniBus(port=args.port) as bus:
        bus.fuzzer.configure_pulse(pin=args.glitch_pin, width_cycles=args.glitch_width)
        print("[+] Glitch Generator ARMED.")


def compile_cli():
    import python.omnic as omnic_main
    omnic_main.main()


def main():
    parser = argparse.ArgumentParser(description="OmniBus Master SDK CLI")
    subparsers = parser.add_subparsers(dest="command")
    subparsers.add_parser("load", help="Flash microcode to hardware")
    subparsers.add_parser("detect", help="Run hardware waveform profiler")
    subparsers.add_parser("fuzz", help="Configure glitch / MitM fuzzer")
    subparsers.add_parser("compile", help="Compile Omni-C source (.c) to assembly (.asm)")
    args = parser.parse_args()

    if args.command == "load":
        load_cli()
    elif args.command == "detect":
        profiler_cli()
    elif args.command == "fuzz":
        fuzz_cli()
    elif args.command == "compile":
        compile_cli()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()

