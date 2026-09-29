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
//                The package is listed first because every other file imports
//                it and all supported simulators resolve imports in file
//                order.  Each module additionally carries
//                `include "sw_switch_pkg.sv"` (guarded, so it is a no-op when
//                the package has already been seen), which keeps every file
//                self-contained.  Some simulators - Questa among them -
//                pre-process each source file with a private macro scope and
//                therefore re-parse the package once per including file; that
//                produces a benign "package will be overwritten" note and
//                nothing else.
// ============================================================================
rtl/sw_switch_pkg.sv
rtl/sw_crc32.sv
rtl/sw_sync_fifo.sv
rtl/sw_gmii_rx.sv
rtl/sw_gmii_tx.sv
rtl/sw_mac_table.sv
rtl/sw_rx_port.sv
rtl/sw_tx_port.sv
rtl/sw_arbiter.sv
rtl/sw_switch.sv
