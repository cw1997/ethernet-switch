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
//                `rtl/es_defs.sv` is listed first because every other RTL file
//                includes it and it holds the shared declarations at
//                compilation-unit scope.  Each module additionally carries a
//                guarded `include "es_defs.sv"`, which is a no-op when the
//                file has already been seen.  `es_switch_core.sv` is the
//                interface-agnostic core; the three `es_switch_*` wrappers are
//                the selectable top modules.
// ============================================================================
rtl/es_defs.sv
rtl/switch/es_switch_crc32.sv
rtl/switch/es_switch_sync_fifo.sv
rtl/switch/es_switch_gmii_rx.sv
rtl/switch/es_switch_mii_adapter.sv
rtl/switch/es_switch_rmii_adapter.sv
rtl/switch/es_switch_rx_port.sv
rtl/switch/es_switch_arbiter.sv
rtl/switch/es_switch_mac_table.sv
rtl/switch/es_switch_gmii_tx.sv
rtl/switch/es_switch_tx_port.sv
rtl/console/es_console_uart.sv
rtl/monitor/es_monitor_mdio.sv
rtl/monitor/es_monitor_phy.sv
rtl/monitor/es_monitor_cache.sv
rtl/monitor/es_monitor_page.sv
rtl/monitor/es_monitor_decimal.sv
rtl/monitor/es_monitor_lcd.sv
rtl/monitor/es_monitor_display.sv
rtl/console/es_console_core.sv
rtl/monitor/es_monitor_ratio.sv
rtl/monitor/es_monitor_core.sv
rtl/switch/es_switch_core.sv
rtl/switch/es_switch_gmii.sv
rtl/switch/es_switch_mii.sv
rtl/switch/es_switch_rmii.sv
