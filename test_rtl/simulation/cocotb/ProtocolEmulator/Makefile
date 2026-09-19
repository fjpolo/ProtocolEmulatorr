# =============================================================================
# Makefile for ProtocolEmulator Cocotb simulation
# =============================================================================

CWD = $(shell pwd)
SIM ?= icarus
PYTHON_BIN ?= python3
TOPLEVEL_LANG ?= verilog
VERILOG_SOURCES ?= $(CWD)/../../../../rtl/ProtocolEmulator.v
TOPLEVEL = ProtocolEmulator
MODULE = testbench

ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace --trace-fst
    COMPILE_ARGS += -Wall
endif

ifeq ($(SIM),icarus)
    PLUSARGS += +dumpvars
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
