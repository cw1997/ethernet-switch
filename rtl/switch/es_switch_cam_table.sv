// ============================================================================
//  File        : es_switch_cam_table.sv
//  Description : Forwarding table for the staged switch: NUM_PORTS parallel
//                lookups AND NUM_PORTS parallel learns in the SAME clock.
//
//                Read-first semantics
//                --------------------
//                A lookup is combinational over the current entries, while a
//                learn is written on the clock edge.  A lookup issued on the
//                same edge as a learn therefore sees the OLD table.  That is
//                deliberate: a frame looks up its destination MAC and learns
//                its own source MAC, and only a self-addressed frame would see
//                its own write (which the decide level filters by source port).
//
//                Storage
//                -------
//                Switch-domain style (AGENTS.md): the only state in this file
//                is two es_mems_reg_bank instances - one for the NENT entries,
//                one for the per-set round-robin pointers - and everything
//                else is a `logic`/`assign` cloud or a pure function.  The
//                banks write one entry per clock through per-entry write
//                enables with constant indices, and their packed data_o IS the
//                flat read view, so no run-time index ever touches unpacked
//                storage (Icarus silently drops a loop-indexed store into an
//                unpacked array and returns stale data for a run-time-indexed
//                read - AGENTS.md 3.1 / 3.3).
//
//                Same-bucket/write-port conflicts
//                --------------------------------
//                `victim[p] = (rr_ptr[set] + p) mod NUM_WAYS` gives concurrent
//                learners in one set different ways.  `cam_grant()` denies
//                (backpressures for one clock) any learner whose way collides
//                with an already-granted lower-numbered one.  A write is never
//                silently dropped: cam_stage keeps `valid` asserted until the
//                corresponding `learn_ready_o` is high.  Exact-tag matches
//                relocate in place and do not advance the round-robin pointer.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_CAM_TABLE_SV
`define ES_SWITCH_CAM_TABLE_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_cam_table #(
  parameter int unsigned NUM_PORTS = 4,
  parameter int unsigned NUM_SETS  = 128,
  parameter int unsigned NUM_WAYS  = 4
) (
  input  var logic                                  clk_i,
  input  var logic                                  rst_ni,

  // ---- NUM_PORTS parallel lookups (combinational, read-first) -----------
  input  var logic [NUM_PORTS-1:0]                  req_i,
  input  var logic [NUM_PORTS*48-1:0]               mac_i,
  output      logic [NUM_PORTS-1:0]                 hit_o,
  output      logic [NUM_PORTS*sw_port_w(NUM_PORTS)-1:0] port_o,

  // ---- NUM_PORTS parallel learns (written on the same clock) ------------
  input  var logic [NUM_PORTS-1:0]                  learn_i,
  input  var logic [NUM_PORTS*48-1:0]               learn_mac_i,
  input  var logic [NUM_PORTS*sw_port_w(NUM_PORTS)-1:0] learn_port_i,
  output      logic [NUM_PORTS-1:0]                 learn_ready_o
);

  localparam int unsigned PW     = sw_port_w(NUM_PORTS);
  localparam int unsigned SETW   = (NUM_SETS < 2) ? 1 : $clog2(NUM_SETS + 1);
  localparam int unsigned WAYW   = (NUM_WAYS <= 2) ? 1 : $clog2(NUM_WAYS);
  localparam int unsigned ENT_W  = 1 + PW + 48;   // {valid, port, mac}
  localparam int unsigned P_LSB  = 48;
  localparam int unsigned V_LSB  = 48 + PW;
  localparam int unsigned NENT   = NUM_SETS * NUM_WAYS;
  localparam int unsigned BW     = NUM_WAYS * ENT_W;

  // --------------------------------------------------------------------------
  // Bucket hash: a pure XOR fold, with no multiplier, divider or 32-bit adder
  // chain.  The earlier FNV-1a form was itself written as shift-adds to avoid a
  // 32x32 multiplier, but yosys still expanded every shift-add into a carry
  // chain and `% NUM_SETS` into a divider, which made `synth -flatten` take
  // tens of minutes for what only needs to be a cheap, evenly distributed
  // bucket number.  Folding the six address octets with their position keeps
  // byte-order information without any arithmetic.
  //
  // SETW = $clog2(NUM_SETS+1) keeps a whole spare bit, so SETW'(NUM_SETS)
  // never truncates to zero and 2**SETW > NUM_SETS holds.  One
  // conditional subtraction therefore brings the folded value into
  // [0, NUM_SETS) for both power-of-two and non-power-of-two geometries; no
  // divider and no constant comparison are involved.
  function automatic logic [SETW-1:0] cam_set(input logic [47:0] m);
    logic [SETW-1:0] r;
    int unsigned      i;
    r = '0;
    for (i = 0; i < 6; i++) begin
      // SETW'(i) is an elaboration-time constant inside the unrolled loop.
      // The cast of an address octet is a deliberate truncation to SETW bits.
      r = r ^ SETW'(m[47-8*i -: 8]) ^ SETW'(i);
    end
    if (r >= SETW'(NUM_SETS)) r = r - SETW'(NUM_SETS);
    cam_set = r;
  endfunction

  /// Select one bucket from the flat entry vector.  The index is a run-time
  /// value, but the loop bound is the constant NUM_SETS, so a synthesis
  /// frontend expands `flat[i*BW +: BW]` into constant part-selects and a
  /// plain mux.  Writing `flat[s*BW +: BW]` instead would infer a barrel
  /// shifter as wide as the whole table - on a 128x4 CAM that is tens of
  /// thousands of bits of `$shiftx`, and `synth -flatten` spends tens of
  /// minutes lowering it.
  function automatic logic [BW-1:0] cam_bucket(
      input logic [NENT*ENT_W-1:0] flat,
      input logic [SETW-1:0]       s);
    logic [BW-1:0] r;
    int unsigned   i;
    r = '0;
    for (i = 0; i < NUM_SETS; i++) begin
      if (SETW'(i) == s) r = flat[i*BW +: BW];
    end
    cam_bucket = r;
  endfunction

  /// Lowest matching way in a bucket: {hit, port}.
  function automatic logic [PW:0] cam_lookup(
      input logic [BW-1:0] b, input logic [47:0] m);
    logic [PW:0] r;
    int unsigned  w;
    r = '0;
    for (w = 0; w < NUM_WAYS; w++) begin
      if (r[PW] == 1'b0 &&
          b[w*ENT_W + V_LSB] == 1'b1 &&
          b[w*ENT_W +: 48] == m) begin
        r = {1'b1, b[w*ENT_W + P_LSB +: PW]};
      end
    end
    cam_lookup = r;
  endfunction

  /// Lowest way already holding this MAC: {found, way}.
  function automatic logic [WAYW:0] cam_exact(
      input logic [BW-1:0] b, input logic [47:0] m);
    logic [WAYW:0] r;
    int unsigned    w;
    r = '0;
    for (w = 0; w < NUM_WAYS; w++) begin
      if (r[WAYW] == 1'b0 &&
          b[w*ENT_W + V_LSB] == 1'b1 &&
          b[w*ENT_W +: 48] == m) begin
        r = {1'b1, WAYW'(w)};
      end
    end
    cam_exact = r;
  endfunction

  /// Advance a round-robin pointer by `delta` places, wrapping explicitly so
  /// a non-power-of-two NUM_WAYS cannot land on an unused encoding.
  function automatic logic [WAYW-1:0] cam_rr_add(
      input logic [WAYW-1:0] cur, input int unsigned delta);
    logic [WAYW-1:0] r;
    int unsigned      i;
    r = cur;
    for (i = 0; i < NUM_PORTS; i++) begin
      if (i < delta)
        r = (r == WAYW'(NUM_WAYS-1)) ? '0 : (r + WAYW'(1));
    end
    cam_rr_add = r;
  endfunction

  /// Grant every learner except those whose (set, way) duplicates an already
  /// granted lower-numbered learner.  Loop bounds are constants; the `q < p`
  /// test is a comparison, so a synthesis frontend can unroll the function.
  function automatic logic [NUM_PORTS-1:0] cam_grant(
      input logic [NUM_PORTS-1:0]            v,
      input logic [NUM_PORTS*SETW-1:0]      s,
      input logic [NUM_PORTS*WAYW-1:0]      w);
    logic [NUM_PORTS-1:0] g;
    int unsigned           p;
    int unsigned           q;
    g = '0;
    for (p = 0; p < NUM_PORTS; p++) begin
      if (v[p]) begin
        g[p] = 1'b1;
        for (q = 0; q < NUM_PORTS; q++) begin
          if (q < p && g[q] &&
              s[q*SETW +: SETW] == s[p*SETW +: SETW] &&
              w[q*WAYW +: WAYW] == w[p*WAYW +: WAYW]) begin
            g[p] = 1'b0;
          end
        end
      end
    end
    cam_grant = g;
  endfunction

  /// One-hot of the lowest set bit.
  function automatic logic [NUM_PORTS-1:0] cam_pick(
      input logic [NUM_PORTS-1:0] v);
    logic [NUM_PORTS-1:0] r;
    logic                 found;
    int unsigned           i;
    r     = '0;
    found = 1'b0;
    for (i = 0; i < NUM_PORTS; i++) begin
      if (!found && v[i]) begin
        r[i]  = 1'b1;
        found = 1'b1;
      end
    end
    cam_pick = r;
  endfunction

  function automatic logic [ENT_W-1:0] cam_wdata(
      input logic [NUM_PORTS-1:0]                onehot,
      input logic [NUM_PORTS*PW-1:0]            ports,
      input logic [NUM_PORTS*48-1:0]            macs);
    logic [ENT_W-1:0] r;
    int unsigned       i;
    r = '0;
    for (i = 0; i < NUM_PORTS; i++) begin
      if (onehot[i]) r = {1'b1, ports[i*PW +: PW], macs[i*48 +: 48]};
    end
    cam_wdata = r;
  endfunction

  // --------------------------------------------------------------------------
  // Storage: two es_mems_reg_bank instances.  `entry_flat` is the packed read
  // view the lookups and the victim selection run over (read-first); the
  // per-entry write-enable vectors computed below carry the learns in.
  // --------------------------------------------------------------------------
  logic [NENT*ENT_W-1:0]     entry_flat;
  logic [NUM_SETS*WAYW-1:0]  rr_flat;

  logic [NENT-1:0]           entry_wr_en;
  logic [NENT*ENT_W-1:0]     entry_wr_data;
  logic [NUM_SETS-1:0]       rr_wr_en;
  logic [NUM_SETS*WAYW-1:0]  rr_wr_data;

  logic [NUM_PORTS*BW-1:0]   r_bucket;
  logic [NUM_PORTS*BW-1:0]   l_bucket;
  logic [NUM_PORTS*SETW-1:0] lset;
  logic [NUM_PORTS*WAYW-1:0] lway;
  logic [NUM_PORTS-1:0]      lexact;
  logic [NUM_PORTS-1:0]      grant;

  genvar gi;
  genvar gp;

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_lookup
      logic [PW:0] lr;
      assign r_bucket[gp*BW +: BW] =
          cam_bucket(entry_flat, cam_set(mac_i[gp*48 +: 48]));
      assign lr = cam_lookup(r_bucket[gp*BW +: BW], mac_i[gp*48 +: 48]);
      assign hit_o[gp]            = req_i[gp] && lr[PW];
      assign port_o[gp*PW +: PW]  = lr[PW-1:0];
    end
  endgenerate

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_learn
      logic [WAYW:0]   ex;
      logic [WAYW-1:0] rr;
      logic [WAYW-1:0] victim;

      assign lset[gp*SETW +: SETW] = cam_set(learn_mac_i[gp*48 +: 48]);
      assign rr = rr_flat[lset[gp*SETW +: SETW]*WAYW +: WAYW];
      assign l_bucket[gp*BW +: BW] =
          cam_bucket(entry_flat, lset[gp*SETW +: SETW]);
      assign ex     = cam_exact(l_bucket[gp*BW +: BW], learn_mac_i[gp*48 +: 48]);
      assign victim = cam_rr_add(rr, gp);
      assign lexact[gp] = ex[WAYW];
      // An exact match relocates in place; otherwise take a distinct victim
      // way so concurrent learners in this set do not fight over one entry.
      assign lway[gp*WAYW +: WAYW] = ex[WAYW] ? ex[WAYW-1:0] : victim;
    end
  endgenerate

  assign grant         = cam_grant(learn_i, lset, lway);
  assign learn_ready_o = grant;

  generate
    for (gi = 0; gi < NENT; gi++) begin : g_entry
      logic [NUM_PORTS-1:0] hits;
      logic [NUM_PORTS-1:0] pick;

      for (gp = 0; gp < NUM_PORTS; gp++) begin : g_hit
        // Both fields are deliberately widened to the 32-bit integer domain
        // before the ADD: NUM_WAYS is an int unsigned, so an unextended
        // SETW/WAYW field would be silently zero-extended (WIDTHEXPAND).
        assign hits[gp] = learn_i[gp] && grant[gp] &&
            ((32'(lset[gp*SETW +: SETW])*NUM_WAYS +
              32'(lway[gp*WAYW +: WAYW])) == gi);
      end

      assign pick = cam_pick(hits);

      assign entry_wr_en[gi]                  = |pick;
      assign entry_wr_data[gi*ENT_W +: ENT_W] =
          cam_wdata(pick, learn_port_i, learn_mac_i);
    end
  endgenerate

  generate
    for (gi = 0; gi < NUM_SETS; gi++) begin : g_rr
      logic [NUM_PORTS-1:0] ins;

      for (gp = 0; gp < NUM_PORTS; gp++) begin : g_ins
        assign ins[gp] = learn_i[gp] && grant[gp] && !lexact[gp] &&
            (lset[gp*SETW +: SETW] == SETW'(gi));
      end

      assign rr_wr_en[gi] = |ins;
      // One learn advances the set's pointer by exactly one way, wrapping
      // explicitly so a non-power-of-two NUM_WAYS cannot land on an unused
      // encoding.
      assign rr_wr_data[gi*WAYW +: WAYW] =
          (rr_flat[gi*WAYW +: WAYW] == WAYW'(NUM_WAYS-1))
              ? '0 : (rr_flat[gi*WAYW +: WAYW] + WAYW'(1));
    end
  endgenerate

  es_mems_reg_bank #(
    .WIDTH       (ENT_W),
    .DEPTH       (NENT),
    .RESET_VALUE ('0)   // an empty entry is all zeros: valid bit low
  ) u_entry_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (entry_wr_en),
    .wr_data_i (entry_wr_data),
    .data_o    (entry_flat)
  );

  es_mems_reg_bank #(
    .WIDTH       (WAYW),
    .DEPTH       (NUM_SETS),
    .RESET_VALUE ('0)
  ) u_rr_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (rr_wr_en),
    .wr_data_i (rr_wr_data),
    .data_o    (rr_flat)
  );

`ifndef SYNTHESIS
  initial begin
    if (NUM_SETS < 1 || NUM_WAYS < 1 || NUM_PORTS < 1)
      $error("es_switch_cam_table: set/way/port counts out of range");
    if (NUM_PORTS > (1 << PW))
      $error("es_switch_cam_table: NUM_PORTS does not fit the port index");
  end
`endif

endmodule : es_switch_cam_table

`default_nettype wire

`endif  // ES_SWITCH_CAM_TABLE_SV
