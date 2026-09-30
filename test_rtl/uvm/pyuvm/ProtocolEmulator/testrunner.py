# =============================================================================
# File        : testrunner.py
# Description : Test runner for pyUVM verification of ProtocolEmulator
# License     : MIT License
# =============================================================================

import os
import sys
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:
    from cocotb.runner import get_runner


def run_pyuvm_tests(sim="icarus", testcase=None):
    proj_path = Path(__file__).resolve().parent
    rtl_dir = (proj_path / "../../../../rtl").resolve()

    sources = [
        rtl_dir / "OmniBus_Profiler.v",
        rtl_dir / "OmniBus_USB_SIE.v",
        rtl_dir / "ProtocolEmulator.v",
    ]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="ProtocolEmulator",
        always=True,
        waves=False,
    )

    testcase_env = testcase or os.getenv("TESTCASE", "run_uvm_test")
    runner.test(
        hdl_toplevel="ProtocolEmulator",
        test_module="uvm_testbench",
        testcase=testcase_env,
        waves=False,
    )


if __name__ == "__main__":
    sim_name = os.getenv("SIM", "icarus")
    run_pyuvm_tests(sim=sim_name)
