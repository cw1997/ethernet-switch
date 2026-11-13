// ============================================================================
//  File        : sw_rx_engine_tb.sv
//  Description : Self-checking regression for the S0/S1 receive level.
//
//                Drives the byte-stream contract exactly as a MAC adapter
//                would (client data only, sof on the first octet, eof on the
//                last, err with the eof) and checks two things independently:
//                the descriptor published for a legal frame, and the bytes
//                that can subsequently be read out of the frame buffer.  A
//                rejected frame must produce neither.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"

module sw_rx_engine_tb;

  localparam int unsigned NUM_PORTS = 4;
  localparam int unsigned PORT_ID   = 2;
  localparam int unsigned MAXB      = 2048;
  localparam int unsigned DESC_W    = sw_pl_desc_w(NUM_PORTS);
  localparam int unsigned PW        = sw_port_w(NUM_PORTS);
  localparam int unsigned DST_LSB   = sw_pl_desc_dstm_lsb(NUM_PORTS);
  localparam int unsigned SRC_LSB   = sw_pl_desc_srcm_lsb(NUM_PORTS);
  localparam int unsigned LEN_LSB   = sw_pl_desc_len_lsb(NUM_PORTS);

  logic clk;
  logic rst_n;

  logic       b_valid;
  logic       b_ready;
  logic [7:0] b_data;
  logic       b_sof;
  logic       b_eof;
  logic       b_err;

  logic                dvalid;
  logic                drd;
  logic [DESC_W-1:0]   dout;

  logic                brd;
  logic [7:0]          bout;
  logic                bempty;

  initial begin : clk_gen
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  es_switch_rx_engine #(
    .NUM_PORTS     (NUM_PORTS),
    .PORT_ID       (PORT_ID),
    .PORT_MAC      (48'h02_00_00_00_00_02),
    .MIN_FRAME_LEN (64),
    .MAX_FRAME_LEN (1518),
    .SLOTS         (2),
    .SLOT_BYTES    (2048),
    .DESC_DEPTH    (8)
  ) u_dut (
    .clk_i    (clk),
    .rst_ni   (rst_n),
    .b_valid_i(b_valid), .b_ready_o(b_ready), .b_data_i(b_data),
    .b_sof_i  (b_sof),   .b_eof_i  (b_eof),   .b_err_i  (b_err),
    .dvalid_o (dvalid),  .drd_i    (drd),     .dout_o   (dout),
    .brd_i    (brd),     .bout_o   (bout),    .bempty_o (bempty)
  );

  int unsigned checks;
  int unsigned errors;

  task automatic check(input bit ok, input string label);
    checks = checks + 1;
    if (!ok) begin
      errors = errors + 1;
      $display("[%0t] FAIL %s", $time, label);
    end
  endtask

  // Build a MAC client frame: dst(6) src(6) l2type(2) optional tag(4) payload.
  function automatic logic [MAXB*8-1:0] mk_frame(
      input logic [47:0] dst, input logic [47:0] src,
      input logic [15:0] l2type, input int unsigned len, input bit vlan);
    logic [MAXB*8-1:0] img;
    int unsigned i;
    int unsigned n;
    img = '0;
    for (i = 0; i < 6; i++) img[i*8 +: 8] = dst[47-8*i -: 8];
    for (i = 0; i < 6; i++) img[(6+i)*8 +: 8] = src[47-8*i -: 8];
    img[12*8 +: 8] = l2type[15:8];
    img[13*8 +: 8] = l2type[7:0];
    n = 14;
    if (vlan) begin
      img[14*8 +: 8] = 8'h00;
      img[15*8 +: 8] = 8'h01;
      img[16*8 +: 8] = 8'h08;
      img[17*8 +: 8] = 8'h00;
      n = 18;
    end
    for (i = n; i < len; i++) img[i*8 +: 8] = 8'(i);
    mk_frame = img;
  endfunction

  task automatic idle(input int unsigned n);
    int unsigned i;
    b_valid = 1'b0;
    b_sof   = 1'b0;
    b_eof   = 1'b0;
    b_err   = 1'b0;
    drd     = 1'b0;
    brd     = 1'b0;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  // Send n client octets.  `err_last` marks the whole frame bad via b_err_i.
  task automatic send(input logic [MAXB*8-1:0] img, input int unsigned n,
                      input bit err_last);
    int unsigned i;
    for (i = 0; i < n; i++) begin
      @(negedge clk);
      b_valid = 1'b1;
      b_data  = img[i*8 +: 8];
      b_sof   = (i == 0);
      b_eof   = (i == n-1);
      b_err   = err_last && (i == n-1);
    end
    @(posedge clk);
    #1;
  endtask

  // Consume one descriptor and its frame, or verify that nothing was queued.
  task automatic expect_frame(input logic [MAXB*8-1:0] img, input int unsigned n,
                              input logic [47:0] dst, input logic [47:0] src,
                              input string label);
    int unsigned i;
    logic [DESC_W-1:0] desc;
    idle(3);
    check(dvalid === 1'b1, {label, ": descriptor missing"});
    if (dvalid) begin
      desc = dout;
      check(desc[DST_LSB +: 48] === dst, {label, ": dst MAC"});
      check(desc[SRC_LSB +: 48] === src, {label, ": src MAC"});
      check(desc[LEN_LSB +: SW_LEN_W] === SW_LEN_W'(n), {label, ": length"});
      check(desc[0 +: PW] === PW'(PORT_ID), {label, ": src port"});
      drd = 1'b1;
      @(posedge clk);
      #1;
      drd = 1'b0;
      for (i = 0; i < n; i++) begin
        check(bempty === 1'b0, {label, ": byte FIFO empty early"});
        check(bout === img[i*8 +: 8], {label, ": byte content"});
        brd = 1'b1;
        @(posedge clk);
        #1;
      end
      brd = 1'b0;
      check(bempty === 1'b1, {label, ": byte FIFO not empty after frame"});
    end
  endtask

  task automatic expect_drop(input string label);
    idle(4);
    check(dvalid === 1'b0, {label, ": bad frame produced a descriptor"});
    check(bempty === 1'b1, {label, ": bad frame bytes were not rewound"});
  endtask

  logic [MAXB*8-1:0] img;
  logic [47:0] host_a;
  logic [47:0] host_b;

  initial begin : main_proc
    checks = 0;
    errors = 0;
    host_a = 48'h02_11_11_11_11_11;
    host_b = 48'h02_22_22_22_22_22;
    rst_n  = 1'b0;
    b_valid = 1'b0; b_data = 8'd0; b_sof = 1'b0; b_eof = 1'b0; b_err = 1'b0;
    drd = 1'b0; brd = 1'b0;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    idle(3);

    // ---- legal minimum frame ---------------------------------------------
    img = mk_frame(host_b, host_a, 16'h0800, 64, 0);
    send(img, 64, 0);
    expect_frame(img, 64, host_b, host_a, "legal 64");
    idle(3);

    // ---- legal 802.1Q frame ----------------------------------------------
    img = mk_frame(host_b, host_a, 16'h8100, 128, 1);
    send(img, 128, 0);
    expect_frame(img, 128, host_b, host_a, "vlan 128");
    idle(3);

    // ---- back-to-back frames ----------------------------------------------
    img = mk_frame(host_a, host_b, 16'h0800, 100, 0);
    send(img, 100, 0);
    idle(1);
    expect_frame(img, 100, host_a, host_b, "back-to-back");
    idle(3);

    // ---- runt --------------------------------------------------------------
    img = mk_frame(host_b, host_a, 16'h0800, 40, 0);
    send(img, 40, 0);
    expect_drop("runt");

    // ---- bad FCS / RX_ER verdict -------------------------------------------
    img = mk_frame(host_b, host_a, 16'h0800, 100, 0);
    send(img, 100, 1);
    expect_drop("bad FCS");

    // ---- over MTU ----------------------------------------------------------
    img = mk_frame(host_b, host_a, 16'h0800, 1519, 0);
    send(img, 1519, 0);
    expect_drop("over MTU");
    idle(6);   // let the drain reach eof

    // ---- exactly MTU is legal ----------------------------------------------
    img = mk_frame(host_b, host_a, 16'h0800, 1518, 0);
    send(img, 1518, 0);
    expect_frame(img, 1518, host_b, host_a, "exactly MTU");
    idle(4);

    // ---- group source address ----------------------------------------------
    img = mk_frame(host_b, 48'h01_00_00_00_00_01, 16'h0800, 100, 0);
    send(img, 100, 0);
    expect_drop("group source");

    // ---- this port's own address as source ---------------------------------
    img = mk_frame(host_b, 48'h02_00_00_00_00_02, 16'h0800, 100, 0);
    send(img, 100, 0);
    expect_drop("own source");

    // ---- 802.3 length field mismatch ---------------------------------------
    img = mk_frame(host_b, host_a, 16'h0032, 100, 0);
    send(img, 100, 0);
    expect_drop("802.3 length mismatch");

    // ---- VLAN tag truncated ------------------------------------------------
    img = mk_frame(host_b, host_a, 16'h8100, 16, 0);
    send(img, 16, 0);
    expect_drop("truncated VLAN tag");

    // ---- reset in the middle of a frame ------------------------------------
    img = mk_frame(host_b, host_a, 16'h0800, 100, 0);
    @(negedge clk);
    b_valid = 1'b1; b_data = img[0*8 +: 8]; b_sof = 1'b1; b_eof = 1'b0; b_err = 1'b0;
    @(posedge clk); #1;
    rst_n = 1'b0;
    repeat (2) @(posedge clk); #1;
    rst_n = 1'b1;
    b_valid = 1'b0; b_sof = 1'b0;
    idle(4);
    check(dvalid === 1'b0, "reset mid-frame produced a descriptor");
    check(bempty === 1'b1, "reset mid-frame left bytes buffered");

    if (errors == 0) $display("sw_rx_engine_tb: PASSED (%0d checks)", checks);
    else             $display("sw_rx_engine_tb: FAILED (%0d of %0d checks)", errors, checks);
    if (errors != 0) $fatal(1, "sw_rx_engine_tb: FAILED");
    $finish;
  end

  initial begin : watchdog
    #2000000;
    $fatal(1, "sw_rx_engine_tb: timeout");
  end

endmodule : sw_rx_engine_tb
