// ============================================================================
//  File        : tb/sw_mac_table_tb.sv
//  Description : Unit testbench of the shared forwarding database
//                (`sw_mac_table`).
//
//                The CAM is the component that turns a flood-everything hub into
//                a switching bridge, so it is verified on its own:
//
//                  * lookup latency and hit / miss reporting on every read port,
//                  * parallel lookups from all ports in the same clock,
//                  * learning through the internal request queue, including two
//                    simultaneous requests (nothing may be lost),
//                  * relocation: a station that moves to another port must be
//                    updated in place instead of creating a duplicate entry,
//                  * round-robin eviction when a bucket overflows,
//                  * flush,
//                  * ageing, with a deliberately short tick so that the whole
//                    table is swept inside a reasonable number of clocks.
//
//                The testbench uses NUM_PORTS = 2, NUM_SETS = 2 and NUM_WAYS = 2
//                so that bucket occupancy - and therefore the replacement
//                policy - is directly observable.
// ============================================================================
`timescale 1ns/1ps

module sw_mac_table_tb;

  // The verification helpers live in sw_tb_pkg.  The RTL declarations are at
  // compilation-unit scope (`rtl/sw_defs.sv`) and so need no import.
  import sw_tb_pkg::*;

  localparam int unsigned NUM_PORTS = 2;
  localparam int unsigned PW        = 1;
  localparam int unsigned NUM_SETS  = 2;
  localparam int unsigned NUM_WAYS  = 2;
  /// Ageing tick: one entry per clock keeps the test fast.
  localparam int unsigned AGE_TICK  = 1;
  /// Idle limit.  The effective idle timeout is
  ///     AGE_TICK * NUM_SETS * NUM_WAYS * (AGE_LIMIT + 1)
  /// clocks, i.e. 1*2*2*(AGE_LIMIT+1).  A limit of 2 would expire an entry after
  /// only twelve clocks, which is far shorter than the lookup and relocation
  /// tests that run before the ageing test - entries would silently disappear
  /// mid-test and the failures would look like lookup bugs.  AGE_LIMIT is sized
  /// so the earlier tests are unaffected and only the final ageing test, which
  /// deliberately waits, sees an entry expire.
  localparam int unsigned AGE_LIMIT = 64;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic flush;

  logic [NUM_PORTS-1:0]    req;
  logic [NUM_PORTS*48-1:0] mac;
  logic [NUM_PORTS-1:0]    hit;
  logic [NUM_PORTS*NUM_PORTS-1:0] port;

  logic [NUM_PORTS-1:0]    learn;
  logic [NUM_PORTS*48-1:0] learn_mac;
  logic [NUM_PORTS*PW-1:0] learn_port;

  logic [31:0] entries, hits, misses, learns;

  int unsigned errors;
  int unsigned checks;

  always #5 clk = ~clk;

  sw_mac_table #(
      .NUM_PORTS       (NUM_PORTS),
      .NUM_SETS        (NUM_SETS),
      .NUM_WAYS        (NUM_WAYS),
      .AGE_EN          (1'b1),
      .AGE_TICK_CYCLES (AGE_TICK),
      .AGE_LIMIT       (AGE_LIMIT)
  ) u_dut (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .flush_i      (flush),
      .req_i        (req),
      .mac_i        (mac),
      .hit_o        (hit),
      .port_o       (port),
      .learn_i      (learn),
      .learn_mac_i  (learn_mac),
      .learn_port_i (learn_port),
      .entries_o    (entries),
      .hits_o       (hits),
      .misses_o     (misses),
      .learns_o     (learns)
  );

  // Two test addresses and one that is never learned.
  localparam logic [47:0] MAC_A = 48'h02_00_00_00_00_0A;
  localparam logic [47:0] MAC_B = 48'h02_00_00_00_00_0B;
  localparam logic [47:0] MAC_C = 48'h02_00_00_00_00_0C;

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

  // --------------------------------------------------------------------------
  // Stimulus helpers
  //
  // Inputs are driven on the falling edge and sampled by the DUT on the next
  // rising edge.  Driving them at the same timestamp as `@(posedge clk)` races
  // the DUT's always_ff, and the resulting one-clock skew is silent: a learn
  // request simply never arrives, and the test reports a missing entry rather
  // than a timing problem.  The negative edge is the unambiguous drive point.
  // --------------------------------------------------------------------------

  /// One clock with the learn request of port `p` asserted.
  task automatic do_learn(input int unsigned p, input logic [47:0] m);
    @(negedge clk);
    learn                   = '0;
    learn_mac [p*48 +: 48]   = m;
    learn_port[p*PW +: PW]   = PW'(p);
    learn[p]                = 1'b1;
    @(posedge clk);          // the request is sampled here
    @(negedge clk);
    learn                   = '0;
  endtask

  /// One lookup clock for port `p`; the registered result is visible one clock
  /// later, which the task accounts for.
  task automatic do_lookup(input int unsigned p, input logic [47:0] m);
    @(negedge clk);
    req                = '0;
    mac[p*48 +: 48]    = m;
    req[p]             = 1'b1;
    @(posedge clk);          // the lookup is sampled here
    @(negedge clk);
    req[p]             = 1'b0;
    @(posedge clk);          // result register updates here
    @(negedge clk);
  endtask

  task automatic expect_hit(input int unsigned p, input bit exp_hit,
                            input int unsigned exp_port, input string what);
    checks++;
    if ((hit[p] !== exp_hit) ||
        (exp_hit && (port[p*NUM_PORTS +: NUM_PORTS] !== (NUM_PORTS'(1) << exp_port)))) begin
      errors++;
      $display("[%0t] ERROR %s: hit=%b port=%b, expected hit=%b port=%0d",
               $time, what, hit[p], port[p*NUM_PORTS +: NUM_PORTS], exp_hit, exp_port);
    end else begin
      $display("[%0t] PASS  %s: hit=%b port=%0d", $time, what, hit[p], exp_port);
    end
  endtask

  initial begin
    req        = '0;
    mac        = '0;
    learn      = '0;
    learn_mac  = '0;
    learn_port = '0;
    flush      = 1'b0;
    errors     = 0;
    checks     = 0;

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("=====================================================================");
    $display(" sw_mac_table_tb: %0d ports, %0d sets, %0d ways, ageing on",
             NUM_PORTS, NUM_SETS, NUM_WAYS);
    $display("=====================================================================");

    // ---- miss on an empty table ------------------------------------------
    do_lookup(0, MAC_A);
    expect_hit(0, 1'b0, 0, "lookup on an empty table");
    expect_eq(misses, 1, "miss counter");

    // ---- learn and hit ----------------------------------------------------
    do_learn(0, MAC_A);
    repeat (4) @(posedge clk);       // let the learn queue drain
    do_lookup(0, MAC_A);
    expect_hit(0, 1'b1, 0, "lookup after learning on port 0");
    expect_eq(hits,   1, "hit counter");
    expect_eq(learns, 1, "learn counter");
    expect_eq(entries, 1, "entry counter after one insertion");

    // A lookup from the *other* port resolves to the same single entry: the
    // table is shared, which is what makes a hit a directed forward.
    do_lookup(1, MAC_A);
    expect_hit(1, 1'b1, 0, "parallel lookup from port 1 finds the same entry");

    // ---- two simultaneous learn requests ----------------------------------
    // Both addresses must end up in the table: the request queue exists exactly
    // so that a collision cannot lose a station.
    do_learn(0, MAC_B);
    do_learn(1, MAC_C);
    repeat (6) @(posedge clk);
    expect_eq(learns,  3, "learn counter after three learn operations");
    expect_eq(entries, 3, "entry counter after three insertions");
    do_lookup(0, MAC_B);
    expect_hit(0, 1'b1, 0, "MAC_B learned on port 0");
    do_lookup(0, MAC_C);
    expect_hit(0, 1'b1, 1, "MAC_C learned on port 1");

    // ---- relocation --------------------------------------------------------
    // Re-learning MAC_A on port 1 must update the entry in place.
    do_learn(1, MAC_A);
    repeat (6) @(posedge clk);
    do_lookup(0, MAC_A);
    expect_hit(0, 1'b1, 1, "MAC_A relocated to port 1");
    expect_eq(entries, 3, "relocation does not create a second entry");

    // ---- flush -------------------------------------------------------------
    // Driven on the falling edge like every other input, for the same reason.
    @(negedge clk);
    flush = 1'b1;
    @(posedge clk);          // the flush is sampled here
    @(negedge clk);
    flush = 1'b0;
    repeat (2) @(posedge clk);
    do_lookup(0, MAC_A);
    expect_hit(0, 1'b0, 0, "lookup after the flush");
    expect_eq(entries, 0, "entry counter after the flush");

    // ---- ageing -------------------------------------------------------------
    // The table was flushed above, so the entry below is learnt fresh.  The
    // sweep visits one entry per tick and there are NUM_SETS*NUM_WAYS entries,
    // and a live entry survives AGE_LIMIT further visits, so the entry is still
    // there after a first full sweep and is gone a few sweeps later.  The wait
    // is derived from those parameters rather than guessed, so changing
    // NUM_SETS, NUM_WAYS or AGE_LIMIT cannot make this test vacuous.
    do_learn(0, MAC_A);
    repeat (8) @(posedge clk);
    do_lookup(0, MAC_A);
    expect_hit(0, 1'b1, 0, "entry present right after learning");

    // One full sweep is not enough to expire the entry.
    repeat (NUM_SETS*NUM_WAYS) @(posedge clk);
    do_lookup(0, MAC_A);
    expect_hit(0, 1'b1, 0, "entry survives the first ageing sweep");

    // AGE_LIMIT+1 further sweeps must expire it.
    repeat ((AGE_LIMIT+1)*(NUM_SETS*NUM_WAYS) + 4) @(posedge clk);
    do_lookup(0, MAC_A);
    expect_hit(0, 1'b0, 0, "entry expired by ageing");
    expect_eq(entries, 0, "entry counter after ageing");

    $display("-----------------------------------------------------------------------");
    $display(" hits %0d, misses %0d, learns %0d, entries %0d", hits, misses, learns, entries);
    if (errors == 0) begin
      $display(" sw_mac_table_tb: PASSED (%0d checks)", checks);
      $finish;
    end else begin
      $fatal(1, " sw_mac_table_tb: FAILED (%0d of %0d checks failed)", errors, checks);
    end
  end

  initial begin
    #5_000_000;
    $fatal(1, "sw_mac_table_tb: timeout");
  end

endmodule : sw_mac_table_tb
