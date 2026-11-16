// ============================================================================
//  File        : es_rx_engine_tb.sv
//  Description : Stage 1 queue and descriptor regression. Byte values encode
//                their offsets so dropped prefixes and queue wrap are visible.
//                No MAC or downstream validation is required by this model.
// ============================================================================
`timescale 1ns/1ps
`include "es_defs.sv"

module es_rx_engine_tb;
  localparam int unsigned N = 3, MAX_LEN = 64;
  localparam int unsigned DW = es_pl_rx_desc_w(N), BASE = es_pl_desc_w(N);
  logic clk = 0, rst_n = 0;
  always #5 clk = !clk;
  logic link_up = 1, valid = 0, ready, sof = 0, eof = 0, err = 0;
  logic [7:0] data = 0, rd_data;
  logic desc_valid, desc_ready = 0, rd = 0, empty, crc_write;
  logic [DW-1:0] desc;
  int checks = 0, errors = 0;

  es_switch_stage_1_rx #(
    .NUM_PORTS     (N),
    .MAX_FRAME_LEN (MAX_LEN),
    .SLOTS         (1),
    .SLOT_BYTES    (128),
    .DESC_DEPTH    (2)
  ) dut (
        .clk_i       (clk),
        .rst_ni      (rst_n),
        .link_up_i   (link_up),
        .b_valid_i   (valid),
        .b_ready_o   (ready),
        .b_sof_i     (sof),
        .b_eof_i     (eof),
        .b_err_i     (err),
        .b_data_i    (data),
        .b_fcs_i     (32'h87654321),
        .crc_write_o (crc_write),
        .crc_i       (32'h0),
        .d_valid_o   (desc_valid),
        .d_ready_i   (desc_ready),
        .desc_o      (desc),
        .rd_i        (rd),
        .data_o      (rd_data),
        .empty_o     (empty)
      );

  // Lower the configured minimum only here to isolate truncated VLAN
  // from the runt rule. Stall the result to check ready/valid retention.
  logic validate_valid = 0, validate_ready, checked_valid, checked_ready = 0;
  logic [DW-1:0] candidate_desc, checked_desc;
  es_switch_stage_2_validate #(
    .NUM_PORTS     (N),
    .MIN_FRAME_LEN (14),
    .MAX_FRAME_LEN (MAX_LEN)
  ) u_validate (
    .clk_i   (clk),
    .rst_ni  (rst_n),
    .i_valid (validate_valid),
    .i_ready (validate_ready),
    .i_desc  (candidate_desc),
    .o_valid (checked_valid),
    .o_ready (checked_ready),
    .o_desc  (checked_desc)
  );

  task automatic check(input bit ok, input string label_text);
    checks++;
    $display("%s %s", ok ? "PASS" : "FAIL", label_text);
    if (!ok) errors++;
  endtask

  task automatic beat(input int index, input bit last, input bit bad);
    @(negedge clk);
    valid = 1; sof = (index == 0); eof = last; err = bad; data = 8'(index);
    @(posedge clk);
    #1;
    valid = 0; sof = 0; eof = 0; err = 0;
  endtask

  task automatic descriptor(input int stored, input int measured, input bit bad);
    check(desc_valid &&
          desc[es_pl_desc_stored_lsb(N) +: ES_LEN_W] == ES_LEN_W'(stored) &&
          desc[BASE +: ES_LEN_W+1] == (ES_LEN_W+1)'(measured) &&
          desc[BASE+ES_PL_RX_ERR_LSB] == bad, "descriptor counts and verdict");
    @(negedge clk); desc_ready = 1;
    @(posedge clk); #1; desc_ready = 0;
  endtask

  task automatic consume(input int stored);
    bit ordered;
    ordered = 1;
    for (int i = 0; i < stored; i++) begin
      @(negedge clk);
      ordered &= !empty && rd_data == 8'(i);
      rd = 1;
      @(posedge clk); #1; rd = 0;
    end
    check(ordered, "buffered prefix remains byte-exact");
  endtask

  task automatic vlan_case(input int unsigned len, input bit reject);
    logic [DW-1:0] held;
    @(negedge clk);
    candidate_desc = {64'b0, 1'b0, 1'b1, 16'h8100, (ES_LEN_W+1)'(len),
                      1'b0, ES_LEN_W'(len), 48'hffff_ffff_ffff,
                      48'h0201_0203_0405, ES_LEN_W'(len), es_port_w(N)'(0)};
    validate_valid = 1;
    check(validate_ready, "validate accepts descriptor");
    @(negedge clk); validate_valid = 0;
    check(checked_valid && checked_desc[BASE+ES_PL_RX_ERR_LSB] == reject &&
          checked_desc[es_pl_desc_len_lsb(N) +: ES_LEN_W] == (reject ? '0 : ES_LEN_W'(len)) &&
          checked_desc[es_pl_desc_stored_lsb(N) +: ES_LEN_W] == ES_LEN_W'(len),
          reject ? "reject truncated VLAN with intact accounting" : "accept complete VLAN header");
    held = checked_desc;
    repeat (3) @(negedge clk);
    check(checked_valid && !validate_ready && checked_desc === held, "validation result holds under backpressure");
    checked_ready = 1;
    @(negedge clk); checked_ready = 0;
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;

    for (int i = 0; i < MAX_LEN; i++) beat(i, 0, 0);
    check(!desc_valid && ready, "exact maximum waits for EOF or excess byte");
    beat(MAX_LEN, 0, 0);
    descriptor(MAX_LEN, MAX_LEN+1, 1);
    consume(MAX_LEN);
    check(empty && ready, "oversize prefix reclaimed before EOF");
    for (int i = MAX_LEN+1; i < MAX_LEN+8; i++) beat(i, i == MAX_LEN+7, 0);
    check(!desc_valid && empty, "remainder never publishes a second descriptor");

    beat(0, 0, 0); beat(1, 0, 1);
    descriptor(1, 2, 1); consume(1);
    beat(2, 1, 0);
    check(!desc_valid && empty, "receive error publishes once, then drains");

    beat(0, 0, 0);
    @(negedge clk); link_up = 0;
    @(posedge clk); #1;
    descriptor(1, 1, 1); consume(1);
    beat(1, 1, 0);
    check(!desc_valid && empty && !ready, "link-down drain closes without reopening admission");
    link_up = 1;

    for (int frame = 0; frame < 2; frame++)
      for (int i = 0; i < MAX_LEN; i++) beat(i, i == MAX_LEN-1, 0);
    check(!ready, "full descriptor and byte queues block admission");
    check(desc[BASE+ES_PL_RX_ERR_LSB+1 +: 32] == 32'h87654321, "EOF delivers raw FCS");
    for (int frame = 0; frame < 2; frame++) begin
      descriptor(MAX_LEN, MAX_LEN, 0); consume(MAX_LEN);
    end
    check(empty && !desc_valid && ready, "queues wrap and recover after congestion");
    vlan_case(17, 1);
    vlan_case(18, 0);
    $display("es_rx_engine_tb: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "stage 1 regression failed");
    $finish;
  end

  initial begin : watchdog
    #20000;
    $fatal(1, "stage 1 watchdog: no progress");
  end
endmodule
