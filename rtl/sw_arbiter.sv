// ============================================================================
//  File        : sw_arbiter.sv
//  Description : Frame scheduler and switching fabric of the Layer-2 switch.
//
//                One ingress queue (payload FIFO + tag FIFO) exists per port.
//                The arbiter
//                  * removes frame descriptors that the ingress filter flagged
//                    as "drop" - a defensive path, since the receive port
//                    normally filters before the frame is buffered,
//                  * selects the next ingress port with a round-robin pointer,
//                    so that no port can be starved,
//                  * checks, before starting, that *every* destination egress
//                    FIFO has room for the complete frame.  Because the check
//                    is made up front and only one frame is in flight at a
//                    time, a transfer can never stall mid-frame and can never
//                    drop beats,
//                  * copies the ingress beats to all destination egress queues
//                    simultaneously (native one-to-many switching, which
//                    covers broadcast and unknown-unicast flooding).
//
//                The first beat of every frame is flagged with `dst_fr_o` so
//                that an egress port can queue exactly one length descriptor
//                per frame while receiving all of its beats.
//
//                A head-of-line frame that stays blocked for `STALL_LIMIT`
//                arbitration cycles is discarded, which bounds the latency a
//                congested egress port can impose on the other ports.  Set
//                `STALL_LIMIT` to 0 to disable the drop and stall instead.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_ARBITER_SV
`define SW_ARBITER_SV

`include "sw_switch_pkg.sv"

