// ============================================================================
//  File        : tb_sw_pl_mii.sv
//  Description : Self-checking four-port regression for the staged `es_switch_mii`
//                top.  Four independent `sw_mii_if` wire models present COMPLETE
//                wire frames (preamble/SFD + client + FCS) on the packed MII
//                nibble pins and reassemble every transmitted frame at the wire
//                boundary, checking preamble and FCS against the independent
//                `sw_tb_pkg` reference.
//
//                Scenarios: reset/idle, broadcast flooding with no source-port
//                loopback, learning followed by known-unicast delivery to the
//                learned port only, and a corrupt-FCS frame dropped everywhere.
//
//                Clock/ports: one clock domain; the simulation clock period is
//                arbitrary because both the adapters and the wire models count
//                BYTE_PERIOD clocks per octet, not nanoseconds.  Ports are all
//                100 Mbit/s on a 50 MHz core (CLK_FREQ_HZ), giving
//                BYTE_PERIOD = sw_byte_period(50 MHz, 100M) = 4, i.e. two core
//                clocks per MII nibble.  `link_up_i` is tied high because this
//                top has no PHY-management dependency; the wire models therefore
//                use `enable_i = 1'b1`.
//
//                Icarus portability: no instance arrays, no run-time-indexed
//                unpacked arrays and no variable hierarchical task calls.  BFM
//                tasks are reached through a constant `case` dispatch over the
//                four generated instances (g_phy[p].u_if), matching the proven
//                pattern in tb_sw_vivado_top.sv.  Timeout watchdog bounds a
//                fabric deadlock; every check prints PASS/FAIL and the run ends
//                with an explicit error count plus $fatal/$finish.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "sw_tb_pkg.sv"

module tb_sw_pl_mii
  import sw_tb_pkg::*;
