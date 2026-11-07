// ============================================================================
//  File        : es_perips_mdio.sv
//  Description : Clause-22 MDIO transaction controller.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                MDC is generated from the core clock, and MDIO is released
//                during the read turnaround.  The board supplies the
//                bidirectional buffer and the external pull-up.
//
//                CLK_FREQ_HZ and MDC_FREQ_HZ are frequencies in hertz.  start_i
//                captures the direction, the PHY and register addresses and the
//                write data; busy_o prevents overlap and valid_o qualifies
//                data_o / error_o.  mdio_oe_o is deasserted for the turnaround
//                and for read-data sampling.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_PERIPS_MDIO_SV
`define ES_PERIPS_MDIO_SV

`default_nettype none

module es_perips_mdio #(
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// Requested management clock frequency in hertz.
  parameter int unsigned MDC_FREQ_HZ = 1_000_000
) (
  /// Core clock, synchronous active-low reset, and transaction controls.
  input var logic clk_i, rst_ni, start_i, read_i,
  /// Clause-22 PHY and register addresses plus write data.
  input var logic [4:0] phy_i, reg_i,
  input var logic [15:0] data_i,
  /// MDIO value sampled from the board-side bidirectional pad.
  input var logic mdio_i,
  /// MDC output, MDIO drive value, and active-high pad output enable.
  output    logic mdc_o, mdio_o, mdio_oe_o,
  /// Transaction state and completion/error-qualified read data.
  output    logic        busy_o, valid_o, error_o,
  output    logic [15:0] data_o
);

  // --------------------------------------------------------------------------
  // MDC half period
  //
  // HALF counts core clocks per MDC half period; two of them make one bit.  The
  // ceiling of 2.5 MHz is the clause-22 limit, and HALF < 2 cannot produce a
  // symmetrical MDC at all.
  // --------------------------------------------------------------------------
  localparam int unsigned HALF = CLK_FREQ_HZ / (2 * MDC_FREQ_HZ);

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
    if ((HALF < 2) || (MDC_FREQ_HZ > 2_500_000)) begin : g_invalid
      SW_MDIO_INVALID_CLOCK invalid_parameters ();
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Transaction registers
  //
  // `bit_q` descends from preamble bit 63 through data bit 0.  The read
  // turnaround releases the pad before the acknowledgement is sampled; data is
  // sampled on MDC rising edges and the index advances on falling edges, so a
  // slave has a full MDC period to present each bit.
  // --------------------------------------------------------------------------
  logic [63:0] frame_q;
  logic [ 5:0] bit_q;
  logic [31:0] timer_q;
  logic        read_q;

  assign mdio_o    = frame_q[bit_q];
  // Driven for the whole write frame, released from bit 17 - the first of the
  // two turnaround bits - downwards, so the PHY can drive the acknowledge and
  // the read data on the same pad.
  assign mdio_oe_o = busy_o && (!read_q || (bit_q >= 6'd18));

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      mdc_o   <= 1'b0;
      busy_o  <= 1'b0;
      valid_o <= 1'b0;
      error_o <= 1'b0;
      frame_q <= '1;
      bit_q   <= '0;
      timer_q <= '0;
      read_q  <= 1'b0;
      data_o  <= '0;
    end else begin
      valid_o <= 1'b0;
      if (!busy_o) begin
        // MDC idles low; it must not be left high between transactions.
        mdc_o <= 1'b0;
        if (start_i) begin
          // Preamble, start-of-frame, opcode, PHY address, register address and
          // the two-bit turnaround, then either write data or a driven-low pad.
          frame_q <= {32'hffff_ffff, 2'b01, (read_i ? 2'b10 : 2'b01),
                      phy_i, reg_i, 2'b10, data_i};
          read_q  <= read_i;
          bit_q   <= 6'd63;
          busy_o  <= 1'b1;
          timer_q <= 32'(HALF - 1);
          data_o  <= '0;
          error_o <= 1'b0;
        end
      end else if (timer_q != 32'd0) timer_q <= timer_q - 32'd1;
      else begin
        timer_q <= 32'(HALF - 1);
        mdc_o   <= !mdc_o;
        if (!mdc_o) begin
          // Rising edge: sample.  Bit 17 is the turnaround, bit 16 the
          // acknowledgement, and bits 15..0 the read data.
          if (read_q && (bit_q == 6'd16)) error_o <= mdio_i;
          if (read_q && (bit_q < 6'd16)) data_o <= {data_o[14:0], mdio_i};
        end else if (bit_q == 6'd0) begin
          // Falling edge of the last bit: the frame is complete.
          busy_o  <= 1'b0;
          valid_o <= 1'b1;
        end else bit_q <= bit_q - 6'd1;
      end
    end
  end

endmodule : es_perips_mdio

`default_nettype wire

`endif  // ES_PERIPS_MDIO_SV
