// ============================================================================
//  File        : sw_monitor_interval_tb.sv
//  Description : Parameterized telemetry publication-interval regression.
//
//                Checks three clock/interval combinations against a ceiling-rounded reference
//                clock count. Polling rejects early publication and reads back both window
//                words; the watchdog bounds a missing publication or stalled CSR response.
// ============================================================================
`timescale 1ns/1ps
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "monitor/es_monitor_defs.sv"
`include "console/es_console_defs.sv"
module sw_interval_case #(
  parameter int HZ = 100000, MS = 500
) (
  output logic finished = 0
);
  logic clk = 0, rst = 0;
  always #5 clk = ~clk;
  logic [31:0] address = 32'd196, data, index;
  logic ready, valid, cam_req;
  localparam logic [63:0] WINDOW = (64'(HZ) * 64'(MS) + 64'd999) / 64'd1000;
  logic [31:0] low_word;
  es_monitor_core #(
    .NUM_PORTS(1),
    .CLK_FREQ_HZ(HZ),
    .REFRESH_INTERVAL_MS(MS)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst),
    .port_stat_i('0),
    .tx_done_i(1'b0),
    .tx_len_i('0),
    .phy_status_i(8'd0),
    .rx_used_i(32'd0),
    .tx_used_i(32'd0),
    .busy_i(1'b0),
    .flush_i(1'b0),
    .cam_entries_i(32'd0),
    .req_i(rst && ready),
    .addr_i(address),
    .ready_o(ready),
    .valid_o(valid),
    .data_o(data),
    .cam_req_o(cam_req),
    .cam_index_o(index),
    .cam_valid_i(1'b0),
    .cam_entry_i(128'd0)
  );
  // --------------------------------------------------------------------------
  // Stimulus and expected results
  // --------------------------------------------------------------------------
  initial begin
    repeat (3) @(negedge clk);
    rst = 1;
    for (int c = 0; c < int'(WINDOW); c++) begin
      @(negedge clk);
      if (valid && data != 0) $fatal(1, "early publication HZ=%0d MS=%0d", HZ, MS);
    end
    wait (valid && data != 0);
    @(negedge clk);
    address = 32'd184;
    repeat (3) @(negedge clk);
    low_word = data;
    address  = 32'd188;
    repeat (3) @(negedge clk);
    if ({data, low_word} !== WINDOW)
      $fatal(1, "wrong interval HZ=%0d MS=%0d got=%h_%h", HZ, MS, data, low_word);
    $display("PASS interval HZ=%0d MS=%0d clocks=%0d", HZ, MS, WINDOW);
    finished = 1;
  end
endmodule
module sw_monitor_interval_tb;
  logic [2:0] finished;
  sw_interval_case default_case (finished[0]);
  sw_interval_case #(
    .HZ(100001),
    .MS(333)
  ) other_case (
    finished[1]
  );
  sw_interval_case #(
    .HZ(10000000),
    .MS(1)
  ) fast_case (
    finished[2]
  );
  initial begin
    wait (&finished);
    $display("sw_monitor_interval_tb: PASS 3 cases, 0 errors");
    $finish;
  end
  // --------------------------------------------------------------------------
  // Watchdog
  //
  // Bounds stalled handshakes and missing completion; expiration is a test
  // failure.
  // --------------------------------------------------------------------------
  initial begin
    #1_000_000;
    $fatal(1, "interval timeout");
  end
endmodule
