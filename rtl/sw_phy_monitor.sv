// Marvell 88E1111 copper manager: discover, advertise only 100FD, then poll.
// Status is unknown until a complete successful poll, never inferred from straps.
`timescale 1ns/1ps
`ifndef SW_PHY_MONITOR_SV
`define SW_PHY_MONITOR_SV
`default_nettype none
module sw_phy_monitor #(
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  parameter int unsigned POLL_INTERVAL_MS = 100,
  parameter int unsigned RESET_WAIT_MS = 20
) (
  input logic clk_i, rst_ni, mdio_i,
  output logic mdc_o, mdio_o, mdio_oe_o,
  output logic [7:0] status_o,
  output logic enabled_o
);
  localparam logic [63:0] POLL = (64'(CLK_FREQ_HZ)*64'(POLL_INTERVAL_MS)+64'd999)/64'd1000;
  localparam logic [63:0] RESET_WAIT = (64'(CLK_FREQ_HZ)*64'(RESET_WAIT_MS)+64'd999)/64'd1000;
  typedef enum logic [1:0] {S_DELAY, S_START, S_WAIT} state_e;
  state_e state_q;
  logic [63:0] delay_q;
  logic [4:0] address_q, reg_addr;
  logic [3:0] step_q;
  logic read_cmd, valid, error, busy;
  logic [15:0] write_data, read_data;
  logic link_q;
  assign enabled_o = status_o[0] && status_o[1] && status_o[2] && (status_o[4:3] == 2'd1) && !status_o[5];
  always_comb begin
    reg_addr = 5'd17; read_cmd = 1'b1; write_data = 16'd0;
    case (step_q)
      4'd0: reg_addr = 5'd2;
      4'd1: reg_addr = 5'd3;
      4'd2: begin reg_addr = 5'd22; read_cmd = 1'b0; end
      4'd3: begin reg_addr = 5'd4; read_cmd = 1'b0; write_data = 16'h0101; end
      4'd4: begin reg_addr = 5'd9; read_cmd = 1'b0; end
      4'd5: begin reg_addr = 5'd0; read_cmd = 1'b0; write_data = 16'h1200; end
      4'd6: reg_addr = 5'd4;
      4'd7: reg_addr = 5'd9;
      4'd8, 4'd9: reg_addr = 5'd1; // BMSR link is latch-low: discard first read.
      default: reg_addr = 5'd17;
    endcase
  end
  sw_mdio #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_mdio (
    .clk_i(clk_i), .rst_ni(rst_ni), .start_i(state_q == S_START), .read_i(read_cmd),
    .phy_i(address_q), .reg_i(reg_addr), .data_i(write_data), .mdio_i(mdio_i),
    .mdc_o(mdc_o), .mdio_o(mdio_o), .mdio_oe_o(mdio_oe_o),
    .busy_o(busy), .valid_o(valid), .error_o(error), .data_o(read_data));
  logic unused_busy;
  assign unused_busy = busy;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_DELAY; delay_q <= RESET_WAIT; address_q <= '0;
      step_q <= '0; status_o <= '0; link_q <= 1'b0;
    end else begin
      case (state_q)
        S_DELAY: if (delay_q == 64'd0) state_q <= S_START;
                 else delay_q <= delay_q - 64'd1;
        S_START: state_q <= S_WAIT;
        S_WAIT: if (valid) begin
          state_q <= S_START;
          if (step_q == 4'd0) begin
            if (!error && (read_data == 16'h0141)) step_q <= 4'd1;
            else if (address_q == 5'd31) begin
              address_q <= '0; status_o <= 8'h20; delay_q <= POLL; state_q <= S_DELAY;
            end else address_q <= address_q + 5'd1;
          end else if (error || ((step_q == 4'd1) && ((read_data & 16'hfff0) != 16'h0cc0)) ||
                       ((step_q == 4'd6) && (read_data != 16'h0101)) ||
                       ((step_q == 4'd7) && ((read_data & 16'h0300) != 16'd0))) begin
            status_o <= 8'h20; step_q <= '0; address_q <= '0;
            delay_q <= POLL; state_q <= S_DELAY;
          end else if (step_q == 4'd9) begin
            link_q <= read_data[2] && read_data[5]; step_q <= 4'd10;
          end else if (step_q == 4'd10) begin
            // Vendor status 17.11 resolves speed/duplex; 17.10 is current link.
            status_o <= {2'd0, 1'b0, read_data[15:14], read_data[13],
                         link_q && read_data[10] && read_data[11], 1'b1};
            step_q <= 4'd8; delay_q <= POLL; state_q <= S_DELAY;
          end else step_q <= step_q + 4'd1;
        end
        default: state_q <= S_DELAY;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif
