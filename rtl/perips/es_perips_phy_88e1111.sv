// ============================================================================
//  File        : es_perips_phy_88e1111.sv
//  Description : Marvell 88E1111 Clause-22 discovery and status polling.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Advertises 100 Mbit/s full duplex only. Status remains unknown
//                until a complete successful poll; latch-low link status
//                requires two BMSR reads.
//  Interface   : CLK_FREQ_HZ is the core frequency; POLL_INTERVAL_MS and
//                RESET_WAIT_MS are clock-counted milliseconds. mdio_oe_o controls
//                the external tri-state buffer. status_o packs validity, link,
//                duplex, speed and management-error bits; enabled_o gates traffic.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_PERIPS_PHY_88E1111_SV
`define ES_PERIPS_PHY_88E1111_SV
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module es_perips_phy_88e1111 #(

  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,

  /// Delay between PHY status polls, in milliseconds.
  parameter int unsigned POLL_INTERVAL_MS = 100,

  /// Startup delay before the first PHY discovery request, in milliseconds.
  parameter int unsigned RESET_WAIT_MS = 20
) (
  /// Clock, synchronous active-low reset, and sampled value from the MDIO pad.
  input var logic clk_i, rst_ni, mdio_i,
  /// MDC plus MDIO output value and active-high pad output enable.
  output    logic mdc_o, mdio_o, mdio_oe_o,
  // Bits 0..5: valid, link, duplex, two-bit speed, management error.
  // The board may enable its MII path only for a valid 100-Mbit full-duplex link.
  /// PHY discovery and negotiated status; validity qualifies every field.
  output    logic [7:0] status_o,
  /// Traffic-enable decision for a valid 100-Mbit full-duplex link.
  output    logic enabled_o
);
  localparam logic [63:0] POLL = (64'(CLK_FREQ_HZ) * 64'(POLL_INTERVAL_MS) + 64'd999) / 64'd1000;
  localparam logic [63:0] RESET_WAIT = (64'(CLK_FREQ_HZ) * 64'(RESET_WAIT_MS) + 64'd999) / 64'd1000;

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_DELAY,
    S_START,
    S_WAIT
  } state_e;
  state_e state_q;
  // Delays are measured in core clocks and rounded up from milliseconds.
  logic [63:0] delay_q;
  // Search addresses until the vendor ID matches, then retain the address for polls.
  logic [4:0] address_q, reg_addr;
  // Steps cover identification, advertisement setup/readback and link resolution.
  logic [3:0] step_q;
  logic read_cmd, valid, error, busy;
  logic [15:0] write_data, read_data;
  logic link_q;
  assign enabled_o = status_o[0] && status_o[1] && status_o[2] && (status_o[4:3] == 2'd1) &&
      !status_o[5];
  always_comb begin
    reg_addr   = 5'd17;
    read_cmd   = 1'b1;
    write_data = 16'd0;
    case (step_q)
      4'd0: reg_addr = 5'd2;
      4'd1: reg_addr = 5'd3;
      4'd2: begin
        reg_addr = 5'd22;
        read_cmd = 1'b0;
      end
      4'd3: begin
        reg_addr   = 5'd4;
        read_cmd   = 1'b0;
        write_data = 16'h0101;
      end
      4'd4: begin
        reg_addr = 5'd9;
        read_cmd = 1'b0;
      end
      4'd5: begin
        reg_addr   = 5'd0;
        read_cmd   = 1'b0;
        write_data = 16'h1200;
      end
      4'd6: reg_addr = 5'd4;
      4'd7: reg_addr = 5'd9;
      4'd8, 4'd9: reg_addr = 5'd1;  // BMSR link is latch-low: discard first read.
      default: reg_addr = 5'd17;
    endcase
  end
  es_perips_mdio #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ)
  ) u_mdio (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .start_i   (state_q == S_START),
    .read_i    (read_cmd),
    .phy_i     (address_q),
    .reg_i     (reg_addr),
    .data_i    (write_data),
    .mdio_i    (mdio_i),
    .mdc_o     (mdc_o),
    .mdio_o    (mdio_o),
    .mdio_oe_o (mdio_oe_o),
    .busy_o    (busy),
    .valid_o   (valid),
    .error_o   (error),
    .data_o    (read_data)
  );
  logic unused_busy;
  assign unused_busy = busy;

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_DELAY;
      delay_q <= RESET_WAIT;
      address_q <= '0;
      step_q <= '0;
      status_o <= '0;
      link_q <= 1'b0;
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
              address_q <= '0;
              status_o  <= 8'h20;
              delay_q   <= POLL;
              state_q   <= S_DELAY;
            end else address_q <= address_q + 5'd1;
          end else if (error || ((step_q == 4'd1) && ((read_data & 16'hfff0) != 16'h0cc0)) ||
                       ((step_q == 4'd6) && (read_data != 16'h0101)) ||
                       ((step_q == 4'd7) && ((read_data & 16'h0300) != 16'd0))) begin
            status_o <= 8'h20;
            step_q <= '0;
            address_q <= '0;
            delay_q <= POLL;
            state_q <= S_DELAY;
          end else if (step_q == 4'd9) begin
            // Require both current link and auto-negotiation completion before
            // combining the result with the vendor-specific resolved status.
            link_q <= read_data[2] && read_data[5];
            step_q <= 4'd10;
          end else if (step_q == 4'd10) begin
            // Vendor status 17.11 resolves speed/duplex; 17.10 is current link.
            status_o <= {
              2'd0,
              1'b0,
              read_data[15:14],
              read_data[13],
              link_q && read_data[10] && read_data[11],
              1'b1
            };
            step_q <= 4'd8;
            delay_q <= POLL;
            state_q <= S_DELAY;
          end else step_q <= step_q + 4'd1;
        end
        default: state_q <= S_DELAY;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif
