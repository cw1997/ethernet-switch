# ============================================================================
#  Makefile - build, lint and run the pipelined SystemVerilog Ethernet switch
#
#  Targets
#    make            build everything and run the full regression
#    make rtl        elaborate the five top modules with Icarus (RTL only)
#    make lint       Verilator lint of the RTL, -Wall, warnings are errors
#    make unit       block-level + staged-fabric + board unit regressions
#    make mii        full MII switch top end-to-end regression
#    make rmii       full RMII switch top end-to-end regression
#    make vivado     eight-port MII Vivado board-template regression
#    make board-unit DE2-115 board-top regression
#    make sim        GMII staged-switch system regression (default geometry)
#    make param      parameterisation regression (3 ports, non-power-of-2 CAM)
#    make param-scan 4/8/16/32/48-port x CAM set/way scan
#    make synth      read + elaborate + synthesise with yosys (NOT in `all`;
#                    a CI gate - see the comment above the target)
#    make clean      remove build products
#
#  `rtl`, `lint` and `synth` each run FIVE top modules - es_switch_gmii (the
#  default GMII front-end), es_switch_mii, es_switch_rmii, and the two board
#  tops es_switch_de2_115_top and es_switch_vivado_top - because each has its
#  own pin list; a top that is never elaborated silently rots.
#
#  Tools
#    Icarus Verilog  simulator. It prints conservative "constant selects in
#                    always_* processes" notes for the header-latch shift
#                    registers; those are harmless (all bits are included).
#    Verilator       -Wall linter; any warning fails the build.
#    yosys           the synthesis frontend the LibreLane flow uses.
# ============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR?= verilator
YOSYS    ?= yosys

RTL_DIR  := rtl
TB_DIR   := tb
BUILD    := build

# Shared declarations live at compilation-unit scope in es_defs.sv; every
# module includes it. RTL_SRCS is the pure-switching staged design: one
# interface-agnostic fabric (es_switch_fabric), three MAC interface adapters
# and the three wrappers. No console, panel, statistics or beat-packing code.
RTL_HEADERS := $(wildcard $(RTL_DIR)/*defs.sv $(RTL_DIR)/*/*defs.sv)

RTL_SRCS := \
  $(RTL_DIR)/common/es_common_sync_2ff.sv \
  $(RTL_DIR)/common/es_common_crc32.sv \
  $(RTL_DIR)/common/es_common_dffs.sv \
  $(RTL_DIR)/common/es_common_pipe_stage.sv \
  $(RTL_DIR)/mems/es_mems_ram_1r1w.sv \
  $(RTL_DIR)/mems/es_mems_reg_bank.sv \
  $(RTL_DIR)/mems/es_mems_sync_fifo.sv \
  $(RTL_DIR)/mac/es_mac_mii_serdes.sv \
  $(RTL_DIR)/mac/es_mac_rmii_serdes.sv \
  $(RTL_DIR)/mac/es_mac_byte_if.sv \
  $(RTL_DIR)/mac/es_mac_adapters.sv \
  $(RTL_DIR)/perips/es_perips_mdio.sv \
  $(RTL_DIR)/perips/es_perips_phy_88e1111.sv \
  $(RTL_DIR)/switch/es_switch_frame_buf.sv \
  $(RTL_DIR)/switch/es_switch_rx_ctrl.sv \
  $(RTL_DIR)/switch/es_switch_rx_parse.sv \
  $(RTL_DIR)/switch/es_switch_rx_check.sv \
  $(RTL_DIR)/switch/es_switch_rx_engine.sv \
  $(RTL_DIR)/switch/es_switch_tx_engine.sv \
  $(RTL_DIR)/switch/es_switch_cam_table.sv \
  $(RTL_DIR)/switch/es_switch_cam_stage.sv \
  $(RTL_DIR)/switch/es_switch_decide.sv \
  $(RTL_DIR)/switch/es_switch_tx_writer.sv \
  $(RTL_DIR)/switch/es_switch_fabric.sv \
  $(RTL_DIR)/switch/es_switch_gmii.sv \
  $(RTL_DIR)/switch/es_switch_mii.sv \
  $(RTL_DIR)/switch/es_switch_rmii.sv

TB_COMMON := \
  $(TB_DIR)/sw_tb_pkg.sv \
  $(TB_DIR)/sw_rec_q.sv

BOARD_DIR      := board/de2_115/quartus_ii/hdl
BOARD_TOP_SRCS := $(RTL_SRCS) $(BOARD_DIR)/es_switch_de2_115_top.sv
VIVADO_TOP_SRCS := $(RTL_SRCS) board/vivado/hdl/es_switch_vivado_top.sv

