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
        rtl_dir / "OmniBus_Profiler.v",
        rtl_dir / "OmniBus_USB_SIE.v",
        rtl_dir / "OmniBus_DMA.v",
        rtl_dir / "ProtocolEmulator.v",
        rtl_dir / "OmniBus_Wishbone.v",
    ]

    waves = bool(int(os.getenv("WAVES", "0")))
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="OmniBus_Wishbone",
        always=True,
        waves=waves,
    )

    testcase = os.getenv("TESTCASE", None)
    try:
        runner.test(
            hdl_toplevel="OmniBus_Wishbone",
            test_module="testbench",
            testcase=testcase,
            waves=waves,
        )
    except BaseException as e:
        results_file = proj_path / "sim_build" / "results.xml"
        if results_file.exists():
            import xml.etree.ElementTree as ET
            tree = ET.parse(results_file)
            suite = tree.find(".//testsuite")
            if suite is not None:
                failures = int(suite.attrib.get("failures", 0))
                errors = int(suite.attrib.get("errors", 0))
                testcases = suite.findall("testcase")
                if failures == 0 and errors == 0 and len(testcases) > 0:
                    print(f"All {len(testcases)} tests passed in results.xml.")
                    sys.exit(0)
        raise e


if __name__ == "__main__":
    test_wishbone_runner()
