# =============================================================================
# File        : core.py
# Module      : omnibus.core
# Description : OmniBus core physical device connection & management driver.
# License     : MIT License
# =============================================================================

import time
from typing import List, Optional, Union, Tuple
from dataclasses import dataclass

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    serial = None

from .assembler import assemble, assemble_file


@dataclass
class DeviceInfo:
    port: str
    baudrate: int
    clock_freq_hz: int = 50_000_000
    imem_size: int = 128
    fifo_depth: int = 64


class OmniBus:
    """Master controller for physical OmniBus Protocol Emulator hardware."""

    def __init__(
        self,
        port: Optional[str] = None,
        baudrate: int = 115_200,
        clock_freq_hz: int = 50_000_000,
        timeout: float = 1.0,
        auto_connect: bool = True
    ):
        self.port_name = port
        self.baudrate = baudrate
        self.clock_freq_hz = clock_freq_hz
        self.timeout = timeout
        self._ser: Optional[serial.Serial] = None

        # Subsystems (lazy initialized)
        self._stream = None
        self._profiler = None
        self._fuzzer = None
        self._dma = None
        self._usb = None
        self._bist = None

        if auto_connect and (port or self.list_available_ports()):
            self.connect(port)

    @staticmethod
    def list_available_ports() -> List[str]:
        """Returns a list of available serial port names."""
        if serial is None:
            return []
        return [p.device for p in serial.tools.list_ports.comports()]

    def connect(self, port: Optional[str] = None) -> "OmniBus":
        """Opens serial communication with the OmniBus hardware."""
        if serial is None:
            raise RuntimeError("pyserial is required for physical hardware communication. Run 'pip install pyserial'.")

        target_port = port or self.port_name
        if not target_port:
            ports = self.list_available_ports()
            if not ports:
                raise ConnectionError("No serial ports found. Connect a Tang Console 60K / Nano 20K or specify a port.")
            target_port = ports[0]

        self.port_name = target_port
        self._ser = serial.Serial(
            port=target_port,
            baudrate=self.baudrate,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=self.timeout
        )
        self._ser.reset_input_buffer()
        self._ser.reset_output_buffer()
        return self

    def disconnect(self):
        """Closes the active serial connection."""
        if self._ser and self._ser.is_open:
            self._ser.close()
            self._ser = None

    def is_connected(self) -> bool:
        """Returns True if the hardware connection is currently open."""
        return self._ser is not None and self._ser.is_open

    def load_microcode(self, program: Union[str, List[int]], verify: bool = True) -> bool:
        """
        Assembles (if source text) and flashes 16-bit microcode words into IMEM.
        
        :param program: Assembly string, .asm file path, or list of 16-bit words.
        :param verify: If True, reads back and verifies words before execution.
        :return: True if upload and verification succeed.
        """
        if isinstance(program, str):
            if program.endswith(".asm") or "\n" not in program:
                try:
                    words = assemble_file(program, clk_freq=self.clock_freq_hz)
                except Exception:
                    words = assemble(program, clk_freq=self.clock_freq_hz)
            else:
                words = assemble(program, clk_freq=self.clock_freq_hz)
        else:
            words = program

        if not self.is_connected():
            raise ConnectionError("Cannot upload microcode: OmniBus hardware is not connected.")

        count = len(words)
        if count > 128:
            raise ValueError(f"Program size ({count} words) exceeds IMEM capacity (128 words).")

        # 1. Send 'W' (0x57) Write Command: 'W' + Addr(7b) + Count(7b) + Words(MSB, LSB)
        header = bytes([0x57, 0x00, count & 0x7F])
        data_payload = bytearray()
        for w in words:
            data_payload.append((w >> 8) & 0xFF)  # MSB
            data_payload.append(w & 0xFF)         # LSB

        self._ser.write(header + data_payload)
        self._ser.flush()

        # 2. Verification check if requested
        if verify:
            verify_cmd = bytes([0x56, 0x00, count & 0x7F])  # 'V' + Addr + Count
            self._ser.write(verify_cmd)
            self._ser.flush()
            
            resp = self._ser.read(count * 2)
            if len(resp) == count * 2:
                for i in range(count):
                    read_word = (resp[i * 2] << 8) | resp[i * 2 + 1]
                    if read_word != words[i]:
                        raise RuntimeError(f"Verification mismatch at IMEM[0x{i:02X}]: expected 0x{words[i]:04X}, got 0x{read_word:04X}")

        # 3. Trigger execution with 'R' (0x52)
        self._ser.write(bytes([0x52]))
        self._ser.flush()
        return True

    def set_baud_divisor(self, divisor: int):
        """Sets the runtime baud rate divisor (drives i_baud_div sentinel $BAUD)."""
        if not self.is_connected():
            raise ConnectionError("Hardware not connected.")
        cmd = bytes([0x42, (divisor >> 8) & 0xFF, divisor & 0xFF])  # 'B' + MSB + LSB
        self._ser.write(cmd)
        self._ser.flush()

    def set_data_register(self, data_byte: int):
        """Sets the input data register byte (drives i_data for PULL)."""
        if not self.is_connected():
            raise ConnectionError("Hardware not connected.")
        cmd = bytes([0x44, data_byte & 0xFF])  # 'D' + byte
        self._ser.write(cmd)
        self._ser.flush()

    def run(self):
        """Sends the 'R' command to trigger execution."""
        if not self.is_connected():
            raise ConnectionError("Hardware not connected.")
        self._ser.write(bytes([0x52]))
        self._ser.flush()

    # Property accessors for dedicated subsystems
    @property
    def stream(self):
        if self._stream is None:
            from .streaming import StreamChannel
            self._stream = StreamChannel(self)
        return self._stream

    @property
    def profiler(self):
        if self._profiler is None:
            from .profiler import WaveformProfiler
            self._profiler = WaveformProfiler(self)
        return self._profiler

    @property
    def fuzzer(self):
        if self._fuzzer is None:
            from .fuzzer import GlitchFuzzer
            self._fuzzer = GlitchFuzzer(self)
        return self._fuzzer

    @property
    def dma(self):
        if self._dma is None:
            from .dma import DmaController
            self._dma = DmaController(self)
        return self._dma

    @property
    def usb(self):
        if self._usb is None:
            from .usb_sie import UsbSieController
            self._usb = UsbSieController(self)
        return self._usb

    @property
    def bist(self):
        if self._bist is None:
            from .bist import BistController
            self._bist = BistController(self)
        return self._bist

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()
