// ============================================================================
//  File        : sw_pipe_stage_tb.sv
//  Description : Self-checking regression for es_common_pipe_stage.
//
//                Models the WIRE, not the RTL: the only assumption is that a
//                valid/ready handshake transfers exactly one octet and that a
//                stage preserves order.  The payload is a free-running counter,
//                so any duplicated, dropped or reordered beat is caught by
//                `o_dat == recv_count` without a queue (Icarus cannot be
//                trusted with a run-time-indexed unpacked array).
//
//                Timing model (the subtle part)
//                -----------------------------
//                A pipe stage replaces its data register on the SAME edge that
//                clears its valid bit, so the outgoing word must be sampled in
//                the half-cycle BEFORE that edge, not after it.  Each cycle is
//                therefore: drive just after a posedge -> sample at the next
//                negedge (these are the values that posedge will use) -> wait
//                for the posedge -> repeat.  Sampling and then re-driving in
//                the same negedge would make the edge see a different word
//                from the one the scoreboard recorded.
// ============================================================================
`timescale 1ns/1ps

module sw_pipe_stage_case #(
  parameter int unsigned DP        = 1,
  parameter int unsigned CUT_READY = 0,
  parameter int unsigned FLUSH_EN  = 0,
  parameter int unsigned NCYC      = 240,
  parameter int unsigned CASE_ID   = 0
) (
  input var logic clk_i,
  output      logic pass_o,
  output      logic done_o
);

  logic       rst_n;
  logic       i_valid;
  logic [7:0] i_dat;
  logic       o_ready;
  logic       flush_req;
  logic       i_ready;
  logic       o_valid;
  logic [7:0] o_dat;
  logic       flush_ack;

  es_common_pipe_stage #(
    .CUT_READY (CUT_READY),
    .DP        (DP),
    .DW        (8),
    .FLUSH_EN  (FLUSH_EN)
  ) u_dut (
    .clk_i       (clk_i),
    .rst_ni      (rst_n),
    .i_valid     (i_valid),
    .i_ready     (i_ready),
    .i_dat       (i_dat),
    .o_valid     (o_valid),
    .o_ready     (o_ready),
    .o_dat       (o_dat),
    .flush_req_i (flush_req),
    .flush_ack_o (flush_ack)
  );

  int unsigned sent;
  int unsigned recv;
  int unsigned checks;
  int unsigned errors;
  int unsigned cycle;
  logic [7:0]  cur_payload;
  logic [7:0]  expected;

  task automatic check_bit(input bit ok, input string label);
    checks = checks + 1;
    if (!ok) begin
      errors = errors + 1;
      $display("[%0t] FAIL case%0d %s", $time, CASE_ID, label);
    end
  endtask

  // One full clock: drive, sample before the edge, then cross the edge.
  // `en_check` is 0 while the consumer is deliberately stalled.
  task automatic do_cycle(input logic d_valid, input logic d_ready,
                          input logic d_flush, input bit en_check);
    i_valid   = d_valid;
    o_ready   = d_ready;
    flush_req = d_flush;
    i_dat     = cur_payload;

    @(negedge clk_i);
    if (i_valid && i_ready) begin
      sent        = sent + 1;
      cur_payload = cur_payload + 8'd1;
    end
    if (o_valid && o_ready) begin
      expected = 8'(recv);
      if (en_check) check_bit(o_dat === expected, "stream payload out of order");
      recv = recv + 1;
    end

    @(posedge clk_i);
    #1;
  endtask

  initial begin : case_proc
    rst_n       = 1'b0;
    i_valid     = 1'b0;
    i_dat       = 8'd0;
    o_ready     = 1'b0;
    flush_req   = 1'b0;
    sent        = 0;
    recv        = 0;
    checks      = 0;
    errors      = 0;
    cur_payload = 8'd0;
    pass_o      = 1'b0;
    done_o      = 1'b0;

    repeat (4) @(posedge clk_i);
    #1;
    rst_n = 1'b1;

    // ---- main stream: periodic backpressure and input bubbles -------------
    for (cycle = 0; cycle < NCYC; cycle++) begin
      do_cycle(~((cycle % 7) == 0), ~((cycle % 4) == 0), 1'b0, 1'b1);
    end

    // ---- drain with the consumer always ready -----------------------------
    for (cycle = 0; cycle < DP + 16; cycle++) begin
      do_cycle(1'b0, 1'b1, 1'b0, 1'b1);
    end
    check_bit(sent == recv, "stream lost or duplicated a beat");
    @(negedge clk_i);
    check_bit(o_valid == 1'b0, "stage still valid after drain");
    @(posedge clk_i);
    #1;

    // ---- flush: fill the pipeline, drop it, expect silence ----------------
    if (FLUSH_EN != 0) begin
      for (cycle = 0; cycle < DP + 4; cycle++) begin
        do_cycle(1'b1, 1'b0, 1'b0, 1'b0);
      end
      check_bit(flush_ack == 1'b0, "flush ack asserted without a request");

      i_valid   = 1'b0;
      o_ready   = 1'b0;
      flush_req = 1'b1;
      i_dat     = cur_payload;
      @(negedge clk_i);
      check_bit(flush_ack == 1'b1, "flush request not acknowledged");
      check_bit(i_ready == 1'b0, "flush accepted an item and lost it");
      @(posedge clk_i);
      #1;

      flush_req = 1'b0;
      o_ready   = 1'b1;
      i_valid   = 1'b0;
      i_dat     = cur_payload;
      for (cycle = 0; cycle < DP + 8; cycle++) begin
        @(negedge clk_i);
        check_bit(o_valid == 1'b0, "flush left a live item in the stage");
        @(posedge clk_i);
        #1;
      end
    end

    // ---- synchronous reset ------------------------------------------------
    rst_n     = 1'b0;
    i_valid   = 1'b0;
    o_ready   = 1'b1;
    flush_req = 1'b0;
    i_dat     = cur_payload;
    repeat (2) @(posedge clk_i);
    #1;
    @(negedge clk_i);
    check_bit(o_valid == 1'b0, "reset left a live item in the stage");
    @(posedge clk_i);
    #1;
    rst_n = 1'b1;
    @(negedge clk_i);
    check_bit(o_valid == 1'b0, "reset release injected a phantom item");
    @(posedge clk_i);
    #1;

    if (errors == 0)
      $display("[%0t] PASS case%0d DP=%0d CUT_READY=%0d FLUSH_EN=%0d (%0d checks)",
               $time, CASE_ID, DP, CUT_READY, FLUSH_EN, checks);
    else
      $display("[%0t] FAIL case%0d (%0d of %0d checks failed)",
               $time, CASE_ID, errors, checks);

    pass_o = (errors == 0);
    done_o = 1'b1;
  end

endmodule : sw_pipe_stage_case

// ============================================================================
//  Top: four configurations in parallel, one shared clock.
// ============================================================================
module sw_pipe_stage_tb;

  logic clk;
  logic [3:0] pass;
  logic [3:0] done;

  initial begin : clk_gen
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  sw_pipe_stage_case #(.DP(0), .CUT_READY(0), .FLUSH_EN(0), .CASE_ID(0)) u0 (
    .clk_i(clk), .pass_o(pass[0]), .done_o(done[0]));
  sw_pipe_stage_case #(.DP(1), .CUT_READY(0), .FLUSH_EN(1), .CASE_ID(1)) u1 (
    .clk_i(clk), .pass_o(pass[1]), .done_o(done[1]));
  sw_pipe_stage_case #(.DP(1), .CUT_READY(1), .FLUSH_EN(1), .CASE_ID(2)) u2 (
    .clk_i(clk), .pass_o(pass[2]), .done_o(done[2]));
  sw_pipe_stage_case #(.DP(2), .CUT_READY(0), .FLUSH_EN(1), .CASE_ID(3)) u3 (
    .clk_i(clk), .pass_o(pass[3]), .done_o(done[3]));

  initial begin : watchdog
    #500000;
    $fatal(1, "sw_pipe_stage_tb: timeout");
  end

  initial begin : verdict
    wait (done == 4'b1111);
    if (pass != 4'b1111) begin
      $display("sw_pipe_stage_tb: FAILED");
      $fatal(1, "sw_pipe_stage_tb: one or more cases failed");
    end
    $display("sw_pipe_stage_tb: PASSED (4 configurations)");
    $finish;
  end

endmodule : sw_pipe_stage_tb
