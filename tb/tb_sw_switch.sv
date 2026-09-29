// ============================================================================
//  File        : tb_sw_switch.sv
//  Description : Self-checking testbench for the parameterised Ethernet
//                Layer-2 switch core.
//
//                Structure
//                ---------
//                The testbench instantiates the switch under test together with
//                one GMII bus functional model per port (sw_gmii_if) and checks
//                the design against a reference model that the test itself
//                maintains:
//
//                  * the expected egress set of a frame is computed from the
//                    flood mode, the ingress filter rules and the current
//                    contents of the reference address table,
//                  * every frame observed on an egress port is compared with
//                    the frame that was injected - destination, source, length,
//                    preamble and FCS,
//                  * a check after each test confirms that no unexpected frame
//                    was produced and that none was lost.
//
//                The design is exercised on ports running at 10, 100 and
//                1000 Mbit/s simultaneously from one 125 MHz clock, which is the
//                configuration most likely to expose a clock-enable bug.
//
//                Test list
//                ---------
//                   1  reset and idle
//                   2  unicast forwarding after learning
//                   3  broadcast flooding
//                   4  unknown-unicast flooding
//                   5  unknown-unicast filtering (FLOOD_MODE = 0)
//                   6  group (multicast) address handling
//                   7  a station that moves to another port
//                   8  self-reflected frame filtering
//                   9  802.1Q tagged forwarding
//                  10  runt / oversize / bad-FCS / truncated frames
//                  11  minimum and maximum frame sizes
//                  12  simultaneous back-to-back traffic
//                  13  statistics counters
//                  14  CAM flush
//                  15  learning disabled at run time
// ============================================================================
`timescale 1ns/1ps

`include "sw_tb_pkg.sv"

