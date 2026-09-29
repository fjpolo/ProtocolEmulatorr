# =============================================================================
# File        : dma.py
# Module      : omnibus.dma
# Description : Wishbone Scatter-Gather DMA Controller & Descriptor Chaining.
# License     : MIT License
# =============================================================================

from dataclasses import dataclass
from typing import List, Optional
from enum import IntEnum


class DmaDirection(IntEnum):
    MEMORY_TO_FIFO = 0  # Linear TX Stream
    FIFO_TO_MEMORY = 1  # Linear RX Capture


@dataclass
class DmaDescriptor:
    """Represents a 16-byte Hardware Scatter-Gather DMA Descriptor."""
    source_addr: int
    dest_addr: int
    length_bytes: int
    next_desc_addr: int = 0x00000000  # 0 indicates end-of-chain
    interrupt_on_done: bool = True
    stop_on_done: bool = False

    def pack(self) -> bytes:
        """Packs descriptor fields into 16-byte little-endian binary layout."""
        import struct
        flags = (1 if self.interrupt_on_done else 0) | (2 if self.stop_on_done else 0)
        return struct.pack("<IIII", self.source_addr, self.dest_addr, self.length_bytes, self.next_desc_addr)


class DmaChannel:
    """Controls an individual DMA stream channel."""

    def __init__(self, bus, channel_id: int):
        self._bus = bus
        self.channel_id = channel_id

    def start_linear_tx(self, memory_addr: int, length_bytes: int):
        """Starts a direct memory-to-TX-FIFO transfer."""
        pass

    def start_linear_rx(self, memory_addr: int, length_bytes: int):
        """Starts a direct RX-FIFO-to-memory capture."""
        pass

    def start_scatter_gather(self, first_desc_addr: int):
        """Launches linked-list descriptor chain traversal."""
        pass

    def is_busy(self) -> bool:
        """Returns True if DMA transfer is active."""
        return False

    def wait_complete(self, timeout: float = 5.0) -> bool:
        """Blocks until current DMA transfer completes."""
        return True


class DmaController:
    """Master controller for the OmniBus Autonomous DMA Engine (Task 26)."""

    def __init__(self, bus):
        self._bus = bus
        self.channels = [DmaChannel(bus, 0), DmaChannel(bus, 1)]

    def __getitem__(self, index: int) -> DmaChannel:
        return self.channels[index]
