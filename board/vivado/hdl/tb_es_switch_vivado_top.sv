// ============================================================================
//  File        : tb_es_switch_vivado_top.sv
//  Description : Self-checking eight-port regression for the Vivado board shell
//                `es_switch_vivado_top`.  Eight independent `sw_mii_if` wire
//                models present COMPLETE wire frames (preamble/SFD + client +
//                FCS) on the packed MII nibble pins and reassemble every
//                transmitted frame at the wire boundary, checking preamble and
//                FCS against the independent `sw_tb_pkg` reference.
//
//                Scenarios: reset/idle, a broadcast from the highest port that
//                must flood across the 7 -> 0 ring boundary (and never back to
//                the source), a learning broadcast that installs a station at
//                port 0, and a known-unicast frame from port 7 to that station
//                that must reach only port 0 - the wraparound boundary again.
//
//                Clock/ports: one clock domain; the absolute simulation clock
//                period is arbitrary because the adapters and wire models count
//                BYTE_PERIOD clocks per octet.  The board shell fixes 50 MHz /
//                100 Mbit/s, giving BYTE_PERIOD = sw_byte_period(50 MHz, 100M)
//                = 4.  `link_up_i` is administratively tied high inside the
//                shell, so the wire models use enable_i = 1'b1.  The reserved
//                PHY RX/TX clocks are tied low: they are unused by design and
//                no data is sampled from them; this is not a CDC or physical
//                MII timing test.
//
//                Alignment: as in tb_sw_pl_mii, es_mac_mii_serdes drives TXD
//                from a free-running reset-grid nibble counter, so the stable
//                nibble is on the FIRST clock of each two-clock window while
//                sw_mii_if samples the second.  A single registration of TXD
//                (monitor input only) re-aligns the independent wire model;
//                verified phase-independent across twelve inter-frame gaps.
//
//                Icarus portability: no instance arrays, no run-time-indexed
//                unpacked arrays and no variable hierarchical task calls; BFM
//                tasks are reached through a constant `case` dispatch.  Timeout
//                watchdog bounds a deadlock; every check prints PASS/FAIL and
//                the run ends with an explicit error count plus $fatal/$finish.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "sw_tb_pkg.sv"

module tb_es_switch_vivado_top
  import sw_tb_pkg::*;
