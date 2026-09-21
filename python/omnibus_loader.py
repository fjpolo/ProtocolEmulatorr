#!/usr/bin/env python3
# =============================================================================
# File        : omnibus_loader.py
# Description : Dynamic Host Microcode Loader for OmniBus Architecture.
#               Uploads assembled microcode into FPGA IMEM in ~20 milliseconds
#               over UART @ 115200 baud without FPGA re-synthesis.
# License     : MIT License
# =============================================================================

import sys
import os
import time
import argparse
import threading

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("Error: pyserial is required. Install via: pip install pyserial", file=sys.stderr)
    sys.exit(1)

# Import assembler from same directory
script_dir = os.path.dirname(os.path.abspath(__file__))
if script_dir not in sys.path:
    sys.path.insert(0, script_dir)

from omnibus_asm import OmnibusAssembler, assemble_file


def detect_com_port():
    """Attempts to auto-detect the Tang Console 60K USB-UART bridge (FTDI / COM19).
    Explicitly excludes Raspberry Pi Pico (VID 2E8A) and Bluetooth ports.
    """
    ports = list(serial.tools.list_ports.comports())
    if not ports:
        return None

    # Blocklist: VIDs that are NOT the Tang Console 60K
    BLOCKED_VIDS = {"2E8A"}  # Raspberry Pi / RP2040

    def is_blocked(p):
        hwid = (p.hwid or "").upper()
        desc = (p.description or "").lower()
        if "bluetooth" in desc:
            return True
        for vid in BLOCKED_VIDS:
            if f"VID:PID={vid}" in hwid or f"VID_{vid}" in hwid:
                return True
        return False

    # First: FTDI Channel B (SER suffix 'B') — Tang Console 60K UART interface
    for p in ports:
        if is_blocked(p):
            continue
        hwid = (p.hwid or "").upper()
        if ("0403:6010" in hwid or "VID:PID=0403" in hwid) and hwid.rstrip().endswith("B"):
            return p.device

    # Second: Any FTDI device (COM19 fallback)
    for p in ports:
        if is_blocked(p):
            continue
        if p.device == "COM19":
            return p.device

    # Third: Any FTDI USB serial port
    for p in ports:
        if is_blocked(p):
            continue
        hwid = (p.hwid or "").upper()
        if "0403:" in hwid or "FTDI" in hwid:
            return p.device

    # Fourth: Highest-numbered non-blocked USB serial port
    usb_ports = []
    for p in ports:
        if is_blocked(p):
            continue
        desc = (p.description or "").lower()
        hwid = (p.hwid or "").lower()
        if "usb" in desc or "serial" in desc or "vid_" in hwid:
            usb_ports.append(p.device)

    if usb_ports:
        import re
        usb_ports.sort(key=lambda d: int(re.search(r'\d+', d).group()) if re.search(r'\d+', d) else 0, reverse=True)
        return usb_ports[0]

    return ports[0].device


