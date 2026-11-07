// ============================================================================
//  File        : es_monitor_core.sv
//  Description : Atomic telemetry capture and read-only CSR service.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Raw counters are extended, one sample at a time is staged, the
//                rates are computed serially, and the result is published with
//                a single sequence increment.  A reader that sees the sequence
//                change has to retry.
//
//                Port n occupies the n-th least-significant packed slice.
//                REFRESH_INTERVAL_MS is a positive millisecond interval, and
//                CLK_FREQ_HZ sets its ceiling-rounded clock count.
//                CAM_CAPACITY reports table entries, not bytes.  req/ready
//                accepts a byte address and valid qualifies data.  CAM requests
//                fetch 128-bit entries.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MONITOR_CORE_SV
`define ES_MONITOR_CORE_SV

`default_nettype none

`include "es_defs.sv"
`include "monitor/es_monitor_defs.sv"
`default_nettype none

module es_monitor_core #(
  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 125_000_000,
  /// Telemetry sampling interval in milliseconds.
  parameter int unsigned REFRESH_INTERVAL_MS = 500,
  /// Reported number of MAC-table entries, independent of CSR byte addresses.
  parameter int unsigned CAM_CAPACITY = 512,
  /// Reported MAC-table aging configuration.
  parameter logic CAM_AGE_EN = 1'b0
) (
  /// Clock and synchronous active-low reset for telemetry state.
  input var logic clk_i, rst_ni,
  /// Per-port statistics, transmit completions, and completed-frame lengths.
  input var logic [NUM_PORTS*32*SW_STAT_COUNT-1:0] port_stat_i,
  input var logic [NUM_PORTS-1:0] tx_done_i,
  input var logic [NUM_PORTS*SW_LEN_W-1:0] tx_len_i,
  /// PHY status per port: valid, link, duplex, speed[4:3], and management error.
  input var logic [NUM_PORTS*8-1:0] phy_status_i,
  /// Per-port FIFO occupancy in beats and shared fabric busy/flush events.
  input var logic [NUM_PORTS*32-1:0] rx_used_i,
  input var logic [NUM_PORTS*32-1:0] tx_used_i,
  input var logic                    busy_i,
  input var logic                    flush_i,
  /// MAC-table occupancy and read-only CSR request/response interface.
  input var logic [31:0] cam_entries_i,
  input var logic        req_i,
  input var logic [31:0] addr_i,
  output    logic        ready_o,
  output    logic        valid_o,
  output    logic [31:0] data_o,
  /// CAM snapshot read request interface for the monitor cache.
  output    logic         cam_req_o,
  output    logic [31:0]  cam_index_o,
  input var logic         cam_valid_i,
  input var logic [127:0] cam_entry_i
);

  // --------------------------------------------------------------------------
  // Parameter check
  //
  // The body instantiates a module that does not exist.  A false generate
  // branch is never elaborated, so a legal configuration costs nothing; an
  // illegal one fails with an unknown-module error that names this block.  The
  // alternative, `$error` in the datapath, is unavailable because yosys has no
  // implementation for it (AGENTS.md 3.4).
  // --------------------------------------------------------------------------
  generate
    if ((NUM_PORTS == 0) || (CLK_FREQ_HZ == 0) || (REFRESH_INTERVAL_MS == 0)) begin : g_invalid
      SW_MONITOR_REQUIRES_POSITIVE_PARAMETERS invalid_parameters ();
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Derived widths and timing
  // --------------------------------------------------------------------------
  localparam int unsigned PORT_ADDR_W = sw_port_w(NUM_PORTS * SW_MON_WORDS);
  localparam int unsigned TOTAL_BITS  = (NUM_PORTS + 1) * SW_MON_BITS;
  localparam int unsigned SNAP_IDX_W  = sw_port_w(TOTAL_BITS);

  /// Byte stride between two record-shaped images: one aggregate record and one
  /// per-port record are both `SW_MON_WORDS` 32-bit words long.
  localparam int unsigned RECORD_BYTES = SW_MON_WORDS * 4;

  /// Bit stride of one port's four rate deltas (RX/TX frames, RX/TX octets).
  localparam int unsigned DELTA_STRIDE = 4 * 64;

  /// Ceiling conversion preserves a non-integral number of clocks per ms.
  localparam logic [63:0] INTERVAL =
      ((64'(CLK_FREQ_HZ) * 64'(REFRESH_INTERVAL_MS)) + 64'd999) / 64'd1000;

  // --------------------------------------------------------------------------
  // Extended counters and window accumulators
  //
  // Every statistic is a free-running 32-bit field in the switch, so a single
  // read can miss a wrap.  Extending to 64 bits on every clock removes that
  // hole regardless of how long the sampling interval becomes.
  // --------------------------------------------------------------------------
  logic [NUM_PORTS*64*SW_STAT_COUNT-1:0] counters;
  logic [NUM_PORTS*32*SW_STAT_COUNT-1:0] previous_raw;

  logic [NUM_PORTS*64*SW_STAT_COUNT-1:0] previous_sample;
  logic [NUM_PORTS*4*64-1:0]             deltas_q;
  logic [NUM_PORTS*32-1:0]               rx_peak_q;
  logic [NUM_PORTS*32-1:0]               tx_peak_q;

  /// Readers see snapshot_q while the serial calculations update staging_q.
  logic [TOTAL_BITS-1:0] staging_q;
  logic [TOTAL_BITS-1:0] snapshot_q;

  logic [63:0] timer_q;
  logic [63:0] uptime_q;
  logic [63:0] sec_timer_q;
  logic [63:0] ticks_q;
  logic [63:0] elapsed_q;
  logic [63:0] busy_cycles_q;
  logic [63:0] sampled_busy_q;
  logic [31:0] sequence_q;
  logic [31:0] flushes_q;

  logic capture;

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,     ///< count clocks until the sampling window closes
    S_START,    ///< launch one serial ratio computation
    S_WAIT,     ///< wait for its result and advance the field/port cursor
    S_PUBLISH   ///< bump the sequence word so readers know the image moved
  } state_e;

  state_e state_q;

  logic [31:0] port_q;    ///< record being computed; NUM_PORTS is the aggregate
  logic [ 2:0] metric_q;  ///< 0..3 rate pairs, 4..5 load per-mille

  logic        ratio_start;
  logic        ratio_busy;
  logic        ratio_valid;
  logic [63:0] ratio_value;
  logic [63:0] ratio_scale;
  logic [63:0] ratio_divisor;
  logic [63:0] ratio_result;

  logic [63:0] speed;       ///< nominal bit rate of the sampled link
  logic [ 7:0] sampled_phy; ///< PHY status byte of the record being computed

  logic [ 1:0] mac_word_q;        ///< word within the 128-bit CAM entry
  logic        mac_wait_q;        ///< a CAM read is outstanding
  logic [31:0] mac_index_q;       ///< CAM index the outstanding read asked for
  logic [127:0] mac_latch_q;      ///< last complete CAM entry
  logic        mac_latch_valid_q; ///< mac_latch_q holds a complete entry
  logic [31:0] time_high_q;       ///< high word of the 64-bit sample clock
  logic [31:0] flush_latch_q;     ///< flush count latched with time_high_q

  // --------------------------------------------------------------------------
  // Counter extension and window capture
  //
  // Raw counter differences are accumulated every core clock.  TX counters
  // instead advance on physical transmit completion, so queued copies are not
  // reported as transmitted.
  // --------------------------------------------------------------------------
  assign capture = (state_q == S_IDLE) && (timer_q >= (INTERVAL - 64'd1));

  genvar p, k;

  generate
    for (p = 0; p < NUM_PORTS; p++) begin : g_port
      for (k = 0; k < SW_STAT_COUNT; k++) begin : g_count
        localparam int unsigned IX = p * SW_STAT_COUNT + k;

        logic [31:0] delta;

        assign delta = port_stat_i[IX*32 +: 32] - previous_raw[IX*32 +: 32];

        always_ff @(posedge clk_i) begin
          if (!rst_ni) begin
            counters[IX*64 +: 64]     <= '0;
            previous_raw[IX*32 +: 32] <= '0;
          end else begin
            previous_raw[IX*32 +: 32] <= port_stat_i[IX*32 +: 32];
            // Extend modulo-32 deltas every clock: even a long sample cannot
            // lose a wrap.  TX is counted at the end of the final FCS window.
            if (k == int'(SW_STAT_TX_FRAMES)) begin
              if (tx_done_i[p]) counters[IX*64 +: 64] <= counters[IX*64 +: 64] + 64'd1;
            end else if (k == int'(SW_STAT_TX_OCTETS)) begin
              if (tx_done_i[p]) begin
                counters[IX*64 +: 64] <= counters[IX*64 +: 64] +
                    {53'd0, tx_len_i[p*SW_LEN_W +: SW_LEN_W]};
              end
            end else counters[IX*64 +: 64] <= counters[IX*64 +: 64] + {32'd0, delta};
          end
        end
      end

      // Occupancy peaks are sampled per port: the peak of a window is the
      // largest occupancy seen inside it, and a new window starts from the
      // current value rather than from zero.
      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          rx_peak_q[p*32 +: 32] <= '0;
          tx_peak_q[p*32 +: 32] <= '0;
        end else begin
          if (capture || (rx_used_i[p*32 +: 32] > rx_peak_q[p*32 +: 32])) begin
            rx_peak_q[p*32 +: 32] <= rx_used_i[p*32 +: 32];
          end
          if (capture || (tx_used_i[p*32 +: 32] > tx_peak_q[p*32 +: 32])) begin
            tx_peak_q[p*32 +: 32] <= tx_used_i[p*32 +: 32];
          end
        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Aggregate snapshot reduction
  //
  // Sum the port records in a function so the reduction temporaries have no
  // simulator sensitivity list: an accumulator that is read back inside an
  // `always_comb` re-triggers on its own output forever.
  // --------------------------------------------------------------------------
  function automatic logic [SW_MON_BITS-1:0] aggregate(
      input var logic [TOTAL_BITS-1:0] image);
    logic [SW_MON_BITS-1:0] result;
    result = image[0 +: SW_MON_BITS];
    // 14 counter pairs, then the four rate pairs; both blocks are 64 bits per
    // port and are summed word by word rather than reinterpreted.
    for (int unsigned c = 0; c < SW_STAT_COUNT; c++) begin
      result[(SW_MON_COUNTER+2*c)*32 +: 64] = '0;
      for (int unsigned n = 0; n < NUM_PORTS; n++) begin
        result[(SW_MON_COUNTER+2*c)*32 +: 64] =
            result[(SW_MON_COUNTER+2*c)*32 +: 64] +
            image[(n+1)*SW_MON_BITS+(SW_MON_COUNTER+2*c)*32 +: 64];
      end
    end
    for (int unsigned r = 0; r < 4; r++) begin
      result[(SW_MON_RATE+2*r)*32 +: 64] = '0;
      for (int unsigned n = 0; n < NUM_PORTS; n++) begin
        result[(SW_MON_RATE+2*r)*32 +: 64] =
            result[(SW_MON_RATE+2*r)*32 +: 64] +
            image[(n+1)*SW_MON_BITS+(SW_MON_RATE+2*r)*32 +: 64];
      end
    end
    aggregate = result;
  endfunction

  // --------------------------------------------------------------------------
  // Ratio operand selection
  //
  // The divider is shared by every rate and load field, so the numerator,
  // scale and denominator are a pure function of the current cursor.  The
  // per-mille fields are normalized against the link rate rather than against
  // the octet counters, so a 10 Mbit/s port and a 1000 Mbit/s port both report
  // "how full the wire is" on the same scale.
  // --------------------------------------------------------------------------
  assign sampled_phy = staging_q[(port_q+32'd1)*32'(SW_MON_BITS) +: 8];

  assign speed = (sampled_phy[4:3] == 2'd0) ? 64'd10_000_000 :
                 (sampled_phy[4:3] == 2'd1) ? 64'd100_000_000 : 64'd1_000_000_000;

  // Bits 7:5 and bit 2 of the PHY status byte are not used by any rate.
  logic unused_phy;
  assign unused_phy = ^{sampled_phy[7:5], sampled_phy[2]};

  always_comb begin
    // Defaults: the aggregate record's fabric-busy per-mille, which is the only
    // field computed with port_q outside the per-port range.
    ratio_value   = sampled_busy_q;
    ratio_scale   = 64'd1000;
    ratio_divisor = elapsed_q;
    if (port_q < 32'(NUM_PORTS)) begin
      case (metric_q)
        3'd0: begin
          ratio_value = deltas_q[(port_q * 32'(DELTA_STRIDE)) +: 64];
          ratio_scale = 64'(CLK_FREQ_HZ);
        end
        3'd1: begin
          ratio_value = deltas_q[(port_q * 32'(DELTA_STRIDE)) + 32'd64 +: 64];
          ratio_scale = 64'(CLK_FREQ_HZ);
        end
        3'd2, 3'd4: begin
          ratio_value = deltas_q[(port_q * 32'(DELTA_STRIDE)) + 32'd128 +: 64];
          ratio_scale = 64'(CLK_FREQ_HZ) * 64'd8;
        end
        3'd3, 3'd5: begin
          ratio_value = deltas_q[(port_q * 32'(DELTA_STRIDE)) + 32'd192 +: 64];
          ratio_scale = 64'(CLK_FREQ_HZ) * 64'd8;
        end
        default: ;  // the two assignments above already cover 6 and 7
      endcase
      if (metric_q >= 3'd4) begin
        // Use the bit/s result for exact per-mille normalization: no loss from
        // a CLK_FREQ_HZ / link_rate truncation at an unusual core frequency.
        ratio_value   = staging_q[(port_q+32'd1)*32'(SW_MON_BITS) +
                                  32'(SW_MON_RATE+4)*32'd32 +
                                  ((metric_q == 3'd5) ? 32'd64 : 32'd0) +: 64];
        ratio_scale   = 64'd1000;
        ratio_divisor = speed;
        // A port without a valid link has no defined load; report zero rather
        // than dividing by a speed nobody negotiated.
        if (!sampled_phy[0] || !sampled_phy[1]) ratio_value = '0;
      end
    end
  end

  assign ratio_start = (state_q == S_START);

  es_common_ratio u_ratio (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .start_i   (ratio_start),
    .value_i   (ratio_value),
    .scale_i   (ratio_scale),
    .divisor_i (ratio_divisor),
    .busy_o    (ratio_busy),
    .valid_o   (ratio_valid),
    .result_o  (ratio_result)
  );

  // The divider's busy flag is not needed: S_WAIT is left on `ratio_valid`.
  logic unused_ratio_busy;
  assign unused_ratio_busy = ratio_busy;

  // --------------------------------------------------------------------------
  // Sample window and sequencer
  //
  // A closed window snapshots the counters and the fabric-busy cycles, then
  // walks the cursor over every port and every metric before publishing.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      timer_q         <= '0;
      uptime_q        <= '0;
      sec_timer_q     <= '0;
      ticks_q         <= '0;
      elapsed_q       <= '0;
      busy_cycles_q   <= '0;
      sampled_busy_q  <= '0;
      sequence_q      <= '0;
      flushes_q       <= '0;
      previous_sample <= '0;
      deltas_q        <= '0;
      state_q         <= S_IDLE;
      port_q          <= '0;
      metric_q        <= '0;
    end else begin
      // Free-running time base: an independent second counter, so uptime is
      // exact even though the sampling window is rounded to whole clocks.
      ticks_q     <= ticks_q + 64'd1;
      timer_q     <= timer_q + 64'd1;
      if (busy_i)  busy_cycles_q <= busy_cycles_q + 64'd1;
      if (flush_i) flushes_q     <= flushes_q + 32'd1;
      if (sec_timer_q == (64'(CLK_FREQ_HZ) - 64'd1)) begin
        sec_timer_q <= '0;
        uptime_q    <= uptime_q + 64'd1;
      end else sec_timer_q <= sec_timer_q + 64'd1;

      case (state_q)
        S_IDLE: if (capture) begin
          timer_q        <= '0;
          elapsed_q      <= timer_q + 64'd1;
          sampled_busy_q <= busy_cycles_q + 64'(busy_i);
          busy_cycles_q  <= '0;
          previous_sample <= counters;
          // Four 64-bit window deltas per port, taken from the extended
          // counters so a 32-bit wrap inside the window cannot leak through.
          for (int unsigned n = 0; n < NUM_PORTS; n++) begin
            deltas_q[n*DELTA_STRIDE +: 64] <=
                counters[(n*SW_STAT_COUNT+int'(SW_STAT_RX_FRAMES))*64 +: 64] -
                previous_sample[(n*SW_STAT_COUNT+int'(SW_STAT_RX_FRAMES))*64 +: 64];
            deltas_q[(n*DELTA_STRIDE)+64 +: 64] <=
                counters[(n*SW_STAT_COUNT+int'(SW_STAT_TX_FRAMES))*64 +: 64] -
                previous_sample[(n*SW_STAT_COUNT+int'(SW_STAT_TX_FRAMES))*64 +: 64];
            deltas_q[(n*DELTA_STRIDE)+128 +: 64] <=
                counters[(n*SW_STAT_COUNT+int'(SW_STAT_RX_OCTETS))*64 +: 64] -
                previous_sample[(n*SW_STAT_COUNT+int'(SW_STAT_RX_OCTETS))*64 +: 64];
            deltas_q[(n*DELTA_STRIDE)+192 +: 64] <=
                counters[(n*SW_STAT_COUNT+int'(SW_STAT_TX_OCTETS))*64 +: 64] -
                previous_sample[(n*SW_STAT_COUNT+int'(SW_STAT_TX_OCTETS))*64 +: 64];
          end
          port_q   <= '0;
          metric_q <= '0;
          state_q  <= S_START;
        end
        S_START: state_q <= S_WAIT;
        S_WAIT: if (ratio_valid) begin
          // port_q == NUM_PORTS is the aggregate record's fabric-busy field,
          // which is why the cursor runs to NUM_PORTS inclusive.
          if (port_q == 32'(NUM_PORTS)) begin
            state_q <= S_PUBLISH;
          end else begin
            if (metric_q == 3'd5) begin
              port_q   <= port_q + 32'd1;
              metric_q <= '0;
            end else metric_q <= metric_q + 3'd1;
            state_q <= S_START;
          end
        end
        S_PUBLISH: begin
          sequence_q <= sequence_q + 32'd1;
          state_q    <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // Staging writers
  //
  // Constant slices and per-page writers avoid a large variable-write barrel
  // shifter that would slow synthesis and add routing load.  Each writer owns
  // a disjoint slice of `staging_q`, so one always_ff per page is a single
  // driver per bit.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      staging_q[0 +: SW_MON_BITS] <= '0;
    end else if (capture) begin
      staging_q[0 +: SW_MON_BITS]                  <= '0;
      staging_q[0 +: 32]                           <= 32'd1;
      staging_q[32 +: 32]                          <= 32'(NUM_PORTS);
      staging_q[SW_MON_UPTIME_WORD*32 +: 64]       <= uptime_q;
      staging_q[SW_MON_WINDOW_WORD*32 +: 64]       <= timer_q + 64'd1;
      staging_q[SW_MON_REFRESH_WORD*32 +: 32]      <= 32'(REFRESH_INTERVAL_MS);
      staging_q[SW_MON_SEQUENCE_WORD*32 +: 32]     <= sequence_q + 32'd1;
      staging_q[SW_MON_VALID_WORD*32 +: 32]        <= 32'd1;
      staging_q[SW_MON_CAM_ENTRIES_WORD*32 +: 32]  <= cam_entries_i;
      staging_q[SW_MON_CAM_CAPACITY_WORD*32 +: 32] <= 32'(CAM_CAPACITY);
      staging_q[SW_MON_FLUSH_WORD*32 +: 32]        <= flushes_q;
      staging_q[SW_MON_AGE_WORD*32 +: 32]          <= 32'(CAM_AGE_EN);
      staging_q[SW_MON_TIME_WORD*32 +: 64]         <= ticks_q;
      staging_q[SW_MON_VERSION_WORD*32 +: 32]      <= 32'(SW_MON_ABI_VERSION);
    end else if ((state_q == S_WAIT) && ratio_valid && (port_q == 32'(NUM_PORTS))) begin
      staging_q[SW_MON_BUSY_WORD*32 +: 32] <= 32'(ratio_result);
    end
  end

  generate
    for (p = 0; p < NUM_PORTS; p++) begin : g_stage
      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          staging_q[(p+1)*SW_MON_BITS +: SW_MON_BITS] <= '0;
        end else if (capture) begin
          staging_q[(p+1)*SW_MON_BITS +: SW_MON_BITS] <= '0;
          staging_q[(p+1)*SW_MON_BITS +: 32]          <= {24'd0, phy_status_i[p*8 +: 8]};
          staging_q[(p+1)*SW_MON_BITS+32 +: 32]       <= rx_used_i[p*32 +: 32];
          staging_q[(p+1)*SW_MON_BITS+64 +: 32]       <= tx_used_i[p*32 +: 32];
          staging_q[(p+1)*SW_MON_BITS+96 +: 32]       <=
              (rx_used_i[p*32 +: 32] > rx_peak_q[p*32 +: 32]) ?
              rx_used_i[p*32 +: 32] : rx_peak_q[p*32 +: 32];
          staging_q[(p+1)*SW_MON_BITS+128 +: 32]      <=
              (tx_used_i[p*32 +: 32] > tx_peak_q[p*32 +: 32]) ?
              tx_used_i[p*32 +: 32] : tx_peak_q[p*32 +: 32];
          staging_q[(p+1)*SW_MON_BITS+SW_MON_COUNTER*32 +: 64*SW_STAT_COUNT] <=
              counters[p*64*SW_STAT_COUNT +: 64*SW_STAT_COUNT];
        end else if ((state_q == S_WAIT) && ratio_valid && (port_q == 32'(p))) begin
          case (metric_q)
            3'd0: staging_q[(p+1)*SW_MON_BITS+(SW_MON_RATE+0)*32 +: 64] <= ratio_result;
            3'd1: staging_q[(p+1)*SW_MON_BITS+(SW_MON_RATE+2)*32 +: 64] <= ratio_result;
            3'd2: staging_q[(p+1)*SW_MON_BITS+(SW_MON_RATE+4)*32 +: 64] <= ratio_result;
            3'd3: staging_q[(p+1)*SW_MON_BITS+(SW_MON_RATE+6)*32 +: 64] <= ratio_result;
            3'd4: staging_q[(p+1)*SW_MON_BITS+SW_MON_RX_LOAD_WORD*32 +: 32] <=
                     32'(ratio_result);
            3'd5: staging_q[(p+1)*SW_MON_BITS+SW_MON_TX_LOAD_WORD*32 +: 32] <=
                     32'(ratio_result);
            default: ;
          endcase
        end
      end
    end

    for (p = 0; p <= NUM_PORTS; p++) begin : g_publish
      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          snapshot_q[p*SW_MON_BITS +: SW_MON_BITS] <= '0;
        end else if (state_q == S_PUBLISH) begin
          // Record zero is reduced from the port records; the rest are copied,
          // so a reader always sees a complete, self-consistent image.
          if (p == 0) begin
            snapshot_q[p*SW_MON_BITS +: SW_MON_BITS] <= aggregate(staging_q);
          end else begin
            snapshot_q[p*SW_MON_BITS +: SW_MON_BITS] <= staging_q[p*SW_MON_BITS +: SW_MON_BITS];
          end
        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // CSR read service
  //
  // A MAC entry is latched on word zero; the next three words read that same
  // entry even if learning replaces it meanwhile.  Every other read is served
  // from the snapshot image.  Two live registers expose the 64-bit sample clock
  // and the flush counter without widening the snapshot.
  // --------------------------------------------------------------------------
  assign ready_o = !mac_wait_q;

  assign cam_req_o   = req_i && ready_o &&
                       (addr_i[31:28] == SW_MON_MAC_BASE[31:28]) &&
                       (addr_i[3:0] == 4'd0);
  assign cam_index_o = {8'd0, addr_i[27:4]};

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      valid_o          <= 1'b0;
      data_o           <= '0;
      mac_wait_q       <= 1'b0;
      mac_word_q       <= '0;
      mac_index_q      <= '0;
      mac_latch_q      <= '0;
      mac_latch_valid_q <= 1'b0;
      time_high_q      <= '0;
      flush_latch_q    <= '0;
    end else begin
      valid_o <= 1'b0;
      if (req_i && ready_o) begin
        valid_o <= !cam_req_o;
        data_o  <= '0;
        if (addr_i[1:0] == 2'd0) begin
          if (addr_i == SW_MON_LIVE_CLOCK) begin
            // Reading the low word also latches the high word and the flush
            // count, so the pair is coherent even if the clock advances.
            time_high_q   <= ticks_q[63:32];
            flush_latch_q <= flushes_q;
            data_o        <= ticks_q[31:0];
          end else if (addr_i == (SW_MON_LIVE_CLOCK + 32'd4)) begin
            data_o <= time_high_q;
          end else if (addr_i == SW_MON_LIVE_FLUSH) begin
            data_o <= flush_latch_q;
          end else if (addr_i < 32'(RECORD_BYTES)) begin
            data_o <= snapshot_q[SNAP_IDX_W'({addr_i[7:2], 5'd0}) +: 32];
          end else if ((addr_i >= SW_MON_PORT_BASE) &&
                       (addr_i < (SW_MON_PORT_BASE + (32'(NUM_PORTS) * 32'(RECORD_BYTES))))) begin
            data_o <= snapshot_q[32'(SW_MON_BITS) +
                                 32'({addr_i[PORT_ADDR_W+1:2], 5'd0}) +: 32];
          end else if (addr_i[31:28] == SW_MON_MAC_BASE[31:28]) begin
            if (cam_req_o) begin
              mac_wait_q  <= 1'b1;
              mac_word_q  <= addr_i[3:2];
              mac_index_q <= cam_index_o;
            end else if (mac_latch_valid_q && (mac_index_q == cam_index_o)) begin
              // The entry is already latched: serve any of its four words
              // without another CSR round trip.
              data_o <= mac_latch_q[addr_i[3:2]*7'd32 +: 32];
            end
          end
        end
      end
      if (mac_wait_q && cam_valid_i) begin
        mac_latch_q       <= cam_entry_i;
        mac_latch_valid_q <= 1'b1;
        data_o            <= cam_entry_i[mac_word_q*7'd32 +: 32];
        valid_o           <= 1'b1;
        mac_wait_q        <= 1'b0;
      end
    end
  end

endmodule : es_monitor_core

`default_nettype wire

`endif  // ES_MONITOR_CORE_SV
