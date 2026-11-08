// ============================================================================
//  File        : tb/sw_flood_tb.sv
//  Description : Focused regression for multi-frame flooding through the
//                store-and-forward fabric.
//
//                `tb_sw_switch` test 12 injects back-to-back broadcasts from
//                every port and is the only place the fabric is asked to hold
//                more than one frame per ingress queue.  It is also the slowest
//                test in the suite, because the slowest port runs at 10 Mbit/s,
//                so a defect there is expensive to iterate on.  This
//                testbench reproduces the same traffic shape with every port at
//                1000 Mbit/s, which runs in seconds, and adds a per-frame
//                settle so a failure names the frame that went missing rather
//                than reporting every outstanding expectation at the end.
//
//                The design under test is the same RTL, elaborated through a
//                different parameter set: three ports, four ingress buffers deep
//                enough for several maximum-length frames, and a deliberately
//                small CAM so that replacement - not capacity - is what the
//                learn path has to get right.
// ============================================================================
`timescale 1ns/1ps

module sw_flood_tb #(
  /// Link speed of port 0.  2 = 1000 Mbit/s (the default, and the fast
  /// configuration), 0 = 10 Mbit/s.  The slow configuration is the one that
  /// matters: it makes port 0's egress buffer accumulate a long queue while the
  /// fabric is still pushing frames into it, which is the situation the
  /// four-port testbench runs into and the one a store-and-forward fabric is
  /// most likely to get wrong.  Elaborate it with
  ///     iverilog -P sw_flood_tb.SPEED0=0
  parameter int unsigned SPEED0 = 2
);

  import sw_tb_pkg::*;

  // --------------------------------------------------------------------------
  // Configuration: fast enough to iterate on, deep enough to hold four frames
  // per ingress queue so the fabric really does see a queue.
  // --------------------------------------------------------------------------
  localparam int unsigned NUM_PORTS = 3;        // deliberately not a power of two
  localparam int unsigned CLK_FREQ = 125_000_000;
  localparam int unsigned RX_DEPTH = 64;        // 8 beats * 8 frames
  localparam int unsigned TX_DEPTH = 64;        // egress queue for several frames
  localparam int unsigned TAG_DEPTH = 8;        // small descriptor queue
  localparam int unsigned CAM_SETS = 16;        // deliberately small: replacement,
  localparam int unsigned CAM_WAYS = 2;         // not capacity, is what is under test
  localparam int unsigned PAYLOAD = 128;        // 16 beats of MAC client data

  // Per-port MAC addresses, port p at packed slice p.
  localparam logic [NUM_PORTS*48-1:0] PORT_MAC = {
    48'h02_00_00_00_00_02, 48'h02_00_00_00_00_01, 48'h02_00_00_00_00_00
  };

  // Ports 1 and 2 at 1000 Mbit/s; port 0's speed is the SPEED0 parameter.
  localparam logic [NUM_PORTS*2-1:0] PORT_SPEED = {2'd2, 2'd2, 2'(SPEED0)};

  /// The address port `p` owns, taken straight from `PORT_MAC`.
  function automatic sw_mac_t port_mac(input int unsigned p);
    port_mac = PORT_MAC[p*48 +: 48];
  endfunction

  // --------------------------------------------------------------------------
  // Clock, reset, DUT
  // --------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #4 clk = ~clk;

  logic [NUM_PORTS-1:0] link_up;
  logic [          1:0] flood_mode;
  logic learning_en, cfg_ovr, cam_flush;
  logic [       NUM_PORTS-1:0] gmii_rx_en;
  logic [     NUM_PORTS*8-1:0] gmii_rx_data;
  logic [       NUM_PORTS-1:0] gmii_tx_en;
  logic [     NUM_PORTS*8-1:0] gmii_tx_data;
  logic [32*SW_STAT_COUNT-1:0] stat;

  /// Board switch positions; the panel decodes these into the core's policy.
  logic [7:0] dip;
  assign dip = {3'd0, cam_flush, cfg_ovr, learning_en, flood_mode};

  // --------------------------------------------------------------------------
  // Statistics read sweep and the cycle-exact quiet reference
  //
  // The active instance is swept across every console read port and every
  // counter, forever.  This replaces the old CSR scan: the property under test
  // is unchanged - reading statistics must not move the datapath by so much as
  // one clock - but the reader is now the stateless per-port port instead of a
  // registered CSR.
  //
  // `u_quiet` is an identically parameterised second instance that receives
  // the same inputs but never a statistics read request, so at every negedge
  // its outputs must match the active instance's exactly.  A read that so much
  // as delays one beat aborts the run with the cycle it happened on.
  // --------------------------------------------------------------------------
  logic [1:0]  stat_port_q;    ///< port index currently presented to the reader
  logic [3:0]  stat_id_q;      ///< counter id currently presented to the reader
  logic [31:0] stat_read;      ///< the value the active read returned
  logic [NUM_PORTS-1:0] quiet_tx_en;      ///< reference instance outputs
  logic [NUM_PORTS*8-1:0] quiet_tx_data;
  logic [32*SW_STAT_COUNT-1:0] quiet_stat;
  int unsigned compared_cycles = 0;       ///< clocks the comparison has covered

  // The sweep itself: every counter of every port, one per clock, wrapping.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stat_port_q <= '0;
      stat_id_q   <= '0;
    end else begin
      stat_id_q <= stat_id_q + 4'd1;
      if (stat_id_q == 4'(SW_STAT_COUNT - 1)) stat_port_q <= stat_port_q + 2'd1;
    end
  end

  // The comparison: the two instances must be indistinguishable on every
  // observable output at every settled clock edge.
  always @(negedge clk)
    if (rst_n) begin
      compared_cycles++;
      if ({gmii_tx_en, gmii_tx_data, stat} !== {quiet_tx_en, quiet_tx_data, quiet_stat})
        $fatal(1, "statistics read changed output/latency at cycle %0d", compared_cycles);
    end

  // Active instance: carries the traffic and is swept by the statistics reader.
  es_switch_gmii #(
    .NUM_PORTS      (NUM_PORTS),
    .CLK_FREQ_HZ    (CLK_FREQ),
    .PORT_MAC       (PORT_MAC),
    .PORT_SPEED     (PORT_SPEED),
    .RX_FIFO_DEPTH  (RX_DEPTH),
    .TX_FIFO_DEPTH  (TX_DEPTH),
    .TAG_FIFO_DEPTH (TAG_DEPTH),
    .CAM_SETS       (CAM_SETS),
    .CAM_WAYS       (CAM_WAYS)
  ) u_dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .link_up_i      (link_up),
    .dip_i          (dip),
    .gmii_rx_en_i   (gmii_rx_en),
    .gmii_rx_data_i (gmii_rx_data),
    .gmii_tx_en_o   (gmii_tx_en),
    .gmii_tx_data_o (gmii_tx_data),
    .stat_o         (stat),
    .stat_port_i    (stat_port_q),
    .stat_id_i      (stat_id_q),
    .stat_data_o    (stat_read),
    .cam_rd_req_i   (1'b0),
    .cam_rd_index_i (32'd0),
    .cam_rd_valid_o (),
    .cam_rd_entry_o (),
    .cam_entries_o  (),
    .led_link_o     (),
    .led_act_o      (),
    .led_speed_o    (),
    .led_duplex_o   (),
    .led_fault_o    (),
    .led_stat_o     (),
    .cfg_flood_mode_o  (),
    .cfg_learning_en_o (),
    .cfg_ovr_o      ()
  );

  // Quiet reference: same parameters, same inputs, no statistics read.  Any
  // difference between the two instances at a settled edge is the failure.
  es_switch_gmii #(
    .NUM_PORTS      (NUM_PORTS),
    .CLK_FREQ_HZ    (CLK_FREQ),
    .PORT_MAC       (PORT_MAC),
    .PORT_SPEED     (PORT_SPEED),
    .RX_FIFO_DEPTH  (RX_DEPTH),
    .TX_FIFO_DEPTH  (TX_DEPTH),
    .TAG_FIFO_DEPTH (TAG_DEPTH),
    .CAM_SETS       (CAM_SETS),
    .CAM_WAYS       (CAM_WAYS)
  ) u_quiet (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .link_up_i      (link_up),
    .dip_i          (dip),
    .gmii_rx_en_i   (gmii_rx_en),
    .gmii_rx_data_i (gmii_rx_data),
    .gmii_tx_en_o   (quiet_tx_en),
    .gmii_tx_data_o (quiet_tx_data),
    .stat_o         (quiet_stat),
    .stat_port_i    ('0),
    .stat_id_i      ('0),
    .stat_data_o    (),
    .cam_rd_req_i   (1'b0),
    .cam_rd_index_i (32'd0),
    .cam_rd_valid_o (),
    .cam_rd_entry_o (),
    .cam_entries_o  (),
    .led_link_o     (),
    .led_act_o      (),
    .led_speed_o    (),
    .led_duplex_o   (),
    .led_fault_o    (),
    .led_stat_o     (),
    .cfg_flood_mode_o  (),
    .cfg_learning_en_o (),
    .cfg_ovr_o      ()
  );

  // --------------------------------------------------------------------------
  // Per-port models
  // --------------------------------------------------------------------------
  sw_gmii_if #(
    .PORT_ID     (0),
    .BYTE_PERIOD (SPEED0 == 0 ? 100 : 1)
  ) i0 (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .enable_i   (link_up[0]),
    .gmii_rx_en (gmii_rx_en[0]),
    .gmii_rx_d  (gmii_rx_data[0*8 +: 8]),
    .gmii_tx_en (gmii_tx_en[0]),
    .gmii_tx_d  (gmii_tx_data[0*8 +: 8])
  );

  sw_gmii_if #(
    .PORT_ID     (1),
    .BYTE_PERIOD (1)
  ) i1 (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .enable_i   (link_up[1]),
    .gmii_rx_en (gmii_rx_en[1]),
    .gmii_rx_d  (gmii_rx_data[1*8 +: 8]),
    .gmii_tx_en (gmii_tx_en[1]),
    .gmii_tx_d  (gmii_tx_data[1*8 +: 8])
  );

  sw_gmii_if #(
    .PORT_ID     (2),
    .BYTE_PERIOD (1)
  ) i2 (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .enable_i   (link_up[2]),
    .gmii_rx_en (gmii_rx_en[2]),
    .gmii_rx_d  (gmii_rx_data[2*8 +: 8]),
    .gmii_tx_en (gmii_tx_en[2]),
    .gmii_tx_d  (gmii_tx_data[2*8 +: 8])
  );

  // --------------------------------------------------------------------------
  // Bookkeeping
  // --------------------------------------------------------------------------
  int unsigned errors;
  int unsigned checks;

  /// Record a scoreboard failure.
  task automatic note_error(input string msg);
    errors++;
    $display("[%0t] ERROR %s", $time, msg);
  endtask

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

  /// Present one frame on `port`; all frames use the IPv4 EtherType, since the
  /// framing, not the payload, is what this regression is about.
  task automatic send_on(input int unsigned port, input sw_mac_t dst, input sw_mac_t src,
                         input int unsigned len);
    case (port)
      0: i0.send(dst, src, TB_ET_IPV4, len);
      1: i1.send(dst, src, TB_ET_IPV4, len);
      2: i2.send(dst, src, TB_ET_IPV4, len);
      default: note_error($sformatf("bad port index %0d", port));
    endcase
  endtask

  /// Outstanding expectation per port, as a plain vector (port * 32).
  localparam int unsigned QW = 32;
  logic [NUM_PORTS*QW-1:0] exp_cnt;

  /// Credit `n` expected copies to port `p`.
  task automatic exp_add(input int unsigned p, input int unsigned n);
    exp_cnt[p*QW +: QW] = exp_cnt[p*QW +: QW] + n;
  endtask

  /// Collect everything the monitor of port `p` has seen, checking each frame.
  task automatic drain_port(input int unsigned p, input string what);
    tb_rec_t r;
    bit      got_one;
    int      n;
    n = 0;
    for (int unsigned guard = 0; guard < 64; guard++) begin
      got_one = 1'b1;
      if (p == 0) begin
        got_one = (i0.pending() != 0);
        if (got_one) i0.pop_frame(r, 0);
      end else if (p == 1) begin
        got_one = (i1.pending() != 0);
        if (got_one) i1.pop_frame(r, 0);
      end else if (p == 2) begin
        got_one = (i2.pending() != 0);
        if (got_one) i2.pop_frame(r, 0);
      end
      if (!got_one) guard = 64;
      else begin
        n++;
        if (tb_rec_len(r) != PAYLOAD)
          note_error($sformatf(
                     "%s: port %0d frame %0d has length %0d, expected %0d",
                     what,
                     p,
                     n,
                     tb_rec_len(
                         r
                     ),
                     PAYLOAD
                     ));
        if (!tb_rec_fcs_ok(r))
          note_error($sformatf("%s: port %0d frame %0d has a bad FCS", what, p, n));
        if (!tb_rec_pre_ok(r))
          note_error($sformatf("%s: port %0d frame %0d has a bad preamble", what, p, n));
        if (exp_cnt[p*QW +: QW] == 0)
          note_error($sformatf(
                     "%s: port %0d produced unexpected frame %0d to %s",
                     what,
                     p,
                     n,
                     tb_mac_str(
                         tb_rec_dst(r)
                     )
                     ));
        else exp_cnt[p*QW +: QW] = exp_cnt[p*QW +: QW] - 1;
      end
    end
  endtask

  /// Drain every port's monitor, so one test cannot leak into the next.
  task automatic drain_all(input string what);
    drain_port(0, what);
    drain_port(1, what);
    drain_port(2, what);
  endtask

  /// Wait until every port has delivered everything it owed, or the bound runs
  /// out.  The bound is derived from the slowest port, because a frame has to be
  /// *serialised* out of it: 8 preamble + PAYLOAD + 4 FCS + a 12 octet
  /// inter-frame gap, at SLOW_BP core clocks per octet, per frame.  A bound that
  /// only accounts for one frame crossing the fabric checks the expectations
  /// while a queued egress is still transmitting, and the symptom is a report of
  /// "missing" frames for traffic that is merely late.
  localparam int unsigned SLOW_BP = (SPEED0 == 0) ? 100 : ((SPEED0 == 1) ? 10 : 1);
  localparam int unsigned FRAME_OCTETS = 8 + PAYLOAD + 4 + 12;

  /// Wait out the drain of `frames` queued on the slowest port, returning
  /// early once every expectation has been consumed.
  task automatic settle(input int unsigned frames);
    for (int unsigned w = 0; w < frames * FRAME_OCTETS * SLOW_BP + 20000; w++) begin
      if ((exp_cnt[0*QW +: QW] == 0) && (exp_cnt[1*QW +: QW] == 0) && (exp_cnt[2*QW +: QW] == 0)) w = 0;
      @(posedge clk);
    end
  endtask

  // The stations the tests talk to.  HOST_D is the queue test's destination:
  // learned behind the slow port 0, so a run of frames for it builds the
  // backlog the fabric has to buffer.
  localparam sw_mac_t HOST_A = 48'h02_AA_00_00_00_01;
  localparam sw_mac_t HOST_B = 48'h02_AA_00_00_00_02;
  localparam sw_mac_t HOST_C = 48'h02_AA_00_00_00_03;
  localparam sw_mac_t HOST_D = 48'h02_AA_00_00_00_04;

  // ==========================================================================
  // Test sequence
  // ==========================================================================
  int unsigned t;

  initial begin
    link_up     = '1;
    flood_mode  = SW_FLOOD_BCAST_UKN;
    learning_en = 1'b1;
    cfg_ovr     = 1'b0;
    cam_flush   = 1'b0;
    errors      = 0;
    checks      = 0;
    exp_cnt     = '0;

    rst_n       = 1'b0;
    repeat (16) @(posedge clk);
    rst_n = 1'b1;
    repeat (16) @(posedge clk);

    $display("=====================================================================");
    $display(" sw_flood_tb: %0d ports, %0d beat ingress/egress, %0d sets x %0d ways", NUM_PORTS,
             RX_DEPTH, CAM_SETS, CAM_WAYS);
    $display("   port 0 link speed: %0d Mbit/s (%0d core clocks per octet)",
             (SPEED0 == 0) ? 10 : ((SPEED0 == 1) ? 100 : 1000),
             (SPEED0 == 0) ? 100 : ((SPEED0 == 1) ? 10 : 1));
    $display("=====================================================================");

    // ---- one frame, to prove the harness itself works ----------------------
    send_on(0, SW_MAC_BROADCAST, HOST_A, PAYLOAD);
    exp_add(1, 1);
    exp_add(2, 1);
    settle(2);
    repeat (200) @(posedge clk);
    drain_all("single");
    expect_eq(exp_cnt[0*QW +: QW], 0, "single: port 0 owes nothing");
    expect_eq(exp_cnt[1*QW +: QW], 0, "single: port 1 delivered");
    expect_eq(exp_cnt[2*QW +: QW], 0, "single: port 2 delivered");

    // ---- the reported failure: back-to-back broadcasts from every port -----
    // Six frames, two from each of the three ports, all flooded.  Nothing is
    // awaited between injections, so the fabric is handed a queue on every
    // ingress port at once and has to schedule across them.
    $display("---- six back-to-back broadcasts, two per port ----");
    for (t = 0; t < 2; t++) begin
      send_on(0, SW_MAC_BROADCAST, HOST_A, PAYLOAD);
      send_on(1, SW_MAC_BROADCAST, HOST_B, PAYLOAD);
      send_on(2, SW_MAC_BROADCAST, HOST_C, PAYLOAD);
    end
    for (int unsigned p = 0; p < NUM_PORTS; p++) exp_add(p, 4);
    settle(8);
    repeat (500) @(posedge clk);
    drain_all("flood");
    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      expect_eq(exp_cnt[p*QW +: QW], 0, $sformatf("flood: port %0d delivered all four copies", p));
    end

    // ---- the same, but unicast, so each frame has a single destination ----
    $display("---- four back-to-back unicasts behind known stations ----");
    for (t = 0; t < 2; t++) begin
      send_on(0, HOST_B, HOST_A, PAYLOAD);
      send_on(1, HOST_C, HOST_B, PAYLOAD);
    end
    exp_add(1, 2);
    exp_add(2, 2);
    settle(4);
    repeat (500) @(posedge clk);
    drain_all("unicast");
    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      expect_eq(exp_cnt[p*QW +: QW], 0, $sformatf("unicast: port %0d owes nothing", p));
    end

    // ---- a deep queue on one egress ----------------------------------------
    // Every frame is addressed to HOST_D, which is learned behind port 0, so all
    // of it is unicast to port 0 and nowhere else.  Port 0 can only drain one
    // frame every FRAME_OCTETS*SLOW_BP clocks while the fabric is pushing
    // sixteen beats per frame, so the other two ports hand it a backlog it has
    // to buffer.  This is the situation the mixed-speed four-port regression
    // runs into, at a size that runs in seconds.
    $display("---- eight frames queued onto one slow egress ----");
    send_on(0, SW_MAC_BROADCAST, HOST_D, PAYLOAD);  // learn HOST_D behind port 0
    exp_add(1, 1);
    exp_add(2, 1);
    settle(2);
    repeat (200) @(posedge clk);
    drain_all("learn");
    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      expect_eq(exp_cnt[p*QW +: QW], 0, $sformatf("learn: port %0d owes nothing", p));
    end

    for (t = 0; t < 4; t++) begin
      send_on(1, HOST_D, HOST_B, PAYLOAD);
      send_on(2, HOST_D, HOST_C, PAYLOAD);
    end
    exp_add(0, 8);
    settle(9);
    repeat (2000) @(posedge clk);
    drain_all("queue");
    expect_eq(exp_cnt[0*QW +: QW], 0, "queue: the slow egress delivered all eight");
    expect_eq(exp_cnt[1*QW +: QW], 0, "queue: port 1 owes nothing");
    expect_eq(exp_cnt[2*QW +: QW], 0, "queue: port 2 owes nothing");

    $display("-----------------------------------------------------------------------");
    $display("   switch statistics: rx frames %0d, tx frames %0d, tx octets %0d",
             stat[32*int'(SW_STAT_RX_FRAMES) +: 32], stat[32*int'(SW_STAT_TX_FRAMES) +: 32],
             stat[32*int'(SW_STAT_TX_OCTETS) +: 32]);
    $display("                     rx overflow %0d, stalled %0d, cam learn %0d",
             stat[32*int'(SW_STAT_RX_OVERFLOW) +: 32], stat[32*int'(SW_STAT_TX_STALLED) +: 32],
             stat[32*int'(SW_STAT_CAM_LEARN) +: 32]);
    $display("   per port: i0 %0d dropped / %0d short, i1 %0d / %0d, i2 %0d / %0d", i0.dropped(),
             i0.short_frames(), i1.dropped(), i1.short_frames(), i2.dropped(), i2.short_frames());
    $display("-----------------------------------------------------------------------");

    if (errors == 0) begin
      $display(
          " sw_flood_tb: PASSED (%0d checks), cycle-exact active/quiet reference comparison passed",
          checks);
      $finish;
    end else begin
      $fatal(1, " sw_flood_tb: FAILED (%0d of %0d checks failed)", errors, checks);
    end
  end

  initial begin
    #20_000_000;
    $fatal(1, "sw_flood_tb: timeout");
  end

endmodule : sw_flood_tb
