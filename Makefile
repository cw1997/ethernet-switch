# ============================================================================
#  Makefile - build, lint and run the SystemVerilog Ethernet switch
#
#  Targets
#    make            build everything and run the full regression
#    make rtl        elaborate the RTL with Icarus (synthesis-style check)
#    make lint       Verilator lint of the RTL, -Wall, warnings are errors
#    make unit       the three block level testbenches plus the fabric
#                    regression in its fast and slow-port forms
#    make sim        the main four-port switch testbench
#    make param      the parameterisation testbench (3 ports, 50 MHz)
#    make synth      read + elaborate + synthesise the RTL with yosys (needs
#                    yosys on PATH; not part of `all`, see the comment above it)
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
#    yosys           the synthesis frontend the OpenLane / LibreLane flow uses.
#                    It is much stricter than either of the above - see the
#                    `synth` target.
# ============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR?= verilator
YOSYS    ?= yosys

RTL_DIR  := rtl
TB_DIR   := tb
BUILD    := build

# The whole design in dependency order.  `sw_defs.sv` holds the shared
# declarations at compilation-unit scope and is compiled first; every other file
# includes it.
RTL_SRCS := \
  $(RTL_DIR)/sw_defs.sv \
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

# The fabric regression runs in two elaborations of the same testbench: every
# port at line rate, and one port at 10 Mbit/s.  The slow one is the interesting
# one - it is the only configuration in the whole suite in which an egress
# buffer has to hold a queue while the fabric keeps pushing into it - and it is
# what `tb_sw_switch` test 12 exercises, at a size that runs in seconds instead
# of minutes.
FLOOD_TBS := sw_flood_tb sw_flood_tb_slow

.PHONY: all rtl lint unit sim param synth clean

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
# Block level and fabric testbenches.  These are seconds rather than minutes and
# isolate a failure to a single block or to the fabric, so they are the first
# thing to run.
# ---------------------------------------------------------------------------
unit: $(BUILD)/sw_crc32_tb.vvp $(BUILD)/sw_sync_fifo_tb.vvp \
      $(BUILD)/sw_mac_table_tb.vvp $(BUILD)/sw_flood_tb.vvp \
      $(BUILD)/sw_flood_tb_slow.vvp
	@echo "--- sw_crc32_tb ---"
	@$(VVP) $(BUILD)/sw_crc32_tb.vvp
	@echo "--- sw_sync_fifo_tb ---"
	@$(VVP) $(BUILD)/sw_sync_fifo_tb.vvp
	@echo "--- sw_mac_table_tb ---"
	@$(VVP) $(BUILD)/sw_mac_table_tb.vvp
	@echo "--- sw_flood_tb (all ports at line rate) ---"
	@$(VVP) $(BUILD)/sw_flood_tb.vvp
	@echo "--- sw_flood_tb (one port at 10 Mbit/s) ---"
	@$(VVP) $(BUILD)/sw_flood_tb_slow.vvp

$(BUILD)/sw_flood_tb.vvp: $(RTL_SRCS) $(TB_COMMON) \
                        $(TB_DIR)/sw_flood_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_flood_tb $(RTL_SRCS) $(TB_COMMON) \
	  $(TB_DIR)/sw_flood_tb.sv

# The same testbench with port 0 at 10 Mbit/s, so one egress has to queue.
$(BUILD)/sw_flood_tb_slow.vvp: $(RTL_SRCS) $(TB_COMMON) \
                             $(TB_DIR)/sw_flood_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -P sw_flood_tb.SPEED0=0 -o $@ -s sw_flood_tb \
	  $(RTL_SRCS) $(TB_COMMON) $(TB_DIR)/sw_flood_tb.sv

$(BUILD)/sw_crc32_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_crc32_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_crc32.sv \
	  $(TB_DIR)/sw_tb_pkg.sv $(TB_DIR)/sw_crc32_tb.sv

$(BUILD)/sw_sync_fifo_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_sync_fifo_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_sync_fifo.sv \
	  $(TB_DIR)/sw_sync_fifo_tb.sv

$(BUILD)/sw_mac_table_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_mac_table_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_mac_table.sv \
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

# ---------------------------------------------------------------------------
# Synthesis readability check.
#
# Not part of `all`, because it needs yosys and the CI lint job does not install
# it.  It is here because the simulators are *far* more permissive than the
# synthesis frontend, so a design can pass every testbench and still be
# unreadable by the flow:
#
#   * a package item is not a constant range, so a port width taken from a
#     package is rejected outright,
#   * a package function has to be called as `pkg::f(x)`,
#   * no form of a package import is accepted at all,
#   * `return` in any function is a syntax error.
#
# All four are invisible to Icarus and Verilator.  The RTL avoids all of them -
# see rtl/sw_defs.sv - and this target is what keeps it that way.  Add yosys to
# a CI job to turn it into a hard gate.
#
# The `-sv` is not optional: read_verilog does not infer SystemVerilog from a
# `.sv` extension, and without it the parse dies on the first declaration with
# `syntax error, unexpected TOK_ID`, which looks like a package problem and is
# not one.  LibreLane passes -sv itself.
# ---------------------------------------------------------------------------
# The script has to reach yosys as a single line: a backslash-newline inside the
# `-p` argument is passed through as a literal character, and yosys then reads the
# first file name as if it were a command.
YOSYS_SCRIPT := read_verilog -defer -noautowire -sv -I$(RTL_DIR) -DSYNTHESIS $(RTL_SRCS); hierarchy -check -top sw_switch -nokeep_prints -nokeep_asserts; synth -top sw_switch -flatten; stat

synth:
	$(YOSYS) -p '$(YOSYS_SCRIPT)'
	@echo "synthesises cleanly"

clean:
	rm -rf $(BUILD)
