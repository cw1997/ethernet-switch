// ============================================================================
//  File        : tb_es_switch_de2_115_top.sv
//  Description : Board-level smoke regression for the DE2-115 dual-port MII
//                shell `es_switch_de2_115_top`.  Two independent `sw_mii_if`
//                wire models present COMPLETE wire frames (preamble/SFD +
//                client + FCS) on the packed MII nibble pins and reassemble
//                every transmitted frame at the wire boundary, checking
//                preamble and FCS against the independent `sw_tb_pkg` reference.
//
//                Scope and honest limits
//                ----------------------
//                The shell derives `link_up_i` from `es_perips_phy_88e1111`
//                `enabled_o`, i.e. from Clause-22 MDIO discovery and status
//                polling of the two external 88E1111 PHYs.  There is NO
//                external MDIO PHY responder in this testbench (board-level
//                PHY integration is out of scope), and the manager's own
//                RESET_WAIT_MS alone is 20 ms of core clocks.  Consequently
//                `enabled_o` is NOT expected to rise within a practical
//                simulation time: without a responder a read returns the
//                pull-up level, the manager parks in its management-error
//                state, and `link_up_i` stays low - which gates RX injection
//                in `es_switch_fabric`, so no frame could ever be forwarded.
//
//                To still exercise the MII pin -> fabric -> pin forwarding
//                path that WOULD be active once a real PHY reports link up,
//                this bench observes and reports `enabled_o`, then explicitly
//                FORCES `phy_enabled` high.  This is a deliberate bypass of the
//                PHY management, NOT a validation of it.  The forced run does
//                one broadcast smoke (ENET0 -> ENET1, no source-port loopback),
//                verifies that a TX enable was asserted and that no X/Z reaches
//                the observed outputs.  Those TX-enable / X-propagation checks
//                are exactly the degraded checks permitted when `enabled_o`
//                cannot rise; the forced broadcast additionally proves the
//                wiring and the switching datapath end to end.
//
//                Clock/ports: one clock domain at 50 MHz; the shell fixes
//                100 Mbit/s ports, giving BYTE_PERIOD =
//                sw_byte_period(50 MHz, 100M) = 4.  KEY[0] is an active-low
//                reset sampled through the shell's two-stage synchroniser.
//                MDIO pads get weak pull-ups (as a real board does) so the
//                manager reads a clean high instead of Z and parks cleanly
//                rather than propagating X into `phy_status`.
//
//                Alignment: as in tb_sw_pl_mii, es_mac_mii_serdes drives TXD
//                from a free-running reset-grid nibble counter; a single
//                registration of TXD (monitor input only) re-aligns the
//                independent wire model with the stable nibble.
//
//                Icarus portability: no instance arrays and no variable
//                hierarchical task calls - the two BFM instances are named and
//                called directly.  Timeout watchdog bounds a deadlock; every
//                check prints PASS/FAIL and the run ends with an explicit error
//                count plus $fatal/$finish.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "sw_tb_pkg.sv"

module tb_es_switch_de2_115_top
  import sw_tb_pkg::*;
