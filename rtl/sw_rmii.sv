// ============================================================================
//  File        : sw_rmii.sv
//  Description : RMII symbol adapter: converts the 2-bit chunk-serial RMII
//                pins into the switch's canonical clock-enable qualified octet
//                stream, and serialises that stream back onto the RMII pins.
//
//                ------------------------------------------------------------------------
//                Synchronous model (no REF_CLK pin)
//                ------------------------------------------------------------------------
//                Like the rest of the core this adapter is synchronous to the
//                single `clk_i` and consumes no PHY clock.  A real RMII clocks
//                its 2-bit chunks with a 50 MHz REF_CLK shared by MAC and PHY;
//                driving or capturing those pins is the job of a board-specific
//                outer shell, which then hands this module a stream that is
//                already synchronous.  The contract the shell - or the
//                testbench - has to meet is:
//
//                  * one 2-bit chunk is presented every BYTE_PERIOD/4 clocks,
//                    in contiguous windows; the first chunk window of a frame
//                    opens at the CRS_DV rising edge,
//                  * the chunks of an octet are transmitted in ascending bit
//                    order.  Ethernet serialises every octet LSB-first on the
//                    wire, so the four chunks carry RXD/TXD bits [1:0], [3:2],
//                    [5:4] and [7:6] in that order,
//                  * CRS_DV is high for whole octet times, so frames start and
//                    end on octet boundaries and are separated by at least one
//                    idle clock.  RMII multiplexes carrier sense onto the same
//                    pin; a full-duplex switch MAC treats CRS_DV as RX_DV and
//                    nothing else,
//                  * the octet stream starts with the destination MAC: the PHY
//                    has already removed the preamble, as a real MAC expects
//                    (the same convention as sw_gmii_rx).
//
//                BYTE_PERIOD must be a multiple of 4 - four whole chunk
//                windows have to fit into every octet time.  1000 Mbit/s would
//                need BYTE_PERIOD = 1, so RMII is a 10/100 Mbit/s front-end;
//                the top level rejects the speed as well.  The natural core
//                clock is 50 MHz (REF_CLK = clk_i), where 100 Mbit/s gives
//                BYTE_PERIOD = 4 and one chunk per clock.
//
//                Unlike a real RMII PHY at 10 Mbit/s, which repeats each
//                2-bit symbol ten times at the fixed 50 MHz REF_CLK, this
//                model stretches the chunk windows instead - the symbol rate
//                follows sw_byte_period, exactly as the GMII front-end
//                stretches its octet windows.  Symbol repetition belongs in
//                the outer shell, together with the clocking.
//
//                RMII has no RX_ER: a PHY with a receive coding error simply
//                delivers corrupt data, which the fabric's FCS check rejects.
//
//                ------------------------------------------------------------------------
//                Receive path
//                ------------------------------------------------------------------------
//                The chunk window counter *parks* while the link is idle and
//                therefore counts every frame's windows from that frame's own
//                CRS_DV rise - no front-end or testbench has to land a frame
//                on any particular grid, exactly as sw_gmii_rx asks nothing of
//                the phase of an incoming frame.  One chunk is sampled at the
//                end of every window; after the fourth, the assembled octet is
//                presented for one full octet time, one octet behind the wire.
//
//                A presentation down-counter closes the window: the counter
//                that produces the sampling instants parks on the idle link,
//                so the *last* octet of a frame has no sampling boundary left
//                to end its presentation window - the down-counter is what
//                keeps the canonical stream stable for a full BYTE_PERIOD
//                after the link went idle, which is what sw_gmii_rx samples
//                on.  A presentation window is always exactly BYTE_PERIOD
//                long, so the octet rate reaching the core is unaffected by
//                the latency.
//
//                ------------------------------------------------------------------------
//                Transmit path
//                ------------------------------------------------------------------------
//                The canonical octet stream is produced by sw_gmii_tx, which
//                only ever updates its octet on an octet boundary of the grid
//                that every module on clk_i derives from reset.  Splitting it
//                into chunks is therefore a pure combinational part-select
//                driven by a *free-running* window counter: chunk k is on the
//                pins during the k-th quarter of every octet time.  The enable
//                is passed through combinationally for the same reason
//                sw_gmii_tx drives its own enable combinationally - a
//                registered enable would be one clock late and clip the first
//                chunk.
//
//                The transmit counter cannot be shared with the receive
//                counter: the receive one parks on the idle link, which would
//                drag the transmit part-select boundaries off the sw_gmii_tx
//                grid during every inter-frame gap.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_RMII_SV
`define SW_RMII_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "sw_defs.sv"

module sw_rmii #(
  /// `clk_i` cycles per octet time of the canonical octet stream.  Must be a
  /// multiple of 4: every octet time carries exactly four 2-bit chunk windows.
  parameter int unsigned BYTE_PERIOD = 4
) (
  input  var logic       clk_i,
  input  var logic       rst_ni,

  // ---- RMII receive pins (synchronous to clk_i) ----------------------------
  input  var logic       rmii_crs_dv_i,  ///< carrier sense / data valid (see header)
  input  var logic [1:0] rmii_rxd_i,

  // ---- RMII transmit pins --------------------------------------------------
  output logic       rmii_tx_en_o,
  output logic [1:0] rmii_txd_o,

  // ---- canonical octet stream (see the module header) ----------------------
  // receive direction: towards sw_rx_port
  output logic       oct_en_o,
  output logic [7:0] oct_d_o,
  // transmit direction: from sw_tx_port
  input  var logic       oct_en_i,
  input  var logic [7:0] oct_d_i
);

  // Chunk window length.  The elaboration check below rejects anything that
  // does not divide evenly, so this module can rely on whole windows.
  localparam int unsigned CPK = BYTE_PERIOD / 4;
  localparam int unsigned CPW = (CPK <= 1) ? 1 : $clog2(CPK);
  /// Last clock of a chunk window (the window counts 0 .. CPK-1).
  localparam logic [CPW-1:0] CHK_LAST = CPK[CPW-1:0] - CPW'(1);
  /// Width of the presentation down-counter, which holds BYTE_PERIOD-1.
  localparam int unsigned PRW = (BYTE_PERIOD <= 4) ? 2 : $clog2(BYTE_PERIOD);

`ifndef SYNTHESIS
  initial begin
    if ((BYTE_PERIOD < 4) || (BYTE_PERIOD % 4 != 0)) begin
      $error("sw_rmii: BYTE_PERIOD (%0d) must be a multiple of 4 clocks - four 2-bit chunk windows per octet time",
             BYTE_PERIOD);
    end
  end
