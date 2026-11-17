// ============================================================================
//  File        : es_mac_frame_tx.sv
//  Description : Transmit framer: canonical 8-bit client byte stream to a
//                complete wire frame (preamble/SFD, short-frame pad, FCS, IFG).
//
//                TX updates its pins on the first clock of each octet window,
//                which is where the transmit monitors sample.  One octet is
//                held for BYTE_PERIOD clocks; the FCS final octet keeps its
//                enable high for the first IFG clock so it is not lost.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_FRAME_TX_SV
`define ES_MAC_FRAME_TX_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_mac_frame_tx #(
  parameter int unsigned BYTE_PERIOD    = 1,
  parameter int unsigned IFG_OCTETS     = 12,
  parameter int unsigned MIN_CLIENT_LEN = 60
) (
  input  var logic       clk_i,  ///< core clock
  input  var logic       rst_ni,  ///< active-low synchronous reset

  input  var logic       b_valid_i,  ///< client byte valid
  output     logic       b_ready_o,  ///< client byte ready
  input  var logic [7:0] b_data_i,  ///< client byte
  input  var logic       b_sof_i,  ///< start of frame
  input  var logic       b_eof_i,  ///< end of frame

  output     logic       oct_en_o,  ///< PHY octet enable
  output     logic [7:0] oct_d_o  ///< PHY octet
);

  localparam int unsigned BPW    = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  localparam logic [BPW-1:0] PHASE_LAST = BYTE_PERIOD[BPW-1:0] - BPW'(1);
  localparam int unsigned CNT_W  = ES_LEN_W + 1;

  typedef enum logic [2:0] {
    T_IDLE,
    T_PRE,
    T_DATA,
    T_PAD,
    T_FCS,
    T_IFG
  } tx_fr_state_e;

  logic [BPW-1:0] phase;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                  phase <= '0;
    else if (phase == PHASE_LAST) phase <= '0;
    else                          phase <= phase + BPW'(1);
  end
  logic tick;
  assign tick = (phase == '0);

  tx_fr_state_e     state_q;
  logic [3:0]       pre_idx;
  logic [1:0]       fcs_idx;
  logic [CNT_W-1:0] client_cnt;
  logic [CNT_W-1:0] ifg_cnt;
  logic [31:0]      crc_q;
  logic [31:0]      crc_fin;
  logic [7:0]       crc_din;
  logic             crc_en;
  logic             crc_clr;

  // Single driver for crc_q: the top-of-block update.  Mixing it into the FSM
  // case would give the register two non-blocking drivers in one process.
  assign crc_fin  = crc_q ^ ES_CRC32_XOROUT;
  assign crc_din  = (state_q == T_PAD) ? 8'h00 : b_data_i;
  assign crc_en   = tick && (((state_q == T_DATA) && b_valid_i) || (state_q == T_PAD));
  assign crc_clr  = (state_q == T_IDLE);
  // The final FCS octet is registered on the same edge that moves the FSM to
  // T_IFG, so a purely combinational enable would fall on that very edge and
  // the last octet would never have an enabled window.  Keeping the enable
  // high for the first T_IFG clock gives it a full octet time on the pins.
  assign oct_en_o = (state_q == T_PRE) || (state_q == T_DATA) ||
                    (state_q == T_PAD) || (state_q == T_FCS) ||
                    ((state_q == T_IFG) && (ifg_cnt == '0));
  // T_PRE never consumes the FWFT egress queue, so the first client octet is
  // still presented when T_DATA takes over on the following octet time.
  assign b_ready_o = tick && (state_q == T_DATA) && b_valid_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q    <= T_IDLE;
      pre_idx    <= '0;
      fcs_idx    <= '0;
      client_cnt <= '0;
      ifg_cnt    <= '0;
      oct_d_o    <= '0;
      crc_q      <= ES_CRC32_INIT;
    end else begin
      if (crc_clr)     crc_q <= ES_CRC32_INIT;
      else if (crc_en) crc_q <= es_crc32_absorb_octet(crc_q, crc_din);

      if (tick) begin
        case (state_q)
          T_IDLE: begin
            oct_d_o <= '0;
            if (b_valid_i && b_sof_i) begin
              state_q    <= T_PRE;
              pre_idx    <= 4'd0;
              client_cnt <= '0;
              oct_d_o    <= ES_PL_PREAMBLE_OCTET;
            end
          end

          T_PRE: begin
            // T_IDLE already registered the first 0x55 on the edge that
            // raised oct_en_o.  T_PRE therefore emits the remaining six 0x55
            // octets (pre_idx 0..5) and then the SFD (pre_idx 6); emitting
            // seven more here would put eight preamble octets on the wire and
            // shift every subsequent field by one.
            if (pre_idx == 4'd6) begin
              oct_d_o <= ES_PL_SFD_OCTET;
              state_q <= T_DATA;
            end else begin
              oct_d_o <= ES_PL_PREAMBLE_OCTET;
              pre_idx <= pre_idx + 4'd1;
            end
          end

          T_DATA: begin
            if (b_valid_i) begin
              oct_d_o    <= b_data_i;
              client_cnt <= client_cnt + CNT_W'(1);
              if (b_eof_i) begin
                if (client_cnt + CNT_W'(1) < CNT_W'(MIN_CLIENT_LEN)) begin
                  state_q <= T_PAD;
                end else begin
                  state_q <= T_FCS;
                  fcs_idx <= '0;
                end
              end
            end
          end

          T_PAD: begin
            oct_d_o    <= 8'h00;
            client_cnt <= client_cnt + CNT_W'(1);
            if (client_cnt + CNT_W'(1) >= CNT_W'(MIN_CLIENT_LEN)) begin
              state_q <= T_FCS;
              fcs_idx <= '0;
            end
          end

          T_FCS: begin
            case (fcs_idx)
              2'd0:    oct_d_o <= crc_fin[7:0];
              2'd1:    oct_d_o <= crc_fin[15:8];
              2'd2:    oct_d_o <= crc_fin[23:16];
              default: oct_d_o <= crc_fin[31:24];
            endcase
            if (fcs_idx == 2'd3) begin
              state_q <= T_IFG;
              ifg_cnt <= '0;
            end else begin
              fcs_idx <= fcs_idx + 2'd1;
            end
          end

          T_IFG: begin
            oct_d_o <= '0;
            if (ifg_cnt + CNT_W'(1) >= CNT_W'(IFG_OCTETS)) begin
              state_q <= T_IDLE;
              ifg_cnt <= '0;
            end else begin
              ifg_cnt <= ifg_cnt + CNT_W'(1);
            end
          end

          default: begin
            state_q <= T_IDLE;
          end
        endcase
      end
    end
  end

endmodule : es_mac_frame_tx

`default_nettype wire

`endif  // ES_MAC_FRAME_TX_SV