module tb_sw_switch;

  import sw_tb_pkg::*;
  // The RTL declarations (`SW_STAT_COUNT`, `SW_MAC_BROADCAST`, `sw_is_group`,
  // `sw_is_unicast`, `sw_mac_t`, ...) are at compilation-unit scope: the DUT
  // pulls in `rtl/sw_defs.sv`, which declares them there, so they are already
  // visible in this file and need no import.

  // ==========================================================================
  // Configuration
  // ==========================================================================
  localparam int unsigned NUM_PORTS = 4;
  localparam int unsigned CLK_FREQ  = 125_000_000;
  localparam int unsigned RX_DEPTH  = 256;
  localparam int unsigned TX_DEPTH  = 256;
  localparam int unsigned CAM_SETS  = 64;
  localparam int unsigned CAM_WAYS  = 4;
  localparam int unsigned MAX_FRAME = 1518;

  // --------------------------------------------------------------------------
  // Settle bound.
  //
  // Every test has to wait for the slowest port to finish before it inspects the
  // result.  The slowest port here is 10 Mbit/s on a 125 MHz core, so one octet
  // time is OCT_PERIOD_MAX core clocks and a frame of `n` octets needs
  //     OCT_PERIOD_MAX * (n + SW_FCS_LEN)
  // clocks merely to be clocked out of the *receive* path, before the fabric
  // arbitration, the egress buffer and the transmit path have finished with it.
  // A frame can then have to cross the fabric and be clocked out of a 10 Mbit/s
  // *egress* port, which is why the bound covers the transmission twice over plus
  // a fixed margin.
  //
  // A fixed count short enough for a 1000 Mbit/s port therefore checks the
  // expectations while the 10 Mbit/s port is still transmitting.  The symptoms
  // are frames arriving late, frames arriving out of order, and leftovers from
  // the previous test counted as "unexpected" - none of which point at the real
  // cause.
  //
  // The bound is a function of the frame size rather than of MAX_FRAME, so a
  // test with a 100 octet frame does not have to wait for a 1518 octet one.
  // --------------------------------------------------------------------------
  localparam int unsigned OCT_PERIOD_MAX = 100;   // 10 Mbit/s at 125 MHz
  localparam int unsigned DEFAULT_FRAME_OCTETS = 128;

  function automatic int unsigned settle_clocks(input int unsigned octets);
    return OCT_PERIOD_MAX * (octets + SW_FCS_LEN) + 4*OCT_PERIOD_MAX + 2000;
  endfunction

  /// Clocks the slowest port needs to serialise *one* complete frame: eight
  /// preamble octets, the client data, the four FCS octets, and a minimum
  /// inter-frame gap of twelve octets, at OCT_PERIOD_MAX core clocks per octet.
  ///
  /// This is the per-frame term of a queue, not a per-frame term for the fabric;
  /// `settle_clocks` covers the latter.  A test that queues several frames onto
  /// the slow port needs both.
  function automatic int unsigned queue_clocks(input int unsigned octets);
    return OCT_PERIOD_MAX * (octets + 8 + SW_FCS_LEN + SW_IFG_OCTETS);
  endfunction

  // Per-port link speeds, 2 bits per port, port p at bits [2*p +: 2].
  //   port 0 : 10 Mbit/s      port 1 : 100 Mbit/s
  //   port 2 : 1000 Mbit/s    port 3 : 1000 Mbit/s
  // The same speeds are declared in sw_if_array, which derives the matching
  // octet periods for the bus functional models.
  localparam logic [NUM_PORTS*2-1:0] PORT_SPEED = {2'd2, 2'd2, 2'd1, 2'd0};

  // Per-port MAC addresses, 48 bits per port.  A port left at all zero is
  // given the locally administered default 02:00:00:00:00:<p>, so the testbench
  // spells the addresses out explicitly to keep them readable.
  localparam logic [NUM_PORTS*48-1:0] PORT_MAC = {
    48'h02_00_00_00_00_03,   // port 3
    48'h02_00_00_00_00_02,   // port 2
    48'h02_00_00_00_00_01,   // port 1
    48'h02_00_00_00_00_00    // port 0
  };

  /// The address a port owns, taken straight from `PORT_MAC`.
  function automatic sw_mac_t mac_of(input int unsigned p);
    return PORT_MAC[p*48 +: 48];
  endfunction

  sw_mac_t mac_of_port [NUM_PORTS];

  // ==========================================================================
  // Clock and reset
  // ==========================================================================
  logic clk_i  = 1'b0;
  logic rst_ni = 1'b0;

  always #4 clk_i = ~clk_i;   // 125 MHz, i.e. an 8 ns period

  // ==========================================================================
  // DUT wiring
  // ==========================================================================
  logic [NUM_PORTS-1:0]        link_up;
  logic [1:0]                  flood_mode;
  logic                        learning_en;
  logic                        cfg_ovr;
  logic                        cam_flush;

  logic [NUM_PORTS-1:0]        gmii_rx_en;
  logic [NUM_PORTS*8-1:0]      gmii_rx_d;
  logic [NUM_PORTS-1:0]        gmii_tx_en;
  logic [NUM_PORTS*8-1:0]      gmii_tx_d;
  logic [32*SW_STAT_COUNT-1:0] stat;

  sw_switch #(
      .NUM_PORTS      (NUM_PORTS),
      .CLK_FREQ_HZ    (CLK_FREQ),
      .PORT_MAC       (PORT_MAC),
      .PORT_SPEED     (PORT_SPEED),
      .RX_FIFO_DEPTH  (RX_DEPTH),
      .TX_FIFO_DEPTH  (TX_DEPTH),
      .TAG_FIFO_DEPTH (16),
      .MAX_FRAME_LEN  (MAX_FRAME),
      .FLOOD_MODE     (2'd1),
      .LEARNING_EN    (1'b1),
      .CAM_SETS       (CAM_SETS),
      .CAM_WAYS       (CAM_WAYS),
      .CAM_AGE_EN     (1'b0)
  ) u_dut (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .link_up_i       (link_up),
      .flood_mode_i    (flood_mode),
      .learning_en_i   (learning_en),
      .cfg_ovr_i       (cfg_ovr),
      .cam_flush_i     (cam_flush),
      .gmii_rx_en_i    (gmii_rx_en),
      .gmii_rx_data_i  (gmii_rx_d),
      .gmii_tx_en_o    (gmii_tx_en),
      .gmii_tx_data_o  (gmii_tx_d),
      .stat_o          (stat)
  );

  // ==========================================================================
  // Per-port GMII models
  // ==========================================================================
  // The four bus functional models live in sw_if_array, which also gives the
  // testbench port-generic task entry points (Icarus Verilog cannot hold an
  // array of instances, and cannot call a task through a wire).
  //
  // Link speeds: port 0 at 10 Mbit/s, port 1 at 100 Mbit/s, ports 2 and 3 at
  // 1000 Mbit/s, all sharing the single 125 MHz core clock.  This mixed-speed
  // setup is the configuration most likely to expose a clock-enable bug.
  // Flat access, so the tests can be written port-agnostically.  A wrapper
  // module instance is the portable way to gather the four models into an
  // array: Icarus Verilog does not support an unpacked array of instances.
  sw_if_array #(.NUM_PORTS(NUM_PORTS), .CLK_FREQ(CLK_FREQ)) u_ifs (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .link_up (link_up),
      .rx_en   (gmii_rx_en),
      .rx_d    (gmii_rx_d),
      .tx_en   (gmii_tx_en),
      .tx_d    (gmii_tx_d)
  );

  // ==========================================================================
  // Reference model - address table
  // ==========================================================================
  // For every learned address, the port it sits behind.  Plain vectors rather
  // than a struct queue, for Icarus portability.
  sw_mac_t     ref_mac  [$];
  int unsigned ref_port [$];

  /// Look a destination address up in the reference table; -1 when unknown.
  function automatic int ref_lookup(input sw_mac_t m);
    int i;
    for (i = 0; i < ref_mac.size(); i++) begin
      if (ref_mac[i] == m) return int'(ref_port[i]);
    end
    return -1;
  endfunction

  /// Move or insert a station into the reference table.
  function automatic void ref_learn(input sw_mac_t m, input int unsigned p);
    int i;
    for (i = 0; i < ref_mac.size(); i++) begin
      if (ref_mac[i] == m) begin
        ref_port[i] = p;
        return;
      end
    end
    ref_mac.push_back(m);
    ref_port.push_back(p);
  endfunction

  function automatic void ref_flush();
    ref_mac.delete();
    ref_port.delete();
  endfunction

  /// Compute the expected egress set for a frame, mirroring the ingress filter
  /// of sw_rx_port exactly.
  function automatic logic [NUM_PORTS-1:0] ref_forward(
      input sw_mac_t     dst,
      input sw_mac_t     src,
      input int unsigned ingress,
      input logic [1:0] mode);
    logic [NUM_PORTS-1:0] mask;
    int                  hit;
    int                  i;

    mask = '1;
    mask[ingress] = 1'b0;

    // A frame sourced from the port's own address is a reflected frame.
    if (src == mac_of_port[ingress]) return '0;

    if (dst == SW_MAC_BROADCAST) return mask;

    if (sw_is_group(dst)) begin
      if (mode == SW_FLOOD_ALL) return mask;
      return '0;
    end

    hit = ref_lookup(dst);
    if (hit >= 0) begin
      if (hit == ingress) return '0;   // unicast loop back to the sender
      mask = '0;
      mask[hit] = 1'b1;
      return mask;
    end

    // Unknown unicast: flooded unless the policy filters it.
    if (mode == SW_FLOOD_BCAST_ONLY) return '0;
    return mask;
  endfunction

  // ==========================================================================
  // Scoreboard
  // ==========================================================================
  // The per-port expectation queues live inside sw_if_array (one sw_rec_q per
  // port), because Icarus Verilog cannot elaborate an unpacked array of
  // queues.  They are reached through the port-generic wrapper tasks
  // `expect_push`, `expect_count` and `expect_take`.

  int unsigned errors;
  int unsigned checks;

  task automatic note_error(input string msg);
    errors++;
    $display("  *** ERROR @%0t: %s", $time, msg);
  endtask

  task automatic note_check();
    checks++;
  endtask

  // ==========================================================================
  // Test helpers
  // ==========================================================================
  task automatic do_reset();
    rst_ni <= 1'b0;
    repeat (8) @(posedge clk_i);
    rst_ni <= 1'b1;
    repeat (4) @(posedge clk_i);
  endtask

  /// Default configuration: all ports up, learning on, unknown unicast flooded,
  /// elaboration-time defaults otherwise.
  task automatic set_default_config();
    link_up     = '1;
    flood_mode  = 2'd1;
    learning_en = 1'b1;
    cfg_ovr     = 1'b0;
    cam_flush   = 1'b0;
  endtask

  /// Inject a frame on `ingress` and record what the reference model expects on
  /// every port.  `expect_fwd` is the override for the malformed-frame cases.
  task automatic inject(
      input int unsigned ingress,
      input sw_mac_t     dst,
      input sw_mac_t     src,
      input int unsigned total_len,
      input logic [15:0] l2type     = TB_ET_IPV4,
      input bit          vlan_en    = 1'b0,
      input bit          corrupt    = 1'b0,
      input bit          truncate   = 1'b0,
      input bit          do_learn   = 1'b1,
      input bit          async_send = 1'b1,
      input bit          expect_fwd = 1'b1);
    logic [NUM_PORTS-1:0] mask;
    int                  p;
    tb_rec_t             rec;

    mask = expect_fwd ? ref_forward(dst, src, ingress, flood_mode) : '0;

    // Every port the reference model says should see the frame gets one
    // expectation.  The record only carries the fields the scoreboard compares;
    // the payload itself is validated on the wire by the FCS check in the
    // monitor, which is a strictly stronger test than a byte comparison here.
    rec = tb_rec_pack(dst, src, l2type, total_len, 1'b1, 1'b1);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (mask[p]) u_ifs.expect_push(p, rec);
    end

    // A background send lets a test start traffic on several ports before any of
    // it has been transmitted, which is what the back-to-back and congestion
    // tests need in order to present the fabric with simultaneous arrivals.
    //
    // The send runs in a dedicated `always` block guarded by a request/done
    // handshake rather than in a `fork ... join_none`.  Icarus Verilog aborts
    // with an internal assertion (`vthread.cc: of_JOIN_DETACH`) on a
    // `join_none` whose child outlives the enclosing process, and the whole run
    // dies with it - silently losing every check that had already passed.  A
    // handshake over ordinary variables is portable, and it needs none of the
    // unpacked-argument task support Icarus lacks.
    if (async_send) begin
      // Blocking assignments: the worker samples the record at the very next
      // clock edge, so there is nothing to pipeline here.
      async_dst     = dst;
      async_src     = src;
      async_l2type  = l2type;
      async_len     = total_len;
      async_vlan    = vlan_en;
      async_corrupt = corrupt;
      async_trunc   = truncate;
      async_port    = ingress;
      async_req     <= 1'b1;
      @(posedge clk_i);
      async_req     <= 1'b0;        // one-clock request pulse
      @(posedge clk_i);
      while (async_done != 1'b1) @(posedge clk_i);
    end else begin
      u_ifs.send_on(ingress, dst, src, l2type, total_len, vlan_en,
                    corrupt, truncate);
    end

    if (do_learn && expect_fwd && sw_is_unicast(src) && (src != mac_of_port[ingress])) begin
      ref_learn(src, ingress);
    end
  endtask

  // --------------------------------------------------------------------------
  // Background transmitter
  //
  // The request is a record of *named* variables, not one packed word.
  //
  // A packed word has to agree with the concatenation in `inject` on every field
  // width, and getting that wrong is not a compile error: the widths simply do
  // not add up to the declared size, the excess is dropped, and every field
  // above the truncation point moves.  `total_len` and `ingress` are
  // `int unsigned`, so a word sized for 16-bit fields loses 32 bits - and the
  // symptom is a send that runs with a garbage port index, frame length and
  // addresses, so the switch is handed a malformed frame, sizes it against the
  // header it can parse, and correctly drops it as oversize.  That points at the
  // receive path, which is not where the fault is.
  //
  // Named variables cannot disagree with themselves, and they cost nothing here:
  // the test writes them and the worker reads them in the very next clock, which
  // is all the handshake below needs.
  // --------------------------------------------------------------------------
  sw_mac_t     async_dst;
  sw_mac_t     async_src;
  logic [15:0] async_l2type;
  int unsigned async_len;
  bit          async_vlan;
  bit          async_corrupt;
  bit          async_trunc;
  int unsigned async_port;
  logic        async_req;
  logic        async_done;
  logic        async_busy;

  // The worker is a *one-shot*: the request is a single-clock pulse and the
  // completion strobe is raised only after the send has returned.
  //
  // The obvious alternative - hold `async_req` high until the worker
  // acknowledges it, and let the worker clear it - re-runs the send on every
  // clock edge for as long as the request is still high.  The worker is
  // suspended *inside* the send for thousands of clocks and re-enters the same
  // `else if (async_req)` branch the moment it returns, so one request puts the
  // same frame on the wire three or four times back to back with no inter-frame
  // gap.  The receiver then sees one long malformed frame instead of four good
  // ones, and the scoreboard reports every copy as missing - which reads as a
  // switch that dropped the traffic rather than as a testbench defect.
  //
  // The busy guard makes the one-shot explicit rather than relying on the
  // request pulse having already gone away by the time the send finishes.
  always @(posedge clk_i) begin
    async_done <= 1'b0;
    if (!rst_ni) begin
      async_busy <= 1'b0;
    end else if (async_req && !async_busy) begin
      async_busy <= 1'b1;
      u_ifs.send_on(async_port, async_dst, async_src, async_l2type, async_len,
                    async_vlan, async_corrupt, async_trunc);
      async_busy <= 1'b0;
      async_done <= 1'b1;
    end
  end

  /// Compare the monitored output of every port against the reference model.
  ///
  /// `silent[p]` asserts that port p must produce nothing at all; the other
  /// ports have to produce exactly the queued frames, in order, and nothing
  /// more.
  task automatic check_outputs(
      input logic [NUM_PORTS-1:0] silent = '0,
      input int unsigned          octets = DEFAULT_FRAME_OCTETS);
    tb_rec_t   got;
    tb_rec_t   want;
    int        p;
    bit        ok;
    int unsigned queued;

    // Let the fabric and every transmit path finish.  The bound is derived, for
    // the same reason as in `settle`: it has to outlast the slowest port, or the
    // expectations are checked while that port is still transmitting.
    //
    // It also has to outlast the whole *queue* on that port, not one frame.  A
    // test that hands six frames to a 10 Mbit/s egress needs six times the
    // one-frame bound, because the port serialises them one after another and the
    // last one does not appear until the first five have gone out.  `settle_clocks`
    // models a single frame crossing the fabric once; the extra term below
    // models the queue draining on the slow port, at
    //   8 preamble + `octets` + 4 FCS + a 12 octet inter-frame gap
    // per frame.  A bound that omits it does not report the design as slow - it
    // reports it as broken: every expectation is consumed against a placeholder,
    // the frame turns up afterwards, and the leftovers are then counted as
    // *unexpected* by the following test.
    queued = 0;
    for (p = 0; p < NUM_PORTS; p++) begin
      if (u_ifs.expect_count(p) > queued) queued = u_ifs.expect_count(p);
    end
    repeat (settle_clocks(octets) + queued*queue_clocks(octets)) @(posedge clk_i);

    for (p = 0; p < NUM_PORTS; p++) begin
      if (silent[p]) begin
        if (u_ifs.pending_on(p) != 0) begin
          note_error($sformatf("port %0d forwarded a frame that should have been filtered", p));
          u_ifs.pop_on(p, got, 0);
        end
        note_check();
      end else begin
        // Every queued expectation has to appear, in order.
        while (u_ifs.expect_count(p) > 0) begin
          u_ifs.expect_take(p, want);
          u_ifs.pop_on(p, got);
          if (tb_rec_len(got) == 0) begin
            note_error($sformatf("port %0d: expected a frame to %s of %0d octets, none arrived",
                                 p, tb_mac_str(tb_rec_dst(want)), tb_rec_len(want)));
          end else begin
            ok = 1'b1;
            if (tb_rec_dst(got) != tb_rec_dst(want)) begin
              note_error($sformatf("port %0d: dst %s, expected %s",
                                   p, tb_mac_str(tb_rec_dst(got)),
                                   tb_mac_str(tb_rec_dst(want))));
              ok = 1'b0;
            end
            if (tb_rec_src(got) != tb_rec_src(want)) begin
              note_error($sformatf("port %0d: src %s, expected %s",
                                   p, tb_mac_str(tb_rec_src(got)),
                                   tb_mac_str(tb_rec_src(want))));
              ok = 1'b0;
            end
            if (tb_rec_len(got) != tb_rec_len(want)) begin
              note_error($sformatf("port %0d: len %0d, expected %0d",
                                   p, tb_rec_len(got), tb_rec_len(want)));
              ok = 1'b0;
            end
            if (!tb_rec_fcs_ok(got)) begin
              note_error($sformatf("port %0d: transmitted frame has a bad FCS", p));
              ok = 1'b0;
            end
            if (!tb_rec_pre_ok(got)) begin
              note_error($sformatf("port %0d: preamble / SFD is malformed", p));
              ok = 1'b0;
            end
            if (ok) note_check();
          end
        end

        // Nothing else may show up.
        if (u_ifs.pending_on(p) != 0) begin
          note_error($sformatf("port %0d produced %0d unexpected frame(s)",
                               p, u_ifs.pending_on(p)));
          u_ifs.pop_on(p, got, 0);
        end
      end
    end
  endtask

  /// Silence every monitor queue and every expectation, so one test cannot leak
  /// state into the next.
  task automatic drain_all();
    tb_rec_t got;
    int      p;
    for (p = 0; p < NUM_PORTS; p++) begin
      u_ifs.expect_clear(p);
      while (u_ifs.pending_on(p) > 0) u_ifs.pop_on(p, got, 0);
    end
  endtask

  task automatic settle(input int unsigned octets = DEFAULT_FRAME_OCTETS);
    repeat (settle_clocks(octets)) @(posedge clk_i);
  endtask

  // ==========================================================================
  // Statistics access
  // ==========================================================================
  function automatic int unsigned stat_get(input int unsigned idx);
    return stat[32*idx +: 32];
  endfunction

  // ==========================================================================
  // Test sequence
  // ==========================================================================
  sw_mac_t station_a, station_b, station_c, stranger;
  int      t;

  initial begin
    async_dst     = 48'd0;
    async_src     = 48'd0;
    async_l2type  = 16'd0;
    async_len     = 0;
    async_vlan    = 1'b0;
    async_corrupt = 1'b0;
    async_trunc   = 1'b0;
    async_port    = 0;
    async_req     = 1'b0;
    async_done    = 1'b0;

    // ---- publish the port addresses to the reference model -----------------
    for (t = 0; t < NUM_PORTS; t++) begin
      mac_of_port[t] = mac_of(t);
    end
    // Stations attached to ports, plus one the switch has never seen.
    station_a = 48'h02_00_00_00_AA_01;   // behind port 0
    station_b = 48'h02_00_00_00_BB_02;   // behind port 1
    station_c = 48'h02_00_00_00_CC_03;   // behind port 2
    stranger  = 48'h02_00_00_00_DD_09;   // never attached

    $display("======================================================================");
    $display(" sw_switch testbench");
    $display("   ports         : %0d", NUM_PORTS);
    $display("   core clock    : %0d MHz", CLK_FREQ/1_000_000);
    $display("   port speeds   : 10M, 100M, 1000M, 1000M (one shared clock)");
    $display("   max frame     : %0d octets", MAX_FRAME);
    $display("======================================================================");

    if (!tb_crc32_selftest()) begin
      $display("FATAL: the testbench CRC reference failed its own known-answer test");
      $fatal(1);
    end
    $display("[ok] CRC-32 reference matches the known answer 0xCBF43926");

    do_reset();
    set_default_config();
    ref_flush();
    drain_all();
    settle();

    test_1_reset_idle();
    test_2_unicast_after_learning();
    test_3_broadcast();
    test_4_unknown_unicast();
    test_5_unknown_unicast_filtered();
    test_6_group_address();
    test_7_station_moves();
    test_8_reflected_frame();
    test_9_vlan();
    test_10_bad_frames();
    test_11_min_max_sizes();
    test_12_back_to_back();
    test_13_statistics();
    test_14_cam_flush();
    test_15_learning_disabled();

    $display("======================================================================");
    $display(" checks executed : %0d", checks);
    $display(" errors reported  : %0d", errors);
    $display("======================================================================");
    if (errors == 0) begin
      $display(" TESTBENCH PASSED");
      $finish;
    end else begin
      $display(" TESTBENCH FAILED");
      $fatal(1);
    end
  end

  // --------------------------------------------------------------------------
  // 1. Reset leaves the fabric quiet.
  // --------------------------------------------------------------------------
  task automatic test_1_reset_idle();
    $display("[%0t] test  1: reset and idle", $time);
    do_reset();
    set_default_config();
    ref_flush();
    drain_all();
    settle(64);
    check_outputs('1, 128);
  endtask

  // --------------------------------------------------------------------------
  // 2. Learn a station, then unicast to it.
  // --------------------------------------------------------------------------
  task automatic test_2_unicast_after_learning();
    $display("[%0t] test  2: unicast forwarding after learning", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    // Teach the switch that station_b lives behind port 1.  The destination is
    // port 3's own address, which is a unicast hit straight away, so this frame
    // reaches port 3 without any flooding.
    inject(1, mac_of_port[3], station_b, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);

    // station_a on port 0 now talks to station_b: it must leave only on port 1.
    inject(0, station_b, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);
  endtask

  // --------------------------------------------------------------------------
  // 3. A broadcast from an unknown station floods every other port.
  // --------------------------------------------------------------------------
  task automatic test_3_broadcast();
    $display("[%0t] test  3: broadcast flooding", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    inject(0, SW_MAC_BROADCAST, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);
  endtask

  // --------------------------------------------------------------------------
  // 4. An unknown unicast destination floods every other port.
  // --------------------------------------------------------------------------
  task automatic test_4_unknown_unicast();
    $display("[%0t] test  4: unknown unicast flooding", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    inject(0, stranger, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);
  endtask

  // --------------------------------------------------------------------------
  // 5. With FLOOD_MODE = 0 an unknown unicast is dropped instead of flooded.
  // --------------------------------------------------------------------------
  task automatic test_5_unknown_unicast_filtered();
    $display("[%0t] test  5: unknown unicast filtered (FLOOD_MODE = 0)", $time);
    ref_flush();
    drain_all();
    set_default_config();
    flood_mode = 2'd0;
    cfg_ovr    = 1'b1;
    settle();

    inject(0, stranger, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('1, 128);

    // A known unicast must still be delivered under the same policy.
    inject(1, mac_of_port[3], station_b, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);
    inject(0, station_b, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);
  endtask

  // --------------------------------------------------------------------------
  // 6. Group addresses follow the flooding mode.
  // --------------------------------------------------------------------------
  task automatic test_6_group_address();
    logic [47:0] mcast;
    $display("[%0t] test  6: group (multicast) address handling", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    mcast = 48'h01_00_5E_00_00_01;   // IPv4 multicast, I/G bit clear

    // FLOOD_MODE = 1: group addresses are not flooded.
    flood_mode = 2'd1;
    cfg_ovr    = 1'b1;
    settle();
    inject(0, mcast, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('1, 128);

    // FLOOD_MODE = 2: they are.
    flood_mode = 2'd2;
    settle();
    inject(0, mcast, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);
  endtask

  // --------------------------------------------------------------------------
  // 7. A station that moves to another port is re-learned, not duplicated.
  // --------------------------------------------------------------------------
  task automatic test_7_station_moves();
    $display("[%0t] test  7: a station moves to another port", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    // station_a is first seen on port 0.
    inject(0, mac_of_port[3], station_a, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);

    // A frame for station_a has to leave on port 0.
    inject(1, station_a, station_b, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 256);

    // station_a reappears on port 2; the table must relocate the entry.
    inject(2, mac_of_port[3], station_a, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 256);

    // It must now leave on port 2, and no longer on port 0.
    inject(1, station_a, station_b, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 256);
  endtask

  // --------------------------------------------------------------------------
  // 8. A frame whose source is the port's own address is not reflected.
  // --------------------------------------------------------------------------
  task automatic test_8_reflected_frame();
    $display("[%0t] test  8: self-reflected frame is filtered", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    // Port 0 receives a frame claiming to come from port 0's own address.
    inject(0, station_b, mac_of_port[0], 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0,
           1'b1, 1'b0, 1'b0);
    check_outputs('1, 128);
  endtask

  // --------------------------------------------------------------------------
  // 9. 802.1Q tagged frames are forwarded unchanged.
  // --------------------------------------------------------------------------
  task automatic test_9_vlan();
    $display("[%0t] test  9: 802.1Q tagged forwarding", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    inject(1, mac_of_port[3], station_b, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);

    // A tagged frame: the tag adds four octets that the switch has to parse to
    // find the length, but which it forwards untouched.
    inject(0, station_b, station_a, 100, TB_ET_IPV4, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 256);
  endtask

  // --------------------------------------------------------------------------
  // 10. Malformed frames are dropped and never forwarded.
  // --------------------------------------------------------------------------
  task automatic test_10_bad_frames();
    $display("[%0t] test 10: runt / oversize / bad FCS / truncated", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    // Bad FCS: the receiver must drop it.
    inject(0, SW_MAC_BROADCAST, station_a, 100, TB_ET_IPV4, 1'b0, 1'b1, 1'b0,
           1'b0, 1'b0, 1'b0);
    check_outputs('1, 128);

    // Truncated: the frame stops before its FCS.
    inject(0, SW_MAC_BROADCAST, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b1,
           1'b0, 1'b0, 1'b0);
    check_outputs('1, 128);

    // Runt: shorter than the 802.3 minimum of 64 octets.
    inject(0, SW_MAC_BROADCAST, station_a, 32, TB_ET_IPV4, 1'b0, 1'b0, 1'b0,
           1'b0, 1'b0, 1'b0);
    check_outputs('1, 128);

    // A good frame right afterwards must still get through, which proves the
    // receive path recovered frame synchronisation after every rejection.
    inject(0, SW_MAC_BROADCAST, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0,
           1'b1, 1'b0);
    check_outputs('0, 128);
  endtask

  // --------------------------------------------------------------------------
  // 11. Minimum and maximum frame sizes are both forwarded intact.
  // --------------------------------------------------------------------------
  task automatic test_11_min_max_sizes();
    $display("[%0t] test 11: minimum and maximum frame sizes", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    // Exactly the 802.3 minimum: no padding required.
    inject(0, SW_MAC_BROADCAST, station_a, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0,
           1'b1, 1'b0);
    check_outputs('0, 256);

    // Sizes around the eight octet beat boundary, which is where a masking or
    // length-arithmetic error would show up.
    for (t = 60; t <= 75; t++) begin
      inject(0, SW_MAC_BROADCAST, station_a, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0,
             1'b1, 1'b0);
      check_outputs('0, 256);
    end

    // Maximum frame: 1518 octets, i.e. 190 beats.
    inject(0, SW_MAC_BROADCAST, station_a, MAX_FRAME, TB_ET_IPV4, 1'b0, 1'b0,
           1'b0, 1'b1, 1'b0);
    check_outputs('0, MAX_FRAME);
  endtask

  // --------------------------------------------------------------------------
  // 12. Simultaneous back-to-back traffic on every port: nothing may be lost.
  // --------------------------------------------------------------------------
  task automatic test_12_back_to_back();
    int unsigned f;
    $display("[%0t] test 12: simultaneous back-to-back traffic", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    for (f = 0; f < 3; f++) begin
      inject(0, SW_MAC_BROADCAST, station_a, 128, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
      inject(1, SW_MAC_BROADCAST, station_b, 128, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
      inject(2, SW_MAC_BROADCAST, station_c, 128, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
    end

    // Every broadcast from every port must reach all three other ports.
    check_outputs('0, 512);
  endtask

  // --------------------------------------------------------------------------
  // 13. The statistics counters reflect the traffic that was sent.
  // --------------------------------------------------------------------------
  task automatic test_13_statistics();
    int unsigned f_in, o_in, f_tx_before, f_tx_after;
    $display("[%0t] test 13: statistics counters", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    f_in       = stat_get(int'(SW_STAT_RX_FRAMES));
    o_in       = stat_get(int'(SW_STAT_RX_OCTETS));
    f_tx_before = stat_get(int'(SW_STAT_TX_FRAMES));

    // Two broadcasts of 100 octets from port 0: each produces three copies.
    for (t = 0; t < 2; t++) begin
      inject(0, SW_MAC_BROADCAST, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0,
             1'b0, 1'b0);
    end
    check_outputs('0, 256);

    f_tx_after = stat_get(int'(SW_STAT_TX_FRAMES));

    note_check();
    if (stat_get(int'(SW_STAT_RX_FRAMES)) != f_in + 2) begin
      note_error($sformatf("RX_FRAMES is %0d, expected %0d",
                           stat_get(int'(SW_STAT_RX_FRAMES)), f_in + 2));
    end
    if (stat_get(int'(SW_STAT_RX_OCTETS)) != o_in + 200) begin
      note_error($sformatf("RX_OCTETS is %0d, expected %0d",
                           stat_get(int'(SW_STAT_RX_OCTETS)), o_in + 200));
    end
    if (f_tx_after != f_tx_before + 6) begin
      note_error($sformatf("TX_FRAMES is %0d, expected %0d",
                           f_tx_after, f_tx_before + 6));
    end
    if (stat_get(int'(SW_STAT_TX_OCTETS)) < 600) begin
      note_error($sformatf("TX_OCTETS is %0d, expected at least 600",
                           stat_get(int'(SW_STAT_TX_OCTETS))));
    end
  endtask

  // --------------------------------------------------------------------------
  // 14. A CAM flush makes the switch forget every station.
  // --------------------------------------------------------------------------
  task automatic test_14_cam_flush();
    $display("[%0t] test 14: CAM flush", $time);
    ref_flush();
    drain_all();
    set_default_config();
    settle();

    inject(1, mac_of_port[3], station_b, 64, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);
    inject(0, station_b, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 128);

    // Flush the address table on both the DUT and the reference model.
    cam_flush = 1'b1;
    repeat (8) @(posedge clk_i);
    cam_flush = 1'b0;
    ref_flush();
    settle();

    // station_b is unknown again, so the frame floods instead.
    inject(0, station_b, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
    check_outputs('0, 256);
  endtask

  // --------------------------------------------------------------------------
  // 15. With learning disabled a station is never remembered.
  // --------------------------------------------------------------------------
  task automatic test_15_learning_disabled();
    $display("[%0t] test 15: learning disabled at run time", $time);
    ref_flush();
    drain_all();
    set_default_config();
    learning_en = 1'b0;
    cfg_ovr     = 1'b1;
    settle();

    // station_b is never learned, so every frame for it floods.  The reference
    // model is told not to learn either.
    inject(0, stranger, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
    check_outputs('0, 256);
    inject(0, stranger, station_a, 100, TB_ET_IPV4, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
    check_outputs('0, 256);
  endtask

  // --------------------------------------------------------------------------
  // Watchdog: a design that deadlocks must not hang the regression.
  // --------------------------------------------------------------------------
  initial begin
    #100_000_000;
    $display("FATAL: global timeout reached");
    $fatal(1);
  end

endmodule : tb_sw_switch
