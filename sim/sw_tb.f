// ============================================================================
//  File        : sim/sw_tb.f
//  Description : Testbench file list of the self-checking verification suite.
//
//                `sim/sw_rtl.f` must be compiled first: the testbench imports
//                `sw_switch_pkg` (through `sw_l2_tb_lib`) and the RTL provides
//                the design under test.
//
//                Compile with:
//                  verilator -Wall -Irtl -Itb -f sim/sw_rtl.f -f sim/sw_tb.f \
//                            --top-module <top> --binary --timing
//                  vlog -sv +incdir+rtl,tb -f sim/sw_rtl.f -f sim/sw_tb.f
//
//                Contents
//                  sw_l2_tb_lib          - reference model helpers (CRC-32,
//                                          frame builder, formatting)
//                  sw_tb_gmii_driver     - GMII transmit bus functional model
//                  sw_tb_gmii_monitor    - GMII receive bus functional model
//                  sw_crc32_tb           - unit test of the CRC-32 engine
//                  sw_sync_fifo_tb       - unit test of the buffer
//                  sw_mac_table_tb       - unit test of the address table
//                  sw_switch_param_tb    - parameterisation test (3 ports, 50 MHz)
//                  sw_switch_tb          - system test with reference scoreboard
// ============================================================================
tb/sw_l2_tb_lib.sv
tb/sw_tb_gmii_driver.sv
tb/sw_tb_gmii_monitor.sv
tb/sw_crc32_tb.sv
tb/sw_sync_fifo_tb.sv
tb/sw_mac_table_tb.sv
tb/sw_switch_param_tb.sv
tb/sw_switch_tb.sv
