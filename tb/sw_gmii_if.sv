// ============================================================================
//  File        : sw_gmii_if.sv
//  Description : Bus functional model of a GMII PHY, instantiated once per
//                switch port by the testbench.
//
//                The model drives the switch's receive interface and monitors
//                its transmit interface, exactly as a real PHY would:
//
//                  * `send` presents a complete Ethernet frame - preamble, SFD,
//                    MAC client data, FCS - on the receive pins, one octet every
//                    BYTE_PERIOD clocks, followed by a legal inter-frame gap.
//                  * The monitor reassembles every frame the switch transmits,
//                    checks the preamble and the FCS against the independent
//                    reference CRC, and appends the result to a queue that the
//                    scoreboard drains.
//
//                The octet cadence comes from BYTE_PERIOD, so a single model
//                drives a 10, 100 or 1000 Mbit/s port by changing one parameter -
//                which is how the multi-speed tests run on one core clock.
//
//                Portability: the received frame image and the record queue hold
//                flat packed vectors rather than unpacked arrays or structs,
//                because Icarus Verilog cannot pass those through task
//                arguments or inside a queue.
// ============================================================================
`ifndef SW_GMII_IF_SV
`define SW_GMII_IF_SV

`include "sw_tb_pkg.sv"

// Both packages are named in the module header import clause.  That is required
// here rather than cosmetic: the parameter and port lists need items from both
// (IFG_OCTETS comes from the RTL package, the frame types from the testbench
// package), and a transitive import - one that reaches the RTL package only
// through sw_tb_pkg - is not visible to a parameter default or to a subroutine
// argument type in Icarus Verilog.
module sw_gmii_if import sw_tb_pkg::*, sw_switch_pkg::*; #(
  /// Port index, used only in diagnostic messages.
  parameter int unsigned PORT_ID    = 0,
  /// `clk_i` cycles per GMII octet time on this port.
  parameter int unsigned BYTE_PERIOD = 1,
  /// Inter-frame gap in octet times inserted after every frame presented.
  parameter int unsigned IFG_OCTETS  = SW_IFG_OCTETS,
  /// Number of monitored frames kept before the oldest is discarded.
  parameter int unsigned MON_DEPTH   = 512
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       enable_i,   ///< 0 = link down: the pins stay idle

  // ---- switch receive pins (driven by the model) --------------------------
  output logic       gmii_rx_en,
  output logic [7:0] gmii_rx_d,

  // ---- switch transmit pins (monitored by the model) ----------------------
  input  logic       gmii_tx_en,
  input  logic [7:0] gmii_tx_d
);


  // ==========================================================================
  // Receive driver
  // ==========================================================================
  // Octet-period pacing: one octet is launched on the first clock of an octet
  // time and held for BYTE_PERIOD clocks, which is exactly the contract stated
  // in sw_gmii_rx (the adapter samples on the last cycle of the window).
  //
  // The receive pins are held idle whenever the link is administratively down,
  // so a disabled port stays silent no matter what a test drives.
  logic       rx_en_r;
  logic [7:0] rx_d_r;
  assign gmii_rx_en = enable_i && rx_en_r;
  assign gmii_rx_d  = rx_d_r;

  /// Present one frame on the receive pins.
  ///
  /// The task blocks for the whole frame plus its inter-frame gap, so a test
  /// calls it and carries on.  Concurrent traffic from several ports is obtained
  /// by forking the task.
  ///
  /// `drop_fcs` stops the transmission just before the FCS octets, which the
  /// switch has to notice as a truncated frame.
  task automatic send(
      input sw_mac_t     dst,
      input sw_mac_t     src,
      input logic [15:0] l2type,
      input int unsigned total_len,
      input bit          vlan_en     = 1'b0,
      input bit          corrupt_fcs = 1'b0,
      input bit          drop_fcs    = 1'b0);
    tb_frame_buf_t frame;
    int unsigned   n;
    int unsigned   i;
    logic [7:0]    o;

    frame = tb_build_frame(dst, src, l2type, total_len, vlan_en, corrupt_fcs);
    n     = tb_frame_octets(total_len, vlan_en);
    if (drop_fcs) n = n - 4;

    // The switch's receive contract states that the preamble and the
    // start-of-frame delimiter have already been removed by the PHY, exactly as
    // a real GMII MAC expects, so the model presents the frame body from the
    // first destination MAC octet onwards.  `tb_build_frame` still produces the
    // preamble because the same builder is used for the transmit monitor, which
    // has to see the octets the switch puts on the wire.
    for (i = SW_PREAMBLE_LEN; i < n; i++) begin
      o = tb_get_octet(frame, i);
      @(posedge clk_i);
      rx_en_r <= 1'b1;
      rx_d_r  <= o;
      for (int unsigned k = 1; k < BYTE_PERIOD; k++) @(posedge clk_i);
    end

    // Inter-frame gap: GMII encodes idle as TX_EN low.
    @(posedge clk_i);
    rx_en_r <= 1'b0;
    rx_d_r  <= 8'h00;
    for (int unsigned k = 1; k < IFG_OCTETS * BYTE_PERIOD; k++) @(posedge clk_i);
  endtask

  // ==========================================================================
  // Transmit monitor
  // ==========================================================================
  // The monitor has to sample the transmit pins exactly once per GMII octet.
  // Sampling on *every* clock would count BYTE_PERIOD octets where there is only
  // one, so an octet counter reproduces the cadence, and the pins are read in the
  // middle of a window - the switch registers the next octet on the *last* clock
  // of a window, so the last clock is exactly the wrong place to look.
  //
  // Sampling also has to happen *after* the non-blocking update of the octet
  // register has settled: a process that reads the pins in the active region of
  // the clock edge still sees the previous octet, which shifts the whole
  localparam int unsigned MPW = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  /// Position within the octet window at which the pins are sampled, counted
  /// from the clock on which the window opened.
  localparam int unsigned MSAMPLE_OFF = BYTE_PERIOD / 2;
  localparam logic [MPW-1:0] MSAMPLE_CNT = MSAMPLE_OFF[MPW-1:0];

  // The pins are sampled in the *active* region of the clock edge, before the
  // non-blocking updates of the clock take effect.  That is deliberate and it is
  // the only point at which the octet that was on the wire during the whole
  // preceding window can be read:
  //
  //   * at BYTE_PERIOD == 1 the switch advances the octet on every clock, so a
  //     sample taken after the delta cycles would read the *next* octet and the
  //     whole frame would be shifted by one position,
  //   * at larger BYTE_PERIOD the octet is stable across the window anyway, so
  //     sampling the middle of it (MSAMPLE_CNT) gives the same answer.
  localparam logic [MPW-1:0] MPHASE_LAST = BYTE_PERIOD[MPW-1:0] - MPW'(1);

  // The octet counter is started by the *enable itself* rather than by a
  // free-running phase.  A free-running counter only works if it happens to be in
  // phase with the switch's own counter: when the first window of a frame is
  // shorter than a full octet time the two disagree, the sample position can
  // fall outside that first window, and exactly one octet is lost.  Counting from
  // the enable removes the alignment requirement altogether, at any line rate.
  logic [MPW-1:0] mon_cnt;
  logic           mon_sample;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || !gmii_tx_en) mon_cnt <= '0;
    else if (mon_cnt == MPHASE_LAST) mon_cnt <= '0;
    else                            mon_cnt <= mon_cnt + MPW'(1);
  end

  assign mon_sample = gmii_tx_en && (mon_cnt == MSAMPLE_CNT);

  // Assembly state of the frame currently on the wire.
  tb_frame_buf_t mon_buf;
  int unsigned   mon_n;
  bit            mon_active;

  int unsigned mon_dropped;
  int unsigned mon_short;        ///< frames shorter than the 802.3 minimum

  // Strobe pair that hands the frame which has just ended to the queue.  Both
  // are driven from the reassembly process below, so the queue is written from a
  // plain process rather than from a function - Icarus Verilog cannot push into a
  // queue from one.
  logic          mon_push_q;
  tb_rec_t       mon_push_rec;

  // Shadow copy of the most recently reassembled frame, kept after the working
  // buffer has been cleared.  The monitor already checks the FCS, so a mismatch
  // points at the payload; without the shadow there is no way to see *which*
  // octet was wrong, because the working buffer is reset the moment the frame is
  // handed over.
  tb_frame_buf_t mon_last;
  int unsigned   mon_last_n;

  // ==========================================================================
  // Received-frame queue
  // ==========================================================================
  // A sw_rec_q instance rather than a language queue, for the same reason the
  // testbench uses one: Icarus Verilog cannot put a typedef'd struct into a
  // queue, and the record layout has to be shared with the scoreboard.
  sw_rec_q #(.DEPTH(MON_DEPTH)) u_mon (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .push_i     (mon_push_q),
      .push_data_i(mon_push_rec)
  );

  // The reassembly, in a single process.
  //
  // The pins and the enable are read in the *active* region of the clock edge,
  // before the non-blocking updates of the clock take effect.  That is the only
  // point at which the octet that was stable across the window which has just
  // ended can be read: at BYTE_PERIOD == 1 the switch advances the octet on every
  // clock, so a sample taken after the delta cycles would read the *next* octet
  // and shift the whole frame by one position.
  //
  // One process owns every signal it writes.  Splitting the queue strobe into a
  // second process would make the assignment a race, and the symptom would be a
  // frame that is silently never queued.
  always @(posedge clk_i) begin
    bit         en;
    logic [7:0] d;
    en = gmii_tx_en;
    d  = gmii_tx_d;

    if (!rst_ni) begin
      mon_push_q  <= 1'b0;
      mon_dropped <= 32'd0;
      mon_short   <= 32'd0;
    end else begin
      // One-clock strobe: raised when a frame ends, consumed by the queue on the
      // following edge and cleared here.
      mon_push_q <= 1'b0;

      // A frame that arrives while the queue is full is a scoreboard loss: the
      // monitor can no longer see what the switch sent, so the whole run is no
      // longer trustworthy.  `monitor_drops` in the testbench reports it.
      if (mon_push_q && u_mon.full_o) mon_dropped <= mon_dropped + 1;

      if (!enable_i) begin
        // Link down: anything in flight is discarded, and the pins are idle.
        mon_buf    = '0;
        mon_n      = 0;
        mon_active = 1'b0;
        mon_last_n = 0;
      end else if (en && mon_sample) begin
        mon_buf    = tb_put_octet(mon_buf, mon_n, d);
        mon_n      = mon_n + 1;
        mon_active = 1'b1;
      end else if (!en && mon_active) begin
        // TX_EN fell, so the frame has ended.  Every non-empty frame is recorded,
        // whatever its length: dropping a short one would hide a transmit-path
        // protocol violation instead of reporting it as a scoreboard mismatch.
        if (mon_n > 0) begin
          mon_push_rec <= mon_check(mon_buf, mon_n);
          mon_push_q   <= 1'b1;
          mon_last     <= mon_buf;
          mon_last_n   <= mon_n;
        end
        // A legal Ethernet frame is never shorter than a preamble plus a minimum
        // frame, so this is counted separately as a protocol violation.
        if (mon_n > 0 && mon_n < 8 + 64 + 4) mon_short <= mon_short + 1;
        mon_buf    = '0;
        mon_n      = 0;
        mon_active = 1'b0;
      end
    end
  end

  /// Check the preamble and the FCS of a received frame and build its record.
  ///
  /// Both are verified here, with the independent reference CRC, so a corrupted
  /// or mis-masked frame is caught at the wire boundary rather than being
  /// reported as a data mismatch somewhere else.  The FCS covers the MAC client
  /// data only, so it starts after the eight preamble octets and stops before
  /// the last four octets.
  function automatic tb_rec_t mon_check(
      input tb_frame_buf_t b,
      input int unsigned   n);
    int unsigned i;
    logic [31:0] fcs_calc;
    logic [31:0] fcs_rx;
    bit          preamble_ok;

    preamble_ok = 1'b1;
    for (i = 0; i < 7; i++) begin
      if (tb_get_octet(b, i) != 8'h55) preamble_ok = 1'b0;
    end
    if (tb_get_octet(b, 7) != 8'hD5) preamble_ok = 1'b0;

    fcs_calc = tb_crc32(b, n - 4 - SW_PREAMBLE_LEN, SW_PREAMBLE_LEN);
    fcs_rx   = {tb_get_octet(b, n-1), tb_get_octet(b, n-2),
                tb_get_octet(b, n-3), tb_get_octet(b, n-4)};

    return tb_rec_from_wire(b, n, (fcs_calc == fcs_rx), preamble_ok);
  endfunction

  // ==========================================================================
  // Scoreboard interface
  // ==========================================================================
  /// Remove and return the oldest monitored frame.  A record whose length field
  /// is zero is returned when nothing arrives within `timeout` clocks.
  task automatic pop_frame(
      output tb_rec_t       r,
      input  int unsigned   timeout = 20000);
    int unsigned waited;
    waited = 0;
    while ((u_mon.size_o == 0) && (waited < timeout)) begin
      @(posedge clk_i);
      waited++;
    end
    if (u_mon.size_o == 0) r = '0;
    else                    u_mon.pop(r);
  endtask

  /// Number of frames received but not yet consumed by the scoreboard.
  function automatic int unsigned pending();
    return u_mon.size_o;
  endfunction

  /// Frames discarded because the monitor queue was full.  A non-zero value
  /// means the scoreboard lost data, which invalidates the whole run.
  function automatic int unsigned dropped();
    return mon_dropped;
  endfunction

  /// Frames the switch emitted that were too short to be a legal Ethernet
  /// frame; any non-zero value is a protocol violation on the transmit path.
  function automatic int unsigned short_frames();
    return mon_short;
  endfunction

  // Initial state for the signals that the clocked processes do not reset
  // themselves: the receive driver registers, the frame reassembly state and the
  // two diagnostic counters.  An X here would not fail loudly - `if (X)` takes the
  // false branch - it would make a frame disappear from the scoreboard instead.
  initial begin
    rx_en_r      = 1'b0;
    rx_d_r       = 8'h00;
    mon_buf      = '0;
    mon_n        = 0;
    mon_active   = 1'b0;
    mon_push_q   = 1'b0;
    mon_push_rec = '0;
    mon_cnt      = '0;
    mon_dropped  = 0;
    mon_short    = 0;
    mon_last     = '0;
    mon_last_n   = 0;
  end

endmodule : sw_gmii_if

`endif // SW_GMII_IF_SV
