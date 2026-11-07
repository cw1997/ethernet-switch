// ============================================================================
//  File        : es_switch_core.sv
//  Description : Interface-agnostic core of the parameterised Ethernet Layer-2
//                switch.
//
//                Scope
//                -----
//                This module contains the switching function and nothing else:
//                it parses a received frame, tells the forwarding address table
//                what it saw, buffers the frame until it is known to be good,
//                decides which egress ports may have it, arbitrates between
//                ingress ports contending for the same egress port, and hands
//                complete frames to the egress buffers.
//
//                Everything the line interface implies lives in `rtl/mac/`.
//                Each port is fed by an `es_mac_*` instance that owns the PHY
//                pins, the preamble and SFD, the FCS, the inter-frame gap, the
//                symbol serialisation and the elastic buffer a PHY needs
//                because it cannot be stalled mid-frame.  The boundary between
//                the two is a plain 64-bit beat stream, so this module compiles
//                unchanged against GMII, MII, RMII or any future interface -
//                including an optical one - and it holds no clock-enable,
//                line-rate or symbol-order knowledge at all.
//
//                Features
//                --------
//                * Arbitrary number of ports, each with its own MAC address
//                  (a locally administered default is derived from the port
//                  index when a port address is left at all zero).
//                * Store-and-forward switching with per-port buffering.
//                * Source address learning into a set-associative CAM with
//                  round-robin replacement and optional idle-time ageing.
//                * 802.1Q / 802.1ad tag aware forwarding and a configurable
//                  unknown-unicast / group-address flooding policy.
//                * Runt / oversize / ingress-overflow / CRC error detection and
//                  a per-port statistics counter block.
//
//                Beat-stream contract
//                ---------------------
//                See `rtl/mac/es_mac_defs.sv`: the receive side is a
//                first-word-fall-through beat stream with frame markers and an
//                FCS verdict; the transmit side is a per-frame valid/ready
//                handshake followed by a beat stream the MAC pulls.
//
//                Observability
//                -------------
//                `stat_o` carries the aggregate of every counter.  Per-port
//                values are read through the separate `stat_port_i` /
//                `stat_id_i` / `stat_data_o` port, one independent read port per
//                console, which is purely combinational and therefore cannot
//                perturb the datapath or require arbitration.
//
//                Parameter encoding
//                ------------------
//                The per-port parameters are *flat packed vectors* rather than
//                unpacked arrays, so that they are accepted by every tool in
//                the flow (Icarus Verilog among them, which does not implement
//                unpacked array parameters):
//                  * `PORT_MAC` - port p occupies bits [48*p +: 48]
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef ES_SWITCH_CORE_SV
`define ES_SWITCH_CORE_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

// The shared declarations arrive through the include above and are visible at
// compilation-unit scope, so the parameter list and the ANSI port list below can
// use them (`sw_port_w`, `sw_tag_width`, `SW_STAT_COUNT`, ...) without an
// import clause.  See es_defs.sv for why a package cannot be used here.
module es_switch_core #(
  // ---- topology ------------------------------------------------------------
  /// Number of Ethernet ports.  Any value >= 1 is supported.
  parameter int unsigned NUM_PORTS   = SW_DEFAULT_NUM_PORTS,
  /// Number of independent console statistic read ports.  Each console drives
  /// its own `stat_port_i` / `stat_id_i` slice and reads its own `stat_data_o`
  /// slice in the same clock, so the readers never contend.  The value is only
  /// a width multiplier; nothing in the datapath depends on it.
  parameter int unsigned NUM_CONSOLE   = 1,
  /// Per-port MAC addresses, 48 bits per port, port p at bits [48*p +: 48].
  /// A port left at all zero gets the locally administered address
  /// 02:00:00:00:00:<p>.
  parameter logic [NUM_PORTS*48-1:0] PORT_MAC = '0,

  // ---- buffer sizing -------------------------------------------------------
  /// Payload beats buffered per ingress port.  Must be >= ceil(MAX_FRAME_LEN/8)
  /// (190 for the default 1518 octet maximum) or maximum-length frames are
  /// reported as ingress overflow.
  parameter int unsigned RX_FIFO_DEPTH  = 256,
  /// Egress beats buffered per port.  Same sizing rule as RX_FIFO_DEPTH.
  parameter int unsigned TX_FIFO_DEPTH  = 256,
  /// Frame descriptors buffered per ingress port.
  parameter int unsigned TAG_FIFO_DEPTH = 16,

  // ---- switching fabric ----------------------------------------------------
  /// Largest frame accepted, in octets, FCS excluded.
  parameter int unsigned MAX_FRAME_LEN = 1518,
  /// 0 = block unknown unicast, 1 = flood it, 2 = flood unknown group too.
  parameter logic [1:0] FLOOD_MODE   = 2'd1,
  /// Source address learning default.
  parameter logic       LEARNING_EN  = 1'b1,
  /// Cycles a head-of-line frame may wait at a congested egress before it is
  /// dropped.  0 stalls forever and never drops.
  parameter int unsigned STALL_LIMIT = 0,

  // ---- forwarding address table -------------------------------------------
  /// Number of CAM sets; the table holds CAM_SETS * CAM_WAYS addresses.
  parameter int unsigned CAM_SETS   = 128,
  /// Ways per CAM set.
  parameter int unsigned CAM_WAYS   = 4,
  /// Enable idle-time ageing of learned addresses.
  parameter logic        CAM_AGE_EN = 1'b0,
  /// Clocks between two ageing steps.  The effective idle timeout is
  /// CAM_AGE_CYCLES * CAM_SETS * CAM_WAYS * (CAM_AGE_LIMIT + 1) clocks.
  parameter int unsigned CAM_AGE_CYCLES = 1_000_000,
  /// Ageing steps an entry may survive before it is evicted.
  parameter int unsigned CAM_AGE_LIMIT  = 4
) (
  /// Core clock and synchronous active-low reset.
  input var logic clk_i,
  input var logic rst_ni,

  // ---- control -------------------------------------------------------------
  /// Run-time flooding policy, sampled instead of FLOOD_MODE when cfg_ovr_i.
  input var logic [1:0] flood_mode_i,
  /// Run-time source-learning enable.
  input var logic learning_en_i,
  /// Use the run-time configuration above rather than the elaboration values.
  input var logic cfg_ovr_i,
  /// Flush every learned address.
  input var logic cam_flush_i,

  // ---- MAC beat interfaces (interface-agnostic) ----------------------------
  //
  // The PHY pins are owned by the per-port `es_mac_*` instances in rtl/mac, so
  // this core neither knows nor cares which line interface a port exposes.
  // Both directions are packed per port with port 0 in the least-significant
  // slice.  See rtl/mac/es_mac_defs.sv for the exact contract.
  /// Receive beats from the MACs: head beat, frame markers, FCS verdict.
  input var logic [NUM_PORTS-1:0]     rx_beat_valid_i,
  input var logic [NUM_PORTS*64-1:0]  rx_beat_data_i,
  input var logic [NUM_PORTS-1:0]     rx_beat_sof_i,
  input var logic [NUM_PORTS-1:0]     rx_beat_eof_i,
  input var logic [NUM_PORTS-1:0]     rx_beat_crc_ok_i,
  input var logic [NUM_PORTS*4-1:0]   rx_beat_octets_i,
  output    logic [NUM_PORTS-1:0]     rx_beat_rd_o,
  /// Frames and beats offered to the MACs.
  output    logic [NUM_PORTS-1:0]           tx_fr_valid_o,
  output    logic [NUM_PORTS*SW_LEN_W-1:0]  tx_fr_len_o,
  input var logic [NUM_PORTS-1:0]           tx_fr_ready_i,
  output    logic [NUM_PORTS-1:0]           tx_beat_valid_o,
  output    logic [NUM_PORTS*64-1:0]        tx_beat_data_o,
  input var logic [NUM_PORTS-1:0]           tx_beat_rd_i,

  // ---- console read ports --------------------------------------------------
  /// Per-port counters: `NUM_CONSOLE` independent stateless readers.  Console c
  /// occupies bits [c*PW +: PW] / [c*4 +: 4] / [c*32 +: 32] respectively.
  input var logic [NUM_CONSOLE*sw_port_w(NUM_PORTS)-1:0] stat_port_i,
  input var logic [NUM_CONSOLE*4-1:0]                    stat_id_i,
  output    logic [NUM_CONSOLE*32-1:0]                   stat_data_o,
  /// Forwarding table inspection.  A single registered read port shared by the
  /// consoles; the arbiter that decides who drives it lives in the console hub.
  input var logic        cam_rd_req_i,
  input var logic [31:0] cam_rd_index_i,
  output    logic        cam_rd_valid_o,
  output    logic [127:0] cam_rd_entry_o,
  /// Entries currently held in the forwarding table.
  output    logic [31:0] cam_entries_o,

  // ---- observability -------------------------------------------------------
  /// Packed aggregate statistics bus, 32 bits per counter, per sw_stat_id_e.
  output logic [32*SW_STAT_COUNT-1:0] stat_o
);

  localparam int unsigned PW   = sw_port_w(NUM_PORTS);
  localparam int unsigned TAGW = sw_tag_width(NUM_PORTS);
  localparam int unsigned FF_W = sw_tx_free_width(TX_FIFO_DEPTH);

  // --------------------------------------------------------------------------
  // Elaboration-time sanity checks
  //
  // A mismatch here is a design error, not a run-time condition, so it is
  // reported with $error instead of being handled.
  //
  // The whole block is excluded from synthesis.  `$error` and `$warning` are
  // simulation system tasks: yosys has no implementation for them and aborts on
  // a design that contains them, so the checks run in simulation - which is where
  // a mis-parameterised instance is actually built - and the synthesised netlist
  // never sees them.  The parameter values themselves are still elaborated, so a
  // genuinely invalid configuration fails the simulation runs just as before.
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (NUM_PORTS == 0) $error("es_switch_core: NUM_PORTS must be >= 1");
    if (NUM_CONSOLE == 0) $error("es_switch_core: NUM_CONSOLE must be >= 1");
    // `stat_id_i` is four bits wide, so a larger counter set would silently
    // alias two counters onto one address.
    if (SW_STAT_COUNT > 16) begin
      $error("es_switch_core: SW_STAT_COUNT (%0d) exceeds the 4-bit stat_id_i",
             SW_STAT_COUNT);
    end
    if (RX_FIFO_DEPTH < sw_beats_of(MAX_FRAME_LEN)) begin
      $warning(
          "es_switch_core: RX_FIFO_DEPTH (%0d) is smaller than the %0d beats a maximum-length frame needs; long frames will be dropped as ingress overflow",
          RX_FIFO_DEPTH, sw_beats_of(MAX_FRAME_LEN));
    end
    if (TX_FIFO_DEPTH < sw_beats_of(MAX_FRAME_LEN)) begin
      $warning(
          "es_switch_core: TX_FIFO_DEPTH (%0d) is smaller than the %0d beats a maximum-length frame needs; long frames will stall the fabric",
          TX_FIFO_DEPTH, sw_beats_of(MAX_FRAME_LEN));
    end
  end
`endif

  // --------------------------------------------------------------------------
  // Per-port wiring
  // --------------------------------------------------------------------------
  logic [NUM_PORTS-1:0]         src_empty;
  logic [NUM_PORTS-1:0]         src_data_rd_en;
  logic [NUM_PORTS*64-1:0]      src_data_rd_data;
  logic [NUM_PORTS-1:0]         src_tag_rd_en;      ///< driven by the fabric
  logic [NUM_PORTS-1:0]         src_tag_empty;
  logic [NUM_PORTS*TAGW-1:0]    src_tag_rd_data;
  logic [NUM_PORTS-1:0]         src_flush;

  logic [NUM_PORTS-1:0]         dst_wr_en;
  logic [NUM_PORTS*64-1:0]      dst_wr_data;
  logic [NUM_PORTS*SW_LEN_W-1:0] dst_wr_len;
  logic [NUM_PORTS-1:0]         dst_fr;
  logic [NUM_PORTS*(FF_W+1)-1:0] dst_free;
  logic [NUM_PORTS-1:0]         dst_slot;  ///< an egress port still fits a frame

  logic [32*SW_STAT_COUNT-1:0] rx_stat [NUM_PORTS];
  logic [32*SW_STAT_COUNT-1:0] tx_stat [NUM_PORTS];

  // One shared CAM serves every port: NUM_PORTS parallel lookup ports and
  // NUM_PORTS learn ports, all in the same single clock domain.
  logic [NUM_PORTS-1:0]          cam_req;
  logic [NUM_PORTS*48-1:0]       cam_mac;
  logic [NUM_PORTS-1:0]          cam_hit;
  logic [NUM_PORTS*NUM_PORTS-1:0] cam_port;
  logic [NUM_PORTS-1:0]          cam_learn;
  logic [NUM_PORTS*48-1:0]       cam_learn_mac;

  logic [31:0] cam_hits;
  logic [31:0] cam_misses;
  logic [31:0] cam_learns;

  /// Learn port index of every port is simply the port number itself, packed.
  logic [NUM_PORTS*PW-1:0] learn_port_idx;

  // Quartus's parser rejects the SV inline form `for (genvar g = 0; ...)` and
  // also rejects a bare module-level `for` - every loop carries an explicit
  // `generate`/`endgenerate` wrapper; yosys, Verilator and Icarus accept
  // all forms (see es_switch_arbiter.sv for the full note).
  genvar gi;
  genvar g;
  genvar mk;

  generate
    for (gi = 0; gi < NUM_PORTS; gi++) begin : g_learn_idx
      assign learn_port_idx[gi*PW +: PW] = PW'(gi);
    end
  endgenerate

  /// Per-port merged counters, 32 bits per `sw_stat_id_e` entry.  This plane is
  /// the source of both `stat_o` (summed) and the console read ports (selected).
  logic [NUM_PORTS*32*SW_STAT_COUNT-1:0] stat_plane;
  /// Scheduler stall events, one bit per port, accumulated per port below.
  logic [NUM_PORTS-1:0]                  arb_stalled;
  logic                                  arb_busy;
  logic                                  unused_arb_busy;

  // --------------------------------------------------------------------------
  // One receive / transmit pair per port
  // --------------------------------------------------------------------------
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_port
      // Locally administered fallback address when the port is left unassigned.
      localparam logic [47:0] MAC_G =
          (PORT_MAC[g*48 +: 48] == 48'h0) ? sw_default_mac(g) : PORT_MAC[g*48 +: 48];

      logic [FF_W:0] tx_free;
      logic          tx_slot;
      logic [31:0]   stalled_q;

      // ---- ingress --------------------------------------------------------
      es_switch_rx_port #(
        .NUM_PORTS      (NUM_PORTS),
        .PORT_ID        (g),
        .PORT_MAC       (MAC_G),
        .MAX_FRAME_LEN  (MAX_FRAME_LEN),
        .RX_FIFO_DEPTH  (RX_FIFO_DEPTH),
        .TAG_FIFO_DEPTH (TAG_FIFO_DEPTH),
        .FLOOD_MODE     (FLOOD_MODE),
        .LEARNING_EN    (LEARNING_EN)
      ) u_rx (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .rx_beat_valid_i  (rx_beat_valid_i[g]),
        .rx_beat_data_i   (rx_beat_data_i[g*64 +: 64]),
        .rx_beat_sof_i    (rx_beat_sof_i[g]),
        .rx_beat_eof_i    (rx_beat_eof_i[g]),
        .rx_beat_crc_ok_i (rx_beat_crc_ok_i[g]),
        .rx_beat_octets_i (rx_beat_octets_i[g*4 +: 4]),
        .rx_beat_rd_o     (rx_beat_rd_o[g]),
        .cam_req_o        (cam_req[g]),
        .cam_mac_o        (cam_mac[g*48 +: 48]),
        .cam_hit_i        (cam_hit[g]),
        .cam_port_i       (cam_port[g*NUM_PORTS +: NUM_PORTS]),
        .learn_o          (cam_learn[g]),
        .learn_mac_o      (cam_learn_mac[g*48 +: 48]),
        .flood_mode_i     (flood_mode_i),
        .learning_en_i    (learning_en_i),
        .cfg_ovr_i        (cfg_ovr_i),
        .rd_data_o        (src_data_rd_data[g*64 +: 64]),
        .empty_o          (src_empty[g]),
        .rd_en_i          (src_data_rd_en[g]),
        .flush_i          (src_flush[g]),
        .tag_rd_en_i      (src_tag_rd_en[g]),
        .tag_rd_data_o    (src_tag_rd_data[g*TAGW +: TAGW]),
        .tag_empty_o      (src_tag_empty[g]),
        .stat_o           (rx_stat[g])
      );

      // ---- egress ---------------------------------------------------------
      es_switch_tx_port #(
        .TX_FIFO_DEPTH (TX_FIFO_DEPTH)
      ) u_tx (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .wr_en_i         (dst_wr_en[g]),
        .wr_data_i       (dst_wr_data[g*64 +: 64]),
        .wr_len_i        (dst_wr_len[g*SW_LEN_W +: SW_LEN_W]),
        .wr_fr_i         (dst_fr[g]),
        .tx_fr_valid_o   (tx_fr_valid_o[g]),
        .tx_fr_len_o     (tx_fr_len_o[g*SW_LEN_W +: SW_LEN_W]),
        .tx_fr_ready_i   (tx_fr_ready_i[g]),
        .tx_beat_valid_o (tx_beat_valid_o[g]),
        .tx_beat_data_o  (tx_beat_data_o[g*64 +: 64]),
        .tx_beat_rd_i    (tx_beat_rd_i[g]),
        .free_o          (tx_free),
        .slot_o          (tx_slot),
        .stat_o          (tx_stat[g])
      );

      assign dst_free[g*(FF_W+1) +: FF_W+1] = tx_free;
      assign dst_slot[g]                    = tx_slot;

      // The scheduler reports a stall as a one-clock event; a counter needs a
      // running total, so it is accumulated here rather than in the arbiter.
      // This is the only per-port source of SW_STAT_TX_STALLED, which is why it
      // survives even though the aggregate value comes from the arbiter.
      always_ff @(posedge clk_i) begin
        if (!rst_ni)               stalled_q <= '0;
        else if (arb_stalled[g])   stalled_q <= stalled_q + 32'd1;
      end

      // A statistics word is either owned by the receive path, by the transmit
      // path, or by this per-port stall accumulator - never by two of them, so
      // the OR below is a selector in practice and not a merge.
      for (mk = 0; mk < SW_STAT_COUNT; mk++) begin : g_stat_word
        if (mk == int'(SW_STAT_TX_STALLED)) begin : g_stall
          assign stat_plane[(g*SW_STAT_COUNT+mk)*32 +: 32] = stalled_q;
        end else begin : g_other
          assign stat_plane[(g*SW_STAT_COUNT+mk)*32 +: 32] =
              rx_stat[g][mk*32 +: 32] | tx_stat[g][mk*32 +: 32];
        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Forwarding address table
  //
  // A single shared CAM serves every port.  Each port gets its own combinational
  // bucket read, so all NUM_PORTS lookups resolve in parallel in one clock and
  // the receive path never has to arbitrate for a lookup.  Learning requests are
  // serialised internally by a request queue of depth NUM_PORTS, so two ports
  // that finish a frame in the same clock both get their address recorded.
  // --------------------------------------------------------------------------
  es_switch_mac_table #(
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
    .rd_req_i     (cam_rd_req_i),
    .rd_index_i   (cam_rd_index_i),
    .rd_valid_o   (cam_rd_valid_o),
    .rd_entry_o   (cam_rd_entry_o),
    .entries_o    (cam_entries_o),
    .hits_o       (cam_hits),
    .misses_o     (cam_misses),
    .learns_o     (cam_learns)
  );

  // --------------------------------------------------------------------------
  // Flush accounting
  //
  // `cam_flush_i` is a one-clock pulse (the panel edge-detects the switch
  // position, so holding it up cannot flush continuously).  The table has no
  // event of its own to report, so the core counts the pulses: publishing the
  // request level instead would make `CAM_FLUSH` read 1 while a flush is
  // asserted and 0 otherwise, which is not a count and not comparable with the
  // other thirteen.
  // --------------------------------------------------------------------------
  logic [31:0] cnt_cam_flush;

  always_ff @(posedge clk_i) begin
    if (!rst_ni)          cnt_cam_flush <= 32'd0;
    else if (cam_flush_i) cnt_cam_flush <= cnt_cam_flush + 32'd1;
  end

  // --------------------------------------------------------------------------
  // Frame scheduler
  // --------------------------------------------------------------------------
  logic [32*SW_STAT_COUNT-1:0] arb_stat;

  es_switch_arbiter #(
    .NUM_PORTS     (NUM_PORTS),
    .TX_FIFO_DEPTH (TX_FIFO_DEPTH),
    .STALL_LIMIT   (STALL_LIMIT)
  ) u_arb (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .src_empty_i        (src_empty),
    .src_tag_empty_i    (src_tag_empty),
    .src_tag_rd_en_o    (src_tag_rd_en),
    .src_tag_rd_data_i  (src_tag_rd_data),
    .src_data_rd_en_o   (src_data_rd_en),
    .src_data_rd_data_i (src_data_rd_data),
    .src_flush_o        (src_flush),
    .dst_wr_en_o        (dst_wr_en),
    .dst_wr_data_o      (dst_wr_data),
    .dst_wr_len_o       (dst_wr_len),
    .dst_fr_o           (dst_fr),
    .dst_free_i         (dst_free),
    .dst_slot_i         (dst_slot),
    .busy_o             (arb_busy),
    .stalled_o          (arb_stalled),
    .stat_o             (arb_stat)
  );

  // --------------------------------------------------------------------------
  // Statistics aggregation
  //
  // Per-port receive and transmit counters are summed; the scheduler and the
  // CAM counters come from their own dedicated blocks.  The loop keeps the
  // "which counter belongs to whom" decision in one readable place.
  // --------------------------------------------------------------------------
  function automatic logic [31:0] stat_get(input var logic [32*SW_STAT_COUNT-1:0] bus,
                                           input int unsigned idx);
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
    stat_o[32*int'(SW_STAT_TX_FRAMES) +: 32]  = stat_get(arb_stat, int'(SW_STAT_TX_FRAMES));
    stat_o[32*int'(SW_STAT_TX_OCTETS) +: 32]  = stat_get(arb_stat, int'(SW_STAT_TX_OCTETS));
    stat_o[32*int'(SW_STAT_TX_STALLED) +: 32] = stat_get(arb_stat, int'(SW_STAT_TX_STALLED));
    // Counters owned by the forwarding address table.
    stat_o[32*int'(SW_STAT_CAM_HIT) +: 32]    = cam_hits;
    stat_o[32*int'(SW_STAT_CAM_MISS) +: 32]   = cam_misses;
    stat_o[32*int'(SW_STAT_CAM_LEARN) +: 32]  = cam_learns;
    // Counted here rather than in the table: see the flush accounting block.
    stat_o[32*int'(SW_STAT_CAM_FLUSH) +: 32]  = cnt_cam_flush;
  end

  // --------------------------------------------------------------------------
  // Console read ports
  //
  // One stateless, purely combinational word port per console.  Nothing here is
  // registered, so reading counters can never perturb the datapath, and because
  // each console owns its own address slice the readers need no arbitration.
  //
  // A port's counters occupy 32*SW_STAT_COUNT = 448 bits, which is not a power
  // of two, so selecting a port with `port * 448` would infer a multiplier.
  // Instead the plane is already laid out with elaboration-time constant
  // offsets, each port's word is picked by its own generate arm, and the final
  // select is a one-hot AND-OR.  There is no run-time arithmetic anywhere.
  //
  // The scheduler's busy flag has no reader of its own; it is reduced into a
  // dummy net rather than dropped, so that "nothing observes this" stays an
  // explicit decision instead of a silent dangling output.
  // --------------------------------------------------------------------------
  assign unused_arb_busy = arb_busy;

  /// Fold one port's packed plane down to the single word `id` selects.  A
  /// function has no sensitivity list, which is what keeps this running OR out
  /// of an `always_comb` (AGENTS.md 3.3).
  function automatic logic [31:0] sw_stat_word(
      input var logic [32*SW_STAT_COUNT-1:0] plane,
      input var logic [3:0]                  id);
    logic [31:0] acc;
    acc = 32'd0;
    for (int unsigned k = 0; k < SW_STAT_COUNT; k++) begin
      // 4'(k) is an elaboration constant, so this is a plain 16-way select.
      acc = acc | ((id == 4'(k)) ? plane[32*k +: 32] : 32'd0);
    end
    sw_stat_word = acc;
  endfunction

  /// AND-OR the one-hot per-port words down to one.  At most one slice is
  /// non-zero, so this is a selector and not a merge.
  function automatic logic [31:0] sw_stat_pick_reduce(
      input var logic [NUM_PORTS*32-1:0] v);
    logic [31:0] acc;
    acc = 32'd0;
    for (int unsigned p = 0; p < NUM_PORTS; p++) acc = acc | v[32*p +: 32];
    sw_stat_pick_reduce = acc;
  endfunction

  genvar gc;
  genvar gp;
  generate
    for (gc = 0; gc < NUM_CONSOLE; gc++) begin : g_console_stat
      /// That console's view of every port, one 32-bit word per port.
      logic [NUM_PORTS*32-1:0] pick;
      logic [NUM_PORTS*32-1:0] hit;

      for (gp = 0; gp < NUM_PORTS; gp++) begin : g_per_port
        assign pick[gp*32 +: 32] =
            sw_stat_word(stat_plane[gp*32*SW_STAT_COUNT +: 32*SW_STAT_COUNT],
                         stat_id_i[gc*4 +: 4]);
        // `PW'(gp)` is a sized cast of an elaboration constant (AGENTS.md 3.2).
        assign hit[gp*32 +: 32] =
            (stat_port_i[gc*PW +: PW] == PW'(gp)) ? pick[gp*32 +: 32] : 32'd0;
      end

      assign stat_data_o[gc*32 +: 32] = sw_stat_pick_reduce(hit);
    end
  endgenerate

endmodule : es_switch_core

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_SWITCH_CORE_SV
