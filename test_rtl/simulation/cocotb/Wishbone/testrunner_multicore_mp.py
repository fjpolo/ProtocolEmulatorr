import os
import sys
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:
    from cocotb.runner import get_runner


def run_mp_suite(num_cores=2):
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent
    rtl_dir = (proj_path / "../../../../rtl").resolve()

    sources = [
        rtl_dir / "omnibus_fifo.v",
        rtl_dir / "OmniBus_Profiler.v",
        rtl_dir / "OmniBus_USB_SIE.v",
        rtl_dir / "OmniBus_DMA.v",
        rtl_dir / "OmniBus_Core.v",
        rtl_dir / "ProtocolEmulator_MP.v",
        rtl_dir / "ProtocolEmulator.v",
        rtl_dir / "OmniBus_Wishbone.v",
    ]

    waves = bool(int(os.getenv("WAVES", "0")))
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        includes=[rtl_dir],
        hdl_toplevel="OmniBus_Wishbone",
        parameters={"NUM_CORES": num_cores},
        always=True,
        waves=waves,
        build_dir=str(proj_path / f"sim_build_mp_{num_cores}core"),
    )

    testcase = os.getenv("TESTCASE", None)
    runner.test(
        hdl_toplevel="OmniBus_Wishbone",
        test_module="testbench_multicore_mp",
        testcase=testcase,
        waves=waves,
        build_dir=str(proj_path / f"sim_build_mp_{num_cores}core"),
    )


def test_multicore_runners():
    for nc in [2, 4]:
        print(f"=== Running OmniBus MP Test Suite for NUM_CORES = {nc} ===")
        run_mp_suite(nc)


if __name__ == "__main__":
    test_multicore_runners()
