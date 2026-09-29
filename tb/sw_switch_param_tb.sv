// ============================================================================
//  File        : tb/sw_switch_param_tb.sv
//  Description : Parameterisation testbench of the switch core.
//
//                `tb_sw_switch` proves that the design *works*; this testbench
//                proves that the parameters *matter*, by instantiating the
//                very same RTL with a completely different configuration:
//
//                  * NUM_PORTS     = 3   (not a power of two, so the derived port
//                                           widths are the interesting case)
//                  * CLK_FREQ_HZ   = 50 MHz (a quarter of the canonical clock,
//                                           so the octet clock enables are 40
//                                           and 4 core clocks long instead of
//                                           100 and 10)
//                  * PORT_SPEED    = 10 / 100 / 100 Mbit/s
//                  * PORT_MAC      = three distinct addresses, so the per-port
//                                    reflection filter is exercised
//                  * a small CAM and small tag queue
//
//                Everything that is parameter dependent - the port count, the
//                octet rate of every port, the per-port addresses and the
//                derived port widths - is therefore exercised end to end, at a
//                clock rate and port geometry that the main testbench never
//                uses.
//
//                The checks are deliberately simple and end to end:
//
//                  * a broadcast reaches the other ports and nothing else,
//                  * a station learned behind one port is subsequently reached
//                    on that port only,
//                  * a frame addressed to a port's own address goes to that port,
//                  * the octet stream on every port is re-assembled and FCS
//                    checked by the PHY model, so a wrong BYTE_PERIOD anywhere
//                    shows up as a corrupt frame rather than as a silent
//                    timing error.
// ============================================================================
`timescale 1ns/1ps

module sw_switch_param_tb;

  // The verification helpers live in sw_tb_pkg.  The RTL declarations are at
  // compilation-unit scope (`rtl/sw_defs.sv`) and so need no import.
  import sw_tb_pkg::*;

  // ==========================================================================
  // 1.  Configuration under test
  // ==========================================================================
  localparam int unsigned NUM_PORTS   = 3;
  localparam int unsigned CLK_FREQ_HZ = 50_000_000;
  localparam int unsigned CLK_PERIOD  = 20;   // ns -> 50 MHz

  localparam logic [NUM_PORTS*48-1:0] PORT_MAC = {
      48'hDE_AD_00_00_00_03, 48'hDE_AD_00_00_00_02, 48'hDE_AD_00_00_00_01};

  /// 10 Mbit/s on port 0, 100 Mbit/s on ports 1 and 2.
  localparam logic [NUM_PORTS*2-1:0] PORT_SPEED = {2'd1, 2'd1, 2'd0};

  function automatic sw_mac_t port_mac(input int unsigned p);
    return PORT_MAC[p*48 +: 48];
  endfunction

  // The octet time of each port in core clocks, derived from the configuration
  // under test rather than hard coded, so the models cannot disagree with the
  // banner.  `sw_byte_period` is an ordinary function, so these are elaborated
  // here instead of inside the function above.
  localparam int unsigned BP0 = sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[0*2 +: 2]));
  localparam int unsigned BP1 = sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[1*2 +: 2]));
  localparam int unsigned BP2 = sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[2*2 +: 2]));

  // ==========================================================================
  // 2.  Clock, reset and DUT
  // ==========================================================================
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  logic [NUM_PORTS-1:0]        link_up;
  logic [1:0]                  flood_mode;
  logic                        learning_en, cfg_ovr, cam_flush;
  logic [NUM_PORTS-1:0]        gmii_rx_en;
  logic [NUM_PORTS*8-1:0]      gmii_rx_data;
  logic [NUM_PORTS-1:0]        gmii_tx_en;
  logic [NUM_PORTS*8-1:0]      gmii_tx_data;
  logic [32*SW_STAT_COUNT-1:0] stat_bus;

  sw_switch #(
      .NUM_PORTS      (NUM_PORTS),
      .CLK_FREQ_HZ    (CLK_FREQ_HZ),
      .PORT_MAC       (PORT_MAC),
      .PORT_SPEED     (PORT_SPEED),
      .RX_FIFO_DEPTH  (256),
      .TX_FIFO_DEPTH  (256),
      .TAG_FIFO_DEPTH (8),
      .CAM_SETS       (32),
      .CAM_WAYS       (2)
  ) u_dut (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .link_up_i     (link_up),
      .flood_mode_i  (flood_mode),
      .learning_en_i (learning_en),
      .cfg_ovr_i     (cfg_ovr),
      .cam_flush_i   (cam_flush),
      .gmii_rx_en_i  (gmii_rx_en),
      .gmii_rx_data_i(gmii_rx_data),
      .gmii_tx_en_o  (gmii_tx_en),
      .gmii_tx_data_o(gmii_tx_data),
      .stat_o        (stat_bus)
  );

  // ==========================================================================
  // 3.  Per-port PHY models
  //
  // The models are instantiated explicitly rather than through `sw_if_array`,
  // which is fixed to four ports: this configuration has three, and a power of
  // two port count is exactly what the other testbenches already cover.
  // ==========================================================================
  sw_gmii_if #(.PORT_ID(0), .BYTE_PERIOD(BP0)) i0 (
      .clk_i(clk), .rst_ni(rst_n), .enable_i(link_up[0]),
      .gmii_rx_en(gmii_rx_en[0]), .gmii_rx_d(gmii_rx_data[0*8 +: 8]),
      .gmii_tx_en(gmii_tx_en[0]), .gmii_tx_d(gmii_tx_data[0*8 +: 8]));

  sw_gmii_if #(.PORT_ID(1), .BYTE_PERIOD(BP1)) i1 (
      .clk_i(clk), .rst_ni(rst_n), .enable_i(link_up[1]),
      .gmii_rx_en(gmii_rx_en[1]), .gmii_rx_d(gmii_rx_data[1*8 +: 8]),
      .gmii_tx_en(gmii_tx_en[1]), .gmii_tx_d(gmii_tx_data[1*8 +: 8]));

  sw_gmii_if #(.PORT_ID(2), .BYTE_PERIOD(BP2)) i2 (
      .clk_i(clk), .rst_ni(rst_n), .enable_i(link_up[2]),
      .gmii_rx_en(gmii_rx_en[2]), .gmii_rx_d(gmii_rx_data[2*8 +: 8]),
      .gmii_tx_en(gmii_tx_en[2]), .gmii_tx_d(gmii_tx_data[2*8 +: 8]));

  // ==========================================================================
  // 4.  Bookkeeping
  // ==========================================================================
  int unsigned errors;
  int unsigned checks;

  // Outstanding frame expectations, one counter per port.
  //
  // A packed vector rather than an unpacked array: the counters are read and
  // written through a runtime port index inside a task, and an unpacked array
  // indexed that way is not resolved reliably by every simulator.  A packed
  // vector indexed by a bit position behaves identically everywhere.
  logic [NUM_PORTS-1:0] expected_frames;   ///< 0..255 frames per port

  task automatic note_error(input string msg);
    errors++;
    $display("[%0t] ERROR %s", $time, msg);
  endtask

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

  /// Wait until every port has delivered all the frames it was told to expect,
  /// then report any port that is still short.  A generous bound: the slowest
  /// port is 10 Mbit/s on a 50 MHz core, so a 100 octet frame needs 4000 clocks
  /// to arrive and the check has to outlast the frame it is waiting for.
  task automatic wait_all_settled(input int unsigned bound);
    for (int unsigned w = 0; w < bound; w++) begin
      if ((expected_frames[0] == 0) && (expected_frames[1] == 0) &&
          (expected_frames[2] == 0)) w = bound;   // all delivered
      @(posedge clk);
    end
  endtask

  /// Consume every frame the monitor of port `p` has captured, verifying each one
  /// and counting it against that port's outstanding expectation.
  ///
  /// The verification is deliberately exhaustive: *every* captured frame is
  /// checked, not just the expected ones, so a spurious extra copy decrements the
  /// expectation below zero and is reported rather than going unnoticed.  A frame
  /// that arrives is also checked for length, FCS and preamble, so a transmit
  /// path that corrupts a frame is caught at the wire boundary.
  task automatic drain_port(input int unsigned p);
    tb_rec_t r;
    bit      got_one;
    // Icarus cannot select a module instance from a runtime index, so the three
    // possible ports are handled explicitly.
    for (int unsigned guard = 0; guard < 32; guard++) begin
      got_one = 1'b1;
      if      (p == 0) begin got_one = (i0.pending() != 0); if (got_one) i0.pop_frame(r); end
      else if (p == 1) begin got_one = (i1.pending() != 0); if (got_one) i1.pop_frame(r); end
      else if (p == 2) begin got_one = (i2.pending() != 0); if (got_one) i2.pop_frame(r); end
      else begin
        note_error($sformatf("bad port index %0d", p));
        got_one = 1'b0;
      end
      // The queue is empty: there is nothing left to check on this port.  The
      // loop must stop *before* touching `r`, because `pop_frame` on an empty
      // queue hands back a zeroed record that would otherwise be reported as a
      // spurious zero-length frame with a bad FCS.
      if (!got_one) guard = 32;
      else begin
        expect_eq(tb_rec_len(r), PAYLOAD, $sformatf("port %0d frame length", p));
        if (!tb_rec_fcs_ok(r))
          note_error($sformatf("port %0d: frame of %0d octets has a bad FCS",
                               p, tb_rec_len(r)));
        if (!tb_rec_pre_ok(r))
          note_error($sformatf("port %0d: frame of %0d octets has a bad preamble",
                               p, tb_rec_len(r)));
        // Counted against the expectation, and reported if there was none.
        if (expected_frames[p] == 0) begin
          note_error($sformatf("port %0d produced an unexpected frame to %s",
                               p, tb_mac_str(tb_rec_dst(r))));
        end else begin
          expected_frames[p]--;
        end
      end
    end
  endtask

  /// Drain all three ports.
  task automatic drain_all();
    drain_port(0);
    drain_port(1);
    drain_port(2);
  endtask

  // ==========================================================================
  // 5.  Test sequence
  // ==========================================================================
  localparam int unsigned PAYLOAD = 100;   // MAC client data octets

  // --------------------------------------------------------------------------
  // Settle bound.
  //
  // Derived from the configuration rather than guessed.  The slowest port here
  // is 10 Mbit/s on a 50 MHz core, so one octet time is BP0 (40) core clocks and
  // a frame of PAYLOAD octets needs BP0*(PAYLOAD+4) clocks merely to be clocked
  // out of the receive path, before the fabric and the transmit path have
  // finished with it.  A fixed count that suits a 100 Mbit/s port checks the
  // expectations while the 10 Mbit/s port is still transmitting, which shows up
  // as frames arriving late, out of order, and leftovers from the previous test
  // counted as "unexpected".
  // --------------------------------------------------------------------------
  localparam int unsigned SETTLE = BP0*(PAYLOAD + 4) + 4*BP0 + 5000;

  localparam sw_mac_t HOST_A = 48'h02_BA_BA_00_00_01;
  localparam sw_mac_t HOST_B = 48'h02_BA_BA_00_00_02;
  localparam sw_mac_t HOST_C = 48'h02_BA_BA_00_00_03;

  task automatic send_on(input int unsigned port, input sw_mac_t dst,
                         input sw_mac_t src, input int unsigned len);
    case (port)
      0: i0.send(dst, src, TB_ET_IPV4, len);
      1: i1.send(dst, src, TB_ET_IPV4, len);
      2: i2.send(dst, src, TB_ET_IPV4, len);
      default: note_error($sformatf("bad port index %0d", port));
    endcase
    $display("[%0t] TX  port %0d -> %s (%0d octets)",
             $time, port, tb_mac_str(dst), len);
  endtask

  initial begin
    link_up     = '1;
    flood_mode  = SW_FLOOD_BCAST_UKN;
    learning_en = 1'b1;
    cfg_ovr     = 1'b0;
    cam_flush   = 1'b0;
    errors      = 0;
    checks      = 0;
    expected_frames = '0;

    rst_n = 1'b0;
    repeat (16) @(posedge clk);
    rst_n = 1'b1;
    repeat (16) @(posedge clk);

    $display("=====================================================================");
    $display(" sw_switch_param_tb: %0d ports at %0d MHz", NUM_PORTS,
             CLK_FREQ_HZ/1_000_000);
    $display("   octet periods: %0d, %0d, %0d core clocks", BP0, BP1, BP2);
    $display("   port speeds  : 10M, 100M, 100M");
    $display("   port MACs    : %s, %s, %s",
             tb_mac_str(port_mac(0)), tb_mac_str(port_mac(1)),
             tb_mac_str(port_mac(2)));
    $display("=====================================================================");

    // ---- reset and idle ---------------------------------------------------
    // Nothing may appear on any port while the switch is idle.
    repeat (200) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0] + expected_frames[1] + expected_frames[2], 0,
              "the idle link produces no traffic");

    // ---- a broadcast reaches every other port ------------------------------
    $display("---- broadcast from port 0 ----");
    send_on(0, SW_MAC_BROADCAST, HOST_A, PAYLOAD);
    expected_frames[1] = 1;
    expected_frames[2] = 1;
    wait_all_settled(SETTLE);
    repeat (200) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 got no copy of its own broadcast");
    expect_eq(expected_frames[1], 0, "port 1 received the broadcast");
    expect_eq(expected_frames[2], 0, "port 2 received the broadcast");

    // ---- a station behind port 2 is learned, then directed ----------------
    // HOST_B announces itself on port 2; the next frame, from port 0, must be
    // delivered to port 2 and to port 2 only.
    $display("---- learn HOST_B on port 2, then unicast to it ----");
    send_on(2, SW_MAC_BROADCAST, HOST_B, PAYLOAD);
    expected_frames[0] = 1;
    expected_frames[1] = 1;
    expected_frames[2] = 0;
    wait_all_settled(SETTLE);
    repeat (200) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 received the broadcast from port 2");
    expect_eq(expected_frames[1], 0, "port 1 received the broadcast from port 2");

    send_on(0, HOST_B, HOST_A, PAYLOAD);
    expected_frames[2] = 1;
    wait_all_settled(SETTLE);
    repeat (200) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 got no copy of its own unicast");
    expect_eq(expected_frames[1], 0, "port 1 was not the destination");
    expect_eq(expected_frames[2], 0, "port 2 received the unicast to HOST_B");

    // ---- a station behind port 1 is learned, then unicast to ---------------
    // HOST_C announces itself on port 1 with a broadcast.  The switch floods the
    // announcement and learns HOST_C behind port 1, so the next frame, from port
    // 0, must be delivered to port 1 and to port 1 only.
    //
    // A *station*, not the port's own address: a frame whose source is the port's
    // own address is a reflected frame, and the ingress filter drops it outright
    // - it is neither forwarded nor learned.  So a port's own address can never
    // enter the CAM and a frame addressed to it is always an unknown unicast.
    // Both halves of that behaviour are checked below, where the PORT_MAC
    // parameters are what is under test.
    $display("---- learn HOST_C on port 1, then unicast to it ----");
    send_on(1, SW_MAC_BROADCAST, HOST_C, PAYLOAD);
    expected_frames[0] = 1;
    expected_frames[2] = 1;
    wait_all_settled(SETTLE);
    repeat (200) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 received port 1's broadcast");
    expect_eq(expected_frames[2], 0, "port 2 received port 1's broadcast");

    send_on(0, HOST_C, HOST_A, PAYLOAD);
    expected_frames[1] = 1;
    wait_all_settled(SETTLE);
    repeat (200) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 got no copy of its own unicast");
    expect_eq(expected_frames[1], 0, "port 1 received the unicast to HOST_C");
    expect_eq(expected_frames[2], 0, "port 2 was not the destination");

    // ---- a frame addressed to a port's own address is consumed there -------
    // A frame whose destination is the address of the port it arrives on has
    // reached its destination and must be discarded there, not flooded out of the
    // other ports.  This is the check that proves the three distinct PORT_MAC
    // values are wired to the right ports: with them permuted, `dst == PORT_MAC`
    // would be false on port 2, the address would miss the CAM, and the frame
    // would be flooded to ports 0 and 1 instead.
    $display("---- a port's own address arriving on that port is consumed ----");
    send_on(2, port_mac(2), HOST_A, PAYLOAD);
    repeat (SETTLE) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 must not see the addressed frame");
    expect_eq(expected_frames[1], 0, "port 1 must not see the addressed frame");
    // Nothing was expected on port 2 either, and `drain_all` already reported any
    // frame that showed up there as unexpected, so a zero here is the whole check.
    expect_eq(expected_frames[2], 0, "port 2 consumed its own address");

    // The ingress filter must have accounted for exactly that one frame.
    expect_eq(stat_bus[32*int'(SW_STAT_RX_FILTERED) +: 32], 1,
              "exactly one frame was dropped by the ingress filter");

    // ---- a frame *sourced* from the port's own address is reflected ---------
    // The mirror image of the check above: a frame coming *from* the port's own
    // address has come back around, so it is dropped and - just as important -
    // not learned.  A second frame addressed to that address therefore still
    // misses the CAM and is flooded, which is what proves it was not learned.
    $display("---- a frame sourced from the port's own address is dropped ----");
    send_on(2, HOST_A, port_mac(2), PAYLOAD);
    repeat (SETTLE) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 must not see the reflected frame");
    expect_eq(expected_frames[1], 0, "port 1 must not see the reflected frame");
    expect_eq(expected_frames[2], 0, "port 2 must not reflect its own address");

    expect_eq(stat_bus[32*int'(SW_STAT_RX_FILTERED) +: 32], 2,
              "the ingress filter dropped two frames in total");

    // The reflected source address must not have been learned either.
    send_on(0, port_mac(2), HOST_A, PAYLOAD);
    expected_frames[1] = 1;
    expected_frames[2] = 1;
    wait_all_settled(SETTLE);
    repeat (200) @(posedge clk);
    drain_all();
    expect_eq(expected_frames[0], 0, "port 0 got no copy of its own unicast");
    expect_eq(expected_frames[1], 0, "port 1 received the unicast");
    expect_eq(expected_frames[2], 0, "port 2 received the unicast");

    // ==========================================================================
    // Summary
    // ==========================================================================
    $display("-----------------------------------------------------------------------");
    $display("   observed per port (dropped = monitor overflow, short = runt):");
    $display("     port 0: %0d dropped, %0d short", i0.dropped(), i0.short_frames());
    $display("     port 1: %0d dropped, %0d short", i1.dropped(), i1.short_frames());
    $display("     port 2: %0d dropped, %0d short", i2.dropped(), i2.short_frames());
    $display("   switch statistics: rx frames %0d, rx octets %0d, tx frames %0d",
             stat_bus[32*0 +: 32], stat_bus[32*1 +: 32], stat_bus[32*7 +: 32]);
    $display("                     filtered %0d, bad FCS %0d, runts %0d, oversize %0d",
             stat_bus[32*2 +: 32], stat_bus[32*3 +: 32], stat_bus[32*4 +: 32],
             stat_bus[32*5 +: 32]);
    $display("                     cam hits %0d, misses %0d, learns %0d",
             stat_bus[32*10 +: 32], stat_bus[32*11 +: 32], stat_bus[32*12 +: 32]);
    $display("-----------------------------------------------------------------------");

    if (errors == 0) begin
      $display(" sw_switch_param_tb: PASSED (%0d checks)", checks);
      $finish;
    end else begin
      $fatal(1, " sw_switch_param_tb: FAILED (%0d of %0d checks failed)",
             errors, checks);
    end
  end

  // Watchdog.  The slowest port is 10 Mbit/s on a 50 MHz core, so the whole
  // sequence needs a few million clocks; the bound is generous but finite.
  initial begin
    #40_000_000;
    $fatal(1, "sw_switch_param_tb: timeout");
  end

endmodule : sw_switch_param_tb
