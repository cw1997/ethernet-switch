// ============================================================================
//  File        : es_perips_mdio.sv
//  Description : Clause-22 MDIO transaction controller.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Generates MDC from the core clock and releases MDIO during
//                read turnaround. The board supplies the bidirectional buffer
//                and external pull-up.
//  Interface   : CLK_FREQ_HZ and MDC_FREQ_HZ are frequencies in hertz. start_i
//                captures read/write, PHY/register addresses and write data.
//                busy_o prevents overlap; valid_o qualifies data_o/error_o.
//                mdio_oe_o is deasserted for turnaround and read-data sampling.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_PERIPS_MDIO_SV
`define ES_PERIPS_MDIO_SV
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module es_perips_mdio #(
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// Requested management clock frequency in hertz.
  parameter int unsigned MDC_FREQ_HZ = 1_000_000
) (
  input var logic clk_i, rst_ni, start_i, read_i,
  input var logic [4:0] phy_i, reg_i,
  input var logic [15:0] data_i,
  input var logic mdio_i,
  output logic mdc_o, mdio_o, mdio_oe_o,
  output logic busy_o, valid_o, error_o,
  output logic [15:0] data_o
);
  localparam int unsigned HALF = CLK_FREQ_HZ / (2 * MDC_FREQ_HZ);
  generate
    if ((HALF < 2) || (MDC_FREQ_HZ > 2_500_000)) begin : g_invalid
      SW_MDIO_INVALID_CLOCK invalid_parameters ();
    end
  endgenerate
  // --------------------------------------------------------------------------
  // Transaction registers
  //
  // bit_q descends from preamble bit 63 through data bit 0. Read turnaround
  // releases the pad before sampling the acknowledgement; data is sampled on
  // MDC rising edges and the index advances on falling edges.
  // --------------------------------------------------------------------------
  logic [63:0] frame_q;
  logic [5:0] bit_q;
  logic [31:0] timer_q;
  logic read_q;
  assign mdio_o = frame_q[bit_q];
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
        mdc_o <= 1'b0;
        if (start_i) begin
          frame_q <= {32'hffff_ffff, 2'b01, (read_i ? 2'b10 : 2'b01), phy_i, reg_i, 2'b10, data_i};
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
          if (read_q && (bit_q == 6'd16)) error_o <= mdio_i;
          if (read_q && (bit_q < 6'd16)) data_o <= {data_o[14:0], mdio_i};
        end else if (bit_q == 6'd0) begin
          busy_o  <= 1'b0;
          valid_o <= 1'b1;
        end else bit_q <= bit_q - 6'd1;
      end
    end
  end
endmodule
`default_nettype wire
`endif
