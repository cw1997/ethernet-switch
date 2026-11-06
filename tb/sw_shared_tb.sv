// ============================================================================
//  File        : sw_shared_tb.sv
//  Description : Shared primitive checks and frozen page-policy cycle comparison.
//                Inputs change on falling edges; comparisons follow NBA updates.
//                RAM data is checked only after writing it; contents are not reset.
// ============================================================================
`timescale 1ns/1ps
module sw_shared_tb;
  logic clk = 0, rst = 0;
  always #5 clk = ~clk;
  int checks = 0, errors = 0;
  logic we = 0;
  logic [1:0] wa = 0, ra = 0;
  logic [7:0] wd = 0, rd;
  es_mems_ram_1r1w #(.WIDTH(8), .DEPTH(3)) ram (
    .clk_i(clk), .wr_en_i(we), .wr_addr_i(wa), .rd_addr_i(ra),
    .wr_data_i(wd), .rd_data_o(rd)
  );
  logic clear = 0;
  logic [2:0] enables = 0;
  logic [23:0] words = 0, contents;
  es_mems_reg_bank #(.WIDTH(8), .DEPTH(3), .RESET_VALUE(8'ha5)) bank (
    .clk_i(clk), .rst_ni(rst), .clear_i(clear), .wr_en_i(enables),
    .wr_data_i(words), .data_o(contents)
  );
  logic async_bit = 1, sampled;
  es_common_sync_2ff sampler (
    .clk_i(clk), .rst_ni(rst), .async_i(async_bit), .sync_o(sampled)
  );
  logic [2:0] keys = '1;
  logic [31:0] page[2], reference_page[2];
  logic [1:0] flush, reference_flush;
  genvar g;
  generate
    for (g = 0; g < 2; g++) begin : g_page
      es_monitor_page #(.NUM_PORTS(3), .CLK_FREQ_HZ(1000), .DEBOUNCE_MS(g*2)) dut (
        .clk_i(clk), .rst_ni(rst), .key_ni(keys), .page_o(page[g]), .flush_o(flush[g])
      );
      sw_page_reference #(.NUM_PORTS(3), .CLK_FREQ_HZ(1000), .DEBOUNCE_MS(g*2)) reference (
        .clk_i(clk), .rst_ni(rst), .key_ni(keys),
        .page_o(reference_page[g]), .flush_o(reference_flush[g])
      );
    end
  endgenerate
  logic start = 0, busy, valid;
  logic [63:0] value = 0, scale = 0, divisor = 1, result;
  es_common_ratio ratio (
    .clk_i(clk), .rst_ni(rst), .start_i(start), .value_i(value),
    .scale_i(scale), .divisor_i(divisor), .busy_o(busy), .valid_o(valid), .result_o(result)
  );
  logic decimal_start = 0, decimal_valid;
  logic [63:0] decimal_value = 0;
  logic [79:0] digits;
  es_common_bin_to_bcd decimal_dut (
    .clk_i(clk), .rst_ni(rst), .start_i(decimal_start), .value_i(decimal_value),
    .valid_o(decimal_valid), .bcd_o(digits)
  );
  task check(input bit ok, input string label);
    checks++;
    if (!ok) begin errors++; $display("FAIL %s", label); end
    else $display("PASS %s", label);
  endtask
  task step;
    @(posedge clk); #1;
  endtask
  task ratio_case(input logic [63:0] v, s, d, expected);
    @(negedge clk); value = v; scale = s; divisor = d; start = 1;
    step(); @(negedge clk); start = 0;
    // Deliberately request another operation while busy: it must not replace operands.
    repeat (3) step(); @(negedge clk); start = 1; value = 42;
    step(); @(negedge clk); start = 0;
    wait(valid); #1;
    check(result === expected, "serial ratio result/busy request");
    step(); check(!valid, "ratio valid is one clock");
  endtask
  task decimal_case(input logic [63:0] v, input logic [79:0] expected);
    @(negedge clk); decimal_value = v; decimal_start = 1;
    step(); @(negedge clk); decimal_start = 0;
    repeat (3) step(); @(negedge clk); decimal_start = 1; decimal_value = 7;
    step(); @(negedge clk); decimal_start = 0;
    wait(decimal_valid); #1;
    check(digits === expected, "BCD result/busy request");
    step(); check(!decimal_valid, "BCD valid is one clock");
  endtask
  initial begin
    step(); check(contents === 24'ha5a5a5 && sampled === 1, "synchronous reset values");
    @(negedge clk); rst = 1; async_bit = 0;
    step(); check(sampled === 1, "sampler first stage");
    step(); check(sampled === 0, "sampler second stage");
    @(negedge clk); enables = 3'b101; words = 24'h123456;
    step(); check(contents === 24'h12a556, "parallel writes and disabled entry hold");
    @(negedge clk); clear = 1;
    step(); check(contents === 24'ha5a5a5, "clear wins writes");
    @(negedge clk); clear = 0; rst = 0;
    step(); check(contents === 24'ha5a5a5, "reset wins writes");
    @(negedge clk); rst = 1; enables = 0; we = 1;
    for (int i = 0; i < 3; i++) begin
      wa = 2'(i); ra = 2'(i); wd = 8'(i+20);
      step(); check(rd === wd, "RAM same-address post-write value");
      @(negedge clk);
    end
    we = 0;
    for (int i = 0; i < 3; i++) begin
      ra = 2'(i); #1; check(rd === 8'(i+20), "RAM non-power-of-two asynchronous read");
      @(negedge clk);
    end
    // Vector patterns include bounce, a held key, simultaneous keys and releases.
    for (int i = 0; i < 160; i++) begin
      if (i < 16) keys = 3'(i);
      else keys = 3'((i/16)%8);
      step();
      for (int j = 0; j < 2; j++)
        check({page[j],flush[j]} === {reference_page[j],reference_flush[j]}, "page/flush cycle reference");
      @(negedge clk);
    end
    ratio_case(0, 99, 3, 0);
    ratio_case(123, 10, 4, 307);
    ratio_case(64'hffffffffffffffff, 2, 1, 64'hffffffffffffffff);
    ratio_case(17, 3, 0, 0);
    decimal_case(0, 80'h0);
    decimal_case(123456789, 80'h123456789);
    decimal_case(64'hffffffffffffffff, 80'h18446744073709551615);
    $display("sw_shared_tb: %0d checks, %0d errors", checks, errors);
    if (errors) $fatal(1, "shared primitives failed");
    $finish;
  end
  // One millisecond allows thousands of serial operations; a missed valid pulse fails.
  initial begin #1_000_000; $fatal(1, "shared primitive timeout"); end
endmodule
