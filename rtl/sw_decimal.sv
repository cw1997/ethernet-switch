// Serial double-dabble formatter. Decimal conversion never sits in the fabric.
`timescale 1ns/1ps
`ifndef SW_DECIMAL_SV
`define SW_DECIMAL_SV
`default_nettype none
module sw_decimal (
  input logic clk_i, rst_ni, start_i,
  input logic [63:0] value_i,
  output logic valid_o,
  output logic [79:0] bcd_o
);
  logic busy_q;
  logic [6:0] left_q;
  logic [63:0] value_q;
  logic [79:0] bcd_q, corrected;
  logic unused_correction;
  assign unused_correction = corrected[79];
  function automatic logic [79:0] correct(input logic [79:0] x);
    logic [79:0] y;
    y = x;
    for (int unsigned d = 0; d < 20; d++)
      if (x[d*4 +: 4] >= 4'd5) y[d*4 +: 4] = x[d*4 +: 4] + 4'd3;
    correct = y;
  endfunction
  assign corrected = correct(bcd_q);
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      busy_q <= 1'b0; valid_o <= 1'b0; bcd_o <= '0;
      left_q <= '0; value_q <= '0; bcd_q <= '0;
    end else begin
      valid_o <= 1'b0;
      if (!busy_q) begin
        if (start_i) begin busy_q <= 1'b1; left_q <= 7'd64; value_q <= value_i; bcd_q <= '0; end
      end else begin
        bcd_q <= {corrected[78:0], value_q[63]}; value_q <= {value_q[62:0], 1'b0};
        left_q <= left_q - 7'd1;
        if (left_q == 7'd1) begin busy_q <= 1'b0; valid_o <= 1'b1; bcd_o <= {corrected[78:0], value_q[63]}; end
      end
    end
  end
endmodule
`default_nettype wire
`endif
