// ============================================================================
//  File        : tb/sw_rmii_if.sv
//  Description : Bus functional model of an RMII PHY, instantiated once per
//                switch port by the `es_switch_rmii` top wrapper.
//
//                The model drives the switch's RMII receive pins and monitors
//                its RMII transmit pins, exactly as a real PHY would:
//
//                  * `send` presents a complete Ethernet frame - preamble, SFD,
//                    MAC client data, FCS - on the receive pins as 2-bit chunk
//                    windows counted from the CRS_DV rise (four chunks per
//                    octet, in ascending bit order), followed by a legal
//                    inter-frame gap.  As a real MAC expects, the switch
//                    receives the frame *without* the preamble, so the model
//                    presents the frame body from the first destination MAC
//                    octet onwards.
//                  * The monitor reassembles every frame the switch transmits
//                    from the chunk stream, checks the preamble and the FCS
//                    against the independent reference CRC, and appends the
//                    result to a queue that the scoreboard drains.
//
//                The chunk cadence comes from BYTE_PERIOD (which must be a
//                multiple of 4), so one model covers every legal 10/100 Mbit/s
//                port.  Like the RTL adapter, the model does not reproduce the
//                symbol repetition a real RMII PHY applies at 10 Mbit/s; the
//                chunk windows are stretched instead.
//
//                RMII has no RX_ER pin, so the model has nothing to drive for
//                receive errors; corrupt octets are rejected by the fabric's
//                FCS check.
//
//                Portability: the received frame image and the record queue
//                hold flat packed vectors rather than unpacked arrays or
//                structs, because Icarus Verilog cannot pass those through
//                task arguments or inside a queue.
// ============================================================================
`ifndef SW_RMII_IF_SV
`define SW_RMII_IF_SV

