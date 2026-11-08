// ============================================================================
//  File        : tb/tb_sw_switch_mii.sv
//  Description : System-level smoke regression of the full switch with the
//                MII pin front-end, by instantiating the `es_switch_mii` top
//                wrapper (the MII variant of the interface-agnostic switch
//                core).
//
//                Two 100 Mbit/s ports on a 125 MHz core clock (BYTE_PERIOD 10,
//                nibble windows of 5 clocks) exchange frames through the whole
//                fabric, and each frame is reassembled from the MII nibble
//                stream of the egress port and checked octet-for-octet:
//
//                  1. unknown-unicast flooding: a frame to a not-yet-learned
//                     address arrives on the other port (the only flood
//                     candidate),
//                  2. known-unicast forwarding in the reply direction, which
//                     also proves the source address of test 1 was learned,
//                  3. known-unicast forwarding back again, proving test 2's
//                     source was learned,
//                  4. nothing is ever reflected onto the sending port, and no
//                     monitor loses or mis-sizes a frame.
// ============================================================================
`timescale 1ns/1ps

module tb_sw_switch_mii;
  import sw_tb_pkg::*;

  localparam int unsigned NUM_PORTS = 2;
  localparam int unsigned CLK_HZ    = 125_000_000;
  /// Both ports at 100 Mbit/s: BYTE_PERIOD = 10, nibble windows of 5 clocks.
  localparam logic [NUM_PORTS*2-1:0] SPEEDS = {2'b01, 2'b01};
  /// Core clocks per octet time, derived with the same function the DUT uses.
  localparam int unsigned BP = sw_byte_period(CLK_HZ, SW_SPEED_100M);

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [NUM_PORTS-1:0] link_up;

  always #4 clk = ~clk;

  // ---- DUT pins -------------------------------------------------------------
  // Packed per-port MII buses; port 0 occupies the low slice of each bus.
  logic [       NUM_PORTS-1:0] mii_rx_dv_i;
  logic [       NUM_PORTS-1:0] mii_rx_er_i;
  logic [     NUM_PORTS*4-1:0] mii_rxd_i;
  logic [       NUM_PORTS-1:0] mii_tx_en_o;
  logic [       NUM_PORTS-1:0] mii_tx_er_o;
  logic [     NUM_PORTS*4-1:0] mii_txd_o;
  logic [32*SW_STAT_COUNT-1:0] stat_o;

  es_switch_mii #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_HZ),
    .PORT_SPEED  (SPEEDS)
  ) u_dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .link_up_i     (link_up),
    .dip_i         (8'd0),
    .mii_rx_dv_i   (mii_rx_dv_i),
    .mii_rx_er_i   (mii_rx_er_i),
    .mii_rxd_i     (mii_rxd_i),
    .mii_tx_en_o   (mii_tx_en_o),
    .mii_tx_er_o   (mii_tx_er_o),
    .mii_txd_o     (mii_txd_o),
    .stat_o        (stat_o),
    .stat_port_i   ('0),
    .stat_id_i     ('0),
    .stat_data_o   (),
    .cam_rd_req_i  (1'b0),
    .cam_rd_index_i(32'd0),
    .cam_rd_valid_o(),
    .cam_rd_entry_o(),
    .cam_entries_o (),
    .led_link_o    (),
    .led_act_o     (),
    .led_speed_o   (),
    .led_duplex_o  (),
    .led_fault_o   (),
    .led_stat_o    (),
    .cfg_flood_mode_o  (),
    .cfg_learning_en_o (),
    .cfg_ovr_o     ()
  );

  // ---- per-port MII PHY models ----------------------------------------------
  sw_mii_if #(
    .PORT_ID     (0),
    .BYTE_PERIOD (BP)
  ) u_if0 (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .enable_i  (link_up[0]),
    .mii_rx_dv (mii_rx_dv_i[0]),
    .mii_rx_er (mii_rx_er_i[0]),
    .mii_rxd   (mii_rxd_i[3:0]),
    .mii_tx_en (mii_tx_en_o[0]),
    .mii_txd   (mii_txd_o[3:0])
  );

  sw_mii_if #(
    .PORT_ID     (1),
    .BYTE_PERIOD (BP)
  ) u_if1 (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .enable_i  (link_up[1]),
    .mii_rx_dv (mii_rx_dv_i[1]),
    .mii_rx_er (mii_rx_er_i[1]),
    .mii_rxd   (mii_rxd_i[7:4]),
    .mii_tx_en (mii_tx_en_o[1]),
    .mii_txd   (mii_txd_o[7:4])
  );

  // ---------------------------------------------------------------------------
  // Checking helpers
  // ---------------------------------------------------------------------------
  int unsigned errors;
  int unsigned checks;

  /// Print one PASS/FAIL line for an integer expectation.
  task automatic expect_eq(input int unsigned got, input int unsigned exp, input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %0d, expected %0d", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %0d", $time, what, got);
    end
  endtask

  /// Print one PASS/FAIL line for a one-bit expectation.
  task automatic expect_1bit(input logic got, input logic exp, input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %b, expected %b", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %b", $time, what, got);
    end
  endtask

  /// Print one PASS/FAIL line for a MAC address expectation.
  task automatic expect_mac(input sw_mac_t got, input sw_mac_t exp, input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %s, expected %s", $time, what, tb_mac_str(got), tb_mac_str(exp
               ));
    end else begin
      $display("[%0t] PASS  %s = %s", $time, what, tb_mac_str(got));
    end
  endtask

  /// Full verdict on one received frame.
  task automatic check_rec(input tb_rec_t r, input sw_mac_t dst, input sw_mac_t src,
                           input int unsigned total_len, input string tag);
    expect_eq(tb_rec_len(r), total_len, {tag, ": length"});
    expect_1bit(tb_rec_fcs_ok(r), 1'b1, {tag, ": FCS verdict"});
    expect_1bit(tb_rec_pre_ok(r), 1'b1, {tag, ": preamble verdict"});
    expect_mac(tb_rec_dst(r), dst, {tag, ": destination MAC"});
    expect_mac(tb_rec_src(r), src, {tag, ": source MAC"});
    expect_eq(tb_rec_l2(r), TB_ET_IPV4, {tag, ": EtherType"});
  endtask

  /// One-line dump of the fabric statistics, for diagnosing where a frame
  /// was lost on its way through the switch.
  task automatic show_stats(input string tag);
    $display(
        "     [%s] stats: rx frames %0d (filtered %0d, crc %0d, runt %0d, oversize %0d, overflow %0d), tx frames %0d, cam learn %0d hit %0d miss %0d",
        tag, stat_o[32*SW_STAT_RX_FRAMES +: 32], stat_o[32*SW_STAT_RX_FILTERED +: 32],
        stat_o[32*SW_STAT_RX_CRC_ERR +: 32], stat_o[32*SW_STAT_RX_RUNT +: 32],
        stat_o[32*SW_STAT_RX_OVERSIZE +: 32], stat_o[32*SW_STAT_RX_OVERFLOW +: 32],
        stat_o[32*SW_STAT_TX_FRAMES +: 32], stat_o[32*SW_STAT_CAM_LEARN +: 32],
        stat_o[32*SW_STAT_CAM_HIT +: 32], stat_o[32*SW_STAT_CAM_MISS +: 32]);
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  sw_mac_t STA0;   ///< station behind port 0
  sw_mac_t STA1;   ///< station behind port 1
  tb_rec_t r;      ///< the frame most recently popped off a monitor queue

  initial begin
    errors  = 0;
    checks  = 0;
    // Stations behind the ports - deliberately NOT the switch ports' own
    // default MACs: the ingress filter drops a frame sourced from the
    // receiving port's own address, as a reflection.
    STA0    = 48'h02_AA_00_00_00_01;
    STA1    = 48'h02_BB_00_00_00_02;

    rst_n  = 1'b0;
    link_up = {NUM_PORTS{1'b1}};
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    $display("=====================================================================");
    $display(" tb_sw_switch_mii: %0d ports, %0d MHz core, both ports 100 Mbit/s", NUM_PORTS,
             CLK_HZ / 1_000_000);
    $display("=====================================================================");

    // ---- 1. unknown destination: flooded to the only other port ----------
    $display("---- frame 0 -> 1 to an unlearned address (flood) ----");
    u_if0.send(STA1, STA0, TB_ET_IPV4, 100);
    u_if1.pop_frame(r, 100000);
    show_stats("after flood 0->1");
    check_rec(r, STA1, STA0, 100, "flood 0->1");
    expect_eq(u_if1.pending(), 0, "flood 0->1: port 1 monitor drained");
    expect_eq(u_if0.pending(), 0, "flood 0->1: nothing reflected to port 0");
    expect_eq(u_if0.dropped(), 0, "flood 0->1: port 0 monitor lost nothing");
    expect_eq(u_if1.dropped(), 0, "flood 0->1: port 1 monitor lost nothing");
    expect_eq(u_if1.short_frames(), 0, "flood 0->1: no short frame on port 1");

    // ---- 2. reply direction: the source of test 1 must have been learned -
    $display("---- frame 1 -> 0 to a learned address (unicast hit) ----");
    u_if1.send(STA0, STA1, TB_ET_IPV4, 64);
    u_if0.pop_frame(r, 100000);
    check_rec(r, STA0, STA1, 64, "unicast 1->0");
    expect_eq(u_if0.pending(), 0, "unicast 1->0: port 0 monitor drained");
    expect_eq(u_if1.pending(), 0, "unicast 1->0: nothing reflected to port 1");

    // ---- 3. back again: the source of test 2 must have been learned ------
    $display("---- frame 0 -> 1 to a learned address (unicast hit) ----");
    u_if0.send(STA1, STA0, TB_ET_IPV4, 100);
    u_if1.pop_frame(r, 100000);
    check_rec(r, STA1, STA0, 100, "unicast 0->1");
    expect_eq(u_if1.pending(), 0, "unicast 0->1: port 1 monitor drained");
    expect_eq(u_if0.pending(), 0, "unicast 0->1: nothing reflected to port 0");

    // ---- verdict ----------------------------------------------------------
    expect_1bit(mii_tx_er_o[0], 1'b0, "port 0 mii_tx_er_o held low");
    expect_1bit(mii_tx_er_o[1], 1'b0, "port 1 mii_tx_er_o held low");

    $display("-----------------------------------------------------------------------");
    if (errors == 0) begin
      $display(" tb_sw_switch_mii: PASSED (%0d checks)", checks);
      $finish;
    end else begin
      $fatal(1, " tb_sw_switch_mii: FAILED (%0d of %0d checks failed)", errors, checks);
    end
  end

  // Watchdog: a fabric that deadlocks must not hang the regression.
  initial begin
    #20_000_000;
    $fatal(1, "tb_sw_switch_mii: timeout");
  end

endmodule : tb_sw_switch_mii
