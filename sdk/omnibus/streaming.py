# =============================================================================
# File        : streaming.py
# Module      : omnibus.streaming
# Description : High-throughput TX/RX FIFO streaming channel driver.
# License     : MIT License
# =============================================================================

import time
from typing import Union, List, Optional


class StreamChannel:
    """Manages high-speed streaming data between host and OmniBus FIFOs."""

    def __init__(self, bus):
        self._bus = bus

    def write(self, data: Union[bytes, bytearray, List[int], str]) -> int:
        """
        Transfers payload data into the OmniBus TX FIFO.
        
        :param data: Byte sequence, list of integers (0..255), or ASCII string.
        :return: Number of bytes written.
        """
        if not self._bus.is_connected():
            raise ConnectionError("OmniBus hardware not connected.")

        if isinstance(data, str):
            payload = data.encode("utf-8")
        elif isinstance(data, list):
            payload = bytes(data)
        else:
            payload = bytes(data)

        self._bus._ser.write(payload)
        self._bus._ser.flush()
        return len(payload)

    def write_byte(self, byte_val: int):
        """Pushes a single byte (0..255) into the TX stream."""
        self.write(bytes([byte_val & 0xFF]))

    def read(self, max_bytes: int = 64, timeout: Optional[float] = None) -> bytes:
        """
        Reads incoming bytes captured from the OmniBus RX FIFO.
        
        :param max_bytes: Maximum number of bytes to retrieve.
        :param timeout: Custom timeout in seconds (None uses device default).
        :return: Received bytes.
        """
        if not self._bus.is_connected():
            raise ConnectionError("OmniBus hardware not connected.")

        ser = self._bus._ser
        old_timeout = ser.timeout
        if timeout is not None:
            ser.timeout = timeout

        try:
            data = ser.read(max_bytes)
        finally:
            ser.timeout = old_timeout

        return data

    def read_exact(self, count: int, timeout: float = 2.0) -> bytes:
        """
        Blocks until exactly `count` bytes are received or timeout expires.
        """
        if not self._bus.is_connected():
            raise ConnectionError("OmniBus hardware not connected.")

        buf = bytearray()
        start = time.time()
        while len(buf) < count:
            remaining = count - len(buf)
            chunk = self._bus._ser.read(remaining)
            if chunk:
                buf.extend(chunk)
            if time.time() - start > timeout:
                raise TimeoutError(f"Timed out waiting for {count} bytes (received {len(buf)}).")
        return bytes(buf)

    def flush(self):
        """Flushes host TX and RX serial buffers."""
        if self._bus.is_connected():
            self._bus._ser.reset_input_buffer()
            self._bus._ser.reset_output_buffer()
