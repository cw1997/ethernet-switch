// ============================================================================
//  File        : tb/sw_shared_tb.sv
//  Description : Shared memory and synchroniser primitives.
//
//                Covers the three primitives that the switch, the panel and the
//                console all build on: the asynchronous-read RAM, the parallel
//                register bank with its per-word write enables and global clear,
//                and the two-stage sampler.
//
//                Inputs change on falling edges so that the design sees them on
//                a rising edge, and comparisons follow the NBA update.
// ============================================================================
`timescale 1ns/1ps
module sw_shared_tb;

  // Active-low reset: start asserted, then release.  Wiring these primitives
  // to a signal that is permanently low holds them in reset and every check
  // below would pass for the wrong reason.
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int checks = 0, errors = 0;

  // ---- asynchronous-read RAM ----------------------------------------------
  // Write port clocked, read port combinational: the value is valid as soon
  // as the address settles, which is the property the payload FIFO read path
  // and the CAM read mux depend on.
  logic we = 0;                 ///< write enable of the single write port
  logic [1:0] wa = 0, ra = 0;   ///< write / read address
  logic [7:0] wd = 0, rd;       ///< write data / combinational read data
  es_mems_ram_1r1w #(.WIDTH(8), .DEPTH(3)) ram (
    .clk_i     (clk), .wr_en_i(we), .wr_addr_i(wa), .rd_addr_i(ra),
    .wr_data_i (wd), .rd_data_o(rd)
  );

  // ---- parallel register bank ---------------------------------------------
  // One word per enable bit; `clear_i` overrides every enable and restores
  // RESET_VALUE, which is what a configuration reset of the panel registers
  // relies on.
  logic clear = 0;              ///< global clear, overrides the enables
  logic [2:0] enables = 0;      ///< one write enable per word
  logic [23:0] words = 0, contents;  ///< packed write data / observed state
  es_mems_reg_bank #(.WIDTH(8), .DEPTH(3), .RESET_VALUE(8'ha5)) bank (
    .clk_i     (clk), .rst_ni(rst_n), .clear_i(clear), .wr_en_i(enables),
    .wr_data_i (words), .data_o(contents)
  );

  // ---- two-stage sampler ---------------------------------------------------
  // The metastability filter used on every asynchronous board input; its
  // contract is two edges of latency, then it follows the input.
  logic async_bit = 1, sampled;
  es_common_sync_2ff sampler (
    .clk_i(clk), .rst_ni(rst_n), .async_i(async_bit), .sync_o(sampled)
  );

  /// Print one PASS/FAIL line and keep the counters for the verdict.
  task check(input bit ok, input string label);
    checks++;
    if (!ok) begin errors++; $display("FAIL %s", label); end
    else $display("PASS %s", label);
  endtask

  /// Advance one clock and settle 1 ns past the edge, so a comparison made
  /// after `step` observes the post-NBA value rather than racing the flops.
  task step;
    @(posedge clk); #1;
  endtask

  // --------------------------------------------------------------------------
  // Stimulus and expected results
  //
  // One phase per primitive, in dependency order: reset values first, then
  // the RAM, then the enables and the clear, then the sampler latency.
  // --------------------------------------------------------------------------
  initial begin
    // Reset the register bank to its documented RESET_VALUE and check the
    // sampler comes up at its reset value too.
    @(negedge clk); rst_n = 1; step();
    step();
    check(contents === {8'ha5, 8'ha5, 8'ha5}, "register bank reset value");

    // RAM: write two entries, read them back.  The read port is asynchronous,
    // so the value is valid as soon as the address settles.
    @(negedge clk); we = 1; wa = 2'd0; wd = 8'h11; step();
    @(negedge clk); wa = 2'd2; wd = 8'h22; step();
    @(negedge clk); we = 0; ra = 2'd0; #1;
    check(rd === 8'h11, "ram read back entry 0");
    @(negedge clk); ra = 2'd2; #1;
    check(rd === 8'h22, "ram read back entry 2");

    // Register bank: a single-word enable must not disturb its neighbours.
    @(negedge clk); enables = 3'b001; words = {8'h33, 8'h22, 8'h11}; step();
    check(contents === {8'ha5, 8'ha5, 8'h11}, "bank writes only the enabled word");
    @(negedge clk); enables = 3'b110; words = {8'h66, 8'h55, 8'h44}; step();
    check(contents === {8'h66, 8'h55, 8'h11}, "bank writes the other two words");

    // Global clear overrides the write enables and restores the reset value.
    @(negedge clk); clear = 1; step();
    check(contents === {8'ha5, 8'ha5, 8'ha5}, "bank global clear");
    @(negedge clk); clear = 0;

    // Sampler: two edges of latency, then it follows the input.
    @(negedge clk); async_bit = 0;
    step();
    check(sampled === 1'b1, "sampler still holds the old level after one edge");
    step();
    check(sampled === 1'b0, "sampler follows the input after two edges");

    $display("sw_shared_tb: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "sw_shared_tb FAILED");
    $display("PASS: sw_shared_tb");
    $finish;
  end
endmodule : sw_shared_tb