`endif

  // --------------------------------------------------------------------------
  // Receive: chunk window counter.
  //
  // Parks at the first chunk window while the link is idle, so the first
  // window of every frame is counted from that frame's own CRS_DV rise - the
  // front-end does not have to land frames on any particular grid.  The parked
  // position (phase 0, chunk 0) is exactly the state the first window of a
  // frame starts from, so no reload edge is needed: the clock that first sees
  // CRS_DV high is already the first clock of the first chunk window.
  // --------------------------------------------------------------------------
  logic [CPW-1:0] rx_phase;   ///< clock within the current chunk window
  logic [1:0]     rx_cidx;    ///< chunk index within the octet (0 = bits [1:0])

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rx_phase <= '0;
      rx_cidx  <= 2'd0;
    end else if (!rmii_crs_dv_i) begin
      rx_phase <= '0;
      rx_cidx  <= 2'd0;
    end else if (rx_phase == CHK_LAST) begin
      rx_phase <= '0;
      rx_cidx  <= (rx_cidx == 2'd3) ? 2'd0 : rx_cidx + 2'd1;
    end else begin
      rx_phase <= rx_phase + CPW'(1);
    end
  end

  /// End of a chunk window with valid data on the pins.
  logic rx_win_end;
  assign rx_win_end = rmii_crs_dv_i && (rx_phase == CHK_LAST);
  /// End of the octet time (the fourth chunk window closes).
  logic rx_oct_end;
  assign rx_oct_end = rx_win_end && (rx_cidx == 2'd3);

  // --------------------------------------------------------------------------
  // Receive: octet assembly and presentation.
  // --------------------------------------------------------------------------
  logic [1:0] rx_c0_q;    ///< bits [1:0], captured in the first window
  logic [1:0] rx_c1_q;    ///< bits [3:2]
  logic [1:0] rx_c2_q;    ///< bits [5:4]
  logic       rx_en_q;    ///< enable presented on the canonical stream
  logic [7:0] rx_d_q;     ///< octet presented on the canonical stream

  /// Presentation window countdown.  Reloaded at every octet end; it is what
  /// closes the *last* octet's window, after the link has gone idle and the
  /// parking counter has stopped producing octet ends.
  logic [PRW-1:0] rx_pres_cnt;

  logic rx_en_nxt;
  assign rx_en_nxt = rx_oct_end || (rx_pres_cnt != '0);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rx_c0_q     <= 2'h0;
      rx_c1_q     <= 2'h0;
      rx_c2_q     <= 2'h0;
      rx_pres_cnt <= '0;
      rx_en_q     <= 1'b0;
      rx_d_q      <= 8'h0;
    end else begin
      if (rx_win_end && (rx_cidx == 2'd0)) rx_c0_q <= rmii_rxd_i;
      if (rx_win_end && (rx_cidx == 2'd1)) rx_c1_q <= rmii_rxd_i;
      if (rx_win_end && (rx_cidx == 2'd2)) rx_c2_q <= rmii_rxd_i;

      // The octet assembled in the windows that just closed is presented from
      // the next clock on; the fourth chunk comes straight off the pins.  The
      // enable follows one clock later through the same edge, so enable and
      // data move together.  CRS_DV low at an octet end closes the frame: no
      // octet is registered and the presentation window is not reloaded.
      if (rx_oct_end) begin
        rx_d_q <= {rmii_rxd_i, rx_c2_q, rx_c1_q, rx_c0_q};
      end

      if (rx_oct_end) begin
        rx_pres_cnt <= PRW'(BYTE_PERIOD - 1);
      end else if (rx_pres_cnt != '0) begin
        rx_pres_cnt <= rx_pres_cnt - PRW'(1);
      end

      rx_en_q <= rx_en_nxt;
    end
  end

  assign oct_en_o = rx_en_q;
  assign oct_d_o  = rx_d_q;

  // --------------------------------------------------------------------------
  // Transmit: free-running chunk windows on the reset grid.
  // --------------------------------------------------------------------------
  logic [CPW-1:0] tx_phase;
  logic [1:0]     tx_cidx;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tx_phase <= '0;
      tx_cidx  <= 2'd0;
    end else if (tx_phase == CHK_LAST) begin
      tx_phase <= '0;
      tx_cidx  <= (tx_cidx == 2'd3) ? 2'd0 : tx_cidx + 2'd1;
    end else begin
      tx_phase <= tx_phase + CPW'(1);
    end
  end

  // `oct_d_i` only ever changes on an octet boundary of the same grid
  // (guaranteed by sw_gmii_tx), so the chunk index alone decides which pair of
  // bits is on the pins.  No register in this path: a registered chunk would
  // lag the combinationally driven enable and shift the first chunk window.
  // Continuous assignment rather than an always_comb case: a constant part
  // select inside an always_* block makes Icarus over-approximate the
  // sensitivity list (it prints a "sorry" and includes every bit).
  assign rmii_tx_en_o = oct_en_i;
  assign rmii_txd_o   = (tx_cidx == 2'd0) ? oct_d_i[1:0] :
                        (tx_cidx == 2'd1) ? oct_d_i[3:2] :
                        (tx_cidx == 2'd2) ? oct_d_i[5:4] :
                                            oct_d_i[7:6];   // tx_cidx == 2'd3

endmodule : sw_rmii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif // SW_RMII_SV
