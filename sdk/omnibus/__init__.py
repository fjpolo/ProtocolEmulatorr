# =============================================================================
# File        : __init__.py
# Module      : omnibus
# Description : Master entry point for the OmniBus Python SDK.
# License     : MIT License
# =============================================================================

"""
OmniBus Software Development Kit (SDK)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A high-performance Python toolkit for the OmniBus Protocol Emulator ASIC.
Enables sub-cycle microcode assembly, hardware in-system flashing,
high-throughput FIFO streaming, waveform profiler telemetry, wire-speed
Man-in-the-Middle mutation, and cycle-accurate glitch fuzzer control.
"""

__version__ = "1.0.0"
__author__ = "OmniBus ASIC Team"

from .core import OmniBus, DeviceInfo
from .streaming import StreamChannel
from .profiler import WaveformProfiler, ProfilerResult
from .fuzzer import GlitchFuzzer, MitMController
from .dma import DmaController, DmaDescriptor, DmaChannel
from .usb_sie import UsbSieController
from .bist import BistController, BistResult
from .assembler import assemble, assemble_file
from .dsl import Protocol, Pin, Direction, ClockEdge

__all__ = [
    "OmniBus",
    "DeviceInfo",
    "StreamChannel",
    "WaveformProfiler",
    "ProfilerResult",
    "GlitchFuzzer",
    "MitMController",
    "DmaController",
    "DmaDescriptor",
    "DmaChannel",
    "UsbSieController",
    "BistController",
    "BistResult",
    "assemble",
    "assemble_file",
    "Protocol",
    "Pin",
    "Direction",
    "ClockEdge"
]