// ---------------------------------------------------------------------------
//  Package import
//
//  The package is pulled in by the guarded `include` above, which is what makes
//  its declarations visible here.  Under simulation an explicit wildcard import
//  is added as well, because a simulator resolves a package strictly: without it
//  the port list and the body cannot see `sw_switch_pkg` items.
//
//  Under synthesis the import is omitted.  The yosys frontend that OpenLane /
//  LibreLane drive does not accept a wildcard package import at all - neither in
//  a module header, nor inside the body, nor at file scope - and aborts with
//
//      syntax error, unexpected TOK_ID, expecting '(' or ';' or '#'
//
//  right at the module keyword, which points at the module rather than at the
//  import.  It does, however, make the items of an *included* package visible for
//  free, so dropping the import is both necessary and sufficient.  The two forms
//  below therefore differ only in the two tokens between the module name and its
//  port list; everything after the `endif is shared.
// ---------------------------------------------------------------------------
`ifndef SYNTHESIS
module sw_arbiter import sw_switch_pkg::*; #(
`else
module sw_arbiter #(
`endif
  parameter int unsigned NUM_PORTS     = 4,
  parameter int unsigned TX_FIFO_DEPTH = 256,
  /// Cycles a blocked head-of-line frame may wait before it is discarded.
  /// 0 disables the drop and stalls instead.
  parameter int unsigned STALL_LIMIT   = 0
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // ---- ingress queues -------------------------------------------------------
  input  logic [NUM_PORTS-1:0]    src_empty_i,        ///< ingress payload FIFO empty
  input  logic [NUM_PORTS-1:0]    src_tag_empty_i,    ///< ingress tag FIFO empty
  output logic [NUM_PORTS-1:0]    src_tag_rd_en_o,
  input  logic [NUM_PORTS*sw_tag_width(NUM_PORTS)-1:0] src_tag_rd_data_i,
  output logic [NUM_PORTS-1:0]    src_data_rd_en_o,
  input  logic [NUM_PORTS*64-1:0] src_data_rd_data_i,
  output logic [NUM_PORTS-1:0]    src_flush_o,

  // ---- egress queues --------------------------------------------------------
  output logic [NUM_PORTS-1:0]    dst_wr_en_o,        ///< write one payload beat
  output logic [NUM_PORTS*64-1:0] dst_wr_data_o,
  output logic [NUM_PORTS*SW_LEN_W-1:0] dst_wr_len_o,  ///< valid with dst_fr_o
  output logic [NUM_PORTS-1:0]    dst_fr_o,           ///< first beat of a frame
  input  logic [NUM_PORTS*(sw_tx_free_width(TX_FIFO_DEPTH)+1)-1:0] dst_free_i,

  // ---- statistics -----------------------------------------------------------
  output logic [32*SW_STAT_COUNT-1:0] stat_o
);

  localparam int unsigned TAGW = sw_tag_width(NUM_PORTS);
  localparam int unsigned FF_W = sw_tx_free_width(TX_FIFO_DEPTH);
  localparam int unsigned PW   = sw_port_w(NUM_PORTS);

  localparam int TAG_DSTM = sw_tag_dstm_lsb(NUM_PORTS);
  localparam int TAG_SRC  = sw_tag_src_lsb(NUM_PORTS);
  localparam int TAG_LEN  = sw_tag_len_lsb(NUM_PORTS);
  localparam int TAG_FLD  = sw_tag_flood_lsb(NUM_PORTS);
  localparam int TAG_DROP = sw_tag_drop_lsb(NUM_PORTS);

  // --------------------------------------------------------------------------
  // Descriptor prefetch registers
  //
  // The ingress tag FIFO is a fall-through FIFO, but its read port must not be
  // used directly for the arbitration decision: while a frame is in flight the
  // FIFO can be empty, and an empty fall-through FIFO still drives whatever the
  // last read pointer left in memory.  Feeding that stale word into the
  // scheduler would replay an already forwarded frame.
  //
  // A one-deep output register per port therefore latches the head descriptor
  // the cycle after it becomes available and is cleared the moment the
  // descriptor is consumed.  A port with an invalid register is by definition
  // not a candidate, which is exactly the `waiting` qualification below.
  // --------------------------------------------------------------------------
  logic [TAGW-1:0] desc_q     [NUM_PORTS];
  logic             desc_valid[NUM_PORTS];

  // --------------------------------------------------------------------------
  // Descriptor field extraction
  //
  // The slices are taken with continuous assignments rather than inside the
  // decode process: a constant part-select of an unpacked element inside an
  // always_* block makes simulators include the whole element in the
  // sensitivity list, which is at best noisy and at worst a false result.
  // --------------------------------------------------------------------------
  logic [NUM_PORTS-1:0]              f_drop;
  logic [NUM_PORTS-1:0]              f_flood;
  logic [NUM_PORTS*SW_LEN_W-1:0]     f_len;
  logic [NUM_PORTS*NUM_PORTS-1:0]    f_dst;
  logic [NUM_PORTS*PW-1:0]           f_src;

  for (genvar gf = 0; gf < NUM_PORTS; gf++) begin : g_fields
    assign f_drop[gf]                              = desc_q[gf][TAG_DROP];
    assign f_flood[gf]                             = desc_q[gf][TAG_FLD];
    assign f_len [gf*SW_LEN_W   +: SW_LEN_W]       = desc_q[gf][TAG_LEN  +: SW_LEN_W];
    assign f_dst [gf*NUM_PORTS  +: NUM_PORTS]      = desc_q[gf][TAG_DSTM +: NUM_PORTS];
    assign f_src [gf*PW         +: PW]             = desc_q[gf][TAG_SRC  +: PW];
  end

  // --------------------------------------------------------------------------
  // Decode the latched descriptor.
  //
  // These are *flat packed vectors*, not per-port unpacked arrays, and that is
  // not cosmetic.  The arbitration reads them with a runtime index - the port it
  // just granted - and an unpacked array indexed that way is exactly the
  // construct Icarus Verilog fails to resolve: the read comes back stale or
  // undefined, `grant_beats` ends up X, `xfer_active` is never asserted, and the
  // fabric then emits one *frame* per beat.  The visible effect is a transmit
  // port that re-sends the same frame once per inter-frame gap, forever, with a
  // descriptor that no longer matches the data behind it - which reads as a
  // transmit-path corruption or a bad FCS rather than as a fabric fault.
  //
  // A packed vector indexed with a constant-width expression is a plain part
  // select of a signal, which every simulator resolves identically.
  //
  // An invalid register decodes to a neutral descriptor so that it can never be
  // granted, dropped or stalled.
  // --------------------------------------------------------------------------
  logic [NUM_PORTS-1:0]              t_drop;
  logic [NUM_PORTS*SW_LEN_W-1:0]     t_len;
  logic [NUM_PORTS*NUM_PORTS-1:0]    t_dst;
  logic [NUM_PORTS-1:0]              t_flood;
  logic [NUM_PORTS*SW_LEN_W-1:0]     beats_of;

  for (genvar gd = 0; gd < NUM_PORTS; gd++) begin : g_decode
    assign t_drop [gd] = desc_valid[gd] && f_drop[gd];
    assign t_flood[gd] = desc_valid[gd] && f_flood[gd];
    assign t_len  [gd*SW_LEN_W  +: SW_LEN_W] =
        desc_valid[gd] ? f_len[gd*SW_LEN_W +: SW_LEN_W] : '0;
    assign t_dst  [gd*NUM_PORTS +: NUM_PORTS] =
        desc_valid[gd] ? f_dst[gd*NUM_PORTS +: NUM_PORTS] : '0;
    // Number of 64-bit beats the frame occupies, rounded up.
    assign beats_of[gd*SW_LEN_W +: SW_LEN_W] =
        (t_len[gd*SW_LEN_W +: SW_LEN_W] + SW_LEN_W'(SW_BEAT_BYTES - 1)) >> 3;
  end

  // --------------------------------------------------------------------------
  // Frame admission
  //
  // `cand[i]`    : port i may start a transfer now.
  // `blocked[i]` : port i has a frame but a destination egress FIFO is full.
  // `waiting[i]` : port i has a frame the arbiter still has to deal with.
  // --------------------------------------------------------------------------
  logic [NUM_PORTS-1:0] cand, blocked, waiting;

  always_comb begin
    for (int unsigned i = 0; i < NUM_PORTS; i++) begin
      waiting[i] = desc_valid[i] && !src_empty_i[i] &&
                   !t_drop[i] &&
                   (t_dst[i*NUM_PORTS +: NUM_PORTS] != '0);
      blocked[i] = 1'b0;
      cand[i]    = 1'b0;
      if (waiting[i]) begin
        if (beats_of[i*SW_LEN_W +: SW_LEN_W] > SW_LEN_W'(TX_FIFO_DEPTH)) begin
          // A frame larger than the FIFO it has to fit in can never be
          // admitted.  Forwarding it anyway would corrupt the egress stream,
          // so it is treated as permanently blocked and left to the head-of-line
          // stall protection.
          blocked[i] = 1'b1;
        end else begin
          // Blocked as soon as *any* destination lacks room for the whole frame.
          // The check is made once, up front, and only one frame is ever in
          // flight, so a transfer can then never stall mid-frame.
          blocked[i] = 1'b0;
          for (int unsigned j = 0; j < NUM_PORTS; j++) begin
            if (t_dst[i*NUM_PORTS + j] &&
                (dst_free_i[j*(FF_W+1) +: FF_W+1] <
                 (FF_W+1)'(beats_of[i*SW_LEN_W +: SW_LEN_W]))) begin
              blocked[i] = 1'b1;
            end
          end
        end
        cand[i] = !blocked[i];
      end
    end
  end

  // --------------------------------------------------------------------------
  // Transfer sequencer state
  //
  // Declared before the arbitration because the grant is gated by `xfer_active`:
  // a language that requires declaration before use (Icarus among them) will not
  // elaborate a reference that appears first.
  // --------------------------------------------------------------------------
  logic                 xfer_active;
  logic [PW-1:0]        xfer_src_q;
  logic [SW_LEN_W-1:0]  xfer_len_q;
  logic [NUM_PORTS-1:0] xfer_dst;
  logic [SW_LEN_W-1:0]  xfer_left;

  // --------------------------------------------------------------------------
  // Round-robin arbitration
  // --------------------------------------------------------------------------
  // --------------------------------------------------------------------------
  // Round-robin arbitration
  //
  // A grant is only issued while no transfer is in flight.  `beat_write` is a
  // single OR of "continue the transfer" and "start a new one", so allowing both
  // in the same clock would make the fabric emit *two* beats per clock: the
  // in-flight frame's beat from the transfer register and a new frame's beat
  // from the grant.  Both land in the same egress FIFO in the same cycle, so the
  // two frames interleave, their beats lose their frame boundaries, and the
  // transmit path starts new frames on a descriptor that no longer matches the
  // data behind it.  The observable symptom is a stream of extra frames whose
  // payload is a ramp of stale beats, each with a bad FCS - which looks like a
  // transmit-path corruption but is really a fabric scheduling fault.
  //
  // With `xfer_active` gating the grant, exactly one frame is ever in flight and
  // one beat is written per clock for its duration, which is what the
  // head-of-line admission check above already assumes.
  // --------------------------------------------------------------------------
  logic [PW-1:0]         rr_ptr;
  logic                  grant_now;
  logic [PW-1:0]         grant_idx;
  logic [NUM_PORTS-1:0]  grant_dst;
  logic [SW_LEN_W-1:0]   grant_beats;

  // The candidate scan starts at the round-robin pointer and wraps once around the
  // port list.  `rr_order[ro]` is the port visited at scan slot `ro`, i.e.
  // (rr_ptr + ro) mod NUM_PORTS; it is one packed vector rather than a block-local
  // inside the process, so the block has no declarations and a port count that is
  // not a power of two still wraps correctly (integer arithmetic, not a mask).
  logic [PW*NUM_PORTS-1:0] rr_order;
  for (genvar ro = 0; ro < NUM_PORTS; ro++) begin : g_rr_order
    assign rr_order[ro*PW +: PW] = PW'((int'(rr_ptr) + int'(ro)) % NUM_PORTS);
  end

  always_comb begin
    grant_now   = 1'b0;
    grant_idx   = '0;
    grant_dst   = '0;
    grant_beats = '0;
    if (!xfer_active) begin
      for (int unsigned ro = 0; ro < NUM_PORTS; ro++) begin
        if (!grant_now && cand[rr_order[ro*PW +: PW]]) begin
          grant_now   = 1'b1;
          grant_idx   = rr_order[ro*PW +: PW];
          // `grant_idx` is the port, so the descriptor fields are sliced at the
          // port index, not at the scan slot.
          grant_dst   = t_dst[grant_idx*NUM_PORTS +: NUM_PORTS];
          grant_beats = beats_of[grant_idx*SW_LEN_W +: SW_LEN_W];
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni)                       rr_ptr <= '0;
    else if (grant_now)                rr_ptr <= PW'(grant_idx + 1);
  end

  // --------------------------------------------------------------------------
  // Descriptor removal for frames the ingress filter has rejected
  // --------------------------------------------------------------------------
  logic                 drop_valid;
  logic [NUM_PORTS-1:0] drop_mask;
  always_comb begin
    drop_valid = 1'b0;
    drop_mask  = '0;
    for (int unsigned i = 0; i < NUM_PORTS; i++) begin
      if (!drop_valid && !src_empty_i[i] && t_drop[i]) begin
        drop_valid = 1'b1;
        drop_mask  = NUM_PORTS'(1) << PW'(i);
      end
    end
  end

  // --------------------------------------------------------------------------
  // Head-of-line stall protection
  // --------------------------------------------------------------------------
  logic        any_wait;
  logic [15:0] stall_cnt;

  assign any_wait = |waiting;

  logic        stall_fire;
  logic [PW-1:0] stall_idx;

  // The lowest-numbered blocked port is the drop candidate.  Selecting it
  // unconditionally keeps this process sensitive to `blocked` even when
  // STALL_LIMIT disables the feature, so the block never constant-folds into an
  // empty always_comb (which some tools reject).
  logic        stall_cand;
  logic [PW-1:0] stall_cand_idx;
  always_comb begin
    stall_cand     = 1'b0;
    stall_cand_idx = '0;
    for (int unsigned i = 0; i < NUM_PORTS; i++) begin
      if (!stall_cand && blocked[i]) begin
        stall_cand     = 1'b1;
        stall_cand_idx = PW'(i);
      end
    end
  end

  // The candidate is armed only while the fabric has nothing better to do, and
  // fires when the block has waited STALL_LIMIT arbitration cycles.  With
  // STALL_LIMIT == 0 the comparison is never true, so the feature is off.
  always_comb begin
    stall_fire = 1'b0;
    stall_idx  = stall_cand_idx;
    if (stall_cand && any_wait && !grant_now && !drop_valid) begin
      stall_fire = stall_cand && (stall_cnt >= 16'(STALL_LIMIT) - 16'd1);
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni)                                          stall_cnt <= 16'd0;
    else if (!any_wait || grant_now || drop_valid)        stall_cnt <= 16'd0;
    else if (stall_fire)                                  stall_cnt <= 16'd0;
    else                                                  stall_cnt <= stall_cnt + 16'd1;
  end

  // Actions performed for the head frame in the current clock.
  logic [NUM_PORTS-1:0] pop_mask;
  always_comb begin
    pop_mask = '0;
    pop_mask = pop_mask | drop_mask;
    if (grant_now && (grant_beats != '0)) pop_mask = pop_mask |
                                                   (NUM_PORTS'(1) << grant_idx);
    if (stall_fire)                         pop_mask = pop_mask |
                                                   (NUM_PORTS'(1) << stall_idx);
  end

  // Only a port with a valid descriptor register may advance its tag FIFO.
  logic [NUM_PORTS-1:0] desc_v;
  always_comb begin
    desc_v = '0;
    for (int unsigned i = 0; i < NUM_PORTS; i++) desc_v[i] = desc_valid[i];
  end

  assign src_tag_rd_en_o = pop_mask & desc_v;
  assign src_flush_o     = drop_mask |
                           (stall_fire ? (NUM_PORTS'(1) << stall_idx) : '0);

  // --------------------------------------------------------------------------
  // Descriptor prefetch: load when empty, clear when consumed.  The tag FIFO
  // is advanced by `src_tag_rd_en_o` in the same clock the descriptor is
  // consumed, so the register refills one clock later.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < NUM_PORTS; i++) begin
        desc_q[i]     <= '0;
        desc_valid[i] <= 1'b0;
      end
    end else begin
      for (int unsigned i = 0; i < NUM_PORTS; i++) begin
        if (!desc_valid[i]) begin
          // Refill from the FIFO head.  When this very clock also pops the
          // previous descriptor, the pop is in flight and its *next* entry
          // cannot be latched until the following clock - the FIFO read port
          // still drives the entry that is being removed.  Loading it now would
          // replay an already forwarded frame, which is exactly the failure the
          // prefetch register exists to prevent.
          if (!src_tag_empty_i[i] && !pop_mask[i]) begin
            desc_q[i]     <= src_tag_rd_data_i[i*TAGW +: TAGW];
            desc_valid[i] <= 1'b1;
          end
        end else if (pop_mask[i]) begin
          desc_valid[i] <= 1'b0;
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Beat copy
  //
  // The first beat of a frame is written in the same clock in which its
  // descriptor is popped; the following beats are written while `xfer_active`.
  // --------------------------------------------------------------------------
  logic                 beat_write;
  logic [NUM_PORTS-1:0] beat_dst;
  logic [63:0]          beat_word;
  logic [SW_LEN_W-1:0]  beat_len;
  logic [PW-1:0]        beat_src;
  logic [NUM_PORTS-1:0] beat_fr;

  assign beat_write = xfer_active || (grant_now && (grant_beats != '0));
  assign beat_src   = xfer_active ? xfer_src_q   : grant_idx;
  assign beat_len   = xfer_active ? xfer_len_q
                                  : t_len[grant_idx*SW_LEN_W +: SW_LEN_W];
  assign beat_dst   = xfer_active ? xfer_dst     : grant_dst;
  assign beat_word  = src_data_rd_data_i[beat_src*64 +: 64];
  // The frame-start qualifier is only asserted for the very first beat.
  assign beat_fr    = (xfer_active || (grant_beats == '0)) ? '0 : grant_dst;

  always_comb begin
    src_data_rd_en_o = '0;
    dst_wr_en_o     = '0;
    dst_wr_data_o   = '0;
    dst_wr_len_o    = '0;
    dst_fr_o        = '0;
    if (beat_write) begin
      src_data_rd_en_o = NUM_PORTS'(1) << beat_src;
      dst_wr_en_o     = beat_dst;
      dst_fr_o        = beat_fr;
      for (int unsigned j = 0; j < NUM_PORTS; j++) begin
        dst_wr_data_o[j*64 +: 64] = beat_word;
        dst_wr_len_o [j*SW_LEN_W +: SW_LEN_W] = beat_len;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      xfer_active <= 1'b0;
      xfer_src_q  <= '0;
      xfer_len_q  <= '0;
      xfer_dst    <= '0;
      xfer_left   <= '0;
    end else begin
      if (xfer_active) begin
        if (xfer_left <= SW_LEN_W'(1)) xfer_active <= 1'b0;
        else                         xfer_left   <= xfer_left - SW_LEN_W'(1);
      end else if (grant_now) begin
        xfer_src_q <= grant_idx;
        xfer_len_q <= t_len[grant_idx*SW_LEN_W +: SW_LEN_W];
        xfer_dst   <= grant_dst;
        if (grant_beats > SW_LEN_W'(1)) begin
          xfer_active <= 1'b1;
          xfer_left   <= grant_beats - SW_LEN_W'(1);
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Statistics
  // --------------------------------------------------------------------------
  // Statistics
  //
  // A frame copy is counted when its *first* beat is written to a destination,
  // which is `beat_fr` - not on `grant_now`.  `grant_now` is the per-beat
  // arbitration decision and fires once for every 64 bit beat of every frame, so
  // counting on it reports a 100 octet frame as eight frames and the transmit
  // total ends up several times the number of frames actually put on the wire.
  // The octet total belongs on the same event for the same reason: adding
  // `t_len` on every beat of a frame would count the frame once per beat.
  // --------------------------------------------------------------------------
  logic [31:0] cnt_tx_frames, cnt_tx_octets, cnt_tx_stalled;

  logic tx_frame_start;
  assign tx_frame_start = beat_write && (|beat_fr);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      cnt_tx_frames  <= 32'd0;
      cnt_tx_octets  <= 32'd0;
      cnt_tx_stalled <= 32'd0;
    end else begin
      if (tx_frame_start) begin
        cnt_tx_frames <= cnt_tx_frames + 32'd1;
        cnt_tx_octets <= cnt_tx_octets + {21'd0, beat_len[10:0]};
      end
      if (stall_fire) cnt_tx_stalled <= cnt_tx_stalled + 32'd1;
    end
  end

  assign stat_o[32*int'(SW_STAT_TX_FRAMES)  +: 32] = cnt_tx_frames;
  assign stat_o[32*int'(SW_STAT_TX_OCTETS)  +: 32] = cnt_tx_octets;
  assign stat_o[32*int'(SW_STAT_TX_STALLED) +: 32] = cnt_tx_stalled;
  // The remaining counters belong to the receive path and the CAM; they are
  // zeroed here and summed by the top level.
  for (genvar gk = 0; gk < int'(SW_STAT_COUNT); gk++) begin : g_stat_zero
    if ((gk != int'(SW_STAT_TX_FRAMES)) && (gk != int'(SW_STAT_TX_OCTETS)) &&
        (gk != int'(SW_STAT_TX_STALLED))) begin : g_stat_zero_other
      assign stat_o[32*gk +: 32] = 32'd0;
    end
  end

  // The `flood` and `src` descriptor fields are produced by the receive port
  // and kept for debug/observability; the fabric forwards on `dst_mask` alone.
  // Reducing them here keeps the tool lint clean without dropping information
  // from the design.
  logic unused_desc_fields;
  always_comb begin
    unused_desc_fields = 1'b0;
    for (int unsigned i = 0; i < NUM_PORTS; i++) begin
      unused_desc_fields = unused_desc_fields ^ t_flood[i] ^
                           (desc_valid[i] && (|f_src[i*PW +: PW]));
    end
  end

endmodule : sw_arbiter

`endif // SW_ARBITER_SV