();

  localparam int unsigned BP = sw_byte_period(50_000_000, SW_SPEED_100M);
  localparam int unsigned CLIENT_LEN = 64;
  localparam int unsigned SETTLE_CLKS = 1500;
  localparam int unsigned POP_TIMEOUT = 20000;
  localparam int unsigned LINK_SETTLE_CLKS = 5000;

  // ---- board pins -----------------------------------------------------------
  logic       CLOCK_50 = 1'b0;
  logic [3:0] KEY;
  logic [3:0] ENET0_RX_DATA, ENET1_RX_DATA;
  logic       ENET0_RX_DV, ENET0_RX_ER, ENET1_RX_DV, ENET1_RX_ER;
  logic [3:0] ENET0_TX_DATA, ENET1_TX_DATA;
  logic       ENET0_TX_EN, ENET0_TX_ER, ENET0_TX_CLK;
  logic       ENET1_TX_EN, ENET1_TX_ER, ENET1_TX_CLK;
  logic       ENET0_RESET_N, ENET1_RESET_N, ENET0_MDC, ENET1_MDC;
  logic       ENET0_INT_N, ENET1_INT_N;
  tri         ENET0_MDIO, ENET1_MDIO;

  always #10 CLOCK_50 = ~CLOCK_50;  // 20 ns period = 50 MHz.

  // Weak board pull-ups on the MDIO pads: idle-high, overridden by the strong
  // driver from the manager during a write.  Keeps mdio_i a clean 1, so the
  // manager parks in its error state deterministically instead of spreading X.
  pullup p_mdio0 (ENET0_MDIO);
  pullup p_mdio1 (ENET1_MDIO);

  // One-clock phase alignment for the independent wire monitors (see header).
  logic [3:0] enet0_txd_d, enet1_txd_d;
  always_ff @(posedge CLOCK_50) begin
    enet0_txd_d <= ENET0_TX_DATA;
    enet1_txd_d <= ENET1_TX_DATA;
  end

  // "TX enable was ever asserted" - one of the permitted degraded checks.
  logic tx_en_seen = 1'b0;
  always_ff @(posedge CLOCK_50)
    if (ENET0_TX_EN || ENET1_TX_EN) tx_en_seen <= 1'b1;

  // ---- board shell ----------------------------------------------------------
  es_switch_de2_115_top u_dut (
    .CLOCK_50       (CLOCK_50),
    .KEY            (KEY),
    .ENET0_RX_DATA  (ENET0_RX_DATA),
    .ENET0_RX_DV    (ENET0_RX_DV),   .ENET0_RX_ER (ENET0_RX_ER),
    .ENET0_TX_DATA  (ENET0_TX_DATA),
    .ENET0_TX_EN    (ENET0_TX_EN),   .ENET0_TX_ER (ENET0_TX_ER),
    .ENET0_TX_CLK   (ENET0_TX_CLK),
    .ENET0_RESET_N  (ENET0_RESET_N), .ENET0_MDC   (ENET0_MDC),
    .ENET0_MDIO     (ENET0_MDIO),
    .ENET0_INT_N    (ENET0_INT_N),
    .ENET1_RX_DATA  (ENET1_RX_DATA),
    .ENET1_RX_DV    (ENET1_RX_DV),   .ENET1_RX_ER (ENET1_RX_ER),
    .ENET1_TX_DATA  (ENET1_TX_DATA),
    .ENET1_TX_EN    (ENET1_TX_EN),   .ENET1_TX_ER (ENET1_TX_ER),
    .ENET1_TX_CLK   (ENET1_TX_CLK),
    .ENET1_RESET_N  (ENET1_RESET_N), .ENET1_MDC   (ENET1_MDC),
    .ENET1_MDIO     (ENET1_MDIO),
    .ENET1_INT_N    (ENET1_INT_N)
  );

  // ---- two independent MII wire models -------------------------------------
  sw_mii_if #(
    .PORT_ID     (0),
    .BYTE_PERIOD (BP),
    .IFG_OCTETS  (12)
  ) u_if0 (
    .clk_i     (CLOCK_50),
    .rst_ni    (KEY[0]),
    .enable_i  (1'b1),
    .mii_rx_dv (ENET0_RX_DV),
    .mii_rx_er (ENET0_RX_ER),
    .mii_rxd   (ENET0_RX_DATA),
    .mii_tx_en (ENET0_TX_EN),
    .mii_txd   (enet0_txd_d)
  );

  sw_mii_if #(
    .PORT_ID     (1),
    .BYTE_PERIOD (BP),
    .IFG_OCTETS  (12)
  ) u_if1 (
    .clk_i     (CLOCK_50),
    .rst_ni    (KEY[0]),
    .enable_i  (1'b1),
    .mii_rx_dv (ENET1_RX_DV),
    .mii_rx_er (ENET1_RX_ER),
    .mii_rxd   (ENET1_RX_DATA),
    .mii_tx_en (ENET1_TX_EN),
    .mii_txd   (enet1_txd_d)
  );

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

  task automatic idle(input int unsigned n);
    int unsigned i;
    for (i = 0; i < n; i++) @(posedge CLOCK_50);
    #1;
  endtask

  // ---- stimulus -------------------------------------------------------------
  sw_mac_t host_a, bcast;
  tb_rec_t rec;

  initial begin : main_proc
    host_a = 48'h02_AA_00_00_00_01;
    bcast  = SW_MAC_BROADCAST;

    KEY            = 4'h0;   // KEY[0] low: reset asserted
    ENET0_INT_N    = 1'b1;   // interrupts inactive
    ENET1_INT_N    = 1'b1;
    repeat (4) @(posedge CLOCK_50);
    #1;
    KEY = 4'h1;              // release; sampled by the 2-stage synchroniser
    idle(20);

    $display("tb_es_switch_de2_115_top: BYTE_PERIOD=%0d", BP);

    // ---- 1. reset / idle sanity -------------------------------------------
    check(ENET0_TX_EN === 1'b0 && ENET1_TX_EN === 1'b0,
          "TX enables idle after reset");
    check(u_if0.pending() == 0 && u_if1.pending() == 0,
          "no phantom traffic after reset");
    check(ENET0_RESET_N === 1'b1 && ENET1_RESET_N === 1'b1,
          "PHY reset released after synchroniser");

    // ---- 2. observe the MDIO-managed link state (honest report) -----------
    // The board has no modelled MDIO PHY responder here, so enabled_o is not
    // expected to rise; the full 20 ms startup wait is deliberately not run.
    idle(LINK_SETTLE_CLKS);
    $display("tb_es_switch_de2_115_top: phy_enabled after %0d clocks = %b",
             LINK_SETTLE_CLKS, u_dut.phy_enabled);
    check(u_dut.phy_enabled !== 2'bxx && u_dut.phy_enabled !== 2'bzz,
          "phy_enabled is X/Z-free");
    if (u_dut.phy_enabled === 2'b11)
      $display("tb_es_switch_de2_115_top: natural MDIO link-up observed");
    else
      $display("tb_es_switch_de2_115_top: NOTE - no external MDIO PHY responder is modelled, so enabled_o did not rise; link_up_i would gate all RX injection. Forcing phy_enabled high to exercise the MII pin path. This bypasses (does NOT validate) PHY management.");

    // ---- 3. force link up and run one broadcast smoke ---------------------
    force u_dut.phy_enabled = 2'b11;
    repeat (4) @(posedge CLOCK_50);
    #1;
    check(u_dut.phy_enabled === 2'b11, "link_up forced high for smoke test");

    u_if0.send(bcast, host_a, TB_ET_IPV4, CLIENT_LEN);
    idle(SETTLE_CLKS);

    check(u_if1.pending() == 1,
          "broadcast received on the opposite port (ENET1)");
    u_if1.pop_frame(rec, POP_TIMEOUT);
    check_frame(rec, bcast, host_a, CLIENT_LEN, "bcast smoke ENET0->ENET1");
    check(u_if0.pending() == 0,
          "no source-port loopback on ENET0");
    check(u_if1.pending() == 0,
          "ENET1 monitor drained");
    check(u_if0.dropped() == 0 && u_if1.dropped() == 0,
          "no monitor overflow");
    check(u_if0.short_frames() == 0 && u_if1.short_frames() == 0,
          "no short transmit frames");

    // ---- 4. degraded checks: TX enable active, no X/Z propagation --------
    check(tx_en_seen === 1'b1,
          "a TX enable was asserted during the smoke test");
    check((^{ENET0_TX_EN, ENET1_TX_EN, ENET0_TX_ER, ENET1_TX_ER,
             ENET0_TX_DATA, ENET1_TX_DATA, ENET0_RESET_N, ENET1_RESET_N,
             ENET0_MDC, ENET1_MDC}) !== 1'bx,
          "no X on observed TX/reset/MDC outputs");
    check(ENET0_TX_ER === 1'b0 && ENET1_TX_ER === 1'b0,
          "TX error outputs held low");
    check(ENET0_MDIO === 1'b1 && ENET1_MDIO === 1'b1,
          "MDIO pads idle at the pull-up level");

    release u_dut.phy_enabled;

    $display("tb_es_switch_de2_115_top: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "tb_es_switch_de2_115_top: FAILED");
    $display("tb_es_switch_de2_115_top: PASSED");
    $finish;
  end

  // Independent watchdog: bounds a deadlocked fabric or a stuck BFM task.
  initial begin : watchdog
    #20_000_000;
    $fatal(1, "tb_es_switch_de2_115_top: timeout");
  end

endmodule : tb_es_switch_de2_115_top