();

  localparam int unsigned NUM_PORTS = 8;
  localparam int unsigned BP = sw_byte_period(50_000_000, SW_SPEED_100M);
  localparam int unsigned CLIENT_LEN = 64;
  /// 1500 clocks covers the egress serialisation of a 76-wire-octet frame,
  /// pipeline latency and IFG before any frame-count verdict is taken.
  localparam int unsigned SETTLE_CLKS = 1500;
  localparam int unsigned POP_TIMEOUT = 20000;
  localparam logic [NUM_PORTS-1:0] ALL_ONES = {NUM_PORTS{1'b1}};

  logic clk = 1'b0;
  logic rst_button_n = 1'b0;

  logic [NUM_PORTS-1:0]   rx_dv, rx_er, tx_en, tx_er, phy_reset_n, mdc;
  logic [NUM_PORTS*4-1:0] rxd, txd, txd_d;
  tri   [NUM_PORTS-1:0]   mdio;

  always #10 clk = ~clk;  // 20 ns period; absolute period is irrelevant.
  // One-clock phase alignment for the independent wire monitors (see header).
  always_ff @(posedge clk) txd_d <= txd;

  // ---- board shell ----------------------------------------------------------
  es_switch_vivado_top u_dut (
    .clk_i         (clk),
    .rst_button_ni (rst_button_n),
    .mii_rx_clk_i  ('0),
    .mii_tx_clk_i  ('0),
    .mii_rx_dv_i   (rx_dv),
    .mii_rx_er_i   (rx_er),
    .mii_rxd_i     (rxd),
    .mii_tx_en_o   (tx_en),
    .mii_tx_er_o   (tx_er),
    .mii_txd_o     (txd),
    .phy_reset_no  (phy_reset_n),
    .phy_mdc_o     (mdc),
    .phy_mdio_io   (mdio)
  );

  // ---- per-port MII wire models --------------------------------------------
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_phy
      sw_mii_if #(
        .PORT_ID     (g),
        .BYTE_PERIOD (BP),
        .IFG_OCTETS  (12)
      ) u_if (
        .clk_i     (clk),
        .rst_ni    (rst_button_n),
        .enable_i  (1'b1),
        .mii_rx_dv (rx_dv[g]),
        .mii_rx_er (rx_er[g]),
        .mii_rxd   (rxd[g*4 +: 4]),
        .mii_tx_en (tx_en[g]),
        .mii_txd   (txd_d[g*4 +: 4])
      );
    end
  endgenerate

  // ---- self-checking helpers ------------------------------------------------
  int unsigned errors = 0;
  int unsigned checks = 0;

  task automatic check(input logic ok, input string label);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("[%0t] FAIL %s", $time, label);
    end else begin
      $display("[%0t] PASS %s", $time, label);
    end
  endtask

  // Constant hierarchical dispatch: Icarus cannot select an elaborated
  // instance with a run-time g_phy[p].u_if reference.
  task automatic send_frame(input int unsigned p, input sw_mac_t dst,
                            input sw_mac_t src, input int unsigned len);
    case (p)
      0: g_phy[0].u_if.send(dst, src, TB_ET_IPV4, len);
      1: g_phy[1].u_if.send(dst, src, TB_ET_IPV4, len);
      2: g_phy[2].u_if.send(dst, src, TB_ET_IPV4, len);
      3: g_phy[3].u_if.send(dst, src, TB_ET_IPV4, len);
      4: g_phy[4].u_if.send(dst, src, TB_ET_IPV4, len);
      5: g_phy[5].u_if.send(dst, src, TB_ET_IPV4, len);
      6: g_phy[6].u_if.send(dst, src, TB_ET_IPV4, len);
      7: g_phy[7].u_if.send(dst, src, TB_ET_IPV4, len);
      default: $fatal(1, "tb_es_switch_vivado_top: invalid sending port %0d", p);
    endcase
  endtask

  task automatic pop_frame(input int unsigned p, output tb_rec_t r);
    case (p)
      0: g_phy[0].u_if.pop_frame(r, POP_TIMEOUT);
      1: g_phy[1].u_if.pop_frame(r, POP_TIMEOUT);
      2: g_phy[2].u_if.pop_frame(r, POP_TIMEOUT);
      3: g_phy[3].u_if.pop_frame(r, POP_TIMEOUT);
      4: g_phy[4].u_if.pop_frame(r, POP_TIMEOUT);
      5: g_phy[5].u_if.pop_frame(r, POP_TIMEOUT);
      6: g_phy[6].u_if.pop_frame(r, POP_TIMEOUT);
      7: g_phy[7].u_if.pop_frame(r, POP_TIMEOUT);
      default: $fatal(1, "tb_es_switch_vivado_top: invalid receiving port %0d", p);
    endcase
  endtask

  function automatic int unsigned pending(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.pending();
      1: return g_phy[1].u_if.pending();
      2: return g_phy[2].u_if.pending();
      3: return g_phy[3].u_if.pending();
      4: return g_phy[4].u_if.pending();
      5: return g_phy[5].u_if.pending();
      6: return g_phy[6].u_if.pending();
      7: return g_phy[7].u_if.pending();
      default: return 32'hffff_ffff;
    endcase
  endfunction

  function automatic int unsigned dropped(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.dropped();
      1: return g_phy[1].u_if.dropped();
      2: return g_phy[2].u_if.dropped();
      3: return g_phy[3].u_if.dropped();
      4: return g_phy[4].u_if.dropped();
      5: return g_phy[5].u_if.dropped();
      6: return g_phy[6].u_if.dropped();
      7: return g_phy[7].u_if.dropped();
      default: return 32'hffff_ffff;
    endcase
  endfunction

  function automatic int unsigned short_frames(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.short_frames();
      1: return g_phy[1].u_if.short_frames();
      2: return g_phy[2].u_if.short_frames();
      3: return g_phy[3].u_if.short_frames();
      4: return g_phy[4].u_if.short_frames();
      5: return g_phy[5].u_if.short_frames();
      6: return g_phy[6].u_if.short_frames();
      7: return g_phy[7].u_if.short_frames();
      default: return 32'hffff_ffff;
    endcase
  endfunction

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
  // one frame, leaving every monitor queue empty for the next phase.
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

  task automatic check_queues();
    int unsigned p;
    for (p = 0; p < NUM_PORTS; p++) begin
      check(pending(p) == 0,      $sformatf("port %0d queue drained", p));
      check(dropped(p) == 0,      $sformatf("port %0d no monitor overflow", p));
      check(short_frames(p) == 0, $sformatf("port %0d no short frames", p));
    end
    check(tx_er === '0, "mii_tx_er held low on all eight ports");
    check(mdc === '0, "all eight MDC pins idle low");
    check(mdio === {NUM_PORTS{1'bz}}, "all eight MDIO pins released");
  endtask

  // ---- stimulus -------------------------------------------------------------
  sw_mac_t host_a, host_b, bcast;
  int unsigned p;

  initial begin : main_proc
    host_a = 48'h02_AA_00_00_00_01;
    host_b = 48'h02_BB_00_00_00_02;
    bcast  = SW_MAC_BROADCAST;

    rst_button_n = 1'b0;
    repeat (4) @(posedge clk);
    #1;
    rst_button_n = 1'b1;
    idle(20);

    $display("tb_es_switch_vivado_top: NUM_PORTS=%0d BYTE_PERIOD=%0d", NUM_PORTS, BP);

    // ---- 1. reset and idle: no phantom traffic ----------------------------
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_a, CLIENT_LEN, "idle");

    // ---- 2. broadcast from port 7 floods across the 7 -> 0 boundary ------
    // Ports 0..6 must each receive one copy; port 7 (the source) sees none.
    send_frame(NUM_PORTS - 1, bcast, host_a, CLIENT_LEN);
    idle(SETTLE_CLKS);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (p == NUM_PORTS - 1)
        expect_on(p, 0, bcast, host_a, CLIENT_LEN, "bcast src");
      else
        expect_on(p, 1, bcast, host_a, CLIENT_LEN, "bcast flood");
    end

    // ---- 3. learn host_b at port 0 ----------------------------------------
    // A broadcast sourced by host_b on port 0 floods to 1..7 and installs
    // host_b -> port 0 in the CAM; those flood copies are drained here.
    send_frame(0, bcast, host_b, CLIENT_LEN);
    idle(SETTLE_CLKS);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (p == 0)
        expect_on(p, 0, bcast, host_b, CLIENT_LEN, "learn src");
      else
        expect_on(p, 1, bcast, host_b, CLIENT_LEN, "learn flood");
    end

    // ---- 4. known unicast from port 7 reaches only port 0 -----------------
    // host_b is learned at port 0; sending from port 7 exercises the ring
    // boundary again, now for a directed frame that must NOT be flooded.
    send_frame(NUM_PORTS - 1, host_b, host_a, CLIENT_LEN);
    idle(SETTLE_CLKS);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (p == 0)
        expect_on(p, 1, host_b, host_a, CLIENT_LEN, "known unicast dest");
      else
        expect_on(p, 0, host_b, host_a, CLIENT_LEN, "known unicast others");
    end

    check(phy_reset_n === ALL_ONES, "all eight PHYs released after reset");
    check_queues();

    $display("tb_es_switch_vivado_top: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "tb_es_switch_vivado_top: FAILED");
    $display("tb_es_switch_vivado_top: PASSED");
    $finish;
  end

  // Independent watchdog: per-receive timeouts cannot protect a task stuck
  // before reception or a stopped clock.  20 ms is far beyond normal runtime.
  initial begin : watchdog
    #20_000_000;
    $fatal(1, "tb_es_switch_vivado_top: timeout");
  end

endmodule : tb_es_switch_vivado_top
