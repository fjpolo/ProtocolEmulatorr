import os
import sys
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:
    from cocotb.runner import get_runner


def test_protocol_emulator_runner():
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent
    rtl_path = (proj_path / "../../../../rtl/ProtocolEmulator.v").resolve()

    # Prefer local copy if present, otherwise use central rtl path
    source_file = proj_path / "ProtocolEmulator.v"
    if not source_file.exists():
        source_file = rtl_path
    profiler_path = (proj_path / "../../../../rtl/OmniBus_Profiler.v").resolve()
    usb_sie_path  = (proj_path / "../../../../rtl/OmniBus_USB_SIE.v").resolve()
    sources = [profiler_path, usb_sie_path, source_file]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="ProtocolEmulator",
        always=True,
        waves=True,
    )

    testcase = os.getenv("TESTCASE", None)
    runner.test(
        hdl_toplevel="ProtocolEmulator",
        test_module="testbench",
        testcase=testcase,
        waves=True,
    )


if __name__ == "__main__":
    test_protocol_emulator_runner()