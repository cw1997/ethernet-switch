// ============================================================================
//  File        : sw_fabric_tb.sv
//  Description : End-to-end regression for the staged switch fabric (S0..S5).
//
//                Drives the 8-bit byte-stream contract directly, without the
//                MAC pin adapters, so a failure can only come from the
//                pipeline itself.  Each egress has an independent wire model
//                that reconstructs frame length, a byte checksum and the two
//                MAC addresses - enough to catch a dropped, duplicated,
//                misrouted or corrupted frame without any unpacked-array or
//                run-time-indexed storage in the testbench.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"

module sw_fabric_mon (
  input  var logic       clk_i,
  input  var logic       rst_ni,
  input  var logic       valid_i,
  input  var logic       ready_i,
  input  var logic       sof_i,
  input  var logic       eof_i,
  input  var logic [7:0] data_i,
  input  var logic       clear_i,
  output      logic [11:0] len_o,
  output      logic [7:0]  sum_o,
  output      logic [47:0] dst_o,
  output      logic [47:0] src_o,
  output      logic [3:0]  cnt_o
);
  logic [11:0] idx;
  logic [11:0] len_r;
  logic [7:0]  sum_r;
  logic [47:0] dst_r;
  logic [47:0] src_r;
  logic [3:0]  cnt_r;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      idx   <= '0;
      len_r <= '0;
      sum_r <= '0;
      dst_r <= '0;
      src_r <= '0;
      cnt_r <= '0;
    end else if (valid_i && ready_i) begin
      if (sof_i) begin
        idx   <= '0;
        sum_r <= '0;
        dst_r <= '0;
        src_r <= '0;
      end
      sum_r <= sum_r + data_i;
      if (idx < 12'd6)      dst_r <= {dst_r[39:0], data_i};
      else if (idx < 12'd12) src_r <= {src_r[39:0], data_i};
      idx <= idx + 12'd1;
      if (eof_i) begin
        len_r <= idx + 12'd1;
        cnt_r <= cnt_r + 4'd1;
      end
    end
  end

  assign len_o = len_r;
  assign sum_o = sum_r;
  assign dst_o = dst_r;
  assign src_o = src_r;
  assign cnt_o = cnt_r;
endmodule : sw_fabric_mon

module sw_fabric_tb;

  localparam int unsigned NUM_PORTS = 4;
  localparam int unsigned MAXF      = 256;
  localparam int unsigned NW        = NUM_PORTS*8;

  logic clk;
  logic rst_n;
  logic clear;

  logic [NUM_PORTS-1:0]   rx_valid;
  logic [NUM_PORTS-1:0]   rx_ready;
  logic [NUM_PORTS*8-1:0] rx_data;
  logic [NUM_PORTS-1:0]   rx_sof;
  logic [NUM_PORTS-1:0]   rx_eof;
  logic [NUM_PORTS-1:0]   rx_err;
  logic [NUM_PORTS-1:0]   link_up;

  logic [NUM_PORTS-1:0]   tx_valid;
  logic [NUM_PORTS-1:0]   tx_ready;
  logic [NUM_PORTS*8-1:0] tx_data;
  logic [NUM_PORTS-1:0]   tx_sof;
  logic [NUM_PORTS-1:0]   tx_eof;

  logic [NUM_PORTS*12-1:0] mon_len;
  logic [NUM_PORTS*8-1:0]  mon_sum;
  logic [NUM_PORTS*48-1:0] mon_dst;
  logic [NUM_PORTS*48-1:0] mon_src;
  logic [NUM_PORTS*4-1:0]  mon_cnt;

  initial begin : clk_gen
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  es_switch_fabric #(
    .NUM_PORTS      (NUM_PORTS),
    .MIN_FRAME_LEN  (64),
    .MAX_FRAME_LEN  (1518),
    .SLOTS          (2),
    .SLOT_BYTES     (2048),
    .DESC_DEPTH     (8),
    .TX_QUEUE_DEPTH (256),
    .CAM_SETS       (16),
    .CAM_WAYS       (2),
    .LEARNING_EN    (1),
    .FLOOD_MODE     (2'd1)
  ) u_dut (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .link_up_i (link_up),
    .rx_valid_i(rx_valid), .rx_ready_o(rx_ready), .rx_data_i(rx_data),
    .rx_sof_i  (rx_sof),   .rx_eof_i  (rx_eof),   .rx_err_i (rx_err),
    .tx_valid_o(tx_valid), .tx_ready_i(tx_ready), .tx_data_o(tx_data),
    .tx_sof_o  (tx_sof),   .tx_eof_o  (tx_eof)
  );

  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_mon
      sw_fabric_mon u_mon (
        .clk_i  (clk),       .rst_ni (rst_n),
        .valid_i(tx_valid[g]), .ready_i(tx_ready[g]),
        .sof_i  (tx_sof[g]),   .eof_i  (tx_eof[g]),
        .data_i (tx_data[g*8 +: 8]), .clear_i(clear),
        .len_o  (mon_len[g*12 +: 12]), .sum_o(mon_sum[g*8 +: 8]),
        .dst_o  (mon_dst[g*48 +: 48]), .src_o(mon_src[g*48 +: 48]),
        .cnt_o  (mon_cnt[g*4 +: 4])
      );
    end
  endgenerate

  int unsigned checks;
  int unsigned errors;

  task automatic check(input bit ok, input string label);
    checks = checks + 1;
    if (!ok) begin
      errors = errors + 1;
      $display("[%0t] FAIL %s", $time, label);
    end
  endtask

  function automatic logic [MAXF*8-1:0] mk_frame(
      input logic [47:0] dst, input logic [47:0] src,
      input int unsigned len);
    logic [MAXF*8-1:0] img;
    int unsigned i;
    img = '0;
    for (i = 0; i < 6; i++) img[i*8 +: 8] = dst[47-8*i -: 8];
    for (i = 0; i < 6; i++) img[(6+i)*8 +: 8] = src[47-8*i -: 8];
    img[12*8 +: 8] = 8'h08;
    img[13*8 +: 8] = 8'h00;
    for (i = 14; i < len; i++) img[i*8 +: 8] = 8'(i);
    mk_frame = img;
  endfunction

  function automatic logic [7:0] frame_sum(input logic [MAXF*8-1:0] img,
                                           input int unsigned len);
    logic [7:0] s;
    int unsigned i;
    s = 8'd0;
    for (i = 0; i < len; i++) s = s + img[i*8 +: 8];
    frame_sum = s;
  endfunction

  // Whole-vector assignments avoid a run-time-indexed store into a packed
  // bus inside a procedural block (Icarus is conservative about those).
  task automatic send_frame(input int unsigned port,
                            input logic [47:0] dst, input logic [47:0] src,
                            input int unsigned len, input bit err_last);
    logic [MAXF*8-1:0] img;
    int unsigned i;
    img = mk_frame(dst, src, len);
    for (i = 0; i < len; i++) begin
      @(negedge clk);
      rx_valid = (NUM_PORTS'(1) << port);
      rx_data  = NW'(img[i*8 +: 8]) << (port*8);
      rx_sof   = (NUM_PORTS'(1) << port) & {NUM_PORTS{(i == 0)}};
      rx_eof   = (NUM_PORTS'(1) << port) & {NUM_PORTS{(i == len-1)}};
      rx_err   = (NUM_PORTS'(1) << port) & {NUM_PORTS{err_last && (i == len-1)}};
    end
    @(posedge clk);
    #1;
    rx_valid = '0;
    rx_sof   = '0;
    rx_eof   = '0;
    rx_err   = '0;
    rx_data  = '0;
  endtask

  task automatic idle(input int unsigned n);
    int unsigned i;
    rx_valid = '0; rx_sof = '0; rx_eof = '0; rx_err = '0; rx_data = '0;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  task automatic clear_monitors();
    clear = 1'b1;
    @(posedge clk);
    #1;
    clear = 1'b0;
  endtask

  task automatic expect_on(input int unsigned port, input int unsigned cnt,
                           input logic [47:0] dst, input logic [47:0] src,
                           input int unsigned len, input string label);
    logic [7:0] want_sum;
    want_sum = frame_sum(mk_frame(dst, src, len), len);
    check(mon_cnt[port*4 +: 4] == 4'(cnt), {label, ": frame count"});
    if (cnt != 0) begin
      check(mon_len[port*12 +: 12] == 12'(len), {label, ": length"});
      check(mon_sum[port*8 +: 8] == want_sum,  {label, ": payload"});
      check(mon_dst[port*48 +: 48] == dst,     {label, ": dst MAC"});
      check(mon_src[port*48 +: 48] == src,     {label, ": src MAC"});
    end
  endtask

  logic [47:0] host_a;
  logic [47:0] host_b;
  logic [47:0] host_c;
  logic [47:0] bcast;

  initial begin : main_proc
    checks = 0;
    errors = 0;
    host_a = 48'h02_aa_00_00_00_01;
    host_b = 48'h02_bb_00_00_00_02;
    host_c = 48'h02_cc_00_00_00_03;
    bcast  = SW_MAC_BROADCAST;

    rst_n    = 1'b0;
    clear    = 1'b0;
    link_up  = '1;
    tx_ready = '1;
    rx_valid = '0; rx_data = '0; rx_sof = '0; rx_eof = '0; rx_err = '0;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    idle(4);
    clear_monitors();

    // ---- 1. broadcast floods to every other port, never the source -------
    send_frame(0, bcast, host_a, 64, 0);
    idle(160);
    expect_on(0, 0, bcast, host_a, 64, "bcast src port 0");
    expect_on(1, 1, bcast, host_a, 64, "bcast port 1");
    expect_on(2, 1, bcast, host_a, 64, "bcast port 2");
    expect_on(3, 1, bcast, host_a, 64, "bcast port 3");
    clear_monitors();

    // ---- 2. learning: HOST_B on port 2, then a known unicast ------------
    send_frame(2, bcast, host_b, 64, 0);
    idle(160);
    clear_monitors();
    send_frame(0, host_b, host_a, 64, 0);
    idle(160);
    expect_on(0, 0, host_b, host_a, 64, "known unicast filtered at src");
    expect_on(1, 0, host_b, host_a, 64, "known unicast not on port 1");
    expect_on(2, 1, host_b, host_a, 64, "known unicast reaches port 2");
    expect_on(3, 0, host_b, host_a, 64, "known unicast not on port 3");
    clear_monitors();

    // ---- 3. unknown unicast floods ---------------------------------------
    send_frame(1, host_c, host_a, 64, 0);
    idle(160);
    expect_on(0, 1, host_c, host_a, 64, "unknown unicast port 0");
    expect_on(1, 0, host_c, host_a, 64, "unknown unicast src port 1");
    expect_on(2, 1, host_c, host_a, 64, "unknown unicast port 2");
    expect_on(3, 1, host_c, host_a, 64, "unknown unicast port 3");
    clear_monitors();

    // ---- 4. a corrupt frame is dropped everywhere ------------------------
    send_frame(0, bcast, host_a, 64, 1);
    idle(160);
    expect_on(0, 0, bcast, host_a, 64, "bad FCS src");
    expect_on(1, 0, bcast, host_a, 64, "bad FCS port 1");
    expect_on(2, 0, bcast, host_a, 64, "bad FCS port 2");
    expect_on(3, 0, bcast, host_a, 64, "bad FCS port 3");
    clear_monitors();

    // ---- 5. MAC relocation -----------------------------------------------
    // Test 3 re-learned HOST_A on port 1 (every legal frame learns its source),
    // so a frame addressed to HOST_A must now go to port 1, not port 0.
    send_frame(0, host_a, host_b, 64, 0);
    idle(160);
    expect_on(0, 0, host_a, host_b, 64, "moved unicast filtered at src");
    expect_on(1, 1, host_a, host_b, 64, "moved unicast reaches new port 1");
    expect_on(2, 0, host_a, host_b, 64, "moved unicast not on port 2");
    expect_on(3, 0, host_a, host_b, 64, "moved unicast not on port 3");
    clear_monitors();

    // ---- 6. source-port filter: destination learned on the ingress port ---
    send_frame(3, bcast, host_c, 64, 0);
    idle(160);
    clear_monitors();
    send_frame(3, host_c, host_a, 64, 0);
    idle(160);
    expect_on(0, 0, host_c, host_a, 64, "self-dest filtered port 0");
    expect_on(1, 0, host_c, host_a, 64, "self-dest filtered port 1");
    expect_on(2, 0, host_c, host_a, 64, "self-dest filtered port 2");
    expect_on(3, 0, host_c, host_a, 64, "self-dest filtered at src");

    if (errors == 0) $display("sw_fabric_tb: PASSED (%0d checks)", checks);
    else             $display("sw_fabric_tb: FAILED (%0d of %0d checks)", errors, checks);
    if (errors != 0) $fatal(1, "sw_fabric_tb: FAILED");
    $finish;
  end

  initial begin : watchdog
    #2000000;
    $fatal(1, "sw_fabric_tb: timeout");
  end

endmodule : sw_fabric_tb
