// ============================================================================
//  File        : sw_phy_adapter.sv
//  Description : Synchronous GMII/MII/RMII/RGMII physical-symbol adapter.
//
//                The switch core consumes a level-held, 8-bit GMII-style byte
//                stream.  This block converts synchronous PHY symbols to that
//                stream and converts the transmit stream back to the selected
//                PHY representation.  Raw PHY clocks and DDR I/O cells belong
//                in a technology-specific outer shell; all signals here are
//                already synchronous to `clk_i`.
//
//                MII sends the low nibble first, RMII sends the low two bits
//                first, and RGMII uses an explicit rise/fall nibble pair.
//                Optional receive preamble removal preserves the existing
//                switch RX contract, which starts at the destination MAC.
// ============================================================================
`timescale 1ns/1ps

`ifndef SW_PHY_ADAPTER_SV
`define SW_PHY_ADAPTER_SV

`default_nettype none

`include "sw_defs.sv"

module sw_phy_adapter #(
  /// External representation: GMII, MII, RMII, or captured RGMII.  The type is
  /// 3 bits wide (see sw_phy_if_e) so further interfaces can be added without
  /// renumbering; an unassigned value holds every output idle.
  parameter logic [2:0] PHY_IF = SW_PHY_GMII,
  /// Number of clk_i cycles per canonical GMII octet.
  parameter int unsigned BYTE_PERIOD = 1,
  /// 1 when the receive pins include 7 x 55 followed by D5.
  parameter logic PHY_RX_PREAMBLE = 1'b0
) (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic       gmii_rx_en_i,
  input  logic       gmii_rx_er_i,
  input  logic [7:0] gmii_rx_data_i,
  input  logic       mii_rx_en_i,
  input  logic       mii_rx_er_i,
  input  logic [3:0] mii_rx_data_i,
  input  logic       rmii_rx_dv_i,
  input  logic       rmii_rx_er_i,
  input  logic [1:0] rmii_rx_data_i,
  input  logic       rgmii_rx_ce_i,
  input  logic [3:0] rgmii_rx_rising_data_i,
  input  logic [3:0] rgmii_rx_falling_data_i,
  input  logic       rgmii_rx_rising_ctl_i,
  input  logic       rgmii_rx_falling_ctl_i,

  output logic       gmii_rx_en_o,
  output logic [7:0] gmii_rx_data_o,

  input  logic       gmii_tx_en_i,
  input  logic [7:0] gmii_tx_data_i,

  output logic       gmii_tx_en_o,
  output logic [7:0] gmii_tx_data_o,
  output logic       gmii_tx_er_o,
  output logic       mii_tx_en_o,
  output logic [3:0] mii_tx_data_o,
  output logic       mii_tx_er_o,
  output logic       rmii_tx_en_o,
  output logic [1:0] rmii_tx_data_o,
  output logic       rgmii_tx_ce_o,
  output logic [3:0] rgmii_tx_rising_data_o,
  output logic [3:0] rgmii_tx_falling_data_o,
  output logic       rgmii_tx_rising_ctl_o,
  output logic       rgmii_tx_falling_ctl_o
);

  localparam int unsigned BPW = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  localparam logic [BPW-1:0] PHASE_LAST = BPW'(BYTE_PERIOD - 32'd1);
  // MII and RMII are normally instantiated with BYTE_PERIOD values of 10 or
  // 100.  The rounded boundaries also make the synchronous model usable for a
  // non-integral symbol ratio such as RMII at 100 Mbit/s on a 125 MHz core:
  // the four windows become 3,2,3,2 clocks for a ten-clock byte.
  localparam logic [BPW-1:0] PHASE_HALF =
      BPW'((BYTE_PERIOD + 32'd1) / 32'd2);
  localparam logic [BPW-1:0] PHASE_Q1 = BPW'((BYTE_PERIOD + 32'd3) / 32'd4);
  localparam logic [BPW-1:0] PHASE_Q2 = BPW'((BYTE_PERIOD + 32'd1) / 32'd2);
  localparam logic [BPW-1:0] PHASE_Q3 =
      BPW'((32'd3 * BYTE_PERIOD + 32'd3) / 32'd4);

  logic [BPW-1:0] phase;
  logic [3:0]     mii_rx_low_q;
  logic           mii_rx_low_er_q;
  logic [1:0]     rmii_rx_chunk0_q;
  logic [1:0]     rmii_rx_chunk1_q;
  logic [1:0]     rmii_rx_chunk2_q;
  logic           rmii_rx_er_q;

  logic [7:0]     rx_byte;
  logic           phy_rx_active;
  logic           phy_rx_error;
  logic           rx_byte_event;
  logic           phy_rx_event;
  logic           rx_boundary;
  logic           rx_end_event;
  logic           rx_payload_q;
  logic           rx_bad_q;
  logic [3:0]     rx_preamble_q;
  logic           rx_en_q;
  logic [7:0]     rx_data_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      phase             <= '0;
      mii_rx_low_q     <= 4'd0;
      mii_rx_low_er_q  <= 1'b0;
      rmii_rx_chunk0_q <= 2'd0;
      rmii_rx_chunk1_q <= 2'd0;
      rmii_rx_chunk2_q <= 2'd0;
      rmii_rx_er_q     <= 1'b0;
      rx_payload_q     <= !PHY_RX_PREAMBLE;
      rx_bad_q         <= 1'b0;
      rx_preamble_q    <= 4'd0;
      rx_en_q          <= 1'b0;
      rx_data_q        <= 8'h00;
    end else begin
      if (phase == PHASE_LAST) phase <= '0;
      else                     phase <= phase + BPW'(1);

      if (PHY_IF == SW_PHY_MII) begin
        if (phase == '0) begin
          mii_rx_low_q    <= mii_rx_data_i;
          mii_rx_low_er_q <= mii_rx_er_i;
        end
      end else if (PHY_IF == SW_PHY_RMII) begin
        if (phase == '0) begin
          rmii_rx_chunk0_q <= rmii_rx_data_i;
          rmii_rx_er_q     <= rmii_rx_er_i;
        end else if (phase == PHASE_Q1) begin
          rmii_rx_chunk1_q <= rmii_rx_data_i;
          rmii_rx_er_q     <= rmii_rx_er_q || rmii_rx_er_i;
        end else if (phase == PHASE_Q2) begin
          rmii_rx_chunk2_q <= rmii_rx_data_i;
          rmii_rx_er_q     <= rmii_rx_er_q || rmii_rx_er_i;
        end else if (phase == PHASE_Q3) begin
          rmii_rx_er_q     <= rmii_rx_er_q || rmii_rx_er_i;
        end
      end

      // A low PHY enable is only acted on at a byte boundary.  This is the
      // important one-byte holding delay: at the boundary where the last byte
      // is assembled, the core still samples the previous registered byte;
      // the following boundary clears rx_en_q after the core has sampled it.
      //
      // A reserved encoding (an interface the enum has not assigned yet) holds
      // the receive state cleared the same way, so an elaborated-but-unmodelled
      // port cannot inject activity into the switch core.  The condition is a
      // constant, so synthesis removes the whole branch.
      if (PHY_IF > SW_PHY_RGMII) begin
        rx_payload_q <= !PHY_RX_PREAMBLE;
        rx_bad_q     <= 1'b0;
        rx_preamble_q <= 4'd0;
        rx_en_q      <= 1'b0;
      end else if (rx_end_event) begin
        rx_payload_q <= !PHY_RX_PREAMBLE;
        rx_bad_q     <= 1'b0;
        rx_preamble_q <= 4'd0;
        rx_en_q      <= 1'b0;
      end else if (phy_rx_event) begin
        // A PHY coding error invalidates the complete frame, including an error
        // reported on the preamble.  Otherwise a bad preamble could be followed
        // by a plausible SFD and be mistaken for a clean frame.
        if (phy_rx_error || rx_bad_q) begin
          rx_bad_q <= 1'b1;
          rx_en_q  <= 1'b0;
        end else if (PHY_RX_PREAMBLE && !rx_payload_q) begin
          rx_en_q <= 1'b0;
          if (rx_preamble_q < 4'd7) begin
            if (rx_byte == 8'h55) begin
              rx_preamble_q <= rx_preamble_q + 4'd1;
            end else begin
              rx_bad_q <= 1'b1;
            end
          end else if (rx_byte == 8'hD5) begin
            rx_payload_q <= 1'b1;
          end else begin
            rx_bad_q <= 1'b1;
          end
        end else begin
          rx_data_q <= rx_byte;
          rx_en_q   <= 1'b1;
        end
      end
    end
  end

  always_comb begin
    phy_rx_active = 1'b0;
    phy_rx_error  = 1'b0;
    rx_byte       = 8'h00;

    case (PHY_IF)
      SW_PHY_GMII: begin
        phy_rx_active = gmii_rx_en_i;
        phy_rx_error  = gmii_rx_er_i;
        rx_byte       = gmii_rx_data_i;
      end
      SW_PHY_MII: begin
        phy_rx_active = mii_rx_en_i;
        phy_rx_error  = mii_rx_er_i || mii_rx_low_er_q;
        rx_byte       = {mii_rx_data_i, mii_rx_low_q};
      end
      SW_PHY_RMII: begin
        phy_rx_active = rmii_rx_dv_i;
        phy_rx_error  = rmii_rx_er_q || rmii_rx_er_i;
        rx_byte       = {rmii_rx_data_i, rmii_rx_chunk2_q,
                         rmii_rx_chunk1_q, rmii_rx_chunk0_q};
      end
      SW_PHY_RGMII: begin
        // RX_CTL rising is RX_DV; the XOR of the two controls is RX_ER.
        phy_rx_active = rgmii_rx_rising_ctl_i;
        phy_rx_error  = rgmii_rx_rising_ctl_i != rgmii_rx_falling_ctl_i;
        rx_byte       = {rgmii_rx_falling_data_i, rgmii_rx_rising_data_i};
      end
      default: begin
        phy_rx_active = 1'b0;
        phy_rx_error  = 1'b0;
        rx_byte       = 8'h00;
      end
    endcase

    rx_byte_event = (PHY_IF == SW_PHY_RGMII) ? rgmii_rx_ce_i :
                    (phase == PHASE_LAST);
    phy_rx_event  = phy_rx_active && rx_byte_event;
    rx_boundary   = (PHY_IF == SW_PHY_RGMII) ? rgmii_rx_ce_i :
                    (phase == PHASE_LAST);
    // The final active symbol is a closing event only when it is a complete
    // canonical byte. RGMII supplies that event explicitly through CE; MII and
    // RMII use the derived byte boundary.
    rx_end_event  = !phy_rx_active && rx_boundary;

    // rx_data_q and rx_en_q are only changed at byte boundaries, so both remain
    // stable for the complete canonical GMII byte window.
    gmii_rx_en_o   = rx_en_q;
    gmii_rx_data_o = rx_data_q;

    gmii_tx_en_o            = 1'b0;
    gmii_tx_data_o          = 8'h00;
    gmii_tx_er_o            = 1'b0;
    mii_tx_en_o             = 1'b0;
    mii_tx_data_o           = 4'h0;
    mii_tx_er_o             = 1'b0;
    rmii_tx_en_o            = 1'b0;
    rmii_tx_data_o          = 2'b00;
    rgmii_tx_ce_o           = 1'b0;
    rgmii_tx_rising_data_o  = 4'h0;
    rgmii_tx_falling_data_o = 4'h0;
    rgmii_tx_rising_ctl_o   = 1'b0;
    rgmii_tx_falling_ctl_o  = 1'b0;

    case (PHY_IF)
      SW_PHY_GMII: begin
        gmii_tx_en_o   = gmii_tx_en_i;
        gmii_tx_data_o = gmii_tx_data_i;
      end
      SW_PHY_MII: begin
        mii_tx_en_o   = gmii_tx_en_i;
        mii_tx_data_o = (phase < PHASE_HALF) ? gmii_tx_data_i[3:0] :
                                                   gmii_tx_data_i[7:4];
      end
      SW_PHY_RMII: begin
        rmii_tx_en_o = gmii_tx_en_i;
        if (phase < PHASE_Q1)      rmii_tx_data_o = gmii_tx_data_i[1:0];
        else if (phase < PHASE_Q2) rmii_tx_data_o = gmii_tx_data_i[3:2];
        else if (phase < PHASE_Q3) rmii_tx_data_o = gmii_tx_data_i[5:4];
        else                       rmii_tx_data_o = gmii_tx_data_i[7:6];
      end
      SW_PHY_RGMII: begin
        rgmii_tx_ce_o           = gmii_tx_en_i && (phase == PHASE_LAST);
        rgmii_tx_rising_data_o  = gmii_tx_data_i[3:0];
        rgmii_tx_falling_data_o = gmii_tx_data_i[7:4];
        rgmii_tx_rising_ctl_o   = gmii_tx_en_i;
        rgmii_tx_falling_ctl_o  = gmii_tx_en_i;
      end
      default: begin
        // All outputs remain idle for an invalid mode encoding.
      end
    endcase
  end

endmodule : sw_phy_adapter

`default_nettype wire

`endif // SW_PHY_ADAPTER_SV