`include "sw_tb_pkg.sv"

// The testbench package is named in the module header import clause.  That is
// required here rather than cosmetic: the frame and record types used in the
// task and function argument lists come from `sw_tb_pkg`, and a transitive
// import is not visible to a subroutine argument type in Icarus Verilog.
module sw_rmii_if
  import sw_tb_pkg::*;
#(
  /// Port index, used only in diagnostic messages.
  parameter int unsigned PORT_ID     = 0,
  /// `clk_i` cycles per octet time; must be a multiple of 4.
  parameter int unsigned BYTE_PERIOD = 4,
  /// Inter-frame gap in octet times inserted after every frame presented.
  parameter int unsigned IFG_OCTETS  = SW_IFG_OCTETS,
  /// Number of monitored frames kept before the oldest is discarded.
  parameter int unsigned MON_DEPTH   = 512
) (
  /// Clock/reset and link enable for this port's wire model.
  input logic clk_i,
  input logic rst_ni,
  input logic enable_i, ///< 0 = link down: the pins stay idle

  // ---- switch receive pins (driven by the model) --------------------------
  /// RMII receive chunk stream; CRS_DV also represents carrier sense.
  output logic       rmii_crs_dv,
  output logic [1:0] rmii_rxd,

  // ---- switch transmit pins (monitored by the model) ----------------------
  /// Transmit chunks observed and checked at the wire boundary.
  input logic       rmii_tx_en,
  input logic [1:0] rmii_txd
);

  localparam int unsigned CPK = BYTE_PERIOD / 4;

  // ==========================================================================
  // Receive driver
  // ==========================================================================
  // One chunk is launched on the first clock of a chunk window and held for
  // CPK clocks; an octet is four consecutive chunk windows in ascending bit
  // order, exactly the contract stated in es_switch_rmii (the adapter samples at the
  // end of each window and counts every frame's windows from the CRS_DV rise).
  //
  // The cadence idiom is the one sw_mii_if and sw_gmii_if use, and getting it
  // wrong by one clock per window is exactly what tb_sw_switch_rmii catches:
  // each chunk is launched with a non-blocking assignment at the posedge that
  // OPENS its window, so it is on the pins for exactly CPK sampling points.
  // Waiting a full extra posedge inside the loop (a "@(posedge) then assign"
  // per chunk) holds every chunk for CPK+1 clocks, the adapter then samples
  // window k while the pins still carry chunk k-1, and every octet of the
  // frame arrives bit-rotated.
  logic       rx_dv_r;
  logic [1:0] rx_d_r;
  assign rmii_crs_dv = enable_i && rx_dv_r;
  assign rmii_rxd    = rx_d_r;

  /// Present one frame on the receive pins.
  ///
  /// The task blocks for the whole frame plus its inter-frame gap, so a test
  /// calls it and carries on.  Concurrent traffic from several ports is
  /// obtained by forking the task.
  task automatic send(input sw_mac_t dst, input sw_mac_t src, input logic [15:0] l2type,
                      input int unsigned total_len, input bit vlan_en = 1'b0,
                      input bit corrupt_fcs = 1'b0, input bit drop_fcs = 1'b0);
    tb_frame_buf_t frame;
    int unsigned   n;
    int unsigned   i;
    int unsigned   c;
    logic [7:0]    o;

    frame = tb_build_frame(dst, src, l2type, total_len, vlan_en, corrupt_fcs);
    n     = tb_frame_octets(total_len, vlan_en);
    if (drop_fcs) n = n - 4;

    for (i = SW_PREAMBLE_LEN; i < n; i++) begin
      o = tb_get_octet(frame, i);
      @(posedge clk_i);  // chunk 0 window opens here
      rx_dv_r <= 1'b1;
      rx_d_r  <= o[1:0];
      repeat (CPK) @(posedge clk_i);  // chunk 1 window opens here
      rx_d_r <= o[3:2];
      repeat (CPK) @(posedge clk_i);  // chunk 2 window opens here
      rx_d_r <= o[5:4];
      repeat (CPK) @(posedge clk_i);  // chunk 3 window opens here
      rx_d_r <= o[7:6];
      repeat (CPK - 1) @(posedge clk_i);
    end
    @(posedge clk_i);  // the enable drops for the gap
    rx_dv_r <= 1'b0;
    rx_d_r  <= 2'h0;
    repeat (IFG_OCTETS * BYTE_PERIOD) @(posedge clk_i);
  endtask

  // ==========================================================================
  // Transmit monitor
  // ==========================================================================
  // The monitor has to sample the transmit pins exactly once per chunk.  An
  // octet counter reproduces the cadence, started by the *enable itself*
  // rather than by a free-running phase - the transmit windows of es_mac_tx_frame
  // are on the reset grid and its enable rises on one of their boundaries, so
  // counting from the enable puts the samples in the middle of each chunk
  // window at any line rate.  The pins are read in the *active* region of the
  // clock edge, before the non-blocking updates take effect, which is the
  // only point at which the chunk that was stable across the preceding window
  // can be read.
  localparam int unsigned MPW = (BYTE_PERIOD <= 2) ? 1 : $clog2(BYTE_PERIOD);
  /// Offsets of the four mid-window sample points inside an octet window.
  /// Icarus cannot take a part-select of an expression, so the values are
  /// staged through plain integer localparams first.
  localparam int unsigned MS_C0_I = CPK / 2;
  localparam int unsigned MS_C1_I = CPK + CPK / 2;
  localparam int unsigned MS_C2_I = 2 * CPK + CPK / 2;
  localparam int unsigned MS_C3_I = 3 * CPK + CPK / 2;
  localparam logic [MPW-1:0] MS_C0 = MS_C0_I[MPW-1:0];
  localparam logic [MPW-1:0] MS_C1 = MS_C1_I[MPW-1:0];
  localparam logic [MPW-1:0] MS_C2 = MS_C2_I[MPW-1:0];
  localparam logic [MPW-1:0] MS_C3 = MS_C3_I[MPW-1:0];
  localparam logic [MPW-1:0] MPHASE_LAST = BYTE_PERIOD[MPW-1:0] - MPW'(1);

  logic [MPW-1:0] mon_cnt;
  logic           mon_s_0;
  logic           mon_s_1;
  logic           mon_s_2;
  logic           mon_s_3;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || !rmii_tx_en) mon_cnt <= '0;
    else if (mon_cnt == MPHASE_LAST) mon_cnt <= '0;
    else mon_cnt <= mon_cnt + MPW'(1);
  end

  assign mon_s_0 = rmii_tx_en && (mon_cnt == MS_C0);
  assign mon_s_1 = rmii_tx_en && (mon_cnt == MS_C1);
  assign mon_s_2 = rmii_tx_en && (mon_cnt == MS_C2);
  assign mon_s_3 = rmii_tx_en && (mon_cnt == MS_C3);

  // Assembly state of the frame currently on the wire.
  tb_frame_buf_t       mon_buf;
  int unsigned         mon_n;
  logic          [1:0] mon_c0_q;
  logic          [1:0] mon_c1_q;
  logic          [1:0] mon_c2_q;
  bit                  mon_active;

  int unsigned         mon_dropped;
  int unsigned         mon_short;  ///< frames shorter than the 802.3 minimum

  // Strobe pair that hands the frame which has just ended to the queue.  Both
  // are driven from the reassembly process below, so the queue is written from
  // a plain process rather than from a function - Icarus Verilog cannot push
  // into a queue from one.
  logic                mon_push_q;
  tb_rec_t             mon_push_rec;

  // Shadow copy of the most recently reassembled frame, kept after the working
  // buffer has been cleared (see sw_gmii_if for the rationale).
  tb_frame_buf_t       mon_last;
  int unsigned         mon_last_n;

  // ==========================================================================
  // Received-frame queue
  // ==========================================================================
  sw_rec_q #(
    .DEPTH(MON_DEPTH)
  ) u_mon (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .push_i      (mon_push_q),
    .push_data_i (mon_push_rec)
  );

  // The reassembly, in a single process.  One process owns every signal it
  // writes; splitting the queue strobe into a second process would make the
  // assignment a race (see sw_gmii_if).
  always @(posedge clk_i) begin
    bit         en;
    logic [1:0] d;
    en = rmii_tx_en;
    d  = rmii_txd;

    if (!rst_ni) begin
      mon_push_q  <= 1'b0;
      mon_dropped <= 32'd0;
      mon_short   <= 32'd0;
    end else begin
      mon_push_q <= 1'b0;

      if (mon_push_q && u_mon.full_o) mon_dropped <= mon_dropped + 1;

      if (!enable_i) begin
        mon_buf    = '0;
        mon_n      = 0;
        mon_active = 1'b0;
        mon_last_n = 0;
      end else if (en && mon_s_0) begin
        mon_c0_q = d;
      end else if (en && mon_s_1) begin
        mon_c1_q = d;
      end else if (en && mon_s_2) begin
        mon_c2_q = d;
      end else if (en && mon_s_3) begin
        mon_buf    = tb_put_octet(mon_buf, mon_n, {d, mon_c2_q, mon_c1_q, mon_c0_q});
        mon_n      = mon_n + 1;
        mon_active = 1'b1;
      end else if (!en && mon_active) begin
        // TX_EN fell, so the frame has ended.  Every non-empty frame is
        // recorded, whatever its length: dropping a short one would hide a
        // transmit-path protocol violation instead of reporting it.
        if (mon_n > 0) begin
          mon_push_rec <= mon_check(mon_buf, mon_n);
          mon_push_q   <= 1'b1;
          mon_last     <= mon_buf;
          mon_last_n   <= mon_n;
        end
        if (mon_n > 0 && mon_n < 8 + 64 + 4) mon_short <= mon_short + 1;
        mon_buf    = '0;
        mon_n      = 0;
        mon_active = 1'b0;
      end
    end
  end

  /// Check the preamble and the FCS of a received frame and build its record
  /// (identical to the sw_gmii_if check: the FCS covers the MAC client data
  /// only, starting after the eight preamble octets).
  function automatic tb_rec_t mon_check(input tb_frame_buf_t b, input int unsigned n);
    int unsigned        i;
    logic        [31:0] fcs_calc;
    logic        [31:0] fcs_rx;
    bit                 preamble_ok;

    preamble_ok = 1'b1;
    for (i = 0; i < 7; i++) begin
      if (tb_get_octet(b, i) != 8'h55) preamble_ok = 1'b0;
    end
    if (tb_get_octet(b, 7) != 8'hD5) preamble_ok = 1'b0;

    fcs_calc = tb_crc32(b, n - 4 - SW_PREAMBLE_LEN, SW_PREAMBLE_LEN);
    fcs_rx = {
      tb_get_octet(b, n - 1), tb_get_octet(b, n - 2), tb_get_octet(b, n - 3), tb_get_octet(b, n - 4)
    };

    return tb_rec_from_wire(b, n, (fcs_calc == fcs_rx), preamble_ok);
  endfunction

  // ==========================================================================
  // Scoreboard interface
  // ==========================================================================
  /// Remove and return the oldest monitored frame.  A record whose length
  /// field is zero is returned when nothing arrives within `timeout` clocks.
  task automatic pop_frame(output tb_rec_t r, input int unsigned timeout = 200000);
    int unsigned waited;
    waited = 0;
    while ((u_mon.size_o == 0) && (waited < timeout)) begin
      @(posedge clk_i);
      waited++;
    end
    if (u_mon.size_o == 0) r = '0;
    else u_mon.pop(r);
  endtask

  /// Number of frames received but not yet consumed by the scoreboard.
  function automatic int unsigned pending();
    return u_mon.size_o;
  endfunction

  /// Frames discarded because the monitor queue was full: a non-zero value
  /// invalidates the whole run.
  function automatic int unsigned dropped();
    return mon_dropped;
  endfunction

  /// Frames the switch emitted that were too short to be a legal Ethernet
  /// frame; any non-zero value is a protocol violation on the transmit path.
  function automatic int unsigned short_frames();
    return mon_short;
  endfunction

  // Initial state for the signals that the clocked processes do not reset
  // themselves (see sw_gmii_if for why this matters).
  initial begin
    rx_dv_r      = 1'b0;
    rx_d_r       = 2'h0;
    mon_buf      = '0;
    mon_n        = 0;
    mon_c0_q     = 2'h0;
    mon_c1_q     = 2'h0;
    mon_c2_q     = 2'h0;
    mon_active   = 1'b0;
    mon_push_q   = 1'b0;
    mon_push_rec = '0;
    mon_cnt      = '0;
    mon_dropped  = 0;
    mon_short    = 0;
    mon_last     = '0;
    mon_last_n   = 0;
  end

endmodule : sw_rmii_if

`endif  // SW_RMII_IF_SV
