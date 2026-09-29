// ============================================================================
//  File        : sw_switch.sv
//  Description : Top level of the parameterised Ethernet Layer-2 switch core.
//
//                Features
//                --------
//                * 10 / 100 / 1000 Mbit/s per port, selected independently at
//                  elaboration time.  All ports share a single `clk_i`; the line
//                  rate is handled with clock enables, so the datapath contains
//                  no clock-domain crossings at all.
//                * Arbitrary number of ports, each with its own MAC address
//                  (a locally administered default is derived from the port
//                  index when a port address is left at all zero).
//                * Store-and-forward switching with per-port buffering.
//                * Source address learning into a set-associative CAM with
//                  round-robin replacement and optional idle-time ageing.
//                * 802.1Q / 802.1ad tag aware forwarding and a configurable
//                  unknown-unicast / group-address flooding policy.
//                * Full FCS generation and checking, runt / oversize /
//                  ingress-overflow / CRC error detection, and a per-port
//                  statistics counter block.
//
//                ------------------------------------------------------------------------
//                PHY interface contract
//                ------------------------------------------------------------------------
//                `gmii_rx_*` and `gmii_tx_*` are GMII-style 8 bit interfaces
//                qualified by a clock enable and synchronous to `clk_i`:
//                  * one octet is transferred every BYTE_PERIOD(port) clocks,
//                  * the enable is asserted for the whole octet time and the
//                    data is stable for the same window,
//                  * the enable is de-asserted during the inter-frame gap.
//                Preamble and start-of-frame delimiter are removed by the PHY
//                on receive and re-inserted on transmit, exactly as a real GMII
//                MAC does.  If the PHY runs on its own clock, wrap the core in
//                asynchronous FIFOs - nothing inside the switch changes.
//
//                ------------------------------------------------------------------------
//                Parameter encoding
//                ------------------------------------------------------------------------
//                The per-port parameters are *flat packed vectors* rather than
//                unpacked arrays, so that they are accepted by every tool in
//                the flow (Icarus Verilog among them, which does not implement
//                unpacked array parameters):
//                  * `PORT_MAC`  - port p occupies bits [48*p +: 48]
//                  * `PORT_SPEED`- port p occupies bits [2*p  +:  2]
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_SWITCH_SV
`define SW_SWITCH_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "sw_defs.sv"

// The shared declarations arrive through the include above and are visible at
// compilation-unit scope, so the parameter list and the ANSI port list below can
// use them (`sw_port_w`, `sw_tag_width`, `SW_STAT_COUNT`, ...) without an
// import clause.  See sw_defs.sv for why a package cannot be used here.
module sw_switch #(
  // ---- topology ------------------------------------------------------------
  /// Number of Ethernet ports.  Any value >= 1 is supported.
  parameter int unsigned NUM_PORTS      = 4,
  /// Core clock frequency in Hz.  Must be >= the 1000BASE-T octet rate
  /// (125 MHz for full line rate); a slower core simply stretches the octet
  /// clock enables and loses line rate, nothing else.
  parameter int unsigned CLK_FREQ_HZ     = 125_000_000,
  /// Per-port MAC addresses, 48 bits per port, port p at bits [48*p +: 48].
  /// A port left at all zero gets the locally administered address
  /// 02:00:00:00:00:<p>.
  parameter logic [NUM_PORTS*48-1:0]  PORT_MAC   = '0,
  /// Per-port link speed, 2 bits per port, port p at bits [2*p +: 2]:
  /// 0 = 10 Mbit/s, 1 = 100 Mbit/s, 2 = 1000 Mbit/s, 3 = administratively
  /// down.  Defaults to 1000 Mbit/s on every port.
  parameter logic [NUM_PORTS*2-1:0]    PORT_SPEED = {NUM_PORTS{2'd2}},

  // ---- buffer sizing -------------------------------------------------------
  /// Payload beats buffered per ingress port.  Must be >= ceil(MAX_FRAME_LEN/8)
  /// (190 for the default 1518 octet maximum) or maximum-length frames are
  /// reported as ingress overflow.
  parameter int unsigned RX_FIFO_DEPTH  = 256,
  /// Egress beats buffered per port.  Same sizing rule as RX_FIFO_DEPTH.
  parameter int unsigned TX_FIFO_DEPTH  = 256,
  /// Frame descriptors buffered per ingress port.
  parameter int unsigned TAG_FIFO_DEPTH = 16,
  /// Elastic beat FIFO between the GMII adapter and the parser.
  parameter int unsigned WF_DEPTH       = 16,

  // ---- switching fabric ----------------------------------------------------
  /// Largest frame accepted, in octets, FCS excluded.
  parameter int unsigned MAX_FRAME_LEN  = 1518,
  /// 0 = block unknown unicast, 1 = flood it, 2 = flood unknown group too.
  parameter logic [1:0]  FLOOD_MODE     = 2'd1,
  /// Source address learning default.
  parameter logic        LEARNING_EN    = 1'b1,
  /// Cycles a head-of-line frame may wait at a congested egress before it is
  /// dropped.  0 stalls forever and never drops.
  parameter int unsigned STALL_LIMIT    = 0,

  // ---- forwarding address table -------------------------------------------
  parameter int unsigned CAM_SETS       = 128,
  parameter int unsigned CAM_WAYS       = 4,
  parameter logic        CAM_AGE_EN     = 1'b0,
  /// Clocks between two ageing steps.  The effective idle timeout is
  /// CAM_AGE_CYCLES * CAM_SETS * CAM_WAYS * (CAM_AGE_LIMIT + 1) clocks.
  parameter int unsigned CAM_AGE_CYCLES = 1_000_000,
  parameter int unsigned CAM_AGE_LIMIT  = 4
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,   ///< active-low reset

  // ---- control -------------------------------------------------------------
  input  logic [NUM_PORTS-1:0]                link_up_i,   ///< port is enabled
  input  logic [1:0]                          flood_mode_i,
  input  logic                                learning_en_i,
  input  logic                                cfg_ovr_i,   ///< use run-time config
  input  logic                                cam_flush_i, ///< flush the CAM

  // ---- GMII receive (clock-enable qualified, synchronous to clk_i) ---------
  input  logic [NUM_PORTS-1:0]                gmii_rx_en_i,
  input  logic [NUM_PORTS*8-1:0]              gmii_rx_data_i,

  // ---- GMII transmit (clock-enable qualified, synchronous to clk_i) -------
  output logic [NUM_PORTS-1:0]                gmii_tx_en_o,
  output logic [NUM_PORTS*8-1:0]              gmii_tx_data_o,

  // ---- observability -------------------------------------------------------
  /// Packed statistics bus, 32 bits per counter, indices per sw_stat_id_e.
  output logic [32*SW_STAT_COUNT-1:0]         stat_o
);

  localparam int unsigned PW   = sw_port_w(NUM_PORTS);
  localparam int unsigned TAGW = sw_tag_width(NUM_PORTS);
  localparam int unsigned FF_W = sw_tx_free_width(TX_FIFO_DEPTH);

  // Elaboration-time sanity checks.  A mismatch here is a design error, not a
  // run-time condition, so it is reported with $error instead of being handled.
  //
  // The whole block is excluded from synthesis.  `$error` and `$warning` are
  // simulation system tasks: yosys has no implementation for them and aborts on
  // a design that contains them, so the checks run in simulation - which is where
  // a mis-parameterised instance is actually built - and the synthesised netlist
  // never sees them.  The parameter values themselves are still elaborated, so a
  // genuinely invalid configuration fails the simulation runs just as before.
`ifndef SYNTHESIS
  initial begin
    if (NUM_PORTS == 0) $error("sw_switch: NUM_PORTS must be >= 1");
    if (RX_FIFO_DEPTH < sw_beats_of(MAX_FRAME_LEN)) begin
      $warning("sw_switch: RX_FIFO_DEPTH (%0d) is smaller than the %0d beats a maximum-length frame needs; long frames will be dropped as ingress overflow",
               RX_FIFO_DEPTH, sw_beats_of(MAX_FRAME_LEN));
    end
    if (TX_FIFO_DEPTH < sw_beats_of(MAX_FRAME_LEN)) begin
      $warning("sw_switch: TX_FIFO_DEPTH (%0d) is smaller than the %0d beats a maximum-length frame needs; long frames will stall the fabric",
               TX_FIFO_DEPTH, sw_beats_of(MAX_FRAME_LEN));
    end
  end
