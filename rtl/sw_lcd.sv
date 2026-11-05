// Write-only HD44780-compatible 16x2 LCD. Input is 32 ASCII bytes, MSB first.
// A complete screen is latched before refresh so its two rows share a snapshot.
`timescale 1ns/1ps
`ifndef SW_LCD_SV
`define SW_LCD_SV
`default_nettype none
module sw_lcd #(
  parameter int unsigned CLK_FREQ_HZ = 50_000_000
) (
  input logic clk_i, rst_ni,
  input logic [255:0] text_i,
  output logic [7:0] data_o,
  output logic rs_o, rw_o, en_o, on_o, blon_o
);
  localparam int unsigned US = (CLK_FREQ_HZ+999_999)/1_000_000;
  typedef enum logic [1:0] {S_WAIT, S_HIGH, S_LOW, S_IDLE} state_e;
  state_e state_q;
  logic [31:0] timer_q;
  logic [5:0] index_q;
  logic [255:0] text_q;
  assign rw_o = 1'b0; assign on_o = 1'b1; assign blon_o = 1'b1;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_WAIT; timer_q <= 32'(40_000*US); index_q <= '0;
      data_o <= '0; rs_o <= 1'b0; en_o <= 1'b0; text_q <= '0;
    end else begin
      if (timer_q != 32'd0) timer_q <= timer_q - 32'd1;
      else case (state_q)
        S_WAIT: begin
          rs_o <= (index_q >= 6'd6) && (index_q != 6'd22);
          case (index_q)
            6'd0, 6'd1: data_o <= 8'h38;
            6'd2: data_o <= 8'h0c;
            6'd3: data_o <= 8'h06;
            6'd4: data_o <= 8'h01;
            6'd5: data_o <= 8'h80;
            6'd22: data_o <= 8'hc0;
            default: data_o <= (index_q < 6'd22) ? text_q[255-(32'(index_q)-32'd6)*32'd8 -: 8] : text_q[127-(32'(index_q)-32'd23)*32'd8 -: 8];
          endcase
          // Data/RS setup for one microsecond before E rises.
          state_q <= S_HIGH; timer_q <= 32'(US);
        end
        S_HIGH: begin en_o <= 1'b1; timer_q <= 32'(US); state_q <= S_LOW; end
        S_LOW: begin
          en_o <= 1'b0;
          timer_q <= ((index_q <= 6'd1) || (index_q == 6'd4)) ? 32'(5000*US) : 32'(50*US);
          if (index_q == 6'd38) state_q <= S_IDLE;
          else begin index_q <= index_q + 6'd1; state_q <= S_WAIT; end
        end
        S_IDLE: if (text_i != text_q) begin text_q <= text_i; index_q <= 6'd5; state_q <= S_WAIT; end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif
