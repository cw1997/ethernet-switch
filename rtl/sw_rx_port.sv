// ============================================================================
//  File        : sw_rx_port.sv
//  Description : Ingress datapath of one Layer-2 switch port.
//
//                Responsibilities
//                ------------------
//                1. Absorb the GMII octet stream into a small elastic beat FIFO.
//                   The GMII interface itself is never stalled (a mid-frame
//                   pause is illegal on GMII), so the parser drains this FIFO
//                   unconditionally and discards data when it has to.
//
//                2. Parse the frame header - destination MAC, source MAC, the
//                   length/EtherType field and an optional 802.1Q / 802.1ad tag -
//                   and resolve the frame size from it.
//
//                3. Issue the CAM lookup for the destination address and apply
//                   the ingress forwarding policy (unicast hit, broadcast,
//                   unknown unicast and group-address flooding).
//
//                4. Buffer the frame in a payload FIFO and describe it with a
//                   single tag word in a tag FIFO.  The tag is written only
//                   once the frame is known to be good, so a rejected frame is
//                   rewound out of the payload FIFO with a single write-pointer
//                   rollback.  Payload and tag can therefore never lose frame
//                   synchronisation, whatever the receive conditions are.
//
//                ------------------------------------------------------------------------
//                Frame size resolution
//                ------------------------------------------------------------------------
//                The length/EtherType field only determines the frame size for
//                a legacy 802.3 *length* field (values <= 1500).  Every modern
//                EtherType frame - IPv4, IPv6, ARP, anything - has an unknown
//                size until the PHY de-asserts TX_EN, so the length is measured
//                on the wire instead: the octet count of the whole frame minus
//                the four FCS octets is the MAC client data length.  Frames that
//                arrive with a length/EtherType field that contradicts the
//                802.3 length convention are rejected as runts or oversize
//                frames, exactly as a real bridge does.
//
//                The forwarding decision is frozen when the frame has been fully
//                received (store and forward).  That keeps the logic short and
//                leaves an obvious place to add policing, mirroring or
//                duplication later on.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_RX_PORT_SV
`define SW_RX_PORT_SV

`include "sw_defs.sv"

