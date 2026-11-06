// ============================================================================
//  File        : sim/sw_tb.f
//  Description : Testbench file list of the self-checking verification suite.
//
//                `sim/sw_rtl.f` must be compiled first: the testbench imports
//                `sw_tb_pkg` and the RTL provides the design under test.
//
//                Compile with:
//                  verilator -Wall -Irtl -Itb -f sim/sw_rtl.f -f sim/sw_tb.f \
//                            --top-module <top> --binary --timing
//                  vlog -sv +incdir+rtl,tb -f sim/sw_rtl.f -f sim/sw_tb.f
//
//                Contents
//                  sw_tb_pkg        - reference model helpers (CRC-32, frame
//                                     builder, formatting)
//                  sw_rec_q         - scoreboard record queue
//                  sw_gmii_if / sw_mii_if / sw_rmii_if - PHY bus functional
//                                     models (GMII / MII / RMII)
//                  sw_if_array      - per-port GMII model array
//                  sw_crc32_tb      - unit test of the CRC-32 engine
//                  sw_sync_fifo_tb  - unit test of the buffer
//                  sw_mac_table_tb  - unit test of the address table
//                  sw_mii_tb / sw_rmii_tb - symbol-adapter unit tests
//                  sw_flood_tb      - fabric regression
//                  sw_switch_param_tb - parameterisation test (3 ports, 50 MHz)
//                  tb_sw_switch     - system test with reference scoreboard
//                  tb_sw_switch_mii / tb_sw_switch_rmii - front-end smoke tests
// ============================================================================
tb/sw_tb_pkg.sv
tb/sw_rec_q.sv
tb/sw_gmii_if.sv
tb/sw_mii_if.sv
tb/sw_rmii_if.sv
tb/sw_if_array.sv
tb/sw_crc32_tb.sv
tb/sw_sync_fifo_reference.sv
tb/sw_sync_fifo_tb.sv
tb/sw_mac_table_reference.sv
tb/sw_mac_table_tb.sv
tb/sw_mii_tb.sv
tb/sw_rmii_tb.sv
tb/sw_flood_tb.sv
tb/sw_switch_param_tb.sv
tb/tb_sw_switch.sv
tb/tb_sw_switch_mii.sv
tb/tb_sw_switch_rmii.sv

tb/sw_page_reference.sv
tb/sw_shared_tb.sv
