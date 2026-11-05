# ============================================================================
#  Makefile - build, lint and run the SystemVerilog Ethernet switch
#
#  Targets
#    make            build everything and run the full regression
#    make rtl        elaborate the RTL with Icarus (synthesis-style check)
#    make lint       Verilator lint of the RTL, -Wall, warnings are errors
#    make unit       the block level testbenches plus the fabric regression
#                    in its fast and slow-port forms
#    make mii        the full switch with the MII pin front-end (sw_switch_mii)
#    make rmii       the full switch with the RMII pin front-end (sw_switch_rmii)
#    make vivado     synchronous eight-port MII Vivado board-template regression
#    make sim        the main four-port switch testbench
#    make param      the parameterisation testbench (3 ports, 50 MHz)
#    make synth      read + elaborate + synthesise the RTL with yosys (needs
#                    yosys on PATH; not part of `all`, but it *is* a CI gate -
#                    see the comment above the target)
#
#  `rtl`, `lint` and `synth` each run FIVE top modules - sw_switch_gmii (the
#  default GMII front-end), sw_switch_mii, sw_switch_rmii, and the two
#  board tops sw_de2_115_top and sw_vivado_top - because the
#  per-interface wrappers and the board shell each give the design its own pin
#  list, and a top that is never elaborated is a top that silently rots.
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
# `sw_switch_core.sv` is the interface-agnostic core; the three
# `sw_switch_*` wrappers (`sw_switch_gmii` / `sw_switch_mii` / `sw_switch_rmii`)
# are the selectable top modules that adapt a physical MAC interface onto it.
# All three wrappers and both symbol adapters (`sw_mii` / `sw_rmii`) are
# compiled for every top: they are include-guarded modules, and compiling them
# always is what keeps their lint and synthesis coverage independent of which
# front-end is selected.
RTL_SRCS := \
  $(RTL_DIR)/sw_defs.sv \
  $(RTL_DIR)/sw_crc32.sv \
  $(RTL_DIR)/sw_sync_fifo.sv \
  $(RTL_DIR)/sw_gmii_rx.sv \
  $(RTL_DIR)/sw_mii.sv \
  $(RTL_DIR)/sw_rmii.sv \
  $(RTL_DIR)/sw_rx_port.sv \
  $(RTL_DIR)/sw_arbiter.sv \
  $(RTL_DIR)/sw_mac_table.sv \
  $(RTL_DIR)/sw_gmii_tx.sv \
  $(RTL_DIR)/sw_tx_port.sv \
  $(RTL_DIR)/sw_uart.sv \
  $(RTL_DIR)/sw_mdio.sv \
  $(RTL_DIR)/sw_phy_monitor.sv \
  $(RTL_DIR)/sw_monitor_cache.sv \
  $(RTL_DIR)/sw_monitor_page.sv \
  $(RTL_DIR)/sw_decimal.sv \
  $(RTL_DIR)/sw_lcd.sv \
  $(RTL_DIR)/sw_monitor_display.sv \
  $(RTL_DIR)/sw_console.sv \
  $(RTL_DIR)/sw_ratio.sv \
  $(RTL_DIR)/sw_monitor.sv \
  $(RTL_DIR)/sw_switch_core.sv \
  $(RTL_DIR)/sw_switch_gmii.sv \
  $(RTL_DIR)/sw_switch_mii.sv \
  $(RTL_DIR)/sw_switch_rmii.sv

TB_COMMON := \
  $(TB_DIR)/sw_tb_pkg.sv \
  $(TB_DIR)/sw_rec_q.sv \
  $(TB_DIR)/sw_gmii_if.sv

# The DE2-115 board shell (board/de2_115/quartus_ii) has a top of its own: it
# wires the MII wrapper to the board's two PHYs, divides the 50 MHz board
# oscillator down to the 25 MHz MII TX_CLK and drives the buttons and LEDs.
# It is pure RTL - no PLL, no vendor primitive - so it goes through the same
# three gates as the rtl/ tops; a board top that only Quartus ever compiles
# would rot exactly like an rtl/ wrapper that is never elaborated.
BOARD_DIR      := board/de2_115/quartus_ii/hdl
BOARD_TOP_SRCS := $(RTL_SRCS) $(BOARD_DIR)/sw_de2_115_top.sv
# The eight-port Vivado template has its own physical pin list. Keep it in
# lint/rtl/synth even though its PHY clocks and XDC pin locations are reserved;
# simulator coverage alone would not catch a board-shell frontend regression.
VIVADO_TOP_SRCS := $(RTL_SRCS) board/vivado/hdl/sw_vivado_top.sv

IVFLAGS := -g2012 -I $(RTL_DIR) -I $(TB_DIR)