IVFLAGS := -g2012 -I $(RTL_DIR) -I $(TB_DIR)

.PHONY: all rtl lint unit mii rmii vivado board-unit sim param param-scan synth clean \
        pipe-unit rx-unit fabric-unit

all: lint rtl unit mii rmii vivado board-unit sim param param-scan

# ---------------------------------------------------------------------------
# Elaborate the RTL on its own: catches anything that only works because a
# testbench happens to declare it.  All five tops.
# ---------------------------------------------------------------------------
rtl: | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/es_switch_gmii.vvp -s es_switch_gmii $(RTL_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/es_switch_mii.vvp -s es_switch_mii $(RTL_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/es_switch_rmii.vvp -s es_switch_rmii $(RTL_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/es_switch_de2_115_top.vvp -s es_switch_de2_115_top $(BOARD_TOP_SRCS)
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/es_switch_vivado_top.vvp -s es_switch_vivado_top $(VIVADO_TOP_SRCS)
	@echo "RTL elaborates cleanly (es_switch_gmii, es_switch_mii, es_switch_rmii, es_switch_de2_115_top and es_switch_vivado_top tops)"

$(BUILD):
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# Lint.  -Wall plus the default error policy; all five tops.
# ---------------------------------------------------------------------------
lint: | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module es_switch_gmii $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module es_switch_mii $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module es_switch_rmii $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module es_switch_de2_115_top $(BOARD_TOP_SRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME \
	  -I$(RTL_DIR) --top-module es_switch_vivado_top $(VIVADO_TOP_SRCS)
	@echo "RTL lints clean (es_switch_gmii, es_switch_mii, es_switch_rmii, es_switch_de2_115_top and es_switch_vivado_top tops)"

# ---------------------------------------------------------------------------
# Block-level and staged-fabric unit regressions.
# ---------------------------------------------------------------------------
UNIT_TBS := sw_crc32_tb sw_sync_fifo_tb sw_mii_tb sw_rmii_tb sw_phy_88e1111_tb \
            sw_pipe_stage_tb sw_rx_engine_tb sw_fabric_tb

unit: $(addprefix $(BUILD)/,$(addsuffix .vvp,$(UNIT_TBS)))
	@set -e; for bench in $(UNIT_TBS); do \
	  echo "--- $$bench ---"; $(VVP) $(BUILD)/$$bench.vvp; done

$(BUILD)/sw_crc32_tb.vvp: $(RTL_HEADERS) | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_crc32_tb \
	  $(RTL_DIR)/es_defs.sv $(RTL_DIR)/common/es_common_crc32.sv \
	  $(TB_DIR)/sw_tb_pkg.sv $(TB_DIR)/sw_crc32_tb.sv

$(BUILD)/sw_sync_fifo_tb.vvp: $(RTL_HEADERS) | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_sync_fifo_tb \
	  $(RTL_DIR)/es_defs.sv $(RTL_DIR)/mems/es_mems_ram_1r1w.sv $(RTL_DIR)/mems/es_mems_sync_fifo.sv \
	  $(TB_DIR)/sw_sync_fifo_reference.sv $(TB_DIR)/sw_sync_fifo_tb.sv

$(BUILD)/sw_mii_tb.vvp: $(RTL_HEADERS) | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_mii_tb \
	  $(RTL_DIR)/es_defs.sv $(RTL_DIR)/mac/es_mac_mii_serdes.sv \
	  $(TB_DIR)/sw_mii_tb.sv

$(BUILD)/sw_rmii_tb.vvp: $(RTL_HEADERS) | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s sw_rmii_tb \
	  $(RTL_DIR)/es_defs.sv $(RTL_DIR)/mac/es_mac_rmii_serdes.sv \
	  $(TB_DIR)/sw_rmii_tb.sv

$(BUILD)/sw_phy_88e1111_tb.vvp: $(RTL_HEADERS) $(RTL_SRCS) $(TB_DIR)/sw_phy_88e1111_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -s sw_phy_88e1111_tb -o $@ $(RTL_SRCS) $(TB_DIR)/sw_phy_88e1111_tb.sv

# Staged-pipeline primitives: each is compiled with only the files it needs.
pipe-unit: $(BUILD)/sw_pipe_stage_tb.vvp
	$(VVP) $<
$(BUILD)/sw_pipe_stage_tb.vvp: $(RTL_HEADERS) \
    $(RTL_DIR)/common/es_common_dffs.sv $(RTL_DIR)/common/es_common_pipe_stage.sv \
    $(TB_DIR)/sw_pipe_stage_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -s sw_pipe_stage_tb -o $@ \
	  $(RTL_DIR)/common/es_common_dffs.sv $(RTL_DIR)/common/es_common_pipe_stage.sv \
	  $(TB_DIR)/sw_pipe_stage_tb.sv

rx-unit: $(BUILD)/sw_rx_engine_tb.vvp
	$(VVP) $<
$(BUILD)/sw_rx_engine_tb.vvp: $(RTL_HEADERS) \
    $(RTL_DIR)/mems/es_mems_ram_1r1w.sv $(RTL_DIR)/mems/es_mems_reg_bank.sv \
    $(RTL_DIR)/mems/es_mems_sync_fifo.sv \
    $(RTL_DIR)/switch/es_switch_frame_buf.sv \
    $(RTL_DIR)/switch/es_switch_rx_ctrl.sv \
    $(RTL_DIR)/switch/es_switch_rx_parse.sv \
    $(RTL_DIR)/switch/es_switch_rx_check.sv \
    $(RTL_DIR)/switch/es_switch_rx_engine.sv \
    $(TB_DIR)/sw_rx_engine_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -s sw_rx_engine_tb -o $@ \
	  $(RTL_DIR)/mems/es_mems_ram_1r1w.sv $(RTL_DIR)/mems/es_mems_reg_bank.sv \
	  $(RTL_DIR)/mems/es_mems_sync_fifo.sv \
	  $(RTL_DIR)/switch/es_switch_frame_buf.sv \
	  $(RTL_DIR)/switch/es_switch_rx_ctrl.sv \
	  $(RTL_DIR)/switch/es_switch_rx_parse.sv \
	  $(RTL_DIR)/switch/es_switch_rx_check.sv \
	  $(RTL_DIR)/switch/es_switch_rx_engine.sv \
	  $(TB_DIR)/sw_rx_engine_tb.sv

# End-to-end staged-fabric regression (8-bit byte stream, no PHY pins).
fabric-unit: $(BUILD)/sw_fabric_tb.vvp
	$(VVP) $<
$(BUILD)/sw_fabric_tb.vvp: $(RTL_HEADERS) $(RTL_SRCS) $(TB_DIR)/sw_fabric_tb.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -s sw_fabric_tb -o $@ $(RTL_SRCS) $(TB_DIR)/sw_fabric_tb.sv

# ---------------------------------------------------------------------------
# Front-end regressions: complete wire frames (preamble/SFD/FCS) are driven
# through the matching PHY bus functional model.  These prove the MAC adapters
# and the board shells, not just the fabric.
# ---------------------------------------------------------------------------
mii: $(BUILD)/tb_sw_pl_mii.vvp
	$(VVP) $<
$(BUILD)/tb_sw_pl_mii.vvp: $(RTL_HEADERS) $(RTL_SRCS) $(TB_COMMON) \
    $(TB_DIR)/sw_mii_if.sv $(TB_DIR)/tb_sw_pl_mii.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_pl_mii $(RTL_SRCS) $(TB_COMMON) \
	  $(TB_DIR)/sw_mii_if.sv $(TB_DIR)/tb_sw_pl_mii.sv

rmii: $(BUILD)/tb_sw_pl_rmii.vvp
	$(VVP) $<
$(BUILD)/tb_sw_pl_rmii.vvp: $(RTL_HEADERS) $(RTL_SRCS) $(TB_COMMON) \
    $(TB_DIR)/sw_rmii_if.sv $(TB_DIR)/tb_sw_pl_rmii.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_pl_rmii $(RTL_SRCS) $(TB_COMMON) \
	  $(TB_DIR)/sw_rmii_if.sv $(TB_DIR)/tb_sw_pl_rmii.sv

vivado: $(BUILD)/tb_es_switch_vivado_top.vvp
	$(VVP) $<
$(BUILD)/tb_es_switch_vivado_top.vvp: $(RTL_HEADERS) $(VIVADO_TOP_SRCS) $(TB_COMMON) \
    $(TB_DIR)/sw_mii_if.sv board/vivado/hdl/tb_es_switch_vivado_top.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_es_switch_vivado_top $(VIVADO_TOP_SRCS) \
	  $(TB_COMMON) $(TB_DIR)/sw_mii_if.sv board/vivado/hdl/tb_es_switch_vivado_top.sv

board-unit: $(BUILD)/tb_es_switch_de2_115_top.vvp
	$(VVP) $<
$(BUILD)/tb_es_switch_de2_115_top.vvp: $(RTL_HEADERS) $(BOARD_TOP_SRCS) $(TB_COMMON) \
    $(TB_DIR)/sw_mii_if.sv $(BOARD_DIR)/tb_es_switch_de2_115_top.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_es_switch_de2_115_top $(BOARD_TOP_SRCS) \
	  $(TB_COMMON) $(TB_DIR)/sw_mii_if.sv $(BOARD_DIR)/tb_es_switch_de2_115_top.sv

# ---------------------------------------------------------------------------
# Main GMII system regression.  NUM_PORTS / CAM_SETS / CAM_WAYS are parameters
# of the testbench, so `param` and `param-scan` reuse the same source.
# ---------------------------------------------------------------------------
sim: $(BUILD)/tb_sw_pl_gmii.vvp
	$(VVP) $(BUILD)/tb_sw_pl_gmii.vvp

$(BUILD)/tb_sw_pl_gmii.vvp: $(RTL_HEADERS) $(RTL_SRCS) \
                            $(TB_DIR)/sw_tb_pkg.sv $(TB_DIR)/tb_sw_pl_gmii.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_pl_gmii $(RTL_SRCS) \
	  $(TB_DIR)/tb_sw_pl_gmii.sv

param: $(BUILD)/tb_sw_pl_param.vvp
	$(VVP) $(BUILD)/tb_sw_pl_param.vvp

$(BUILD)/tb_sw_pl_param.vvp: $(RTL_HEADERS) $(RTL_SRCS) \
                             $(TB_DIR)/sw_tb_pkg.sv $(TB_DIR)/tb_sw_pl_gmii.sv | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_sw_pl_gmii \
	  -P tb_sw_pl_gmii.NUM_PORTS=3 -P tb_sw_pl_gmii.CAM_SETS=96 \
	  -P tb_sw_pl_gmii.CAM_WAYS=3 \
	  $(RTL_SRCS) $(TB_DIR)/tb_sw_pl_gmii.sv

# Layered port-count / CAM-geometry scan (4/8/16/32/48 ports).  A full
# cross-product at 48 ports would exceed the CI time budget, so the large
# geometries run the same scenario suite but at sampled frame lengths.
param-scan: | $(BUILD)
	@set -e; \
	for cfg in "4 16 2" "4 96 3" "4 64 1" "8 32 4" "16 128 4" "32 64 2" "48 48 5"; do \
	  set -- $$cfg; \
	  echo "=== NUM_PORTS=$$1 CAM_SETS=$$2 CAM_WAYS=$$3 ==="; \
	  $(IVERILOG) $(IVFLAGS) -o $(BUILD)/pl_scan.vvp -s tb_sw_pl_gmii \
	    -P tb_sw_pl_gmii.NUM_PORTS=$$1 -P tb_sw_pl_gmii.CAM_SETS=$$2 \
	    -P tb_sw_pl_gmii.CAM_WAYS=$$3 \
	    $(RTL_SRCS) $(TB_DIR)/tb_sw_pl_gmii.sv; \
	  $(VVP) $(BUILD)/pl_scan.vvp; \
	done

# ---------------------------------------------------------------------------
# Synthesis readability check.  NOT part of `all`: the CI lint job runs it,
# and it is the only gate that enforces the three yosys restrictions that are
# invisible to Icarus and Verilator:
#   * a package item is not a constant range, so a port width taken from a
#     package is rejected outright,
#   * a package function has to be called as `pkg::f(x)`,
#   * no form of a package import is accepted at all,
#   * `return` in any function is a syntax error.
# The `-sv` is not optional: read_verilog does not infer SystemVerilog from the
# file extension.
# ---------------------------------------------------------------------------
# A single line: a backslash-newline inside the `-p` argument reaches yosys as
# a literal character and the first file name is read as a command.
YOSYS_SCRIPT = read_verilog -defer -noautowire -sv -I$(RTL_DIR) -DSYNTHESIS $(2); hierarchy -check -top $(1) -nokeep_prints -nokeep_asserts; synth -top $(1) -flatten; stat

synth:
	$(YOSYS) -p '$(call YOSYS_SCRIPT,es_switch_gmii,$(RTL_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,es_switch_mii,$(RTL_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,es_switch_rmii,$(RTL_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,es_switch_de2_115_top,$(BOARD_TOP_SRCS))'
	$(YOSYS) -p '$(call YOSYS_SCRIPT,es_switch_vivado_top,$(VIVADO_TOP_SRCS))'
	@echo "synthesises cleanly (es_switch_gmii, es_switch_mii, es_switch_rmii, es_switch_de2_115_top and es_switch_vivado_top tops)"

clean:
	rm -rf $(BUILD)

# Included declaration edits must invalidate previously compiled simulations.
$(wildcard $(BUILD)/*.vvp): $(RTL_HEADERS) $(RTL_SRCS)
