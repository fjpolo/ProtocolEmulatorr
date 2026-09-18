CWD=$(shell pwd)
COCOTB_REDUCED_LOG_FMT = True
SIM ?= icarus
VERILOG_SOURCES = ProtocolEmulator.v
MODULE = uvm_testbench
TOPLEVEL = ProtocolEmulator
TOPLEVEL_LANG = verilog
COCOTB_HDL_TIMEUNIT = 1us
COCOTB_HDL_TIMEPRECISION = 1us

# Add PYTHONPATH for pyuvm if needed
PYTHONPATH := $(PYTHONPATH):$(CWD)

# Verilator-specific settings
ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace  # Enable waveform generation
    EXTRA_ARGS += --coverage  # Enable coverage if needed
    COMPILE_ARGS += -Wall  # Show all warnings
endif

# Icarus-specific settings
ifeq ($(SIM),icarus)
    EXTRA_ARGS += -v  # Verbose output
endif

include $(shell cocotb-config --makefiles)/Makefile.sim