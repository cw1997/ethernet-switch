// ============================================================================
//  File        : sw_monitor_ui_tb.sv
//  Description : Page controls, telemetry display and LCD wire regression.
//
//                Exercises default and overridden port counts, button bounce, page wrap and
//                flush pulses. Display checks use constructed telemetry records; a falling-
//                enable LCD observer reconstructs written characters. Clock-counted models do
//                not verify physical LCD timing.
// ============================================================================
`timescale 1ns/1ps
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "monitor/es_monitor_defs.sv"
`include "console/es_console_defs.sv"
module sw_page_case #(
  parameter int N = 3,
  parameter bit USE_DEFAULT = 0
) (
  output logic finished = 0
);
  logic clk = 0, rst = 0;
  always #5 clk = ~clk;
  logic [2:0] keys = 3'b111;
  logic flush;
  logic [31:0] page;
  int errors = 0, flushes = 0;
  // The default case deliberately omits NUM_PORTS so a stale two-port default fails.
  generate
    if (USE_DEFAULT) begin : g_default
      es_monitor_page #(
        .CLK_FREQ_HZ(1000),
        .DEBOUNCE_MS(2)
      ) dut (
        .clk_i  (clk),
        .rst_ni (rst),
        .key_ni (keys),
        .flush_o(flush),
        .page_o (page)
      );
    end else begin : g_override
      es_monitor_page #(
        .NUM_PORTS  (N),
        .CLK_FREQ_HZ(1000),
        .DEBOUNCE_MS(2)
      ) dut (
        .clk_i  (clk),
        .rst_ni (rst),
        .key_ni (keys),
        .flush_o(flush),
        .page_o (page)
      );
    end
  endgenerate
  always @(negedge clk) if (flush) flushes++;
  // --------------------------------------------------------------------------
  // Reference and checking helpers
  // --------------------------------------------------------------------------
  task check(input bit ok, input string label);
    if (!ok) begin
      errors++;
      $display("FAIL page N=%0d %s got=%0d", N, label, page);
    end else $display("PASS page N=%0d %s", N, label);
  endtask
  task press(input logic [2:0] k);
    keys = k;
    repeat (10) @(negedge clk);
    keys = '1;
    repeat (10) @(negedge clk);
  endtask
  // --------------------------------------------------------------------------
  // Stimulus and expected results
  // --------------------------------------------------------------------------
  initial begin
    repeat (4) @(negedge clk);
    rst = 1;
    repeat (10) @(negedge clk);
    check(page == 0, "reset aggregate");
    keys = 3'b011;
    @(negedge clk);
    keys = '1;
    repeat (10) @(negedge clk);
    check(page == 0, "bounce ignored");
    press(3'b101);
    check(page == 32'(N), "previous from aggregate wraps to last port");
    press(3'b011);
    check(page == 0, "next from last port wraps to aggregate");
    for (int n = 1; n <= N; n++) begin
      press(3'b011);
      check(page == 32'(n), "next page");
    end
    press(3'b001);
    check(page == 32'(N), "simultaneous keys ignored");
    press(3'b110);
    check(flushes == 1, "flush one pulse per press");
    if (errors) $fatal(1, "page errors %0d", errors);
    finished = 1;
  end
endmodule
module sw_monitor_ui_tb;
  logic [4:0] finished;
  sw_page_case #(.N(1)) p1 (finished[0]);
  sw_page_case #(.N(2)) p2 (finished[1]);
  sw_page_case #(.N(3)) p3 (finished[2]);
  sw_page_case #(.N(5)) p5 (finished[3]);
  sw_page_case #(
    .N(4),
    .USE_DEFAULT(1)
  ) p4 (
    finished[4]
  );
  logic clk = 0, rst = 0;
  always #5 clk = ~clk;
  logic [3*SW_MON_BITS-1:0] image = '0;
  logic [31:0] page = 0;
  logic [55:0] hex;
  logic rk, tk;
  logic [255:0] text;
  logic [  7:0] lcd_data;
  logic rs, rw, en, on_pin, bl;
  int errors = 0, writes = 0;
  logic [255:0] screen = '0;
  int lcd_pos = 0;
  es_monitor_display #(
    .NUM_PORTS(2)
  ) display_dut (
    .clk_i(clk),
    .rst_ni(rst),
    .page_i(page),
    .image_i(image),
    .hex_o(hex),
    .rx_kpps_o(rk),
    .tx_kpps_o(tk),
    .text_o(text)
  );
  es_perips_lcd #(
    .CLK_FREQ_HZ(1_000_000)
  ) lcd_dut (
    .clk_i (clk),
    .rst_ni(rst),
    .text_i(text),
    .data_o(lcd_data),
    .rs_o  (rs),
    .rw_o  (rw),
    .en_o  (en),
    .on_o  (on_pin),
    .blon_o(bl)
  );
  always @(negedge en)
    if (rst) begin
      if (rw) $fatal(1, "LCD must be write only");
      if (!rs) begin
        if (lcd_data == 8'h80) lcd_pos = 0;
        if (lcd_data == 8'hc0) lcd_pos = 16;
      end else if (lcd_pos < 32) begin
        screen[255-lcd_pos*8 -: 8] = lcd_data;
        lcd_pos++;
        writes++;
      end
    end
  task check(input bit ok, input string label);
    if (ok) $display("PASS %s", label);
    else begin
      errors++;
      $display("FAIL %s screen=%s text=%s", label, screen, text);
    end
  endtask
  initial begin
    repeat (4) @(negedge clk);
    rst = 1;
    repeat (1500) @(negedge clk);
    check(text == "     ALLR------k     ALLT------k", "unavailable display before sample");
    image[49*32 +: 32] = 1;
    image[50*32] = 1;
    image[SW_MON_RATE*32 +: 64] = 64'd12345;
    image[(SW_MON_RATE+2)*32 +: 64] = 64'd987;
    image[(SW_MON_RATE+4)*32 +: 64] = 64'd100000000;
    image[(SW_MON_RATE+6)*32 +: 64] = 64'd2300000;
    image[SW_MON_BITS+SW_MON_RATE*32 +: 64] = 64'd20;
    image[SW_MON_BITS+(SW_MON_RATE+2)*32 +: 64] = 64'd40;
    image[SW_MON_BITS+(SW_MON_RATE+4)*32 +: 64] = 64'd3000;
    image[SW_MON_BITS+(SW_MON_RATE+6)*32 +: 64] = 64'd5000;
    repeat (1600) @(negedge clk);
    check(rk && !tk, "pps four digit auto scaling units");
    check(text == "     ALLR100000k     ALLT002300k", "aggregate LCD kbit/s conversion");
    page = 1;
    repeat (1600) @(negedge clk);
    check(!rk && !tk, "page reuses same sample without waiting interval");
    check(text == "00000000R000003k00000000T000005k", "LCD and HEX share port page");
    repeat (80_000) @(negedge clk);
    check(screen == text && writes >= 32, "LCD model receives complete correct two-row screen");
    check(on_pin && bl, "LCD power controls enabled");
    wait (&finished);
    $display("sw_monitor_ui_tb: %0d errors", errors);
    if (errors) $fatal(1, "UI failed");
    $finish;
  end
  // --------------------------------------------------------------------------
  // Watchdog
  //
  // Bounds stalled handshakes and missing completion; expiration is a test
  // failure.
  // --------------------------------------------------------------------------
  initial begin
    #2_000_000;
    $fatal(1, "UI timeout");
  end
endmodule