class OmnibusLoader:
    def __init__(self, port, baud=115200, timeout=1.0):
        self.port = port
        self.baud = baud
        self.timeout = timeout
        self.ser = None

    def connect(self):
        print(f"[*] Opening serial port {self.port} @ {self.baud} 8N1...")
        self.ser = serial.Serial(
            port=self.port,
            baudrate=self.baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=self.timeout
        )
        self.ser.dtr = True
        self.ser.rts = True
        time.sleep(0.05)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

    def sync(self, max_retries=5):
        """Sends magic unlock token (0xAA 0x55 0x50) to capture core and enter Programming Mode."""
        token = bytes([0xAA, 0x55, 0x50]) # Non-ASCII sync token

        for attempt in range(1, max_retries + 1):
            print(f"[*] Synchronizing with bootloader (Attempt {attempt}/{max_retries})...")
            self.ser.reset_input_buffer()

            # First, check if bootloader is ALREADY active in CMD_WAIT_OP
            self.ser.write(bytes([ord('R'), 0x00]))
            self.ser.flush()
            time.sleep(0.02)
            if self.ser.in_waiting >= 3:
                check = self.ser.read(self.ser.in_waiting)
                if len(check) >= 3 and check[0] == 0x06:
                    print(f"[OK] Bootloader already synchronized in programming mode!")
                    return True

            # Otherwise, send unlock sequence
            self.ser.reset_input_buffer()
            self.ser.write(token)
            self.ser.flush()

            # Wait for ACK sequence (0x06 'O' 'K' '\r' '\n') in received stream
            # Note: Active microcode (e.g. echo) may echo back 0xAA/0x55 before entering prog mode
            t_end = time.time() + 0.3
            rx_buf = bytearray()
            while time.time() < t_end:
                if self.ser.in_waiting > 0:
                    rx_buf.extend(self.ser.read(self.ser.in_waiting))
                    if b'\x06OK' in rx_buf:
                        time.sleep(0.02) # allow trailing \r\n to arrive
                        self.ser.reset_input_buffer()
                        print(f"[OK] Bootloader synchronized! (ACK confirmed)")
                        return True
                time.sleep(0.01)

            time.sleep(0.05)

        raise RuntimeError("Failed to synchronize with OmniBootloader. Check FPGA power and bitstream.")

    def write_word(self, addr, word):
        """Writes one 16-bit instruction word into IMEM at target addr."""
        data_hi = (word >> 8) & 0xFF
        data_lo = word & 0xFF
        pkt = bytes([ord('W'), addr & 0x1F, data_hi, data_lo])
        self.ser.write(pkt)
        self.ser.flush()

        resp = self.ser.read(2)
        if len(resp) < 2 or resp[0] != 0x06 or resp[1] != (addr & 0x1F):
            raise RuntimeError(f"Write failure at address 0x{addr:02X} (got: {resp.hex()})")

    def read_word(self, addr):
        """Reads back one 16-bit instruction word from IMEM."""
        pkt = bytes([ord('R'), addr & 0x1F])
        self.ser.write(pkt)
        self.ser.flush()

        resp = self.ser.read(3)
        if len(resp) < 3 or resp[0] != 0x06:
            raise RuntimeError(f"Read failure at address 0x{addr:02X} (got: {resp.hex()})")
        return (resp[1] << 8) | resp[2]

    def exit_and_run(self):
        """Exits Programming Mode, restoring execution to the core."""
        print("[*] Releasing core into execution mode...")
        self.ser.write(b'X')
        self.ser.flush()

        resp = self.ser.read(6)
        if resp and resp[0] == 0x06:
            print(f"[OK] Core running! (Response: {resp[1:].decode(errors='replace').strip()})")
        else:
            print(f"[!] Warning: Exit ACK not confirmed, but continuing (got: {resp.hex()})")

    def upload_program(self, instructions, verify=True):
        """Uploads a list of (addr, word, text) to IMEM."""
        t0 = time.perf_counter()
        print(f"[*] Uploading {len(instructions)} microcode instructions...")
        for addr, word, line in instructions:
            self.write_word(addr, word)
            print(f"    [0x{addr:02X}] 0x{word:04X}  --  {line.strip()[:30]}")

        t_write = (time.perf_counter() - t0) * 1000.0
        print(f"[OK] {len(instructions)} words written in {t_write:.1f} ms.")

        if verify:
            print("[*] Verifying IMEM contents...")
            t_v0 = time.perf_counter()
            for addr, word, _ in instructions:
                readback = self.read_word(addr)
                if readback != word:
                    raise RuntimeError(f"Verification mismatch at 0x{addr:02X}: Expected 0x{word:04X}, read 0x{readback:04X}")
            t_verify = (time.perf_counter() - t_v0) * 1000.0
            print(f"[OK] 100% verified in {t_verify:.1f} ms! Data integrity guaranteed.")

        self.exit_and_run()
        total_time = (time.perf_counter() - t0) * 1000.0
        print(f"[SUCCESS] Total reprogramming time: {total_time:.1f} ms!")

    def interactive_terminal(self):
        """Launches live interactive serial terminal."""
        print("\n" + "=" * 60)
        print("  OmniBus Interactive Serial Terminal")
        print(f"  Port: {self.port} | Baud: {self.baud} 8N1")
        print("  Press Ctrl+C to exit")
        print("=" * 60 + "\n")

        running = True

        def reader():
            while running:
                try:
                    if self.ser.in_waiting > 0:
                        data = self.ser.read(self.ser.in_waiting)
                        if data:
                            sys.stdout.write(data.decode("utf-8", errors="replace"))
                            sys.stdout.flush()
                    else:
                        time.sleep(0.005)
                except Exception:
                    break

        t = threading.Thread(target=reader, daemon=True)
        t.start()

        try:
            # On Windows, use msvcrt for unbuffered character input
            import msvcrt
            while running:
                if msvcrt.kbhit():
                    ch = msvcrt.getch()
                    if ch == b'\x03': # Ctrl+C
                        break
                    self.ser.write(ch)
                    self.ser.flush()
                else:
                    time.sleep(0.005)
        except ImportError:
            # Unix-like fallback
            try:
                while running:
                    line = sys.stdin.readline()
                    if not line:
                        break
                    self.ser.write(line.encode("utf-8"))
                    self.ser.flush()
            except KeyboardInterrupt:
                pass
        except KeyboardInterrupt:
            pass
        finally:
            running = False
            print("\n[*] Disconnected from serial monitor.")

    def close(self):
        if self.ser and self.ser.is_open:
            self.ser.close()


def main():
    parser = argparse.ArgumentParser(description="OmniBus Microcode Host Loader")
    parser.add_argument("-p", "--port", default=None, help="Serial port (e.g. COM19). Auto-detects if omitted.")
    parser.add_argument("-b", "--baud", type=int, default=115200, help="Baud rate (default: 115200)")
    parser.add_argument("-f", "--file", help="Microcode file to load (.asm or .hex)")
    parser.add_argument("-t", "--terminal", action="store_true", help="Launch interactive serial terminal after loading")
    parser.add_argument("-d", "--dump", action="store_true", help="Dump all 32 words of IMEM")
    parser.add_argument("--no-verify", action="store_true", help="Skip readback verification")

    args = parser.parse_args()

    port = args.port or detect_com_port()
    if not port:
        print("Error: No serial port found. Connect your FPGA board or specify with --port COMx", file=sys.stderr)
        sys.exit(1)

    loader = OmnibusLoader(port=port, baud=args.baud)

    try:
        loader.connect()
        loader.sync()

        if args.dump:
            print("[*] Dumping IMEM contents (32 words):")
            for addr in range(32):
                w = loader.read_word(addr)
                print(f"  [0x{addr:02X}]: 0x{w:04X}")
            loader.exit_and_run()

        elif args.file:
            if args.file.endswith(".hex"):
                instructions = []
                with open(args.file, "r") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("@"):
                            p = line[1:].split()
                            addr = int(p[0], 16)
                            word = int(p[1], 16)
                            instructions.append((addr, word, f"HEX @{addr:02X}"))
            else:
                instructions, _ = assemble_file(args.file)

            loader.upload_program(instructions, verify=(not args.no_verify))

        if args.terminal:
            loader.interactive_terminal()

    except Exception as e:
        print(f"\n[ERROR] {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        loader.close()


if __name__ == "__main__":
    main()
