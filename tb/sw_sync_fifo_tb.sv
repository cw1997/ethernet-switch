// ============================================================================
//  File        : tb/sw_sync_fifo_tb.sv
//  Description : Unit testbench of the parameterised fall-through FIFO
//                (`sw_sync_fifo`).
//
//                The FIFO has three facilities that the switch datapath depends
//                on, and each of them is verified here:
//
//                  1. fall-through read port - the head of the queue is visible
//                     on `rd_data_o` before anything is read,
//                  2. `undo_i` - the write pointer is rewound by `undo_cnt_i`
//                     entries, which is how the receive path removes a frame
//                     that turned out to be corrupt while the reader is running,
//                  3. `flush_i` - both pointers are cleared.
//
//                In addition the usual boundary conditions are checked: full,
//                empty, the free-space counter and simultaneous push/pop.
// ============================================================================
`timescale 1ns/1ps

module sw_sync_fifo_tb;

  localparam int unsigned WIDTH = 16;
  localparam int unsigned DEPTH = 8;
  localparam int unsigned CNT_W = $clog2(DEPTH) + 1;

  logic            clk = 1'b0;
  logic            rst_n = 1'b0;
  logic            undo;
  logic [CNT_W-1:0] undo_cnt;
  logic            flush;
  logic            wr_en;
  logic [WIDTH-1:0] wr_data;
  logic            full;
  logic [CNT_W-1:0] free_cnt;
  logic            rd_en;
  logic [WIDTH-1:0] rd_data;
  logic            empty;

  int unsigned errors;
  int unsigned checks;

  always #5 clk = ~clk;

  sw_sync_fifo #(
      .WIDTH (WIDTH),
      .DEPTH (DEPTH)
  ) u_dut (
      .clk_i      (clk),
      .rst_ni     (rst_n),
      .undo_i     (undo),
      .undo_cnt_i (undo_cnt),
      .flush_i    (flush),
      .wr_en_i    (wr_en),
      .wr_data_i  (wr_data),
      .full_o     (full),
      .free_o     (free_cnt),
      .rd_en_i    (rd_en),
      .rd_data_o  (rd_data),
      .empty_o    (empty)
  );

  task automatic expect_eq(input int unsigned got, input int unsigned exp,
                           input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %0d, expected %0d", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %0d", $time, what, got);
    end
  endtask

  task automatic expect_data(input logic [WIDTH-1:0] got,
                             input logic [WIDTH-1:0] exp, input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %04x, expected %04x", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %04x", $time, what, got);
    end
  endtask

  // --------------------------------------------------------------------------
  // Stimulus helpers
  //
  // Inputs are driven on the falling edge and sampled by the FIFO on the next
  // rising edge.  Driving them at the same timestamp as `@(posedge clk)` races
  // the DUT's always_ff, and the skew is silent rather than fatal: the entry
  // appears one clock late, so the FIFO looks as if it had swallowed an entry
  // and every subsequent check is off by one.  The negative edge is the
  // unambiguous drive point.
  // --------------------------------------------------------------------------

  /// Push one entry and wait for it to land.
  task automatic push(input logic [WIDTH-1:0] v);
    @(negedge clk);
    wr_en   = 1'b1;
    wr_data = v;
    @(posedge clk);          // the entry is written here
    @(negedge clk);
    wr_en   = 1'b0;
  endtask

  /// Check the fall-through head, then consume it.
  task automatic pop_check(input logic [WIDTH-1:0] exp, input string what);
    // The read port is fall-through: the head is visible before rd_en.
    expect_data(rd_data, exp, {what, " (fall-through head)"});
    @(negedge clk);
    rd_en = 1'b1;
    @(posedge clk);          // the entry is consumed here
    @(negedge clk);
    rd_en = 1'b0;
  endtask

  initial begin
    undo    = 1'b0;
    undo_cnt= '0;
    flush   = 1'b0;
    wr_en   = 1'b0;
    wr_data = '0;
    rd_en   = 1'b0;
    errors  = 0;
    checks  = 0;

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    $display("=====================================================================");
    $display(" sw_sync_fifo_tb: %0d x %0d bit fall-through FIFO", DEPTH, WIDTH);
    $display("=====================================================================");

    // ---- empty state -----------------------------------------------------
    expect_eq(empty, 1'b1, "empty after reset");
    expect_eq(full,  1'b0, "not full after reset");
    expect_eq(free_cnt, DEPTH, "free entries after reset");

    // ---- basic ordering --------------------------------------------------
    push(16'h1111);
    push(16'h2222);
    push(16'h3333);
    expect_eq(empty, 1'b0, "not empty after three pushes");
    expect_eq(free_cnt, DEPTH - 3, "free entries after three pushes");
    pop_check(16'h1111, "first entry");
    pop_check(16'h2222, "second entry");
    pop_check(16'h3333, "third entry");
    expect_eq(empty, 1'b1, "empty after three pops");

    // ---- fill to the brim ------------------------------------------------
    for (int unsigned i = 0; i < DEPTH; i++) push(16'(i + 1));
    expect_eq(full, 1'b1, "full after DEPTH pushes");
    expect_eq(free_cnt, 0, "no free entries when full");

    // A write while full is ignored - the FIFO never wraps silently.
    @(negedge clk);
    wr_en   = 1'b1;
    wr_data = 16'hDEAD;
    @(posedge clk);          // the write is attempted here
    @(negedge clk);
    wr_en = 1'b0;
    expect_data(rd_data, 16'd1, "head unchanged by a write while full");

    for (int unsigned i = 0; i < DEPTH; i++) pop_check(16'(i + 1), "ordered pop");
    expect_eq(empty, 1'b1, "empty again");

    // ---- simultaneous push and pop ---------------------------------------
    push(16'hAAAA);
    @(negedge clk);
    wr_en   = 1'b1;
    wr_data = 16'hBBBB;
    rd_en   = 1'b1;
    @(posedge clk);          // read and write are sampled together here
    @(negedge clk);
    wr_en = 1'b0;
    rd_en = 1'b0;
    // The read consumed the previous head and the write appended a new entry,
    // so exactly one entry is left.
    expect_data(rd_data, 16'hBBBB, "push and pop in the same clock");
    expect_eq(empty, 1'b0, "one entry left after a simultaneous push and pop");
    pop_check(16'hBBBB, "survivor of the simultaneous push and pop");
    expect_eq(empty, 1'b1, "empty again");

    // ---- undo (frame abort) ----------------------------------------------
    // Three entries are written and the two *newest* ones are rewound.  That is
    // exactly the receive path behaviour when a frame fails its FCS check after
    // most of it has been buffered: the frame occupies the newest entries, so
    // rolling the write pointer back discards it and nothing else.
    push(16'h1000);
    push(16'h2000);
    push(16'h3000);
    @(negedge clk);
    undo     = 1'b1;
    undo_cnt = CNT_W'(2);
    @(posedge clk);          // the rewind is sampled here
    @(negedge clk);
    undo     = 1'b0;
    undo_cnt = '0;
    expect_eq(free_cnt, DEPTH - 1, "free entries after the rewind");
    pop_check(16'h1000, "survivor after the rewind");
    expect_eq(empty, 1'b1, "empty after the rewind survivor");

    // A rewind that is larger than the occupancy must be ignored entirely
    // rather than underflowing the counter.
    push(16'h4000);
    @(negedge clk);
    undo     = 1'b1;
    undo_cnt = CNT_W'(DEPTH);
    @(posedge clk);          // the rewind is sampled here
    @(negedge clk);
    undo     = 1'b0;
    undo_cnt = '0;
    expect_eq(empty, 1'b0, "over-long rewind leaves the buffer alone");
    expect_eq(free_cnt, DEPTH - 1, "free entries after an over-long rewind");
    pop_check(16'h4000, "entry kept by the rejected rewind");
    expect_eq(empty, 1'b1, "empty at the end of the rewind tests");

    // ---- flush ------------------------------------------------------------
    push(16'h5555);
    push(16'h6666);
    expect_eq(empty, 1'b0, "not empty before the flush");
    flush = 1'b1;
    @(posedge clk);          // the flush is sampled here
    @(negedge clk);
    flush = 1'b0;
    expect_eq(empty, 1'b1, "empty after the flush");
    expect_eq(free_cnt, DEPTH, "free entries after the flush");

    // The FIFO must be fully usable again after a flush.
    push(16'h7777);
    pop_check(16'h7777, "reuse after the flush");

    $display("-----------------------------------------------------------------------");
    if (errors == 0) begin
      $display(" sw_sync_fifo_tb: PASSED (%0d checks)", checks);
      $finish;
    end else begin
      $fatal(1, " sw_sync_fifo_tb: FAILED (%0d of %0d checks failed)", errors, checks);
    end
  end

  initial begin
    #1_000_000;
    $fatal(1, "sw_sync_fifo_tb: timeout");
  end

endmodule : sw_sync_fifo_tb
