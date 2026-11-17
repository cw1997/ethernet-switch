// ============================================================================
//  File        : es_pipe_stage_tb.sv
//  Description : Top for the es_common_pipe_stage regression: four
//                configurations in parallel on one clock, PASS/FAIL per case
//                and a watchdog-bounded verdict.
// ============================================================================
`timescale 1ns/1ps

module es_pipe_stage_tb;

  logic clk;
  logic [3:0] pass;
  logic [3:0] done;

  initial begin : clk_gen
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  es_pipe_stage_case #(
    .DP        (0),
    .CUT_READY (0),
    .FLUSH_EN  (0),
    .CASE_ID   (0)
  ) u0 (
    .clk_i  (clk),
    .pass_o (pass[0]),
    .done_o (done[0])
  );
  es_pipe_stage_case #(
    .DP        (1),
    .CUT_READY (0),
    .FLUSH_EN  (1),
    .CASE_ID   (1)
  ) u1 (
    .clk_i  (clk),
    .pass_o (pass[1]),
    .done_o (done[1])
  );
  es_pipe_stage_case #(
    .DP        (1),
    .CUT_READY (1),
    .FLUSH_EN  (1),
    .CASE_ID   (2)
  ) u2 (
    .clk_i  (clk),
    .pass_o (pass[2]),
    .done_o (done[2])
  );
  es_pipe_stage_case #(
    .DP        (2),
    .CUT_READY (0),
    .FLUSH_EN  (1),
    .CASE_ID   (3)
  ) u3 (
    .clk_i  (clk),
    .pass_o (pass[3]),
    .done_o (done[3])
  );

  initial begin : watchdog
    #500000;
    $fatal(1, "es_pipe_stage_tb: timeout");
  end

  initial begin : verdict
    wait (done == 4'b1111);
    if (pass != 4'b1111) begin
      $display("es_pipe_stage_tb: FAILED");
      $fatal(1, "es_pipe_stage_tb: one or more cases failed");
    end
    $display("es_pipe_stage_tb: PASSED (4 configurations)");
    $finish;
  end

endmodule : es_pipe_stage_tb
