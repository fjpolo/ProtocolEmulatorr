import os
import sys
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:
    from cocotb.runner import get_runner


def test_wishbone_runner():
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent
    rtl_dir = (proj_path / "../../../../rtl").resolve()

    sources = [
        rtl_dir / "omnibus_fifo.v",
        rtl_dir / "ProtocolEmulator.v",
        rtl_dir / "OmniBus_Wishbone.v",
    ]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="OmniBus_Wishbone",
        always=True,
        waves=True,
    )

    testcase = os.getenv("TESTCASE", None)
    runner.test(
        hdl_toplevel="OmniBus_Wishbone",
        test_module="testbench",
        testcase=testcase,
        waves=True,
    )


if __name__ == "__main__":
    test_wishbone_runner()
