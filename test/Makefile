# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# Defaults
SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v

ifneq ($(GATES),yes)

# RTL simulation
SIM_BUILD = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate-level simulation
SIM_BUILD = sim_build/gl

COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DSIM

VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_io/verilog/sg13g2_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v

# This gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`
COMPILE_ARGS += -I$(SRC_DIR)

# Include the Cocotb testbench wrapper
VERILOG_SOURCES += $(PWD)/tb.v

# Cocotb/Verilog top-level testbench
TOPLEVEL = tb

# Python Cocotb test module
COCOTB_TEST_MODULES = test

# Include Cocotb's Makefile rules
include $(shell cocotb-config --makefiles)/Makefile.sim
