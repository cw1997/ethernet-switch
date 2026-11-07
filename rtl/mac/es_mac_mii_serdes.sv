// ============================================================================
//  File        : es_mac_mii_serdes.sv
//  Description : MII symbol adapter: converts the 4-bit nibble-serial MII pins
//                into the switch's canonical clock-enable qualified octet
//                stream, and serialises that stream back onto the MII pins.
//
//                Synchronous model (no PHY clock pins)
//                --------------------------------------
//                Like the rest of the core this adapter is synchronous to the
//                single `clk_i` and consumes no PHY clock.  A real MII clocks
//                its nibbles with the PHY's RX_CLK / TX_CLK; capturing those
//                asynchronous pins into the `clk_i` domain is the job of a
//                board-specific outer shell, which then hands this module a
//                stream that is already synchronous.  The contract the shell -
//                or the testbench - has to meet is:
//
//                  * one nibble is presented every BYTE_PERIOD/2 clocks, in
//                    contiguous windows; the first (low-nibble) window of a
//                    frame opens at the RX_DV rising edge,
//                  * the low nibble of an octet is transmitted first.  Ethernet
//                    serialises every octet LSB-first on the wire, so the first
//                    nibble carries RXD/TXD bits [3:0] and the second [7:4],
//                  * RX_DV is high for whole octet times, so frames start and
//                    end on octet boundaries and are separated by at least one
//                    idle clock,
//                  * the octet stream starts with the destination MAC: the PHY
//                    has already removed the preamble, as a real MII MAC
//                    expects (the same convention as es_mac_rx_frame).
//
//                BYTE_PERIOD must be an even number of clocks - two whole
//                nibble windows have to fit into every octet time - and at
//                least 2.  1000 Mbit/s would need BYTE_PERIOD = 1, so MII is a
//                10/100 Mbit/s front-end; the top level rejects the speed as
//                well.
//
//                Receive path
//                ------------
//                The nibble window counter *parks* while the link is idle and
//                therefore counts every frame's windows from that frame's own
//                DV rise - no front-end or testbench has to land a frame on
//                any particular grid, exactly as es_mac_rx_frame asks nothing
//                of the phase of an incoming frame.  The low nibble is sampled
//                at the end of the first half of every octet time and the high
//                nibble at the end of the second.
//
//                The assembled octet is presented for one full octet time,
//                one octet behind the wire.  A presentation down-counter
//                closes the window: the counter that produces the sampling
//                instants parks on the idle link, so the *last* octet of a
//                frame has no sampling boundary left to end its presentation
//                window - the down-counter is what keeps the canonical stream
//                stable for a full BYTE_PERIOD after the link went idle, which
//                is what es_mac_rx_frame samples on.  A presentation window is
//                always exactly BYTE_PERIOD long, so the octet rate reaching
//                the core is unaffected by the latency.
//
//                RX_ER while the link is enabled sets a sticky flag that
//                suppresses the enable from that octet onwards, so an errored
//                frame is truncated at the adapter instead of entering the
//                fabric.  A frame truncated this way is rejected downstream as
//                a runt or a CRC error, never forwarded.  The flag clears when
//                the link goes idle.
//
//                Transmit path
//                -------------
//                The canonical octet stream is produced by es_mac_tx_frame,
//                which only ever updates its octet on an octet boundary of the
//                grid that every module on clk_i derives from reset.  Splitting
//                it into nibbles is therefore a pure combinational part-select
//                driven by a *free-running* window counter: the low nibble is
//                on the pins during the first half of every octet time, the
//                high nibble during the second.  The enable is passed through
//                combinationally for the same reason es_mac_tx_frame drives
//                its own enable combinationally - a registered enable would be
//                one clock late and clip the first nibble.
//
//                The transmit counter cannot be shared with the receive
//                counter: the receive one parks on the idle link, which would
//                drag the transmit part-select boundaries off the
//                es_mac_tx_frame grid during every inter-frame gap.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef ES_MAC_MII_SERDES_SV
`define ES_MAC_MII_SERDES_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_mac_mii_serdes #(
  /// `clk_i` cycles per octet time of the canonical octet stream.  Must be an
  /// even number >= 2: every octet time carries exactly two nibble windows.
  parameter int unsigned BYTE_PERIOD = 2
) (
  /// Clock/reset; this model has no separate PHY clock inputs.
  input var logic clk_i,
  input var logic rst_ni,

  // ---- MII receive pins (synchronous to clk_i) -----------------------------
  /// Low-nibble-first receive symbols and per-frame receive error indication.
  input var logic       mii_rx_dv_i,
  input var logic       mii_rx_er_i,
  input var logic [3:0] mii_rxd_i,

  // ---- MII transmit pins ---------------------------------------------------
  /// Low-nibble-first transmit symbols; error is tied low by this adapter.
  output    logic       mii_tx_en_o,
  output    logic       mii_tx_er_o,  ///< never asserted: no transmit error source
  output    logic [3:0] mii_txd_o,

  // ---- canonical octet stream (see the module header) ----------------------
  /// Receive octets are presented for one complete BYTE_PERIOD window.
  output    logic       oct_en_o,
  output    logic [7:0] oct_d_o,
  /// Transmit octets are consumed on the canonical octet grid.
  input var logic       oct_en_i,
  input var logic [7:0] oct_d_i
);

  // --------------------------------------------------------------------------
  // Window timing
  //
  // NPK clocks per nibble window, two windows per octet time.  The elaboration
  // check below rejects anything that does not divide evenly, so this module can
  // rely on whole windows.
  // --------------------------------------------------------------------------
  localparam int unsigned NPK = BYTE_PERIOD / 2;
  localparam int unsigned NPW = (NPK <= 1) ? 1 : $clog2(NPK);
  /// Last clock of a nibble window (the window counts 0 .. NPK-1).
  localparam logic [NPW-1:0] NIB_LAST = NPK[NPW-1:0] - NPW'(1);
  /// Width of the presentation down-counter, which holds BYTE_PERIOD-1.
  localparam int unsigned PRW = (BYTE_PERIOD <= 2) ? 1 : $clog2(BYTE_PERIOD);

  // --------------------------------------------------------------------------
  // Parameter check
  //
  // Excluded from synthesis because yosys has no implementation for `$error`
  // (AGENTS.md 3.4).
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if ((BYTE_PERIOD < 2) || ((BYTE_PERIOD % 2) != 0)) begin
      $error(
          "es_mac_mii_serdes: BYTE_PERIOD (%0d) must be an even number of clocks >= 2 - two nibble windows per octet time",
          BYTE_PERIOD);
    end
  end
`endif

  // --------------------------------------------------------------------------
  // Receive: nibble window counter
  //
  // Parks at the start of a low-nibble window while the link is idle, so the
  // first window of every frame is counted from that frame's own DV rise - the
  // front-end does not have to land frames on any particular grid.  The parked
  // position (phase 0, low half) is exactly the state the first window of a
  // frame starts from, so no reload edge is needed: the clock that first sees
  // DV high is already the first clock of the first low-nibble window.
  // --------------------------------------------------------------------------
  logic [NPW-1:0] rx_phase;  ///< clock within the current nibble window
  logic           rx_half;   ///< 0 = low-nibble window, 1 = high-nibble window

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rx_phase <= '0;
      rx_half  <= 1'b0;
    end else if (!mii_rx_dv_i) begin
      rx_phase <= '0;
      rx_half  <= 1'b0;
    end else if (rx_phase == NIB_LAST) begin
      rx_phase <= '0;
      rx_half  <= !rx_half;
    end else begin
      rx_phase <= rx_phase + NPW'(1);
    end
  end

  /// End of a nibble window with valid data on the pins.
  logic rx_win_end;
  /// End of the low-nibble window of the octet being assembled.
  logic rx_lo_end;
  /// End of the octet time (the high-nibble window closes).
  logic rx_oct_end;

  assign rx_win_end = mii_rx_dv_i && (rx_phase == NIB_LAST);
  assign rx_lo_end  = rx_win_end && !rx_half;
  assign rx_oct_end = rx_win_end && rx_half;

  // --------------------------------------------------------------------------
  // Receive: octet assembly and presentation
  // --------------------------------------------------------------------------
  logic [3:0] rx_lo_q;      ///< low nibble captured in the first half
  logic       rx_err;       ///< sticky: RX_ER seen while the link was enabled
  logic       rx_en_q;      ///< enable presented on the canonical stream
  logic [7:0] rx_d_q;       ///< octet presented on the canonical stream
  logic [PRW-1:0] rx_pres_cnt;  ///< presentation window countdown

  /// Effective receive error: the sticky flag from an earlier window, or RX_ER
  /// on the pins in the window that is just ending.
  logic rx_err_eff;
  assign rx_err_eff = rx_err || mii_rx_er_i;

  /// The presentation down-counter is reloaded at every octet end that presents
  /// an octet; it is what closes the *last* octet's window, after the link has
  /// gone idle and the parking counter has stopped producing octet ends.
  logic rx_en_nxt;
  assign rx_en_nxt = (rx_oct_end && !rx_err_eff) || (rx_pres_cnt != '0);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rx_lo_q     <= 4'h0;
      rx_err      <= 1'b0;
      rx_pres_cnt <= '0;
      rx_en_q     <= 1'b0;
      rx_d_q      <= 8'h0;
    end else begin
      // Set by RX_ER during an enabled window, cleared by the link going idle.
      rx_err <= mii_rx_dv_i && (rx_err || mii_rx_er_i);

      if (rx_lo_end) begin
        rx_lo_q <= mii_rxd_i;
      end

      // The octet assembled in the window that just closes is presented from
      // the next clock on; the enable follows one clock later through the same
      // edge, so enable and data move together.
      if (rx_oct_end) begin
        rx_d_q <= {mii_rxd_i, rx_lo_q};
      end

      if (rx_oct_end && !rx_err_eff) begin
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
  // Transmit: free-running nibble windows on the reset grid
  // --------------------------------------------------------------------------
  logic [NPW-1:0] tx_phase;
  logic           tx_half;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tx_phase <= '0;
      tx_half  <= 1'b0;
    end else if (tx_phase == NIB_LAST) begin
      tx_phase <= '0;
      tx_half  <= !tx_half;
    end else begin
      tx_phase <= tx_phase + NPW'(1);
    end
  end

  // `oct_d_i` only ever changes on an octet boundary of the same grid
  // (guaranteed by es_mac_tx_frame), so the half flag alone decides which
  // nibble is on the pins.  No register in this path: a registered nibble would
  // lag the combinationally driven enable and shift the first nibble window.
  assign mii_tx_en_o = oct_en_i;
  assign mii_txd_o   = !tx_half ? oct_d_i[3:0] : oct_d_i[7:4];
  assign mii_tx_er_o = 1'b0;

endmodule : es_mac_mii_serdes

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_MAC_MII_SERDES_SV
