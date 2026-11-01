// ============================================================================
//  File        : sim/sw_rtl.f
//  Description : RTL file list of the parameterised Ethernet Layer-2 switch.
//
//                Usage
//                -----
//                  Verilator : verilator -Wall -Irtl -f sim/sw_rtl.f \
//                                 --top-module <top> -f sim/sw_tb.f
//                  Questa    : vlog -sv +incdir+rtl -f sim/sw_rtl.f -work work
//                  VCS       : vcs -f sim/sw_rtl.f -f sim/sw_tb.f
//
//                `rtl/sw_defs.sv` is listed first because every other RTL file
//                includes it and it holds the shared declarations at
//                compilation-unit scope.  Each module additionally carries a
//                guarded `include "sw_defs.sv"`, which is a no-op when the
//                file has already been seen.  `sw_switch_core.sv` is the
//                interface-agnostic core; the three `sw_switch_*` wrappers are
//                the selectable top modules.
// ============================================================================
rtl/sw_defs.sv
rtl/sw_crc32.sv
rtl/sw_sync_fifo.sv
rtl/sw_gmii_rx.sv
rtl/sw_mii.sv
rtl/sw_rmii.sv
rtl/sw_rx_port.sv
rtl/sw_arbiter.sv
rtl/sw_mac_table.sv
rtl/sw_gmii_tx.sv
rtl/sw_tx_port.sv
rtl/sw_switch_core.sv
rtl/sw_switch_gmii.sv
rtl/sw_switch_mii.sv
rtl/sw_switch_rmii.sv
