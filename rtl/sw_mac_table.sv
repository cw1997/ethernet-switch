// ============================================================================
//  File        : sw_mac_table.sv
//  Description : Shared learning / lookup content-addressable memory (CAM) of
//                the Layer-2 switch - the forwarding database.
//
//                One table serves *all* ports:
//
//                * `NUM_SETS` buckets, each holding `NUM_WAYS` entries.  The
//                  bucket index comes from an FNV-1a hash of the 48-bit MAC
//                  address, which spreads the address space evenly at very low
//                  logic cost.
//                * NUM_PORTS read ports.  A read only touches the single bucket
//                  selected by the hash, so the cost per port is NUM_WAYS
//                  48-bit comparators; every port is served in parallel in
//                  exactly one clock, which is what keeps the receive path free
//                  of lookup arbitration.
//                * NUM_PORTS learn ports, serialised by an internal request
//                  queue of depth NUM_PORTS.  The queue is what makes learning
//                  lossless: two ports that finish a frame in the same clock
//                  both get their address written, the second one a clock
//                  later.  No station can be "forgotten" by a collision.
//                * Insertion first searches the bucket for an exact tag match,
//                  so a station that moves to another port is relocated instead
//                  of creating a duplicate entry.  Otherwise a per-bucket
//                  round-robin pointer selects the victim way.
//                * Optional ageing sweeps the table and invalidates entries that
//                  have not been refreshed.  Refreshing is implicit: the source
//                  address is re-learned on every accepted frame.
//
//                NUM_SETS and NUM_WAYS need not be powers of two: the hash and
//                the replacement pointer are both bounded explicitly.
//
//                Implementation note: the entry array is a register file that
//                is cleared on reset and on `flush_i`, which keeps the table
//                deterministic in simulation and gives a fully parallel
//                implementation.  A product design would map the same logic
//                onto a memory by dropping the reset (using a power-up initial
//                state or an explicit "valid generation" bit instead) and
//                replicating the array per read port.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_MAC_TABLE_SV
`define SW_MAC_TABLE_SV

`include "sw_defs.sv"

