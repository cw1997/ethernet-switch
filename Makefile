# ============================================================================
#  Makefile - build, lint and run the SystemVerilog Ethernet switch
#
#  Targets
#    make            build everything and run the full regression
#    make rtl        elaborate the RTL with Icarus (synthesis-style check)
#    make lint       Verilator lint of the RTL, -Wall, warnings are errors
#    make unit       the three block level testbenches (fast)
#    make sim        the main four-port switch testbench
#    make param      the parameterisation testbench (3 ports, 50 MHz)
#    make clean      remove build products
#
#  Tools
#    Icarus Verilog  the simulator; the RTL and the testbenches are written so
#                    that it elaborates and runs them without warnings beyond the
#                    two documented "constant selects" notes in sw_mac_table.
#    Verilator       the linter.  It is also the more trustworthy of the two for
#                    behaviour: Icarus is known to mis-resolve unpacked arrays
#                    that are indexed with a runtime value, and the RTL avoids
#                    that construct everywhere it matters.
# ============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR?= verilator

RTL_DIR  := rtl
TB_DIR   := tb
BUILD    := build

# The whole design in dependency order.  `sw_switch_pkg.sv` is a package and is
# compiled first; every other file imports it.
RTL_SRCS := \
  $(RTL_DIR)/sw_switch_pkg.sv \
  $(RTL_DIR)/sw_crc32.sv \
  $(RTL_DIR)/sw_sync_fifo.sv \
  $(RTL_DIR)/sw_gmii_rx.sv \
  $(RTL_DIR)/sw_rx_port.sv \
  $(RTL_DIR)/sw_arbiter.sv \
  $(RTL_DIR)/sw_mac_table.sv \
  $(RTL_DIR)/sw_gmii_tx.sv \
  $(RTL_DIR)/sw_tx_port.sv \
  $(RTL_DIR)/sw_switch.sv

TB_COMMON := \
  $(TB_DIR)/sw_tb_pkg.sv \
  $(TB_DIR)/sw_rec_q.sv \
  $(TB_DIR)/sw_gmii_if.sv

IVFLAGS := -g2012 -I $(RTL_DIR) -I $(TB_DIR)

# Block level testbenches: one top per block, no cross-port models needed.
UNIT_TBS := sw_crc32_tb sw_sync_fifo_tb sw_mac_table_tb

.PHONY: all rtl lint unit sim param clean

all: lint unit sim param

# ---------------------------------------------------------------------------
# Elaborate the RTL on its own.  This is the synthesis-style check: it catches
# anything that only works because a testbench happens to drive it.
# ---------------------------------------------------------------------------
rtl: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/sw_switch.vvp -s sw_switch $(RTL_SRCS)
	@echo "RTL elaborates cleanly"

$(BUILD):
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# Lint.  -Wall plus the default error policy, so any warning fails the build.
# ---------------------------------------------------------------------------
lint: | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module sw_switch $(RTL_SRCS)
	@echo "RTL lints clean"

# ---------------------------------------------------------------------------
# Block level testbenches.  These are fast (milliseconds) and isolate a failure
# to a single block, so they are the first thing to run.
# ---------------------------------------------------------------------------
unit: $(BUILD)/sw_crc32_tb.vvp $(BUILD)/sw_sync_fifo_tb.vvp \
      $(BUILD)/sw_mac_table_tb.vvp
	@echo "--- sw_crc32_tb ---"
	@$(VVP) $(BUILD)/sw_crc32_tb.vvp
	@echo "--- sw_sync_fifo_tb ---"
	@$(VVP) $(BUILD)/sw_sync_fifo_tb.vvp
	@echo "--- sw_mac_table_tb ---"
	@$(VVP) $(BUILD)/sw_mac_table_tb.vvp

$(BUILD)/sw_crc32_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_crc32_tb \
	  $(RTL_DIR)/sw_switch_pkg.sv $(RTL_DIR)/sw_crc32.sv \
	  $(TB_DIR)/sw_tb_pkg.sv $(TB_DIR)/sw_crc32_tb.sv

$(BUILD)/sw_sync_fifo_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_sync_fifo_tb \
	  $(RTL_DIR)/sw_switch_pkg.sv $(RTL_DIR)/sw_sync_fifo.sv \
	  $(TB_DIR)/sw_sync_fifo_tb.sv

$(BUILD)/sw_mac_table_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_mac_table_tb \
	  $(RTL_DIR)/sw_switch_pkg.sv $(RTL_DIR)/sw_mac_table.sv \
	  $(TB_COMMON) $(TB_DIR)/sw_mac_table_tb.sv

# ---------------------------------------------------------------------------
# Main regression: four ports at 10/100/1000/1000 Mbit/s on one 125 MHz clock.
#
# This is the slow one.  The 10 Mbit/s port needs BYTE_PERIOD = 100 core clocks
# per octet, and every test waits for the slowest port to finish before it looks
# at the result, so the run takes a couple of minutes of wall clock.
# ---------------------------------------------------------------------------
sim: $(BUILD)/tb_sw_switch.vvp
	$(VVP) $(BUILD)/tb_sw_switch.vvp

$(BUILD)/tb_sw_switch.vvp: $(RTL_SRCS) $(TB_COMMON) \
                          $(TB_DIR)/sw_if_array.sv $(TB_DIR)/tb_sw_switch.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_switch $(RTL_SRCS) $(TB_COMMON) \
	  $(TB_DIR)/sw_if_array.sv $(TB_DIR)/tb_sw_switch.sv

# ---------------------------------------------------------------------------
# Parameterisation regression: the same RTL with three ports (not a power of
# two) at 50 MHz, so the octet clock enables are 40 and 4 core clocks long
# instead of 125 and 10.
# ---------------------------------------------------------------------------
param: $(BUILD)/sw_switch_param_tb.vvp
	$(VVP) $(BUILD)/sw_switch_param_tb.vvp

$(BUILD)/sw_switch_param_tb.vvp: $(RTL_SRCS) $(TB_COMMON) \
                                $(TB_DIR)/sw_switch_param_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_switch_param_tb $(RTL_SRCS) $(TB_COMMON) \
	  $(TB_DIR)/sw_switch_param_tb.sv

clean:
	rm -rf $(BUILD)
