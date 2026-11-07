// ============================================================================
//  File        : es_perips_phy_88e1111.sv
//  Description : Marvell 88E1111 Clause-22 discovery and status polling.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                The block advertises 100 Mbit/s full duplex only.  Status stays
//                unknown until a complete successful poll, and because the BMSR
//                link bit is latch-low it takes two reads to see a stable link.
//
//                CLK_FREQ_HZ is the core frequency; POLL_INTERVAL_MS and
//                RESET_WAIT_MS are clock-counted milliseconds.  mdio_oe_o
//                controls the external tri-state buffer.  status_o packs
//                validity, link, duplex, speed and management-error bits, and
//                enabled_o is the traffic-enable decision derived from them.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_PERIPS_PHY_88E1111_SV
`define ES_PERIPS_PHY_88E1111_SV

`default_nettype none

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
  /// PHY discovery and negotiated status; validity qualifies every field.
  /// Bits 0..5: valid, link, duplex, two-bit speed, management error.  The
  /// board may enable its MII path only for a valid 100-Mbit full-duplex link.
  output    logic [7:0] status_o,
  /// Traffic-enable decision for a valid 100-Mbit full-duplex link.
  output    logic enabled_o
);

  // --------------------------------------------------------------------------
  // Timing
  //
  // Both delays are rounded up from milliseconds to core clocks: the PHY needs
  // the reset wait in full, so rounding down would sample it too early.
  // --------------------------------------------------------------------------
  localparam logic [63:0] POLL =
      ((64'(CLK_FREQ_HZ) * 64'(POLL_INTERVAL_MS)) + 64'd999) / 64'd1000;
  localparam logic [63:0] RESET_WAIT =
      ((64'(CLK_FREQ_HZ) * 64'(RESET_WAIT_MS)) + 64'd999) / 64'd1000;

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_DELAY,  ///< wait out RESET_WAIT or the inter-poll delay
    S_START,  ///< present one MDIO transaction
    S_WAIT    ///< hold until the controller reports completion
  } state_e;

  state_e state_q;

  logic [63:0] delay_q;    ///< remaining delay in core clocks
  logic [ 4:0] address_q;  ///< PHY address retained once the vendor ID matches
  logic        link_q;     ///< BMSR link sampled during this poll
  /// Write-pass step.  Steps cover identification, advertisement setup and
  /// readback, then link resolution.
  logic [ 3:0] step_q;

  // --------------------------------------------------------------------------
  // MDIO transaction request
  //
  // The register address, direction and write data for the current step are a
  // pure decode of `step_q`.  Step 17 (vendor status) is the default so that an
  // out-of-range step cannot drive an undefined register address onto the bus.
  // --------------------------------------------------------------------------
  logic        read_cmd;
  logic [ 4:0] reg_addr;
  logic [15:0] write_data;

  always_comb begin
    read_cmd   = 1'b1;
    reg_addr   = 5'd17;
    write_data = 16'd0;
    case (step_q)
      4'd0:       reg_addr = 5'd2;   // PHYIDR1
      4'd1:       reg_addr = 5'd3;   // PHYIDR2
      4'd2: begin
        reg_addr = 5'd22;            // PHYSCR: leave power-down
        read_cmd = 1'b0;
      end
      4'd3: begin
        reg_addr   = 5'd4;           // ANAR: advertise 100BASE-TX full duplex
        read_cmd   = 1'b0;
        write_data = 16'h0101;
      end
      4'd4: begin
        reg_addr = 5'd9;             // GBCR: restart auto-negotiation
        read_cmd = 1'b0;
      end
      4'd5: begin
        reg_addr   = 5'd0;           // BMCR: begin auto-negotiation
        read_cmd   = 1'b0;
        write_data = 16'h1200;
      end
      4'd6:       reg_addr = 5'd4;   // ANAR readback
      4'd7:       reg_addr = 5'd9;   // GBCR readback
      4'd8, 4'd9: reg_addr = 5'd1;   // BMSR link is latch-low: discard first read
      default:    reg_addr = 5'd17;  // PHYSR: vendor-resolved speed and duplex
    endcase
  end

  // --------------------------------------------------------------------------
  // MDIO controller
  // --------------------------------------------------------------------------
  logic        valid;
  logic        error;
  logic        busy;
  logic [15:0] read_data;

  es_perips_mdio #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ)
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

  // The controller's busy flag is not needed here: S_WAIT is left on `valid`,
  // which is only asserted once the controller has returned to idle.
  logic unused_busy;
  assign unused_busy = busy;

  // --------------------------------------------------------------------------
  // Traffic enable
  //
  // Valid, link, full duplex, 100 Mbit/s (speed code 01) and no management
  // error - all five from the last successful poll.
  // --------------------------------------------------------------------------
  assign enabled_o = status_o[0] && status_o[1] && status_o[2] &&
                     (status_o[4:3] == 2'd1) && !status_o[5];

  // --------------------------------------------------------------------------
  // Poll sequencer
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q   <= S_DELAY;
      delay_q   <= RESET_WAIT;
      address_q <= '0;
      step_q    <= '0;
      status_o  <= '0;
      link_q    <= 1'b0;
    end else begin
      case (state_q)
        S_DELAY: if (delay_q == 64'd0) state_q <= S_START;
        else delay_q <= delay_q - 64'd1;
        S_START: state_q <= S_WAIT;
        S_WAIT: if (valid) begin
          state_q <= S_START;
          if (step_q == 4'd0) begin
            // Discovery: sweep the five-bit PHY address space until the vendor
            // ID matches.  Reaching address 31 without a match parks the block
            // in the error state and retries after the poll interval.
            if (!error && (read_data == 16'h0141)) step_q <= 4'd1;
            else if (address_q == 5'd31) begin
              address_q <= '0;
              status_o  <= 8'h20;
              delay_q   <= POLL;
              state_q   <= S_DELAY;
            end else address_q <= address_q + 5'd1;
          end else if (error ||
                       ((step_q == 4'd1) && ((read_data & 16'hfff0) != 16'h0cc0)) ||
                       ((step_q == 4'd6) && (read_data != 16'h0101)) ||
                       ((step_q == 4'd7) && ((read_data & 16'h0300) != 16'd0))) begin
            // Any management error, a wrong model number, an advertisement that
            // did not take, or a link that is not up after negotiation all end
            // the poll in the error state.
            status_o  <= 8'h20;
            step_q    <= '0;
            address_q <= '0;
            delay_q   <= POLL;
            state_q   <= S_DELAY;
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
            step_q  <= 4'd8;
            delay_q <= POLL;
            state_q <= S_DELAY;
          end else step_q <= step_q + 4'd1;
        end
        default: state_q <= S_DELAY;
      endcase
    end
  end

endmodule : es_perips_phy_88e1111

`default_nettype wire

`endif  // ES_PERIPS_PHY_88E1111_SV