// The shared declarations (`sw_port_w`, `sw_mac_t`) arrive through the include
// above and are visible at compilation-unit scope, which is what lets them appear
// in a port range and in a subroutine argument type.  See sw_defs.sv for why a
// package cannot be used here.
module sw_mac_table #(
  /// Number of switch ports (read and learn ports).
  parameter int unsigned NUM_PORTS       = 4,
  /// Number of CAM buckets; the address space is hashed into this range.
  parameter int unsigned NUM_SETS        = 128,
  /// Associativity: entries per bucket.
  parameter int unsigned NUM_WAYS        = 4,
  /// 1 = enable entry ageing.
  parameter logic        AGE_EN          = 1'b0,
  /// clk_i cycles between two ageing steps; 0 steps once per clock.
  parameter int unsigned AGE_TICK_CYCLES = 1_000_000,
  /// Ageing countdown reload value; 0 expires an entry on the next sweep.
  parameter int unsigned AGE_LIMIT       = 0
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    flush_i,   ///< invalidate every entry

  // ---- lookup ports: one per ingress port, one clock of latency ------------
  input  logic [NUM_PORTS-1:0]    req_i,
  input  logic [NUM_PORTS*48-1:0] mac_i,
  output logic [NUM_PORTS-1:0]    hit_o,     ///< a valid entry matched
  /// One-hot learned egress port, one NUM_PORTS-wide vector per lookup port.
  output logic [NUM_PORTS*NUM_PORTS-1:0] port_o,

  // ---- learn ports: one per ingress port, serialised internally -----------
  input  logic [NUM_PORTS-1:0]    learn_i,
  input  logic [NUM_PORTS*48-1:0] learn_mac_i,
  /// Ingress port index of every learn port (`learn_port_i[p]` == p).
  input  logic [NUM_PORTS*sw_port_w(NUM_PORTS)-1:0] learn_port_i,

  // ---- status counters -----------------------------------------------------
  output logic [31:0]             entries_o,///< entries currently held
  output logic [31:0]             hits_o,    ///< lookups that resolved
  output logic [31:0]             misses_o,  ///< lookups that did not resolve
  output logic [31:0]             learns_o   ///< learn operations performed
);

  // --------------------------------------------------------------------------
  // Local parameters and storage declarations
  // --------------------------------------------------------------------------
  localparam int unsigned PW    = sw_port_w(NUM_PORTS);
  localparam int unsigned IDX_W = (NUM_SETS <= 2) ? 1 : $clog2(NUM_SETS);
  localparam int unsigned WAY_W = (NUM_WAYS <= 2) ? 1 : $clog2(NUM_WAYS);
  localparam int unsigned AGE_W = (AGE_LIMIT < 2) ? 1 : $clog2(AGE_LIMIT + 1);
  localparam int unsigned ENT_W = 1 + PW + 48;      // { valid, port, mac }
  localparam int unsigned LQ_W  = 48 + PW;          // queued learn request
  /// Depth of the learn request queue.
  ///
  /// Every port can request a learn in the same clock, and the write port drains
  /// one entry per clock, so a depth of NUM_PORTS is exactly on the edge: the
  /// queue fills completely and the next request is dropped.  One spare slot per
  /// port is added so a burst of simultaneous learns is always absorbed, and the
  /// extra storage is a handful of small registers.
  localparam int unsigned QP_DEPTH = 2*NUM_PORTS;
  /// Queue occupancy needs to represent QP_DEPTH entries plus a guard bit.
  localparam int unsigned QN_W  = (QP_DEPTH < 2) ? 1 : $clog2(QP_DEPTH + 1);
  localparam int unsigned QP_W  = (QP_DEPTH <= 2) ? 1 : $clog2(QP_DEPTH);

  /// One entry: validity, the port the station sits behind, and its address.
  typedef logic [ENT_W-1:0] entry_t;

  // The table is a *flat register file*, one entry per way of every bucket, and
  // it is deliberately not declared as a memory.
  //
  // A memory with several distributed readers (the per-port bucket fetch, the
  // learn-side fetch, and the flat view used by the storage decode) plus
  // per-element writers in a generate loop is more than Icarus will settle: the
  // write enable and the data are both correct, the store simply never lands, so
  // a learned entry silently never appears and a later lookup misses forever.
  // Declaring the entries as registers and keeping the array *shape* flat makes
  // every reader an ordinary continuous assignment of a constant-indexed
  // element.  The table is NUM_SETS*NUM_WAYS entries of ENT_W+AGE_W bits; for
  // any table that fits in a block RAM a synthesis tool re-infers the storage
  // from the identical per-entry always_ff blocks below, and for a small CAM the
  // registers are usually what was wanted anyway.
  //
  // The flat index of way `w` of bucket `s` is always `s*NUM_WAYS + w`; it is
  // written out explicitly rather than computed by a helper function, because a
  // function that writes a module level array would be an illegal side effect.
  entry_t          mem    [0:NUM_SETS*NUM_WAYS-1];
  logic [AGE_W-1:0] age    [0:NUM_SETS*NUM_WAYS-1];  ///< expiry countdown
  logic [WAY_W-1:0] rr_ptr [0:NUM_SETS-1];           ///< replacement pointer

  logic [31:0] entries_q, hits_q, misses_q, learns_q;

  // --------------------------------------------------------------------------
  // Address hash (FNV-1a, 32 bit) truncated to the bucket index.
  //
  // The modulo keeps the index inside the table for a NUM_SETS that is not a
  // power of two; without it IDX_W bits could address past the last bucket.
  // --------------------------------------------------------------------------
  function automatic logic [IDX_W-1:0] mac_hash(input logic [47:0] m);
    logic [31:0] h;
    h = 32'h811C_9DC5;
    for (int unsigned i = 0; i < 6; i++) begin
      h = (h ^ {24'd0, m[i*8 +: 8]}) * 32'h0100_0193;
    end
    mac_hash = IDX_W'(h % NUM_SETS);
  endfunction

  // --------------------------------------------------------------------------
  // Entry field layout
  //
  //   bit  ENT_W-1      : valid
  //   bits [48+PW-1:48] : port
  //   bits [47:0]       : MAC address
  //
  // The address sits at the bottom of the word and the validity flag at the top,
  // so the port field is *not* at `ENT_W-1 -: PW` - that slice overlaps the valid
  // bit and would decode the port one bit too high.  Deriving the offset from the
  // address width keeps these accessors consistent with `make_entry` and
  // `kill_entry` by construction.
  // --------------------------------------------------------------------------
  localparam int P_LSB = 48;   // port field offset
  localparam int V_LSB = 48 + PW;  // valid flag offset

  // The accessors are field extractors: each deliberately returns one field of
  // the packed entry, so the remaining bits of the argument are unused by
  // construction.  The waiver keeps `-Wall` clean without hiding real issues.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic        entry_valid(input entry_t e);
    entry_valid = e[V_LSB];
  endfunction

  function automatic logic [PW-1:0] entry_port(input entry_t e);
    entry_port = e[P_LSB +: PW];
  endfunction

  function automatic sw_mac_t     entry_mac(input entry_t e);
    entry_mac = e[47:0];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic entry_match(input entry_t e, input sw_mac_t m);
    entry_match = entry_valid(e) && (entry_mac(e) == m);
  endfunction

  function automatic entry_t make_entry(input sw_mac_t m, input logic [PW-1:0] p);
    make_entry = entry_t'({1'b1, p, m});
  endfunction

  /// Clear the valid flag while keeping the address and the port, so that an
  /// expired entry still has deterministic contents.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic entry_t kill_entry(input entry_t e);
    kill_entry = entry_t'({1'b0, e[ENT_W-1:1]});
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ==========================================================================
  // Lookup - combinational bucket read, registered result (one clock latency)
  //
  // Every port reads the bucket selected by the hash of its own address, so all
  // NUM_PORTS lookups complete in parallel.  The lowest matching way wins,
  // which makes the result independent of the physical way order.
  // ==========================================================================
  // Candidate address per lookup port, and the bucket it hashes to.
  logic [47:0]     rd_mac [NUM_PORTS];
  logic [IDX_W-1:0] rd_idx [NUM_PORTS];

  for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : g_rd_addr
    assign rd_mac[gp] = mac_i[gp*48 +: 48];
    assign rd_idx[gp] = mac_hash(rd_mac[gp]);
  end

  // Per-port result, held in unpacked arrays so that the process body below
  // needs no part-select at all; the flattening into the output vectors happens
  // in the generate loop that follows.
  logic             rd_hit_v  [NUM_PORTS];
  logic [NUM_PORTS-1:0] rd_port_v [NUM_PORTS];

  // The search is deliberately split across *two* combinational blocks.
  //
  // Scanning the ways needs a "found yet?" accumulator, and a block that writes a
  // variable and later reads it back in the same execution puts that variable in
  // its own implicit sensitivity list.  Such a block re-triggers itself on its
  // own output and never settles: simulation time stops advancing and the
  // simulator spins forever.  That is precisely the failure an always_comb is
  // supposed to prevent, and it is a property of sensitivity inference rather
  // than of the logic.
  //
  // So the first block only *reads* the table and writes per-way match bits, and
  // the second block only reduces those bits.  Neither block reads a signal it
  // writes, both are ordinary combinational cones, and the synthesised hardware
  // is identical to a single merged block.
  //
  // The bucket contents are fetched into a flat per-port vector with continuous
  // assignments *before* any comparison happens.
  //
  // An always_comb that reads `mem` directly with a runtime index is what makes
  // Icarus fold the table into the block's implicit sensitivity list: the block
  // then retriggers on writes to the very memory it is reading, time stops
  // advancing and the run hangs.  Staging the read through a continuous
  // assignment is the ordinary way to describe a combinational RAM read, and it
  // leaves the process body touching only plain vectors, which every simulator
  // handles.  The generated hardware is the same array of comparators.
  logic [ENT_W*NUM_WAYS-1:0] rd_bucket [NUM_PORTS];

  for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : g_rd_fetch
    for (genvar gw = 0; gw < NUM_WAYS; gw++) begin : g_rd_word
      assign rd_bucket[gp][gw*ENT_W +: ENT_W] = mem[rd_idx[gp]*NUM_WAYS + gw];
    end
  end

  // The per-way compare, one continuous assignment per (port, way).
  //
  // A variable-offset part select through a function (`bucket_word(b, w)`) forces
  // the enclosing block to over-approximate its sensitivity list, and with an
  // unpacked bucket array that is enough to make the block re-trigger on its own
  // outputs forever.  A generate loop gives every way a constant offset, so each
  // comparison is a fixed slice of a fixed signal and there is nothing left to
  // over-approximate.
  logic [NUM_WAYS-1:0] way_hit [NUM_PORTS];      ///< per-way tag match
  logic [PW-1:0]      way_port[NUM_PORTS][NUM_WAYS];

  for (genvar gp2 = 0; gp2 < NUM_PORTS; gp2++) begin : g_way
    for (genvar gw2 = 0; gw2 < NUM_WAYS; gw2++) begin : g_way_w
      localparam int unsigned WB = gw2*ENT_W;
      assign way_hit[gp2][gw2]  = entry_match(rd_bucket[gp2][WB +: ENT_W], rd_mac[gp2]);
      assign way_port[gp2][gw2] = entry_port (rd_bucket[gp2][WB +: ENT_W]);
    end
  end

  // Priority encode across the ways: the lowest matching way wins, which makes
  // the reported port independent of the physical way order.
  //
  // This is a function rather than a block.  It needs a "have I matched yet?"
  // accumulator, and in an always_comb that accumulator would be read after being
  // written, which puts it in the block's own implicit sensitivity list: the
  // block retriggers on its own output, never settles, and the simulation hangs
  // with time standing still.  A function keeps no sensitivity list at all - it
  // is re-evaluated because it is read - so the accumulator is safe there and the
  // logic is unchanged.
  //
  // The per-way ports arrive as one packed vector rather than an unpacked array
  // because Icarus cannot pass an unpacked array to a subroutine.
  function automatic logic [PW-1:0] prio_port(
      input logic [NUM_WAYS-1:0]         hit_v,
      input logic [PW*NUM_WAYS-1:0]      port_v);
    logic [PW-1:0] p;
    p = '0;
    for (int unsigned k = NUM_WAYS; k > 0; k--) begin
      if (hit_v[k-1]) p = port_v[(k-1)*PW +: PW];
    end
    prio_port = p;
  endfunction

  // Per-way port fields, flattened into the packed vector the function takes.
  logic [PW*NUM_WAYS-1:0] way_port_flat [NUM_PORTS];
  logic          hit_f  [NUM_PORTS];
  logic [PW-1:0] port_f [NUM_PORTS];

  for (genvar gp3 = 0; gp3 < NUM_PORTS; gp3++) begin : g_prio
    for (genvar gq = 0; gq < NUM_WAYS; gq++) begin : g_prio_flat
      assign way_port_flat[gp3][gq*PW +: PW] = way_port[gp3][gq];
    end
    assign hit_f[gp3]  = |way_hit[gp3];
    assign port_f[gp3] = prio_port(way_hit[gp3], way_port_flat[gp3]);
  end

  for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : g_rd_out_flat
    assign rd_hit_v[gp]  = hit_f[gp];
    // A miss produces an all-zero port mask, which is exactly "no hit".
    assign rd_port_v[gp] = hit_f[gp] ? (NUM_PORTS'(1) << PW'(port_f[gp])) : '0;
  end

  // Per-clock lookup tally, so that two ports hitting in the same clock are
  // both counted (a non-blocking assignment inside a loop would only count one).
  logic [31:0] hits_inc, misses_inc;
  logic [NUM_PORTS-1:0] hit_b, miss_b;   ///< per-port qualifiers for the tally
  logic [31:0] occ_add, occ_sub;         ///< occupancy delta, see the storage block

  // Per-port result registers, held unpacked for the same reason as the
  // combinational results above.
  logic             hit_v_q  [NUM_PORTS];
  logic [NUM_PORTS-1:0] port_v_q [NUM_PORTS];

  // Hoisted one-bit views of the request and hit signals, so neither process
  // below needs a part-select.
  logic [NUM_PORTS-1:0] req_v, hit_v;
  for (genvar gv = 0; gv < NUM_PORTS; gv++) begin : g_tally
    assign req_v[gv] = req_i[gv];
    assign hit_v[gv] = rd_hit_v[gv];
  end

  // The tally is a popcount of the per-port qualifiers, computed with a
  // continuous assignment so that the count is a pure function of its inputs.
  //
  // Accumulating it inside an always_comb (`hits_inc = hits_inc + 1`) would read
  // a variable the same block writes, which puts it in the block's own implicit
  // sensitivity list: the block then re-triggers on its own output, never
  // settles, and the run hangs with time standing still.  This form cannot.
  for (genvar gt = 0; gt < NUM_PORTS; gt++) begin : g_tally_bit
    assign hit_b[gt]    = req_v[gt] &&  hit_v[gt];
    assign miss_b[gt]   = req_v[gt] && !hit_v[gt];
  end

  // `popcount` is not available in every simulator, and an adder over the
  // qualifier bits is the same thing without depending on it.  The width is an
  // explicit parameter: Icarus cannot infer it from the argument, and the two
  // call sites use vectors of different sizes.
  function automatic logic [31:0] count_port_bits(input logic [NUM_PORTS-1:0] v);
    logic [31:0] n;
    n = 32'd0;
    for (int unsigned b = 0; b < NUM_PORTS; b++) n = n + {31'd0, v[b]};
    count_port_bits = n;
  endfunction

  function automatic logic [31:0] count_entry_bits(
      input logic [NUM_SETS*NUM_WAYS-1:0] v);
    logic [31:0] n;
    n = 32'd0;
    for (int unsigned b = 0; b < NUM_SETS*NUM_WAYS; b++) n = n + {31'd0, v[b]};
    count_entry_bits = n;
  endfunction

  assign hits_inc   = count_port_bits(hit_b);
  assign misses_inc = count_port_bits(miss_b);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      hits_q   <= 32'd0;
      misses_q <= 32'd0;
      for (int unsigned p = 0; p < NUM_PORTS; p++) begin
        hit_v_q[p]  <= 1'b0;
        port_v_q[p] <= '0;
      end
    end else begin
      for (int unsigned p = 0; p < NUM_PORTS; p++) begin
        if (req_v[p]) begin
          hit_v_q[p]  <= rd_hit_v[p];
          port_v_q[p] <= rd_port_v[p];
        end
      end
      hits_q   <= hits_q   + hits_inc;
      misses_q <= misses_q + misses_inc;
    end
  end

  for (genvar gh = 0; gh < NUM_PORTS; gh++) begin : g_hit_out
    assign hit_o [gh]                        = hit_v_q[gh];
    assign port_o[gh*NUM_PORTS +: NUM_PORTS] = port_v_q[gh];
  end

  // ==========================================================================
  // Learn request queue
  //
  // A CAM has a single write port, but every port can finish a frame in the
  // same clock.  Requests are therefore collected into a small FIFO which is
  // drained one entry per clock, so no learn request is ever lost.  The lowest
  // numbered requesting port wins the arbitration inside a clock, which makes
  // the behaviour fully deterministic.
  // ==========================================================================
  // The queue storage is a single packed vector rather than an unpacked array.
  // Entry `e` occupies bits [e*LQ_W +: LQ_W].  The queue is only a few entries
  // deep, so a packed vector costs nothing, and it keeps every access a plain
  // part select of a signal - the form every simulator handles identically.
  logic [LQ_W*QP_DEPTH-1:0] lq;
  logic [QP_W-1:0] lq_head, lq_tail;
  logic [QN_W-1:0] lq_cnt;

  // Push arbitration: the lowest port index that requests a learn wins.
  //
  // As with the lookup priority encode, the ports are walked from the highest
  // index down and every request overwrites the accumulator, so the last write is
  // the lowest requesting port.  The accumulator is therefore never read back
  // inside its own block.
  logic          lq_push;
  logic [PW-1:0] lq_push_idx;
  always_comb begin
    lq_push     = 1'b0;
    lq_push_idx = '0;
    for (int unsigned k = NUM_PORTS; k > 0; k--) begin
      if (learn_i[k-1]) begin
        lq_push     = 1'b1;
        lq_push_idx = PW'(k-1);
      end
    end
  end

  // A push is only accepted while there is room; a learn request that cannot be
  // queued is dropped, which is reported through the learn statistics.
  logic lq_push_ok;
  assign lq_push_ok = lq_push && (lq_cnt < QN_W'(QP_DEPTH));

  logic lq_pop;
  assign lq_pop = (lq_cnt != '0) && !flush_i;

  // Occupancy after this clock edge; push and pop may coincide.
  //
  // The next value is written unconditionally from the current count, never
  // accumulated on top of a partially written `lq_cnt_d`.  Reading a variable
  // back inside the block that writes it puts that variable in the block's own
  // implicit sensitivity list, so the block re-triggers on its own output and
  // never settles - simulation time stops advancing and the run hangs.
  logic [QN_W-1:0] lq_cnt_d;
  always_comb begin
    lq_cnt_d = lq_cnt;
    if (lq_push_ok) lq_cnt_d = lq_cnt + QN_W'(1);
    if (lq_pop)      lq_cnt_d = lq_cnt - QN_W'(1);
  end

  // Queued address and port of the requesting port, hoisted out of the push.
  logic [47:0]  lq_push_mac;
  logic [PW-1:0] lq_push_port;
  assign lq_push_mac  = learn_mac_i[lq_push_idx*48 +: 48];
  assign lq_push_port = learn_port_i[lq_push_idx*PW +: PW];

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      lq      <= '0;
      lq_head <= '0;
      lq_tail <= '0;
      lq_cnt  <= '0;
    end else begin
      lq <= (lq & ~lq_push_mask) | (lq_push_din & lq_push_mask);
      if (lq_pop)      lq_head <= lq_head + QP_W'(1);
      if (lq_push_ok)  lq_tail <= lq_tail + QP_W'(1);
      lq_cnt  <= lq_cnt_d;
    end
  end

  // The push is a masked write into the packed vector: a variable-offset part
  // select of a signal, with no unpacked array involved.
  logic [LQ_W*QP_DEPTH-1:0] lq_push_mask;
  logic [LQ_W*QP_DEPTH-1:0] lq_push_din;
  always_comb begin
    lq_push_din  = '0;
    lq_push_mask = '0;
    for (int unsigned e = 0; e < QP_DEPTH; e++) begin
      if (lq_push_ok && (lq_tail == QP_W'(e))) begin
        lq_push_mask[e*LQ_W +: LQ_W] = {LQ_W{1'b1}};
        lq_push_din [e*LQ_W +: LQ_W] = {lq_push_port, lq_push_mac};
      end
    end
  end

  // Head of the queue drives the write port (fall-through, no read latency).
  //
  // Field layout of a queued request is { port, mac }, i.e. the port occupies
  // bits [LQ_W-1 : LQ_W-48] and the address occupies the bottom 48 bits.  Both
  // offsets are derived from LQ_W, so the extraction cannot silently drift - an
  // off-by-one here would read the port field into the top of the address and
  // silently hash every station into the wrong bucket.
  logic        lq_valid;
  logic [47:0] lq_mac;
  logic [PW-1:0] lq_port;
  // The queue storage is never cleared, so its contents are undefined until
  // first written.  While the queue is empty the head is a don't-care; reading
  // it as zero keeps X out of the hash function and the comparator below
  // without needing a reset over the whole array.
  assign lq_valid = lq_pop;
  assign lq_mac   = lq_pop ? lq[lq_head*LQ_W +: 48]          : 48'd0;
  assign lq_port  = lq_pop ? lq[lq_head*LQ_W + LQ_W-1 -: PW] : '0;

  // ==========================================================================
  // Ageing - a slow divider paces a pointer that walks the whole table.
  // The effective idle timeout is
  //     AGE_TICK_CYCLES * NUM_SETS * NUM_WAYS * (AGE_LIMIT + 1) clocks.
  //
  // Each entry stores a *countdown* to expiry rather than an age counter: the
  // countdown is reloaded with AGE_LIMIT on every (re-)learn and decremented
  // once per ageing sweep of that entry.  A countdown of zero therefore means
  // "expire now", which also makes AGE_LIMIT = 0 degenerate to "expire on the
  // first sweep after the last refresh" without any special casing.
  // ==========================================================================
  localparam int unsigned DIV_W = (AGE_TICK_CYCLES < 2) ? 1 : $clog2(AGE_TICK_CYCLES);
  logic [DIV_W-1:0]  age_div;
  logic              age_tick;
  logic [IDX_W-1:0]  age_idx;
  logic [WAY_W-1:0]  age_way;

  assign age_tick = AGE_EN && (age_div == DIV_W'(AGE_TICK_CYCLES) - DIV_W'(1));

  // Advance the sweep pointer one entry per ageing tick.  The wrap compares
  // against a pre-sized constant, so NUM_SETS and NUM_WAYS need not be powers
  // of two.
  logic age_way_wrap;
  logic age_idx_wrap;
  assign age_way_wrap = (age_way == logic'(NUM_WAYS)  - WAY_W'(1));
  assign age_idx_wrap = (age_idx == IDX_W'(NUM_SETS) - IDX_W'(1));

  always_ff @(posedge clk_i) begin
    if (!rst_ni || !AGE_EN) begin
      age_div <= '0;
      age_idx <= '0;
      age_way <= '0;
    end else if (age_tick) begin
      age_div <= '0;
      if (age_way_wrap) begin
        age_way <= '0;
        age_idx <= age_idx_wrap ? '0 : (age_idx + IDX_W'(1));
      end else begin
        age_way <= age_way + WAY_W'(1);
      end
    end else begin
      age_div <= age_div + DIV_W'(1);
    end
  end

  // ==========================================================================
  // Write port - learn > age > hold.
  //
  // A single process owns `mem` / `age`, so the array is inferred as one
  // coherent structure.
  // ==========================================================================
  logic [IDX_W-1:0] lr_idx;

  // Per-way match vector for the queued learn request; the OR of it tells the
  // write port whether this is a relocation (the address is already present in
  // the bucket) or a genuine insertion.
  logic lr_hit;

  // Per-way write enables, hoisted out of the storage process so that the body
  // of that process contains no part-select.
  logic [NUM_WAYS-1:0] learn_hit_way;   ///< exact tag match in this bucket
  logic                learn_this_set;  ///< the learn request targets this bucket
  logic                learn_advance;   ///< genuine insertion: move the pointer

  // The learn queue storage is written but never cleared on reset, so while the
  // queue is empty its head holds an undefined address.  Hashing that undefined
  // value would drive X onto the CAM read address of every bucket, so the index
  // is pinned to bucket 0 whenever there is no learn request in flight.  The
  // address is then purely a don't-care, and the storage is not enabled either,
  // so nothing in the table depends on it.
  assign lr_idx = lq_valid ? mac_hash(lq_mac) : IDX_W'(0);

  // The learn bucket is fetched the same way as the lookup buckets, for the same
  // reason: an always_comb must not index the table directly.
  logic [ENT_W*NUM_WAYS-1:0] lr_bucket;
  for (genvar gl = 0; gl < NUM_WAYS; gl++) begin : g_lr_fetch
    assign lr_bucket[gl*ENT_W +: ENT_W] = mem[lr_idx*NUM_WAYS + gl];
  end

  // Per-way match bits, one continuous assignment per way, for the same reason
  // as the lookup compares above.
  for (genvar gl2 = 0; gl2 < NUM_WAYS; gl2++) begin : g_lr_cmp
    localparam int unsigned LB = gl2*ENT_W;
    assign learn_hit_way[gl2] = entry_match(lr_bucket[LB +: ENT_W], lq_mac);
  end

  assign lr_hit         = |learn_hit_way;
  assign learn_this_set = lq_valid;
  // The pointer only moves for a genuine insertion, not for a relocation.
  assign learn_advance  = lq_valid && !lr_hit;

  // One-hot view of every bucket's replacement pointer plus its wrap flag, used
  // to drive the victim select and the pointer update inside the storage
  // process without any inline compare there.
  //
  // These are continuous assignments rather than an always_comb.  Written as a
  // loop in an always_comb the nested `s*NUM_WAYS + w` part-select is enough to
  // make Icarus fold the block into a self-retriggering sensitivity list: the
  // simulation stops advancing and hangs, with no clock edge to observe it on.
  // A generate loop produces exactly the same gates and is unambiguous for every
  // simulator, and it keeps the structure correct for a NUM_WAYS that is not a
  // power of two.
  logic [NUM_SETS*NUM_WAYS-1:0] rr_onehot;
  logic [NUM_SETS-1:0]         rr_last;

  for (genvar gs = 0; gs < NUM_SETS; gs++) begin : g_rr
    assign rr_last[gs] = (rr_ptr[gs] == WAY_LAST);
    for (genvar gw = 0; gw < NUM_WAYS; gw++) begin : g_rr_way
      assign rr_onehot[gs*NUM_WAYS + gw] = (rr_ptr[gs] == WAY_W'(gw));
    end
  end

  // Ageing: which entry (if any) this tick touches.
  //
  // Continuous assignments for the same reason as `rr_onehot` above: these are
  // pure decodes of two small counters, and a generate loop states them without
  // any part-select that a simulator could fold into a self-retriggering
  // sensitivity list.
  logic [NUM_SETS-1:0] age_set_hit;
  logic [NUM_WAYS-1:0] age_way_hit;

  for (genvar ga = 0; ga < NUM_SETS; ga++) begin : g_age_set
    assign age_set_hit[ga] = age_tick && (age_idx == IDX_W'(ga));
  end
  for (genvar gb = 0; gb < NUM_WAYS; gb++) begin : g_age_way
    assign age_way_hit[gb] = age_tick && (age_way == WAY_W'(gb));
  end

  // Comparisons against a generate-loop index.  These are pure elaboration
  // constants, so each use site is written as a sized cast of its own genvar
  // rather than through a table built at run time.
  //
  // The earlier form filled `idx_c` / `way_c` in an `initial` block, which is a
  // real design mistake and not merely a simulator quirk: an `initial` block is
  // not synthesizable on an FPGA, and the values gate the CAM *write* path.  If
  // the block is skipped or scheduled late, `lr_idx == idx_c[s]` is false for
  // every bucket, no learn is ever written, and the table silently stays empty -
  // the station is then never forwarded to and the switch looks like a hub.  A
  // sized cast of a genvar is resolved at elaboration and is always correct.
  localparam logic [WAY_W-1:0] WAY_LAST = logic'(NUM_WAYS) - WAY_W'(1);

  // --------------------------------------------------------------------------
  // Flat views of the whole table, used by the storage process below.
  //
  // The process walks the table as one flat range and reads these vectors, which
  // are plain combinational copies of `mem` and `age`.  Indexing the memories
  // themselves with a loop variable inside the process is what makes Icarus fold
  // the table into the block's sensitivity list: the block retriggers on its own
  // writes, time stops advancing and the run hangs.  Staging the data into
  // vectors first makes the process a plain "read these wires, write those
  // registers" and the inferred hardware is unchanged.
  // --------------------------------------------------------------------------
  logic [ENT_W-1:0] mem_flat [0:NUM_SETS*NUM_WAYS-1];
  logic [AGE_W-1:0] age_flat[0:NUM_SETS*NUM_WAYS-1];

  for (genvar gf = 0; gf < NUM_SETS*NUM_WAYS; gf++) begin : g_flat
    assign mem_flat[gf] = mem[gf];
    assign age_flat[gf] = age[gf];
  end

  // --------------------------------------------------------------------------
  // Per-entry decisions, all combinational and all derived from the flat views
  // above, so the storage process contains no table read at all.
  //
  //   `wr_en`      - this entry is written this clock (learn, or ageing expiry)
  //   `age_touch`  - this entry is visited by the ageing sweep this clock
  //   `occ_add/sub`- whether the write adds or removes a live entry
  // --------------------------------------------------------------------------
  logic [NUM_SETS*NUM_WAYS-1:0] wr_en;
  logic [NUM_SETS*NUM_WAYS-1:0] age_touch;
  logic [NUM_SETS*NUM_WAYS-1:0] occ_add_b;
  logic [NUM_SETS*NUM_WAYS-1:0] occ_sub_b;

  // One entry's next contents, held unpacked so that the per-entry storage block
  // below reads a plain element.  A variable-offset part select on the
  // right-hand side of a non-blocking assign (`mem[i] <= wr_dat[i*ENT_W +: ENT_W]`)
  // is the one remaining construct Icarus fails to settle: the write enable and
  // the data are correct, the store just never lands, so a learned entry silently
  // never appears in the table.
  logic [ENT_W-1:0] wr_dat [0:NUM_SETS*NUM_WAYS-1];
  logic [AGE_W-1:0] wr_age [0:NUM_SETS*NUM_WAYS-1];

  for (genvar gs2 = 0; gs2 < NUM_SETS; gs2++) begin : g_side_set
    for (genvar gw2 = 0; gw2 < NUM_WAYS; gw2++) begin : g_side_way
      localparam int unsigned IX = gs2*NUM_WAYS + gw2;

      // A learn writes the way that either holds the station (relocation) or is
      // the round-robin victim (eviction).  The learn can only target its own
      // bucket, so the enable is qualified with the bucket comparison.
      logic learn_wr;
      assign learn_wr = learn_this_set && (lr_idx == IDX_W'(gs2)) &&
                        (learn_hit_way[gw2] || rr_onehot[IX]);

      assign age_touch[IX] = age_set_hit[gs2] && age_way_hit[gw2];

      assign wr_en[IX] = learn_wr || (age_touch[IX] && (age_flat[IX] == '0));

      // A learn replaces the entry wholesale; an expiry only clears the valid
      // flag and leaves the stored data bits alone.
      assign wr_dat[IX] = learn_wr ? make_entry(lq_mac, lq_port)
                                   : kill_entry(mem_flat[IX]);
      assign wr_age[IX] = learn_wr ? AGE_W'(AGE_LIMIT) : age_flat[IX];

      // Occupancy bookkeeping.
      //
      // A learn writes one way, and that way holds exactly one entry before and
      // after, so a learn is *always* net zero: relocating a station to another
      // port overwrites the entry in place, and evicting a station to make room
      // replaces it.  Only a learn that fills a genuinely empty way is an
      // addition, and only ageing can remove an entry.  Treating "overwrote a
      // live entry" as a removal as well would make a relocation look like a
      // delete and drive the count down by one.
      assign occ_add_b[IX] = learn_wr && !entry_valid(mem_flat[IX]);
      assign occ_sub_b[IX] = age_touch[IX] && (age_flat[IX] == '0) &&
                             entry_valid(mem_flat[IX]);
    end
  end

  // The replacement pointer of the bucket that receives a genuine insertion.
  logic                  rr_adv [0:NUM_SETS-1];
  logic [WAY_W-1:0]      rr_nxt[0:NUM_SETS-1];
  for (genvar gp2 = 0; gp2 < NUM_SETS; gp2++) begin : g_rr_nxt
    assign rr_adv[gp2] = learn_advance && (lr_idx == IDX_W'(gp2));
    // Explicit wrap so that NUM_WAYS need not be a power of two.
    assign rr_nxt[gp2] = rr_last[gp2] ? '0 : (rr_ptr[gp2] + WAY_W'(1));
  end

  assign occ_add = count_entry_bits(occ_add_b);
  assign occ_sub = count_entry_bits(occ_sub_b);

  // The table registers are written from per-entry generate blocks rather than
  // from a loop inside one always_ff.  Two reasons, both about simulators rather
  // than about the logic:
  //
  //   * a loop-indexed write into an unpacked array inside always_ff is not
  //     reliably executed by every simulator - Icarus accepts the code, drives
  //     the write enable correctly, and then silently drops the store, so a
  //     learned entry never appears in the table;
  //   * a per-entry always_ff keeps exactly one memory object per entry, which
  //     is also what an FPGA tool wants to see when it infers the table.
  //
  // The result is the same set of registers with the same enable conditions.
  for (genvar gm = 0; gm < NUM_SETS*NUM_WAYS; gm++) begin : g_mem_wr
    always_ff @(posedge clk_i) begin
      if (!rst_ni || flush_i) begin
        mem[gm] <= '0;
        age[gm] <= '0;
      end else if (wr_en[gm]) begin
        mem[gm] <= wr_dat[gm];
        age[gm] <= wr_age[gm];
      end else if (age_touch[gm]) begin
        // Ageing decrements the countdown; the entry itself is left alone
        // unless `wr_en` fired above, which is where the expiry happens.
        age[gm] <= age_flat[gm] - AGE_W'(1);
      end
    end
  end

  for (genvar gr = 0; gr < NUM_SETS; gr++) begin : g_rr_wr
    always_ff @(posedge clk_i) begin
      if (!rst_ni || flush_i) rr_ptr[gr] <= '0;
      else if (rr_adv[gr])    rr_ptr[gr] <= rr_nxt[gr];
    end
  end

  // The occupancy counter is owned by the same clock that writes the table, so
  // it can never drift away from what the table actually holds.  It has to move
  // in *both* directions: up when a learn fills an empty way, down when
  // round-robin evicts a valid entry or when ageing expires one, and back to
  // zero on a flush.
  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      // A flush empties the table outright, so the counter is simply cleared.
      // The per-entry delta is *not* applied in the same clock: it is computed
      // from the pre-flush contents, and subtracting it from a counter that is
      // being cleared to zero would underflow.
      entries_q <= 32'd0;
    end else if (occ_add != occ_sub) begin
      entries_q <= entries_q + occ_add - occ_sub;
    end
  end

  // ==========================================================================
  // Status counters
  //
  // `entries_q` is *not* maintained here: it is owned by the storage process
  // above, which is the only place that knows whether an overwritten way held a
  // live entry and whether an aged-out entry was in use.
  // ==========================================================================
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      learns_q <= 32'd0;
    end else if (lq_valid) begin
      learns_q <= learns_q + 32'd1;
    end
  end

  assign entries_o = entries_q;
  assign hits_o    = hits_q;
  assign misses_o  = misses_q;
  assign learns_o  = learns_q;

endmodule : sw_mac_table

`endif // SW_MAC_TABLE_SV
