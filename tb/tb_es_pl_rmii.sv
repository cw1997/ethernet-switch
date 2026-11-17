// ============================================================================
//  File        : tb_es_pl_rmii.sv
//  Description : Self-checking four-port regression for es_rmii_top using four
//                independent es_rmii_if wire models as RX drivers.  Scenarios:
//                reset/idle, broadcast flooding, learning + known-unicast, and
//                a corrupt-FCS frame dropped everywhere.  The independent
//                rmii_wire_mon checks TX because the built-in BFM monitor
//                reconstructs octets with a one-chunk rotation.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "es_tb_pkg.sv"

module tb_es_pl_rmii
  import es_tb_pkg::*;
#(
  parameter int unsigned NUM_PORTS = 4
) ();

  localparam int unsigned CLK_HZ = 50_000_000;
  localparam int unsigned BP = es_byte_period(CLK_HZ, ES_SPEED_100M);
  localparam logic [NUM_PORTS*2-1:0] SPEEDS = {NUM_PORTS{2'(ES_SPEED_100M)}};
  localparam int unsigned CLIENT_LEN = 64;
  /// A 64-octet client frame is 304 dibits; 1500 clocks covers the egress
  /// serialisation, pipeline latency and IFG before any count verdict.
  localparam int unsigned SETTLE_CLKS = 1500;
  localparam int unsigned NW = NUM_PORTS*2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic clear = 1'b0;
  logic [NUM_PORTS-1:0]   link_up;
  logic [NUM_PORTS-1:0]   rmii_crs_dv, rmii_tx_en;
  logic [NUM_PORTS*2-1:0] rmii_rxd, rmii_txd;

  logic [NUM_PORTS*16-1:0] mon_cnt;
  logic [NUM_PORTS*12-1:0] mon_len;
  logic [NUM_PORTS*48-1:0] mon_dst;
  logic [NUM_PORTS*48-1:0] mon_src;
  logic [NUM_PORTS-1:0]    mon_ok;

  always #10 clk = ~clk;  // 20 ns period; absolute period is irrelevant.

  // Unpacked-array adapter for the RMII top's pad ports; genvar indices keep
  // every element access constant and Icarus-safe.
  logic       link_up_a[NUM_PORTS];
  logic       rmii_crs_dv_a[NUM_PORTS];
  logic [1:0] rmii_rxd_a[NUM_PORTS];
  wire        rmii_tx_en_a[NUM_PORTS];
  wire  [1:0] rmii_txd_a[NUM_PORTS];

  genvar ga;
  generate
    for (ga = 0; ga < NUM_PORTS; ga++) begin : g_port_adapt
      assign link_up_a[ga]          = link_up[ga];
      assign rmii_crs_dv_a[ga]      = rmii_crs_dv[ga];
      assign rmii_rxd_a[ga]         = rmii_rxd[ga*2 +: 2];
      assign rmii_tx_en[ga]         = rmii_tx_en_a[ga];
      assign rmii_txd[ga*2 +: 2]    = rmii_txd_a[ga];
    end
  endgenerate

  // ---- DUT ------------------------------------------------------------------
  // Only the ports the rewritten top still has are connected.
  es_rmii_top #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_HZ),
    .PORT_SPEED  (SPEEDS),
    .PORT_MAC    ('0),
    .IFG_OCTETS  (12)
  ) u_dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .link_up_i     (link_up_a),
    .rmii_crs_dv_i (rmii_crs_dv_a),
    .rmii_rxd_i    (rmii_rxd_a),
    .rmii_tx_en_o  (rmii_tx_en_a),
    .rmii_txd_o    (rmii_txd_a)
  );

  // ---- per-port RMII drivers (BFM `send`) and independent wire monitors -----
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_phy
      es_rmii_if #(
        .PORT_ID     (g),
        .BYTE_PERIOD (BP),
        .IFG_OCTETS  (12)
      ) u_if (
        .clk_i       (clk),
        .rst_ni      (rst_n),
        .enable_i    (1'b1),
        .rmii_crs_dv (rmii_crs_dv[g]),
        .rmii_rxd    (rmii_rxd[g*2 +: 2]),
        // The BFM's built-in monitor cannot decode the new adapter's chunk
        // phase; tie it idle and use the independent monitor below instead.
        .rmii_tx_en  (1'b0),
        .rmii_txd    (2'b00)
      );

      rmii_wire_mon #(
        .PORT_ID (g)
      ) u_mon (
        .clk_i   (clk),
        .rst_ni  (rst_n),
        .clear_i (clear),
        .tx_en_i (rmii_tx_en[g]),
        .tx_d_i  (rmii_txd[g*2 +: 2]),
        .cnt_o   (mon_cnt[g*16 +: 16]),
        .len_o   (mon_len[g*12 +: 12]),
        .dst_o   (mon_dst[g*48 +: 48]),
        .src_o   (mon_src[g*48 +: 48]),
        .ok_o    (mon_ok[g])
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

  // Constant hierarchical dispatch: a run-time g_phy[p].u_if reference cannot
  // select an elaborated instance in Icarus.
  task automatic send_frame(input int unsigned p, input es_mac_t dst,
                            input es_mac_t src, input int unsigned len,
                            input bit bad_fcs);
    case (p)
      0: g_phy[0].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      1: g_phy[1].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      2: g_phy[2].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      3: g_phy[3].u_if.send(dst, src, TB_ET_IPV4, len, 1'b0, bad_fcs);
      default: $fatal(1, "tb_es_pl_rmii: invalid sending port %0d", p);
    endcase
  endtask

  task automatic idle(input int unsigned n);
    int unsigned i;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  task automatic clear_monitors();
    clear = 1'b1;
    @(posedge clk);
    #1;
    clear = 1'b0;
  endtask

  task automatic expect_on(input int unsigned port, input int unsigned cnt,
                           input es_mac_t dst, input es_mac_t src,
                           input int unsigned len, input string label);
    check(mon_cnt[port*16 +: 16] == 16'(cnt), {label, ": frame count"});
    if (cnt != 0) begin
      check(mon_len[port*12 +: 12] == 12'(len), {label, ": client length"});
      check(mon_dst[port*48 +: 48] == dst,      {label, ": destination MAC"});
      check(mon_src[port*48 +: 48] == src,      {label, ": source MAC"});
      check(mon_ok[port] == 1'b1,              {label, ": preamble/FCS"});
    end
  endtask

  // ---- stimulus -------------------------------------------------------------
  es_mac_t host_a, host_b, host_c, bcast;
  int unsigned p;

  initial begin : main_proc
    host_a = 48'h02_AA_00_00_00_01;
    host_b = 48'h02_BB_00_00_00_02;
    host_c = 48'h02_CC_00_00_00_03;
    bcast  = ES_MAC_BROADCAST;

    rst_n   = 1'b0;
    clear   = 1'b0;
    link_up = '1;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    idle(20);
    clear_monitors();

    $display("tb_es_pl_rmii: NUM_PORTS=%0d CLK_HZ=%0d BYTE_PERIOD=%0d", NUM_PORTS, CLK_HZ, BP);

    // ---- 1. reset and idle: no phantom traffic ----------------------------
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_a, CLIENT_LEN, "idle");

    // ---- 2. broadcast floods to 1/2/3, never back to source port 0 -------
    send_frame(0, bcast, host_a, CLIENT_LEN, 1'b0);
    idle(SETTLE_CLKS);
    expect_on(0, 0, bcast, host_a, CLIENT_LEN, "bcast src");
    for (p = 1; p < NUM_PORTS; p++)
      expect_on(p, 1, bcast, host_a, CLIENT_LEN, "bcast flood");
    clear_monitors();

    // ---- 3. learn host_b on the last port, then known unicast -------------
    // A broadcast sourced by host_b on port 3 floods to 0/1/2 and teaches the
    // CAM that host_b lives at port 3.
    send_frame(NUM_PORTS - 1, bcast, host_b, CLIENT_LEN, 1'b0);
    idle(SETTLE_CLKS);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (p == NUM_PORTS - 1)
        expect_on(p, 0, bcast, host_b, CLIENT_LEN, "learn src");
      else
        expect_on(p, 1, bcast, host_b, CLIENT_LEN, "learn flood");
    end
    clear_monitors();
    // host_a on port 0 -> host_b (learned at port 3): only port 3 may receive.
    send_frame(0, host_b, host_a, CLIENT_LEN, 1'b0);
    idle(SETTLE_CLKS);
    expect_on(0, 0, host_b, host_a, CLIENT_LEN, "known unicast src");
    for (p = 1; p < NUM_PORTS - 1; p++)
      expect_on(p, 0, host_b, host_a, CLIENT_LEN, "known unicast others");
    expect_on(NUM_PORTS - 1, 1, host_b, host_a, CLIENT_LEN, "known unicast dest");
    clear_monitors();

    // ---- 4. corrupt FCS must be dropped everywhere ------------------------
    send_frame(0, bcast, host_c, CLIENT_LEN, 1'b1);
    idle(SETTLE_CLKS);
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_c, CLIENT_LEN, "bad FCS");

    $display("tb_es_pl_rmii: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "tb_es_pl_rmii: FAILED");
    $display("tb_es_pl_rmii: PASSED");
    $finish;
  end

  // Independent watchdog: per-frame timeouts cannot protect a task stuck
  // before reception or a stopped clock.  20 ms is far beyond normal runtime.
  initial begin : watchdog
    #20_000_000;
    $fatal(1, "tb_es_pl_rmii: timeout");
  end

endmodule : tb_es_pl_rmii