// The shared declarations (`SW_LEN_W`, `SW_STAT_COUNT`, `sw_tag_width`) arrive
// through the include above and are visible at compilation-unit scope, which is
// what lets them appear in a port range.  See sw_defs.sv for why a package cannot
// be used here.
module sw_rx_port #(
  /// Total number of switch ports (the port index must be < NUM_PORTS).
  parameter int unsigned NUM_PORTS      = 4,
  /// Index of this port; drives the ingress source index and the CAM learn.
  parameter int unsigned PORT_ID        = 0,
  /// MAC address owned by this port; frames sourced from it are not reflected.
  parameter logic [47:0]  PORT_MAC      = 48'h0,
  /// `clk_i` cycles per GMII octet time on this port.
  parameter int unsigned BYTE_PERIOD    = 1,
  /// Largest frame accepted, in octets (FCS excluded).
  parameter int unsigned MAX_FRAME_LEN  = 1518,
  /// Payload beats buffered per port.  Must be >= ceil(MAX_FRAME_LEN/8) or
  /// maximum-length frames are dropped as ingress overflow.
  parameter int unsigned RX_FIFO_DEPTH  = 256,
  /// Frame descriptors buffered per port.  Bounds how many complete frames
  /// may wait for the fabric.
  parameter int unsigned TAG_FIFO_DEPTH = 16,
  /// Elastic beat FIFO between the GMII adapter and the parser.
  parameter int unsigned WF_DEPTH       = 16,
  /// Unknown / group address flooding policy (elaboration-time default).
  parameter logic [1:0]  FLOOD_MODE     = 2'd1,
  /// Source address learning enable (elaboration-time default).
  parameter logic        LEARNING_EN    = 1'b1
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    link_up_i,   ///< port administratively up

  // ---- GMII receive interface (clock-enable qualified) ---------------------
  input  logic                    gmii_en_i,
  input  logic [7:0]              gmii_d_i,

  // ---- CAM lookup interface (answer valid one clock after the request) ------
  output logic                    cam_req_o,
  output logic [47:0]             cam_mac_o,
  input  logic                    cam_hit_i,
  input  logic [NUM_PORTS-1:0]    cam_port_i,

  // ---- CAM learn interface -------------------------------------------------
  output logic                    learn_o,
  output logic [47:0]             learn_mac_o,

  // ---- configuration -------------------------------------------------------
  // `cfg_ovr_i` selects the run-time configuration ports over the
  // elaboration-time defaults `FLOOD_MODE` / `LEARNING_EN`.
  input  logic [1:0]              flood_mode_i,
  input  logic                    learning_en_i,
  input  logic                    cfg_ovr_i,

  // ---- payload FIFO read side (driven by the arbiter) ---------------------
  output logic [63:0]             rd_data_o,
  output logic                    empty_o,
  input  logic                    rd_en_i,     ///< pop the next payload beat
  input  logic                    flush_i,     ///< discard everything buffered

  // ---- tag FIFO read side (driven by the arbiter) -------------------------
  // The fabric owns the read side of this FIFO: it decides which ingress
  // descriptor to consume next, so `tag_rd_en_i` is an *input* here.  The
  // descriptor has to leave the tag FIFO in the same clock the fabric registers
  // it, otherwise the FIFO stalls, the fabric keeps re-reading the head, and the
  // same frame is forwarded over and over.
  input  logic                    tag_rd_en_i,  ///< pop the head descriptor
  output logic [sw_tag_width(NUM_PORTS)-1:0] tag_rd_data_o,
  output logic                    tag_empty_o,

  // ---- statistics ----------------------------------------------------------
  output logic [32*SW_STAT_COUNT-1:0] stat_o
);

  localparam int unsigned PW    = sw_port_w(NUM_PORTS);
  localparam int unsigned TAGW  = sw_tag_width(NUM_PORTS);
  localparam int unsigned BEATW = 11;                ///< beat index width
  localparam int unsigned OCTW  = SW_LEN_W + 7;      ///< wire octet counter
  localparam int unsigned UF_W  = (RX_FIFO_DEPTH <= 2) ? 1 : $clog2(RX_FIFO_DEPTH);
  localparam int unsigned MAX_BEATS = sw_beats_of(MAX_FRAME_LEN);

  // A one-hot port bit, correctly sized for NUM_PORTS == 1 and 2 as well.
  localparam logic [NUM_PORTS-1:0] PORT_BIT_ONE = {{(NUM_PORTS-1){1'b0}}, 1'b1};

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------
  /// Copy only the first `n` octets of a beat and zero the rest.  The final
  /// beat of a frame is almost never a full 8 octets, and the unused lanes must
  /// not leak stale data into the egress FIFO.
  function automatic logic [63:0] mask_octets(input logic [63:0] d, input logic [3:0] n);
    logic [63:0] r;
    r = 64'd0;
    for (int unsigned k = 0; k < 8; k++) begin
      if (k < n) r[63 - k*8 -: 8] = d[63 - k*8 -: 8];
    end
    mask_octets = r;
  endfunction

  // --------------------------------------------------------------------------
  // 1. GMII octet adapter and elastic beat FIFO
  // --------------------------------------------------------------------------
  logic        beat_valid, beat_sof, beat_eof, beat_crc_ok;
  logic [63:0] beat_data;
  logic [3:0]  beat_octets;

  sw_gmii_rx #(
      .BYTE_PERIOD (BYTE_PERIOD)
  ) u_gmii_rx (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .gmii_en_i     (gmii_en_i & link_up_i),
      .gmii_d_i      (gmii_d_i),
      .beat_valid_o  (beat_valid),
      .beat_data_o   (beat_data),
      .beat_sof_o    (beat_sof),
      .beat_eof_o    (beat_eof),
      .beat_crc_ok_o (beat_crc_ok),
      .beat_octets_o (beat_octets)
  );

  // Elastic beat FIFO word: { valid octets, FCS verdict, eof, sof, data }
  localparam int unsigned WF_W = 64 + 4 + 3;

  logic           wf_wr_en;
  logic [WF_W-1:0] wf_wr_data;
  logic           wf_rd_en;
  logic [WF_W-1:0] wf_rd_data;
  logic           wf_empty;

  assign wf_wr_en   = beat_valid;
  assign wf_wr_data = {beat_octets, beat_crc_ok, beat_eof, beat_sof, beat_data};

  wire [63:0] w_data  = wf_rd_data[63:0];
  wire        w_sof   = wf_rd_data[64];
  wire        w_eof   = wf_rd_data[65];
  wire        w_crcok = wf_rd_data[66];
  wire [3:0]  w_oct   = wf_rd_data[67 +: 4];

  // --------------------------------------------------------------------------
  // 2. Parser state machine
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE  = 3'd0, ///< between frames
    S_HDR2  = 3'd1, ///< collecting beat 1: source MAC + length/EtherType
    S_HDR3  = 3'd2, ///< collecting beat 2: 802.1Q inner EtherType
    S_DEC   = 3'd3, ///< CAM answer available, forwarding verdict frozen
    S_PRE   = 3'd4, ///< pushing the captured header beats into the payload FIFO
    S_BODY  = 3'd5, ///< streaming the remaining beats
    S_TAIL  = 3'd6, ///< the payload is complete, only the FCS beat is left
    S_DRAIN = 3'd7  ///< discarding the remainder of a rejected frame
  } state_e;

  state_e state;

  logic [63:0]  hdr_w0, hdr_w1, hdr_w2;   ///< captured header beats
  logic [15:0]  src_hi_q;                 ///< first two octets of the source MAC
  logic         hdr_vlan_q;               ///< header carried a 802.1Q tag
  logic [15:0]  hdr_type_q;               ///< resolved (inner) length/EtherType
  sw_mac_t      dst_mac_q, src_mac_q;

  logic                 fixed_len_q;   ///< 802.3 length field governs the size
  logic [SW_LEN_W-1:0] frame_len_q;    ///< declared size (fixed) or the bound
  logic [BEATW-1:0]     last_beat_q;   ///< index of the last payload beat
  logic [BEATW-1:0]     widx;          ///< payload beats written so far
  logic [BEATW-1:0]     wr_cnt;        ///< beats written for this frame
  logic [OCTW-1:0]      oct_cnt;       ///< octets popped from the beat FIFO

  logic [NUM_PORTS-1:0] verdict_mask_q;
  logic                 verdict_flood_q;

  // --------------------------------------------------------------------------
  // 3. CAM request
  // --------------------------------------------------------------------------
  // The address must be presented in the very clock in which the request is
  // asserted, so it is taken combinationally from the beat FIFO head.
  assign cam_req_o = (state == S_IDLE) && !wf_empty && w_sof;
  assign cam_mac_o = w_data[63:16];

  // Registered CAM answer: the CAM needs one clock to respond, and the header
  // parse costs one more, so the verdict is evaluated in S_DEC.
  logic                 cam_hit_q;
  logic [NUM_PORTS-1:0] cam_port_q;

  always_ff @(posedge clk_i) begin
    cam_hit_q  <= cam_hit_i;
    cam_port_q <= cam_port_i;
  end

  // --------------------------------------------------------------------------
  // 4. Ingress forwarding policy, evaluated in S_DEC
  //
  //  * A frame whose source address is the port's own address is a reflected
  //    frame: it has come back around to the port it came from, so it is neither
  //    forwarded nor learned.
  //  * A frame whose *destination* is the port's own address and that arrived on
  //    that port has reached its destination here.  It must not be flooded out of
  //    the other ports: that would leak a unicast onto every other segment of the
  //    network.  The port's own address can never be in the CAM - the source rule
  //    above prevents it from ever being learned - so without this test the
  //    address would simply miss the lookup and be treated as an unknown unicast,
  //    which is how a frame addressed to port 2 silently appears on ports 0
  //    and 1.
  //  * The broadcast address is always flooded to every other port.
  //  * A group (multicast) address is flooded only when the policy asks for it.
  //  * A unicast address known to the CAM goes to the single learned port; if
  //    that port is the ingress port itself the frame is a unicast loop and is
  //    filtered.
  //  * A unicast address that misses in the CAM is flooded (or filtered)
  //    according to the policy.
  // --------------------------------------------------------------------------
  logic [NUM_PORTS-1:0] port_bit;
  assign port_bit = PORT_BIT_ONE << PW'(PORT_ID);

  // --------------------------------------------------------------------------
  // Effective run-time configuration.  `cfg_ovr_i` selects the run-time
  // configuration ports over the elaboration-time defaults `FLOOD_MODE` and
  // `LEARNING_EN`; the signal is resolved once here and used by both the
  // forwarding policy below and the learning logic further down.
  // --------------------------------------------------------------------------
  logic [1:0] flood_mode;
  logic       learning_en;
  assign flood_mode = cfg_ovr_i ? flood_mode_i : 2'(FLOOD_MODE);
  assign learning_en = cfg_ovr_i ? learning_en_i : LEARNING_EN;

  logic [NUM_PORTS-1:0] hit_mask;
  assign hit_mask = cam_port_q & ~port_bit;

  // Unknown-unicast and group-address flooding permission.
  logic flood_unknown_ucast;
  logic flood_group;
  always_comb begin
    case (flood_mode)
      SW_FLOOD_ALL       : begin flood_unknown_ucast = 1'b1; flood_group = 1'b1; end
      SW_FLOOD_BCAST_UKN : begin flood_unknown_ucast = 1'b1; flood_group = 1'b0; end
      default            : begin flood_unknown_ucast = 1'b0; flood_group = 1'b0; end
    endcase
  end

  // Address classification, hoisted out of the policy process below.
  logic dst_is_bcast;
  logic dst_is_group;
  assign dst_is_bcast = sw_is_broadcast(dst_mac_q);
  assign dst_is_group = sw_is_group(dst_mac_q);

  logic                 fwd_drop;
  logic [NUM_PORTS-1:0] fwd_mask;
  logic                 fwd_flood;

  always_comb begin
    fwd_mask  = '0;
    fwd_flood = 1'b0;
    fwd_drop  = 1'b1;
    if (src_mac_q != PORT_MAC) begin
      if (dst_mac_q == PORT_MAC) begin
        // Addressed to this port and arriving on this port: consumed here, never
        // leaked to the other ports.  `fwd_mask` stays zero and `fwd_drop` set.
        fwd_mask  = '0;
        fwd_flood = 1'b0;
        fwd_drop  = 1'b1;
      end else if (dst_is_bcast) begin
        fwd_mask  = ~port_bit;
        fwd_flood = 1'b1;
        fwd_drop  = 1'b0;
      end else if (dst_is_group) begin
        if (flood_group) begin
          fwd_mask  = ~port_bit;
          fwd_flood = 1'b1;
          fwd_drop  = 1'b0;
        end
      end else if (cam_hit_q) begin
        if (hit_mask != '0) begin
          fwd_mask = hit_mask;
          fwd_drop = 1'b0;
        end
      end else if (flood_unknown_ucast) begin
        fwd_mask  = ~port_bit;
        fwd_flood = 1'b1;
        fwd_drop  = 1'b0;
      end
    end
  end

  // --------------------------------------------------------------------------
  // 5. Frame geometry derived from the length / EtherType field
  // --------------------------------------------------------------------------
  logic [15:0] declared_payload;
  always_comb begin
    if (sw_is_8023_length(hdr_type_q)) begin
      // 802.3 length field: the frame is exactly this long.  Values below the
      // 802.3 minimum are zero padded by the transmitter.
      declared_payload = (hdr_type_q < 16'(SW_MIN_PAYLOAD))
                         ? 16'(SW_MIN_PAYLOAD) : hdr_type_q;
    end else begin
      // EtherType: the size is not known here, it is measured on the wire.
      declared_payload = 16'(MAX_FRAME_LEN -
                            (hdr_vlan_q ? SW_HDR_LEN_VLAN : SW_HDR_LEN));
    end
  end

  logic [16:0] len_calc;
  assign len_calc = 17'(hdr_vlan_q ? SW_HDR_LEN_VLAN : SW_HDR_LEN) +
                    {1'b0, declared_payload};

  logic [15:0] len_clamped;
  always_comb begin
    if      (len_calc > 17'(MAX_FRAME_LEN))   len_clamped = 16'(MAX_FRAME_LEN);
    else if (len_calc < 17'(SW_MIN_FRAME_LEN)) len_clamped = 16'(SW_MIN_FRAME_LEN);
    else                                      len_clamped = 16'(len_calc);
  end

  // --------------------------------------------------------------------------
  // 6. Ingress buffers
  //
  // Each port owns one payload FIFO (the frame octets, 64 bits per beat) and
  // one descriptor FIFO (one `TAGW` word per frame).  Both are fall-through on
  // the read side, so the fabric can start a transfer in the very clock in
  // which it pops the descriptor.  `data_full` / `tag_full` are needed by the
  // frame-close decision below, hence the early declaration.
  // --------------------------------------------------------------------------
  logic            data_wr_en;
  logic [63:0]     data_wr_data;
  logic            data_full;
  logic            data_undo;
  logic [UF_W:0]   data_undo_cnt;
  logic            data_flush;

  logic               tag_wr_en;
  logic [TAGW-1:0]    tag_wr_data;
  logic               tag_full;
  logic [TAGW-1:0]    tag_rd_data;
  logic               tag_empty;

  // --------------------------------------------------------------------------
  // 7. Frame close decision
  //
  // Evaluated in S_BODY and S_TAIL for the beat that carries end-of-frame.  The
  // same expressions are valid in both states, because `widx` already accounts
  // for the beats already written and `w_oct` is the octet count of the closing
  // beat itself.
  // --------------------------------------------------------------------------
  logic [16:0]  fin_wire;    ///< octets the whole frame occupied on the wire
  logic [15:0]  fin_len;     ///< MAC client data length derived from the wire
  logic [15:0]  fin_beats;   ///< payload beats the frame occupies
  logic [3:0]   fin_octets;  ///< valid octets in the final payload beat
  logic         fin_write;   ///< the closing beat still carries payload
  logic [63:0]  fin_data;    ///< closing beat, masked to `fin_octets`
  logic         fin_runt;    ///< too short, or shorter than declared
  logic         fin_ovr;     ///< too long, or longer than declared
  logic         fin_room;    ///< the closing beat and the tag still fit

  // Hoisted constant select: the number of octets in the final payload beat.
  logic [2:0]  fin_len_lo;
  assign fin_len_lo = fin_len[2:0];

  always_comb begin
    // Octets of the complete frame: everything popped so far plus the closing
    // beat, which still includes the four FCS octets.
    fin_wire = 17'(oct_cnt) + 17'(w_oct);

    if (fixed_len_q) begin
      // The 802.3 length field promised an exact size; hold it to that.
      fin_len = 16'(frame_len_q);
    end else begin
      // EtherType frame: the size is whatever arrived, minus the FCS.
      fin_len = (fin_wire > 17'(SW_FCS_LEN))
                ? 16'(fin_wire - 17'(SW_FCS_LEN)) : 16'd0;
    end

    fin_beats  = 16'((16'(fin_len) + 16'd7) >> 3);
    fin_octets = (fin_len_lo == 3'd0) ? 4'd8 : {1'b0, fin_len_lo};
    fin_write  = (widx < BEATW'(fin_beats));
    fin_data   = mask_octets(w_data, fin_octets);

    // ---- length classification --------------------------------------------
    fin_runt = 1'b0;
    fin_ovr  = 1'b0;
    if (fixed_len_q) begin
      if (fin_wire != 17'(frame_len_q) + 17'(SW_FCS_LEN)) begin
        if (fin_wire < 17'(frame_len_q) + 17'(SW_FCS_LEN)) fin_runt = 1'b1;
        else                                              fin_ovr  = 1'b1;
      end
    end else begin
      if      (fin_len < 16'(SW_MIN_FRAME_LEN)) fin_runt = 1'b1;
      else if (fin_len > 16'(MAX_FRAME_LEN))   fin_ovr  = 1'b1;
    end
    // A frame that cannot possibly fit into the payload buffer is oversize.
    if (16'(MAX_BEATS) < fin_beats) fin_ovr = 1'b1;

    // ---- buffer space ------------------------------------------------------
    // A closing beat is only written when it still carries payload; a pure FCS
    // beat is consumed without touching the payload FIFO.
    fin_room = (fin_write ? !data_full : 1'b1) && !tag_full;
  end

  // --------------------------------------------------------------------------
  // 8. Payload/tag FIFO read side and beat consumption
  // --------------------------------------------------------------------------
  assign tag_rd_data_o = tag_rd_data;
  assign tag_empty_o   = tag_empty;

  // A hard flush must never cut a frame in half, so it is only accepted while
  // the parser is not driving a payload FIFO write.
  assign data_flush = flush_i && ((state == S_IDLE)  || (state == S_HDR2) ||
                                  (state == S_HDR3) || (state == S_DEC)  ||
                                  (state == S_DRAIN));

  assign data_undo_cnt = (UF_W+1)'(wr_cnt);

  // Beat consumption.
  //
  // A beat is only popped when its octets are actually absorbed.  Two states
  // must *not* pop even when the FIFO is not empty:
  //
  //   S_DEC - the forwarding verdict is frozen here; the beat at the head is
  //           the first payload beat and is written to the payload FIFO in
  //           S_BODY, so popping it here would silently drop it.
  //   S_PRE - the header beats were already captured into `hdr_w0/1/2` and are
  //           pushed from those registers, so the FIFO head is left alone.
  //
  // S_BODY additionally waits for payload FIFO space, because a full buffer
  // cannot accept the next beat.
  logic pop;
  always_comb begin
    case (state)
      S_DEC, S_PRE : pop = 1'b0;
      S_BODY       : pop = !wf_empty && !data_full;
      default      : pop = !wf_empty;
    endcase
  end
  assign wf_rd_en = pop;

  // --------------------------------------------------------------------------
  // 9. Frame tag assembly
  // --------------------------------------------------------------------------
  // The descriptor length comes from the declared size while the frame is
  // being received, and from the size measured on the wire once the frame
  // closes.  For an EtherType frame only the latter is meaningful.
  logic [SW_LEN_W-1:0] tag_len_src;
  assign tag_len_src = ((state == S_BODY) || (state == S_TAIL))
                         ? SW_LEN_W'(fin_len) : frame_len_q;

  // The field order below is the mirror image of the `sw_tag_*_lsb()` helpers in
  // the package, so the two cannot drift apart: the package defines the bit
  // offsets and this concatenation defines the word, in the same order.
  //   { drop, flood, len[SW_LEN_W-1:0], src[PW-1:0], dst_mask[NUM_PORTS-1:0] }
  logic [TAGW-1:0] tag;
  assign tag = { 1'b0,              // ingress filtering already applied
                 verdict_flood_q,
                 SW_LEN_W'(tag_len_src),
                 PW'(PORT_ID),
                 verdict_mask_q };

  // --------------------------------------------------------------------------
  // 10. Statistics counters
  // --------------------------------------------------------------------------
  logic [31:0] cnt_frames, cnt_octets, cnt_filtered, cnt_crc, cnt_runt, cnt_ovr;
  logic [31:0] cnt_ovf;   ///< ingress buffer exhaustion (distinct from oversize)

  assign stat_o[32*int'(SW_STAT_RX_FRAMES)  +: 32] = cnt_frames;
  assign stat_o[32*int'(SW_STAT_RX_OCTETS)  +: 32] = cnt_octets;
  assign stat_o[32*int'(SW_STAT_RX_FILTERED)+: 32] = cnt_filtered;
  assign stat_o[32*int'(SW_STAT_RX_CRC_ERR) +: 32] = cnt_crc;
  assign stat_o[32*int'(SW_STAT_RX_RUNT)    +: 32] = cnt_runt;
  assign stat_o[32*int'(SW_STAT_RX_OVERSIZE)+: 32] = cnt_ovr;
  // Ingress buffer exhaustion is reported separately from an oversize frame,
  // because it points at a buffer that is too small rather than at a bad frame.
  assign stat_o[32*int'(SW_STAT_RX_OVERFLOW)+: 32] = cnt_ovf;
  // The remaining counters are produced by the transmit path, the scheduler
  // and the CAM; the top level sums them in.
  for (genvar gk = 0; gk < int'(SW_STAT_COUNT); gk++) begin : g_stat_zero
    if ((gk != int'(SW_STAT_RX_FRAMES)) && (gk != int'(SW_STAT_RX_OCTETS)) &&
        (gk != int'(SW_STAT_RX_FILTERED)) && (gk != int'(SW_STAT_RX_CRC_ERR)) &&
        (gk != int'(SW_STAT_RX_RUNT)) && (gk != int'(SW_STAT_RX_OVERSIZE)) &&
        (gk != int'(SW_STAT_RX_OVERFLOW))) begin : g_stat_zero_other
      assign stat_o[32*gk +: 32] = 32'd0;
    end
  end

  // --------------------------------------------------------------------------
  // 10. Main parser
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state           <= S_IDLE;
      hdr_w0          <= 64'd0;
      hdr_w1          <= 64'd0;
      hdr_w2          <= 64'd0;
      src_hi_q        <= 16'd0;
      hdr_vlan_q      <= 1'b0;
      hdr_type_q      <= 16'd0;
      dst_mac_q       <= 48'd0;
      src_mac_q       <= 48'd0;
      fixed_len_q     <= 1'b0;
      frame_len_q     <= '0;
      last_beat_q     <= '0;
      widx            <= '0;
      wr_cnt          <= '0;
      oct_cnt         <= '0;
      verdict_mask_q  <= '0;
      verdict_flood_q <= 1'b0;
      data_wr_en      <= 1'b0;
      data_wr_data    <= 64'd0;
      data_undo       <= 1'b0;
      tag_wr_en       <= 1'b0;
      tag_wr_data     <= '0;
      learn_o         <= 1'b0;
      learn_mac_o     <= 48'd0;
      cnt_frames      <= 32'd0;
      cnt_octets      <= 32'd0;
      cnt_filtered    <= 32'd0;
      cnt_crc         <= 32'd0;
      cnt_runt        <= 32'd0;
      cnt_ovr         <= 32'd0;
      cnt_ovf         <= 32'd0;
    end else begin
      data_wr_en <= 1'b0;
      data_undo  <= 1'b0;
      tag_wr_en  <= 1'b0;
      learn_o    <= 1'b0;

      // Every octet that leaves the elastic FIFO is counted, FCS included.
      if (pop) oct_cnt <= oct_cnt + OCTW'(w_oct);

      case (state)
        // ---------------------------------------------------------------
        // The 14 octet MAC header does not line up with the 8 octet beat
        // boundary, so it is stitched together from two beats:
        //
        //   beat 0 : dst[0..5]      src[0..1]
        //   beat 1 : src[2..5]      l2type[0..1]  payload[0..5]
        //
        // with octet 0 of a beat in [63:56].  The destination address therefore
        // comes entirely from beat 0, while the source address and the
        // length/EtherType field straddle the boundary.  Getting this split
        // wrong shifts every header field by two octets, so it is spelled out
        // here rather than left to a reader.
        S_IDLE: begin
          wr_cnt <= '0;
          if (pop && w_sof) begin
            hdr_w0    <= w_data;
            dst_mac_q <= w_data[63:16];              // dst[0..5]
            src_hi_q  <= w_data[15:0];               // src[0..1]
            oct_cnt   <= OCTW'(w_oct);
            state     <= S_HDR2;
          end
        end

        // ---------------------------------------------------------------
        S_HDR2: begin
          if (pop) begin
            hdr_w1     <= w_data;
            src_mac_q  <= {src_hi_q, w_data[63:32]};  // src[0..1] ++ src[2..5]
            hdr_type_q <= w_data[31:16];              // l2type[0..1]
            hdr_vlan_q <= sw_is_vlan_type(w_data[31:16]);
            state      <= sw_is_vlan_type(w_data[31:16]) ? S_HDR3 : S_DEC;
          end
        end

        // ---------------------------------------------------------------
        // 802.1Q / 802.1ad: the real length or EtherType follows the 2 octet tag
        // control information, which straddles the beat boundary in the same way
        // as the header above:
        //
        //   beat 1 : ... l2type[0..1]  tci[0..1]  payload[0..5]
        //   beat 2 : inner_type[0..1]  payload[6..13]
        S_HDR3: begin
          if (pop) begin
            hdr_w2     <= w_data;
            hdr_type_q <= w_data[63:48];              // inner_type[0..1]
            state      <= S_DEC;
          end
        end

        // ---------------------------------------------------------------
        // The CAM answer was requested two clocks ago and is available now,
        // so the forwarding verdict can be frozen before a single payload
        // beat has been committed.
        S_DEC: begin
          verdict_mask_q  <= fwd_mask;
          verdict_flood_q <= fwd_flood;
          fixed_len_q     <= sw_is_8023_length(hdr_type_q);
          frame_len_q     <= fixed_len_q ? SW_LEN_W'(len_clamped)
                                         : SW_LEN_W'(MAX_FRAME_LEN);
          last_beat_q     <= BEATW'((16'(len_clamped) + 16'd7) >> 3) - BEATW'(1);
          widx            <= '0;
          if (fwd_drop) begin
            // Known-doomed frame: never buffer it at all.
            cnt_filtered <= cnt_filtered + 32'd1;
            state        <= S_DRAIN;
          end else begin
            state <= S_PRE;
          end
        end

        // ---------------------------------------------------------------
        // Push the two (or three) captured header beats into the payload FIFO.
        S_PRE: begin
          if (data_full) begin
            // The header could not even be buffered: ingress congestion.
            cnt_ovf <= cnt_ovf + 32'd1;
            state   <= S_DRAIN;
          end else if (widx == BEATW'(0)) begin
            data_wr_en   <= 1'b1;
            data_wr_data <= hdr_w0;
            wr_cnt       <= wr_cnt + BEATW'(1);
            widx         <= BEATW'(1);
          end else if (widx == BEATW'(1)) begin
            data_wr_en   <= 1'b1;
            data_wr_data <= hdr_w1;
            wr_cnt       <= wr_cnt + BEATW'(1);
            widx         <= BEATW'(2);
          end else if (hdr_vlan_q && (widx == BEATW'(2))) begin
            data_wr_en   <= 1'b1;
            data_wr_data <= hdr_w2;
            wr_cnt       <= wr_cnt + BEATW'(1);
            widx         <= BEATW'(3);
          end else begin
            state <= S_BODY;
          end
        end

        // ---------------------------------------------------------------
        // Stream the remaining payload beats.  The frame ends on the beat the
        // PHY closes it with; the size is then checked against the declared
        // geometry (802.3 length field) or simply measured (EtherType).
        S_BODY: begin
          if (pop) begin
            if (w_eof) begin
              if (!w_crcok) begin
                // Frame check sequence mismatch: not forwarded.
                cnt_crc   <= cnt_crc + 32'd1;
                data_undo <= 1'b1;
                state     <= S_IDLE;
              end else if (fin_runt) begin
                cnt_runt   <= cnt_runt + 32'd1;
                data_undo  <= 1'b1;
                state      <= S_IDLE;
              end else if (fin_ovr) begin
                cnt_ovr    <= cnt_ovr  + 32'd1;
                data_undo  <= 1'b1;
                state      <= S_IDLE;
              end else if (!fin_room) begin
                // The closing beat or the tag descriptor does not fit: the
                // ingress buffer is too small for this traffic, not the frame
                // being malformed.
                cnt_ovf    <= cnt_ovf  + 32'd1;
                data_undo  <= 1'b1;
                state      <= S_IDLE;
              end else begin
                if (fin_write) begin
                  data_wr_en   <= 1'b1;
                  data_wr_data <= fin_data;
                  wr_cnt       <= wr_cnt + BEATW'(1);
                end
                tag_wr_en   <= 1'b1;
                tag_wr_data <= tag;
                learn_o     <= learning_en && sw_is_unicast(src_mac_q) &&
                               (src_mac_q != PORT_MAC);
                learn_mac_o <= src_mac_q;
                cnt_frames  <= cnt_frames + 32'd1;
                cnt_octets  <= cnt_octets + {21'd0, fin_len[10:0]};
                state       <= S_IDLE;
              end
            end else if (fixed_len_q && (widx == last_beat_q)) begin
              // The declared payload ended exactly on a beat boundary, so the
              // four FCS octets arrive in a beat of their own.
              data_wr_en   <= 1'b1;
              data_wr_data <= w_data;
              wr_cnt       <= wr_cnt + BEATW'(1);
              widx         <= widx + BEATW'(1);
              state        <= S_TAIL;
            end else if (widx >= BEATW'(MAX_BEATS)) begin
              // Longer than the largest configurable frame: stop buffering.
              cnt_ovr <= cnt_ovr + 32'd1;
              state   <= S_DRAIN;
            end else begin
              data_wr_en   <= 1'b1;
              data_wr_data <= w_data;
              wr_cnt       <= wr_cnt + BEATW'(1);
              widx         <= widx + BEATW'(1);
            end
          end
        end

        // ---------------------------------------------------------------
        // Every payload beat has been written; only the FCS octets are left.
        // They never enter the payload FIFO, they only carry the verdict and
        // the total octet count that the size check needs.
        S_TAIL: begin
          if (pop) begin
            if (!w_eof) begin
              // More octets on the wire than the header declared: malformed.
              cnt_ovr   <= cnt_ovr + 32'd1;
              data_undo <= 1'b1;
              state     <= S_IDLE;
            end else if (!w_crcok) begin
              cnt_crc   <= cnt_crc + 32'd1;
              data_undo <= 1'b1;
              state     <= S_IDLE;
            end else if (fin_runt || fin_ovr) begin
              if (fin_runt) cnt_runt <= cnt_runt + 32'd1;
              else          cnt_ovr  <= cnt_ovr  + 32'd1;
              data_undo <= 1'b1;
              state     <= S_IDLE;
            end else if (!tag_full) begin
              // `fin_write` is false here by construction: the payload is
              // complete, the closing beat carried FCS octets only.
              tag_wr_en   <= 1'b1;
              tag_wr_data <= tag;
              learn_o     <= learning_en && sw_is_unicast(src_mac_q) &&
                             (src_mac_q != PORT_MAC);
              learn_mac_o <= src_mac_q;
              cnt_frames  <= cnt_frames + 32'd1;
              cnt_octets  <= cnt_octets + {21'd0, fin_len[10:0]};
              state       <= S_IDLE;
            end else begin
              cnt_ovr   <= cnt_ovr + 32'd1;
              data_undo <= 1'b1;
              state     <= S_IDLE;
            end
          end
        end

        // ---------------------------------------------------------------
        // Discard the remainder of a rejected frame.  `wr_cnt` does not move
        // while draining, so the whole partial frame leaves the payload FIFO
        // in one rewind as soon as the end-of-frame beat is seen.
        S_DRAIN: begin
          if (pop && w_eof) begin
            data_undo <= 1'b1;
            state     <= S_IDLE;
          end
        end

        // ---------------------------------------------------------------
        default: state <= S_IDLE;
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // 11. Storage instances
  // --------------------------------------------------------------------------
  logic        data_rd_en;
  logic [63:0] data_rd_data;

  assign data_rd_en = rd_en_i;

  /* verilator lint_off PINCONNECTEMPTY */
  sw_sync_fifo #(
      .WIDTH (64),
      .DEPTH (RX_FIFO_DEPTH)
  ) u_data_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .undo_i    (data_undo),
      .undo_cnt_i(data_undo_cnt),
      .flush_i   (data_flush),
      .wr_en_i   (data_wr_en),
      .wr_data_i (data_wr_data),
      .full_o    (data_full),
      .free_o    (),
      .rd_en_i   (data_rd_en),
      .rd_data_o (data_rd_data),
      .empty_o   (empty_o)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  assign rd_data_o = data_rd_data;

  /* verilator lint_off PINCONNECTEMPTY */
  sw_sync_fifo #(
      .WIDTH (WF_W),
      .DEPTH (WF_DEPTH)
  ) u_wf (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .undo_i    (1'b0),
      .undo_cnt_i('0),
      .flush_i   (1'b0),
      .wr_en_i   (wf_wr_en),
      .wr_data_i (wf_wr_data),
      .full_o    (),     // the parser drains this FIFO unconditionally
      .free_o    (),
      .rd_en_i   (wf_rd_en),
      .rd_data_o (wf_rd_data),
      .empty_o   (wf_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  /* verilator lint_off PINCONNECTEMPTY */
  sw_sync_fifo #(
      .WIDTH (TAGW),
      .DEPTH (TAG_FIFO_DEPTH)
  ) u_tag_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .undo_i    (1'b0),
      .undo_cnt_i('0),
      .flush_i   (1'b0),
      .wr_en_i   (tag_wr_en),
      .wr_data_i (tag_wr_data),
      .full_o    (tag_full),
      .free_o    (),
      .rd_en_i   (tag_rd_en_i),
      .rd_data_o (tag_rd_data),
      .empty_o   (tag_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

endmodule : sw_rx_port

`endif // SW_RX_PORT_SV
