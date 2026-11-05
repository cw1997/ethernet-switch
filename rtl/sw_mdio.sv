// Clause 22 management engine, complete preamble on every transaction.
// Board shell owns the only tri-state buffer; the engine itself is pure RTL.
`timescale 1ns/1ps
`ifndef SW_MDIO_SV
`define SW_MDIO_SV
`default_nettype none
module sw_mdio #(
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  parameter int unsigned MDC_FREQ_HZ = 1_000_000
) (
  input logic clk_i, rst_ni, start_i, read_i,
  input logic [4:0] phy_i, reg_i,
  input logic [15:0] data_i,
  input logic mdio_i,
  output logic mdc_o, mdio_o, mdio_oe_o,
  output logic busy_o, valid_o, error_o,
  output logic [15:0] data_o
);
  localparam int unsigned HALF = CLK_FREQ_HZ/(2*MDC_FREQ_HZ);
  generate
    if ((HALF < 2) || (MDC_FREQ_HZ > 2_500_000)) begin : g_invalid
      SW_MDIO_INVALID_CLOCK invalid_parameters();
    end
  endgenerate
  logic [63:0] frame_q;
  logic [5:0] bit_q;
  logic [31:0] timer_q;
  logic read_q;
  assign mdio_o = frame_q[bit_q];
  assign mdio_oe_o = busy_o && (!read_q || (bit_q >= 6'd18));
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      mdc_o <= 1'b0; busy_o <= 1'b0; valid_o <= 1'b0; error_o <= 1'b0;
      frame_q <= '1; bit_q <= '0; timer_q <= '0; read_q <= 1'b0; data_o <= '0;
    end else begin
      valid_o <= 1'b0;
      if (!busy_o) begin
        mdc_o <= 1'b0;
        if (start_i) begin
          frame_q <= {32'hffff_ffff, 2'b01, (read_i ? 2'b10 : 2'b01), phy_i, reg_i, 2'b10, data_i};
          read_q <= read_i; bit_q <= 6'd63; busy_o <= 1'b1;
          timer_q <= 32'(HALF-1); data_o <= '0; error_o <= 1'b0;
        end
      end else if (timer_q != 32'd0) timer_q <= timer_q - 32'd1;
      else begin
        timer_q <= 32'(HALF-1); mdc_o <= !mdc_o;
        if (!mdc_o) begin
          if (read_q && (bit_q == 6'd16)) error_o <= mdio_i;
          if (read_q && (bit_q < 6'd16)) data_o <= {data_o[14:0], mdio_i};
        end else if (bit_q == 6'd0) begin
          busy_o <= 1'b0; valid_o <= 1'b1;
        end else bit_q <= bit_q - 6'd1;
      end
    end
  end
endmodule
`default_nettype wire
`endif
