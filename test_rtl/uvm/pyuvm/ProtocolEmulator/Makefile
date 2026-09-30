CWD = $(shell pwd)
COCOTB_REDUCED_LOG_FMT = True
SIM ?= icarus
RTL_DIR = $(CWD)/../../../../rtl
VERILOG_SOURCES = $(RTL_DIR)/OmniBus_Profiler.v $(RTL_DIR)/OmniBus_USB_SIE.v $(RTL_DIR)/ProtocolEmulator.v
MODULE = uvm_testbench
TOPLEVEL = ProtocolEmulator
TOPLEVEL_LANG = verilog
COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ps

PYTHONPATH := $(PYTHONPATH):$(CWD):$(CWD)/../../../../

ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace
    COMPILE_ARGS += -Wall
endif

ifeq ($(SIM),icarus)
    PLUSARGS += +dumpvars
endif

include $(shell cocotb-config --makefiles)/Makefile.sim