# Block level testbenches: one top per block, no cross-port models needed.
# The two symbol-adapter benches are self-contained - they instantiate
# sw_mii / sw_rmii directly and do not need the SW_IF_* front-end defines.
UNIT_TBS := sw_crc32_tb sw_sync_fifo_tb sw_mac_table_tb sw_mii_tb sw_rmii_tb

# The fabric regression runs in two elaborations of the same testbench: every
# port at line rate, and one port at 10 Mbit/s.  The slow one is the interesting
# one - it is the only configuration in the whole suite in which an egress
# buffer has to hold a queue while the fabric keeps pushing into it - and it is
# what `tb_sw_switch` test 12 exercises, at a size that runs in seconds instead
# of minutes.
FLOOD_TBS := sw_flood_tb sw_flood_tb_slow

.PHONY: all rtl lint unit mii rmii vivado sim param synth clean

all: lint mii rmii vivado unit sim param

# ---------------------------------------------------------------------------
# Elaborate the RTL on its own.  This is the synthesis-style check: it catches
# anything that only works because a testbench happens to drive it.  Run for
# all five top modules: each per-interface wrapper has its own pin list and
# generate code, and the board shell has its own clocking, so a top that is
# only elaborated in one place can break in another without any testbench
# noticing.
# ---------------------------------------------------------------------------
rtl: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/sw_switch_gmii.vvp -s sw_switch_gmii $(RTL_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/sw_switch_mii.vvp -s sw_switch_mii $(RTL_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/sw_switch_rmii.vvp -s sw_switch_rmii $(RTL_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/sw_de2_115_top.vvp -s sw_de2_115_top $(BOARD_TOP_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/sw_vivado_top.vvp -s sw_vivado_top $(VIVADO_TOP_SRCS)
	@echo "RTL elaborates cleanly (sw_switch_gmii, sw_switch_mii, sw_switch_rmii, sw_de2_115_top and sw_vivado_top tops)"

$(BUILD):
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# Lint.  -Wall plus the default error policy, so any warning fails the build.
# All five top modules, for the same reason as `rtl` above.
# ---------------------------------------------------------------------------
lint: | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module sw_switch_gmii $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module sw_switch_mii $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module sw_switch_rmii $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module sw_de2_115_top $(BOARD_TOP_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module sw_vivado_top $(VIVADO_TOP_SRCS)
	@echo "RTL lints clean (sw_switch_gmii, sw_switch_mii, sw_switch_rmii, sw_de2_115_top and sw_vivado_top tops)"

# ---------------------------------------------------------------------------
# Block level and fabric testbenches.  These are seconds rather than minutes and
# isolate a failure to a single block or to the fabric, so they are the first
# thing to run.
# ---------------------------------------------------------------------------
unit: vivado $(BUILD)/sw_crc32_tb.vvp $(BUILD)/sw_sync_fifo_tb.vvp \
      $(BUILD)/sw_mac_table_tb.vvp $(BUILD)/sw_mii_tb.vvp \
      $(BUILD)/sw_rmii_tb.vvp $(BUILD)/sw_flood_tb.vvp \
      $(BUILD)/sw_flood_tb_slow.vvp
	@echo "--- sw_crc32_tb ---"
	@$(VVP) $(BUILD)/sw_crc32_tb.vvp
	@echo "--- sw_sync_fifo_tb ---"
	@$(VVP) $(BUILD)/sw_sync_fifo_tb.vvp
	@echo "--- sw_mac_table_tb ---"
	@$(VVP) $(BUILD)/sw_mac_table_tb.vvp
	@echo "--- sw_mii_tb ---"
	@$(VVP) $(BUILD)/sw_mii_tb.vvp
	@echo "--- sw_rmii_tb ---"
	@$(VVP) $(BUILD)/sw_rmii_tb.vvp
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

# ---------------------------------------------------------------------------
# Front-end smoke regressions: the full switch built with the sw_switch_mii
# resp. sw_switch_rmii top wrapper, exercised end to end through the matching
# PHY bus functional model.  These are the system-level counterpart of
# sw_mii_tb / sw_rmii_tb: the block benches prove the symbol adapters against
# their contract, these prove the adapted pins drive the real datapath
# (flooding, learning and known-unicast forwarding).  Seconds each, and part
# of `all` - the alternative is a front-end change that passes every GMII-side
# gate and then fails in integration, which is exactly the failure these exist
# to catch early.
# ---------------------------------------------------------------------------
mii: $(BUILD)/tb_sw_switch_mii.vvp
	$(VVP) $(BUILD)/tb_sw_switch_mii.vvp

$(BUILD)/tb_sw_switch_mii.vvp: $(RTL_SRCS) $(TB_COMMON) \
                          $(TB_DIR)/sw_mii_if.sv $(TB_DIR)/tb_sw_switch_mii.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_switch_mii $(RTL_SRCS) \
	  $(TB_COMMON) $(TB_DIR)/sw_mii_if.sv $(TB_DIR)/tb_sw_switch_mii.sv

rmii: $(BUILD)/tb_sw_switch_rmii.vvp
	$(VVP) $(BUILD)/tb_sw_switch_rmii.vvp

$(BUILD)/tb_sw_switch_rmii.vvp: $(RTL_SRCS) $(TB_COMMON) \
                          $(TB_DIR)/sw_rmii_if.sv $(TB_DIR)/tb_sw_switch_rmii.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_switch_rmii $(RTL_SRCS) \
	  $(TB_COMMON) $(TB_DIR)/sw_rmii_if.sv $(TB_DIR)/tb_sw_switch_rmii.sv

$(BUILD)/sw_crc32_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_crc32_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_crc32.sv \
	  $(TB_DIR)/sw_tb_pkg.sv $(TB_DIR)/sw_crc32_tb.sv

$(BUILD)/sw_sync_fifo_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_sync_fifo_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_sync_fifo.sv \
	  $(TB_DIR)/sw_sync_fifo_tb.sv

$(BUILD)/sw_mac_table_tb.vvp: $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_mac_table.sv \
                            $(TB_COMMON) $(TB_DIR)/sw_mac_table_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_mac_table_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_mac_table.sv \
	  $(TB_COMMON) $(TB_DIR)/sw_mac_table_tb.sv

$(BUILD)/sw_mii_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_mii_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_mii.sv \
	  $(TB_DIR)/sw_mii_tb.sv

$(BUILD)/sw_rmii_tb.vvp: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_rmii_tb \
	  $(RTL_DIR)/sw_defs.sv $(RTL_DIR)/sw_rmii.sv \
	  $(TB_DIR)/sw_rmii_tb.sv

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
# Not part of `all`, because `all` is what you want to run while iterating on
# behaviour and this target needs yosys.  The CI lint job installs yosys and
# runs it, so it is a hard gate there.  It is here because the simulators are
# *far* more permissive than the synthesis frontend, so a design can pass every
# testbench and still be unreadable by the flow:
#
#   * a package item is not a constant range, so a port width taken from a
#     package is rejected outright,
#   * a package function has to be called as `pkg::f(x)`,
#   * no form of a package import is accepted at all,
#   * `return` in any function is a syntax error.
#
# All four are invisible to Icarus and Verilator.  The RTL avoids all of them -
# see rtl/sw_defs.sv and AGENTS.md - and this target is what keeps it that way.
#
# The `-sv` is not optional: read_verilog does not infer SystemVerilog from a
# `.sv` extension, and without it the parse dies on the first declaration with
# `syntax error, unexpected TOK_ID`, which looks like a package problem and is
# not one.  LibreLane passes -sv itself.
# ---------------------------------------------------------------------------
# The script has to reach yosys as a single line: a backslash-newline inside the
# `-p` argument is passed through as a literal character, and yosys then reads the
# first file name as if it were a command.  $(1) carries the top module and $(2)
# the file list: all three per-interface wrappers plus both board shells
# are read, because each has its own pin list and generate code, and yosys is
# the only gate that sees them the way the flows will.
YOSYS_SCRIPT = read_verilog -defer -noautowire -sv -I$(RTL_DIR) -DSYNTHESIS $(2); hierarchy -check -top $(1) -nokeep_prints -nokeep_asserts; synth -top $(1) -flatten; stat

synth:
	$(YOSYS) -p '$(call YOSYS_SCRIPT,sw_switch_gmii,$(RTL_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,sw_switch_mii,$(RTL_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,sw_switch_rmii,$(RTL_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,sw_de2_115_top,$(BOARD_TOP_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,sw_vivado_top,$(VIVADO_TOP_SRCS))'
	@echo "synthesises cleanly (sw_switch_gmii, sw_switch_mii, sw_switch_rmii, sw_de2_115_top and sw_vivado_top tops)"

clean:
	rm -rf $(BUILD)

# ---------------------------------------------------------------------------
# Eight-port board-template regression. Every ingress floods to seven egresses,
# then learned traffic crosses every ring boundary (including port 7 -> 0).
# The existing MII wire models check reconstructed frames/FCS independently;
# reset and management-pin checks exercise the shell rather than the core alone.
# This uses the synchronous MII contract, not physical PHY capture/CDC timing.
# unit depends on this target so CI's existing unit job also covers the board.
# ---------------------------------------------------------------------------
vivado: $(BUILD)/tb_sw_vivado_top.vvp
	$(VVP) $(BUILD)/tb_sw_vivado_top.vvp

$(BUILD)/tb_sw_vivado_top.vvp: $(VIVADO_TOP_SRCS) $(TB_COMMON) \
                            $(TB_DIR)/sw_mii_if.sv $(TB_DIR)/tb_sw_vivado_top.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_vivado_top $(VIVADO_TOP_SRCS) \
	  $(TB_COMMON) $(TB_DIR)/sw_mii_if.sv $(TB_DIR)/tb_sw_vivado_top.sv