#(
  parameter int unsigned NUM_PORTS = 4
) ();

  localparam int unsigned CLK_HZ = 50_000_000;
  /// Core clocks per octet time, derived with the same function the DUT uses.
  localparam int unsigned BP = sw_byte_period(CLK_HZ, SW_SPEED_100M);
  localparam logic [NUM_PORTS*2-1:0] SPEEDS = {NUM_PORTS{2'(SW_SPEED_100M)}};
  localparam int unsigned CLIENT_LEN = 64;
  /// Generous post-send settle: a 64-octet client frame is 76 wire octets, and
  /// at BP=4 the egress MAC serialises that in 304 clocks after the store-and-
  /// forward pipeline.  1500 clocks covers TX, pipeline latency and the IFG on
  /// every flooding egress before any frame-count verdict is taken.
  localparam int unsigned SETTLE_CLKS = 1500;
  localparam int unsigned POP_TIMEOUT = 20000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [NUM_PORTS-1:0]   link_up;
  logic [NUM_PORTS-1:0]   mii_rx_dv, mii_rx_er, mii_tx_en, mii_tx_er;
  logic [NUM_PORTS*4-1:0] mii_rxd, mii_txd;
  // The new es_mac_mii_serdes drives TXD from a free-running reset-grid nibble
  // counter, so a nibble is stable on the FIRST clock of each two-clock window
  // and can change on the second.  sw_mii_if samples the middle (second) clock
  // of each window counted from the TX_EN rise, which therefore reads one clock
  // late.  A single registration of TXD - only on the monitor input, never on
  // the pins the DUT drives - re-aligns the independent wire model with the
  // stable nibble.  Verified phase-independent across twelve inter-frame gaps.
  logic [NUM_PORTS*4-1:0] mii_txd_d;

  always #10 clk = ~clk;  // 20 ns period; absolute period is irrelevant, see header.
  always_ff @(posedge clk) mii_txd_d <= mii_txd;

  // ---- DUT ------------------------------------------------------------------
  // Only the ports the rewritten top still has are connected: the legacy
  // dip/stat/cam-readback/LED/cfg ports no longer exist.
  es_switch_mii #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_HZ),
    .PORT_SPEED  (SPEEDS),
    .PORT_MAC    ('0),
    .IFG_OCTETS  (12)
  ) u_dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .link_up_i     (link_up),
    .mii_rx_dv_i   (mii_rx_dv),
    .mii_rx_er_i   (mii_rx_er),
    .mii_rxd_i     (mii_rxd),
    .mii_tx_en_o   (mii_tx_en),
    .mii_tx_er_o   (mii_tx_er),
    .mii_txd_o     (mii_txd)
  );

  // ---- per-port MII wire models --------------------------------------------
  // Constant part-selects inside a generate loop keep the pin mapping
  // elaboration-time; port g occupies rxd/txd[g*4 +: 4].
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_phy
      sw_mii_if #(
        .PORT_ID     (g),
        .BYTE_PERIOD (BP),
        .IFG_OCTETS  (12)
      ) u_if (
        .clk_i     (clk),
        .rst_ni    (rst_n),
        .enable_i  (1'b1),
        .mii_rx_dv (mii_rx_dv[g]),
        .mii_rx_er (mii_rx_er[g]),
        .mii_rxd   (mii_rxd[g*4 +: 4]),
        .mii_tx_en (mii_tx_en[g]),
        .mii_txd   (mii_txd_d[g*4 +: 4])
      );
    end
  endgenerate

  // ---- self-checking helpers ------------------------------------------------
  int unsigned errors = 0;
  int unsigned checks = 0;

  task automatic check(input logic ok, input string label);
    checks++;
    // Case inequality treats an X/Z predicate as a failure: an uninitialised
    // DUT or a lost pin must not be able to pass a check.
    if (ok !== 1'b1) begin
      errors++;
      $display("[%0t] FAIL %s", $time, label);
    end else begin
      $display("[%0t] PASS %s", $time, label);
    end
  endtask

  // Constant hierarchical dispatch.  A run-time g_phy[p].u_if reference cannot
  // select an elaborated instance in Icarus, so each port has its own case arm.
  task automatic send_frame(input int unsigned p, input sw_mac_t dst,
                            input sw_mac_t src, input int unsigned len,
                            input bit bad_fcs);
    case (p)
      0: g_phy[0].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      1: g_phy[1].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      2: g_phy[2].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      3: g_phy[3].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      default: $fatal(1, "tb_sw_pl_mii: invalid sending port %0d", p);
    endcase
  endtask

  task automatic pop_frame(input int unsigned p, output tb_rec_t r);
    case (p)
      0: g_phy[0].u_if.pop_frame(r, POP_TIMEOUT);
      1: g_phy[1].u_if.pop_frame(r, POP_TIMEOUT);
      2: g_phy[2].u_if.pop_frame(r, POP_TIMEOUT);
      3: g_phy[3].u_if.pop_frame(r, POP_TIMEOUT);
      default: $fatal(1, "tb_sw_pl_mii: invalid receiving port %0d", p);
    endcase
  endtask

  function automatic int unsigned pending(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.pending();
      1: return g_phy[1].u_if.pending();
      2: return g_phy[2].u_if.pending();
      3: return g_phy[3].u_if.pending();
      default: return 32'hffff_ffff;
    endcase
  endfunction

  function automatic int unsigned dropped(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.dropped();
      1: return g_phy[1].u_if.dropped();
      2: return g_phy[2].u_if.dropped();
      3: return g_phy[3].u_if.dropped();
      default: return 32'hffff_ffff;
    endcase
  endfunction

  function automatic int unsigned short_frames(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.short_frames();
      1: return g_phy[1].u_if.short_frames();
      2: return g_phy[2].u_if.short_frames();
      3: return g_phy[3].u_if.short_frames();
      default: return 32'hffff_ffff;
    endcase
  endfunction

  // Full content verdict on one received wire record.
  task automatic check_frame(input tb_rec_t r, input sw_mac_t dst,
                             input sw_mac_t src, input int unsigned len,
                             input string tag);
    check(tb_rec_len(r) == len,       {tag, ": client length"});
    check(tb_rec_dst(r) == dst,       {tag, ": destination MAC"});
    check(tb_rec_src(r) == src,       {tag, ": source MAC"});
    check(tb_rec_l2(r) == TB_ET_IPV4, {tag, ": EtherType"});
    check(tb_rec_fcs_ok(r),           {tag, ": independent FCS"});
    check(tb_rec_pre_ok(r),           {tag, ": preamble/SFD"});
  endtask

  // Expected frame count for a port; a non-zero count also drains and verifies
  // one frame, so every scenario leaves all monitor queues empty for the next.
  task automatic expect_on(input int unsigned p, input int unsigned cnt,
                           input sw_mac_t dst, input sw_mac_t src,
                           input int unsigned len, input string tag);
    tb_rec_t r;
    check(pending(p) == cnt, {tag, ": frame count"});
    if (cnt != 0) begin
      pop_frame(p, r);
      check_frame(r, dst, src, len, tag);
    end
  endtask

  task automatic idle(input int unsigned n);
    int unsigned i;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  // Monitor integrity: no leftover/reflected frames, no queue overflow and no
  // too-short transmit frames on any port.
  task automatic check_queues();
    int unsigned p;
    for (p = 0; p < NUM_PORTS; p++) begin
      check(pending(p) == 0,       $sformatf("port %0d queue drained", p));
      check(dropped(p) == 0,       $sformatf("port %0d no monitor overflow", p));
      check(short_frames(p) == 0,  $sformatf("port %0d no short frames", p));
    end
    check(mii_tx_er === '0, "mii_tx_er held low on all ports");
  endtask

  // ---- stimulus -------------------------------------------------------------
  sw_mac_t host_a, host_b, host_c, bcast;
  int unsigned p;

  initial begin : main_proc
    host_a = 48'h02_AA_00_00_00_01;
    host_b = 48'h02_BB_00_00_00_02;
    host_c = 48'h02_CC_00_00_00_03;
    bcast  = SW_MAC_BROADCAST;

    rst_n   = 1'b0;
    link_up = '1;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    idle(20);

    $display("tb_sw_pl_mii: NUM_PORTS=%0d CLK_HZ=%0d BYTE_PERIOD=%0d", NUM_PORTS, CLK_HZ, BP);

    // ---- 1. reset and idle: no phantom traffic ----------------------------
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_a, CLIENT_LEN, "idle");

    // ---- 2. broadcast floods to 1/2/3, never back to source port 0 -------
    send_frame(0, bcast, host_a, CLIENT_LEN, 1'b0);
    idle(SETTLE_CLKS);
    expect_on(0, 0, bcast, host_a, CLIENT_LEN, "bcast src");
    for (p = 1; p < NUM_PORTS; p++)
      expect_on(p, 1, bcast, host_a, CLIENT_LEN, "bcast flood");

    // ---- 3. learn host_b on the last port, then known unicast -------------
    // A broadcast sourced by host_b on port 3 floods to 0/1/2 and teaches the
    // CAM that host_b lives at port 3.  Draining that flood here also leaves
    // every queue empty for the directed frame that follows.
    send_frame(NUM_PORTS - 1, bcast, host_b, CLIENT_LEN, 1'b0);
    idle(SETTLE_CLKS);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (p == NUM_PORTS - 1)
        expect_on(p, 0, bcast, host_b, CLIENT_LEN, "learn src");
      else
        expect_on(p, 1, bcast, host_b, CLIENT_LEN, "learn flood");
    end
    // host_a on port 0 -> host_b (learned at port 3): only port 3 may receive.
    send_frame(0, host_b, host_a, CLIENT_LEN, 1'b0);
    idle(SETTLE_CLKS);
    expect_on(0, 0, host_b, host_a, CLIENT_LEN, "known unicast src");
    for (p = 1; p < NUM_PORTS - 1; p++)
      expect_on(p, 0, host_b, host_a, CLIENT_LEN, "known unicast others");
    expect_on(NUM_PORTS - 1, 1, host_b, host_a, CLIENT_LEN, "known unicast dest");

    // ---- 4. corrupt FCS must be dropped everywhere ------------------------
    send_frame(0, bcast, host_c, CLIENT_LEN, 1'b1);
    idle(SETTLE_CLKS);
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_c, CLIENT_LEN, "bad FCS");

    check_queues();

    $display("tb_sw_pl_mii: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "tb_sw_pl_mii: FAILED");
    $display("tb_sw_pl_mii: PASSED");
    $finish;
  end

  // Independent watchdog: per-receive timeouts cannot protect a task stuck
  // before reception or a stopped clock.  20 ms is far beyond normal runtime.
  initial begin : watchdog
    #20_000_000;
    $fatal(1, "tb_sw_pl_mii: timeout");
  end

endmodule : tb_sw_pl_mii