`endif

  // --------------------------------------------------------------------------
  // Per-port wiring
  // --------------------------------------------------------------------------
  logic [NUM_PORTS-1:0]                src_empty;
  logic [NUM_PORTS-1:0]                src_data_rd_en;
  logic [NUM_PORTS*64-1:0]             src_data_rd_data;
  logic [NUM_PORTS-1:0]                src_tag_rd_en;   ///< driven by the fabric
  logic [NUM_PORTS-1:0]                src_tag_empty;
  logic [NUM_PORTS*TAGW-1:0]           src_tag_rd_data;
  logic [NUM_PORTS-1:0]                src_flush;

  logic [NUM_PORTS-1:0]                dst_wr_en;
  logic [NUM_PORTS*64-1:0]             dst_wr_data;
  logic [NUM_PORTS*SW_LEN_W-1:0]       dst_wr_len;
  logic [NUM_PORTS-1:0]                dst_fr;
  logic [NUM_PORTS*(FF_W+1)-1:0]       dst_free;
  logic [NUM_PORTS-1:0]                dst_slot;   ///< an egress port still fits a frame

  logic [32*SW_STAT_COUNT-1:0]         rx_stat [NUM_PORTS];
  logic [32*SW_STAT_COUNT-1:0]         tx_stat [NUM_PORTS];

  // One shared CAM serves every port: NUM_PORTS parallel lookup ports and
  // NUM_PORTS learn ports, all in the same single clock domain.
  logic [NUM_PORTS-1:0]                cam_req;
  logic [NUM_PORTS*48-1:0]             cam_mac;
  logic [NUM_PORTS-1:0]                cam_hit;
  logic [NUM_PORTS*NUM_PORTS-1:0]      cam_port;
  logic [NUM_PORTS-1:0]                cam_learn;
  logic [NUM_PORTS*48-1:0]             cam_learn_mac;
  // `cam_entries` is the number of CAM insertions since the last flush.  It is
  // a debug/bring-up observable rather than a traffic counter, so it is
  // reduced into a dummy net here instead of being added to `stat_o`.
  logic [31:0]                         cam_entries;
  logic                                unused_cam_entries;
  assign unused_cam_entries = ^cam_entries;
  logic [31:0]                         cam_hits;
  logic [31:0]                         cam_misses;
  logic [31:0]                         cam_learns;

  // Learn port index of every port is simply the port number itself, packed.
  logic [NUM_PORTS*PW-1:0] learn_port_idx;
  for (genvar gi = 0; gi < NUM_PORTS; gi++) begin : g_learn_idx
    assign learn_port_idx[gi*PW +: PW] = PW'(gi);
  end

  for (genvar g = 0; g < NUM_PORTS; g++) begin : g_port

    // Locally administered fallback address when the port is left unassigned.
    localparam logic [47:0] MAC_G =
        (PORT_MAC[g*48 +: 48] == 48'h0) ? sw_default_mac(g) : PORT_MAC[g*48 +: 48];

    // Clock enables per GMII octet for this port's link speed.
    localparam int unsigned BP_G =
        sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[g*2 +: 2]));

    // ---- ingress --------------------------------------------------------
    sw_rx_port #(
        .NUM_PORTS      (NUM_PORTS),
        .PORT_ID        (g),
        .PORT_MAC       (MAC_G),
        .BYTE_PERIOD    (BP_G),
        .MAX_FRAME_LEN  (MAX_FRAME_LEN),
        .RX_FIFO_DEPTH  (RX_FIFO_DEPTH),
        .TAG_FIFO_DEPTH (TAG_FIFO_DEPTH),
        .WF_DEPTH       (WF_DEPTH),
        .FLOOD_MODE     (FLOOD_MODE),
        .LEARNING_EN    (LEARNING_EN)
    ) u_rx (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .link_up_i     (link_up_i[g]),
        .gmii_en_i     (gmii_rx_en_i[g]),
        .gmii_d_i      (gmii_rx_data_i[g*8 +: 8]),
        .cam_req_o     (cam_req[g]),
        .cam_mac_o     (cam_mac[g*48 +: 48]),
        .cam_hit_i     (cam_hit[g]),
        .cam_port_i    (cam_port[g*NUM_PORTS +: NUM_PORTS]),
        .learn_o       (cam_learn[g]),
        .learn_mac_o   (cam_learn_mac[g*48 +: 48]),
        .flood_mode_i  (flood_mode_i),
        .learning_en_i (learning_en_i),
        .cfg_ovr_i     (cfg_ovr_i),
        .rd_data_o     (src_data_rd_data[g*64 +: 64]),
        .empty_o       (src_empty[g]),
        .rd_en_i       (src_data_rd_en[g]),
        .flush_i       (src_flush[g]),
        .tag_rd_en_i   (src_tag_rd_en[g]),
        .tag_rd_data_o (src_tag_rd_data[g*TAGW +: TAGW]),
        .tag_empty_o   (src_tag_empty[g]),
        .stat_o        (rx_stat[g])
    );

    // ---- egress ---------------------------------------------------------
    logic [FF_W:0] tx_free;
    logic         tx_slot;

    sw_tx_port #(
        .BYTE_PERIOD (BP_G),
        .TX_FIFO_DEPTH (TX_FIFO_DEPTH)
    ) u_tx (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .wr_en_i    (dst_wr_en[g]),
        .wr_data_i  (dst_wr_data[g*64 +: 64]),
        .wr_len_i   (dst_wr_len[g*SW_LEN_W +: SW_LEN_W]),
        .wr_fr_i    (dst_fr[g]),
        .gmii_en_o  (gmii_tx_en_o[g]),
        .gmii_d_o   (gmii_tx_data_o[g*8 +: 8]),
        .free_o     (tx_free),
        .slot_o     (tx_slot),
        .stat_o     (tx_stat[g])
    );

    assign dst_free[g*(FF_W+1) +: FF_W+1] = tx_free;
    assign dst_slot[g]                     = tx_slot;

  end

  // --------------------------------------------------------------------------
  // Forwarding address table
  //
  // A single shared CAM serves every port.  Each port gets its own combinational
  // bucket read, so all NUM_PORTS lookups resolve in parallel in one clock and
  // the receive path never has to arbitrate for a lookup.  Learning requests are
  // serialised internally by a request queue of depth NUM_PORTS, so two ports
  // that finish a frame in the same clock both get their address recorded.
  // --------------------------------------------------------------------------
  sw_mac_table #(
      .NUM_PORTS       (NUM_PORTS),
      .NUM_SETS        (CAM_SETS),
      .NUM_WAYS        (CAM_WAYS),
      .AGE_EN          (CAM_AGE_EN),
      .AGE_TICK_CYCLES (CAM_AGE_CYCLES),
      .AGE_LIMIT       (CAM_AGE_LIMIT)
  ) u_cam (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .flush_i      (cam_flush_i),
      .req_i        (cam_req),
      .mac_i        (cam_mac),
      .hit_o        (cam_hit),
      .port_o       (cam_port),
      .learn_i      (cam_learn),
      .learn_mac_i  (cam_learn_mac),
      .learn_port_i (learn_port_idx),
      .entries_o    (cam_entries),
      .hits_o       (cam_hits),
      .misses_o     (cam_misses),
      .learns_o     (cam_learns)
  );

  // --------------------------------------------------------------------------
  // Frame scheduler
  // --------------------------------------------------------------------------
  logic [32*SW_STAT_COUNT-1:0] arb_stat;

  sw_arbiter #(
      .NUM_PORTS     (NUM_PORTS),
      .TX_FIFO_DEPTH (TX_FIFO_DEPTH),
      .STALL_LIMIT   (STALL_LIMIT)
  ) u_arb (
      .clk_i             (clk_i),
      .rst_ni            (rst_ni),
      .src_empty_i       (src_empty),
      .src_tag_empty_i   (src_tag_empty),
      .src_tag_rd_en_o   (src_tag_rd_en),
      .src_tag_rd_data_i (src_tag_rd_data),
      .src_data_rd_en_o  (src_data_rd_en),
      .src_data_rd_data_i(src_data_rd_data),
      .src_flush_o       (src_flush),
      .dst_wr_en_o       (dst_wr_en),
      .dst_wr_data_o     (dst_wr_data),
      .dst_wr_len_o      (dst_wr_len),
      .dst_fr_o          (dst_fr),
      .dst_free_i        (dst_free),
      .dst_slot_i        (dst_slot),
      .stat_o            (arb_stat)
  );

  // --------------------------------------------------------------------------
  // Statistics aggregation
  //
  // Per-port receive and transmit counters are summed; the scheduler and the
  // CAM counters come from their own dedicated blocks.  The generate loop keeps
  // the "which counter belongs to whom" decision in one readable place.
  // --------------------------------------------------------------------------
  function automatic logic [31:0] stat_get(
      input logic [32*SW_STAT_COUNT-1:0] bus, input int unsigned idx);
    stat_get = bus[32*idx +: 32];
  endfunction

  always_comb begin
    for (int unsigned k = 0; k < SW_STAT_COUNT; k++) stat_o[32*k +: 32] = 32'd0;

    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      // Receive counters: the transmit path never drives these.
      for (int unsigned k = 0; k < SW_STAT_COUNT; k++) begin
        if ((k != int'(SW_STAT_TX_FRAMES)) && (k != int'(SW_STAT_TX_OCTETS)) &&
            (k != int'(SW_STAT_TX_STALLED))) begin
          stat_o[32*k +: 32] = stat_o[32*k +: 32] + stat_get(rx_stat[p], k);
        end
      end
      // Transmit counters: the receive path never drives these.
      for (int unsigned k = 0; k < SW_STAT_COUNT; k++) begin
        if ((k != int'(SW_STAT_TX_FRAMES)) && (k != int'(SW_STAT_TX_OCTETS))) begin
          stat_o[32*k +: 32] = stat_o[32*k +: 32] + stat_get(tx_stat[p], k);
        end
      end
    end

    // Counters owned by the scheduler.
    stat_o[32*int'(SW_STAT_TX_FRAMES)  +: 32] = stat_get(arb_stat, int'(SW_STAT_TX_FRAMES));
    stat_o[32*int'(SW_STAT_TX_OCTETS)  +: 32] = stat_get(arb_stat, int'(SW_STAT_TX_OCTETS));
    stat_o[32*int'(SW_STAT_TX_STALLED) +: 32] = stat_get(arb_stat, int'(SW_STAT_TX_STALLED));
    // Counters owned by the forwarding address table.
    stat_o[32*int'(SW_STAT_CAM_HIT)    +: 32] = cam_hits;
    stat_o[32*int'(SW_STAT_CAM_MISS)   +: 32] = cam_misses;
    stat_o[32*int'(SW_STAT_CAM_LEARN)  +: 32] = cam_learns;
    // A flush request is a one-shot software action rather than an event the
    // CAM can count, so it is reported straight from the request line.
    stat_o[32*int'(SW_STAT_CAM_FLUSH)  +: 32] = cam_flush_i ? 32'd1 : 32'd0;
  end

endmodule : sw_switch

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif // SW_SWITCH_SV
