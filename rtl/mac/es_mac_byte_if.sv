// ============================================================================
//  File        : es_mac_byte_if.sv
//  Description : The 8-bit byte-stream boundary between a PHY and the staged
//                switch core.  Contains two independent framer modules.
//
//                D5 contract: the RX framer ITSELF hunts for 7 x 0x55 + 0xD5.
//                The PHY is not assumed to have stripped the preamble.  A
//                broken run produces no bytes at all.  The TX framer emits the
//                preamble/SFD, pads short client data, recomputes the FCS and
//                inserts the inter-frame gap.  The switch core therefore sees
//                MAC client data only and has no line-format knowledge.
//
//                Both framers use the shared sw_crc32_absorb_octet() function
//                rather than instantiating es_common_crc32: that module's
//                `crc_fin_o` would be unconnected on RX (and `resid_ok_o` on
//                TX), which needs a PINCONNECTEMPTY waiver.  The function is
//                the same reflected polynomial, just written as eight bit
//                steps instead of a table lookup.
//
//                Cadence: one octet is presented by the PHY (or by the MII /
//                RMII serdes) for BYTE_PERIOD clocks.  RX samples on the last
//                clock of that window, exactly like the legacy framer, so the
//                existing bus functional models drive it unchanged.  TX
//                updates its pins on the first clock of each window, which is
//                where the transmit monitors sample.
//
//                The receive side deliberately does not backpressure the PHY:
//                `es_switch_rx_engine` admits a frame only when its FIFO can
//                hold an entire maximum-length frame, so b_ready_i is high for
//                every byte of an admitted frame.  It is still honoured on the
//                closing (S_TAIL) byte.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_BYTE_IF_SV
`define ES_MAC_BYTE_IF_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

// ============================================================================
// Receive framer: PHY octets (preamble + client + FCS) -> client byte stream
// ============================================================================
module es_mac_frame_rx #(
  parameter int unsigned BYTE_PERIOD = 1
) (
  input  var logic       clk_i,
  input  var logic       rst_ni,
  input  var logic       oct_en_i,
  input  var logic [7:0] oct_d_i,
  input  var logic       oct_er_i,

  output      logic       b_valid_o,
  input  var logic        b_ready_i,
  output      logic [7:0] b_data_o,
  output      logic       b_sof_o,
  output      logic       b_eof_o,
  output      logic       b_err_o
);

  localparam int unsigned BPW    = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  localparam logic [BPW-1:0] PHASE_LAST = BYTE_PERIOD[BPW-1:0] - BPW'(1);
  localparam int unsigned CNT_W  = SW_LEN_W + 1;

  typedef enum logic [1:0] {
    S_HUNT,   ///< looking for the preamble / SFD
    S_DATA,   ///< receiving client data and FCS
    S_TAIL    ///< one clock that emits the final client octet with its verdict
  } rx_fr_state_e;

  logic [BPW-1:0] phase;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                  phase <= '0;
    else if (phase == PHASE_LAST) phase <= '0;
    else                          phase <= phase + BPW'(1);
  end

  logic sample;
  assign sample = oct_en_i && (phase == PHASE_LAST);

  rx_fr_state_e        state_q;
  logic [3:0]          pre_cnt;
  logic [CNT_W-1:0]    cnt_q;
  logic [39:0]         dl_q;        // five-octet delay line, oldest at [39:32]
  logic                in_frame_q;
  logic                er_q;
  logic [31:0]         crc_q;
  logic                crc_en;
  logic                crc_clr;
  logic                crc_resid_ok;
  logic                fend;

  // The LFSR is held in reset during the preamble and the inter-frame gap.
  // It must NOT be cleared on the frame-end clock itself: that clock is what
  // makes the final residue available to the S_TAIL verdict.
  assign crc_clr       = !oct_en_i && (state_q == S_HUNT);
  assign crc_en        = sample && (state_q == S_DATA);
  assign crc_resid_ok  = (crc_q == SW_CRC32_RESIDUE);
  assign fend          = !oct_en_i && in_frame_q && (state_q == S_DATA);

  // Five octets of delay put the four FCS octets plus one alignment clock
  // between the wire and the client stream, so the last client octet is
  // emitted on the clock AFTER the final FCS octet was absorbed - exactly when
  // the residue is valid.  b_eof_o and b_err_o can therefore share a clock.
  always_comb begin
    b_valid_o = 1'b0;
    b_data_o  = dl_q[39:32];
    b_sof_o   = 1'b0;
    b_eof_o   = 1'b0;
    b_err_o   = 1'b0;
    case (state_q)
      S_DATA: begin
        if (sample && (cnt_q >= CNT_W'(5))) begin
          b_valid_o = 1'b1;
          b_sof_o   = (cnt_q == CNT_W'(5));
        end
      end
      S_TAIL: begin
        b_valid_o = 1'b1;
        b_eof_o   = 1'b1;
        b_err_o   = !crc_resid_ok || er_q;
      end
      default: begin
        b_valid_o = 1'b0;
      end
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q    <= S_HUNT;
      pre_cnt    <= '0;
      cnt_q      <= '0;
      dl_q       <= '0;
      in_frame_q <= 1'b0;
      er_q       <= 1'b0;
      crc_q      <= SW_CRC32_INIT;
    end else begin
      if (crc_clr)      crc_q <= SW_CRC32_INIT;
      else if (crc_en)  crc_q <= sw_crc32_absorb_octet(crc_q, oct_d_i);

      if (crc_clr)      er_q <= 1'b0;
      else if (sample && oct_er_i) er_q <= 1'b1;

      case (state_q)
        S_HUNT: begin
          if (!oct_en_i) begin
            in_frame_q <= 1'b0;
            pre_cnt    <= '0;
            cnt_q      <= '0;
            dl_q       <= '0;
          end else if (sample) begin
            in_frame_q <= 1'b1;
            if (oct_d_i == SW_PL_PREAMBLE_OCTET) begin
              if (pre_cnt != 4'd7) pre_cnt <= pre_cnt + 4'd1;
            end else if ((oct_d_i == SW_PL_SFD_OCTET) && (pre_cnt == 4'd7)) begin
              state_q <= S_DATA;
              cnt_q   <= '0;
              dl_q    <= '0;
            end else begin
              pre_cnt <= '0;
            end
          end
        end

        S_DATA: begin
          if (sample) begin
            dl_q  <= {dl_q[31:0], oct_d_i};
            cnt_q <= cnt_q + CNT_W'(1);
          end else if (fend) begin
            // A frame too short to have produced any client octet is simply
            // abandoned; the ingress runt check would reject it anyway.
            if (cnt_q >= CNT_W'(6)) begin
              state_q <= S_TAIL;
            end else begin
              state_q    <= S_HUNT;
              in_frame_q <= 1'b0;
              pre_cnt    <= '0;
              cnt_q      <= '0;
              dl_q       <= '0;
            end
          end
        end

        S_TAIL: begin
          // Honour the handshake on the closing octet; b_valid_o stays high
          // until the core accepts it.
          if (b_ready_i) begin
            state_q    <= S_HUNT;
            in_frame_q <= 1'b0;
            pre_cnt    <= '0;
            cnt_q      <= '0;
            dl_q       <= '0;
          end
        end

        default: begin
          state_q <= S_HUNT;
        end
      endcase
    end
  end

endmodule : es_mac_frame_rx

// ============================================================================
// Transmit framer: client byte stream -> complete wire frame
// ============================================================================
module es_mac_frame_tx #(
  parameter int unsigned BYTE_PERIOD     = 1,
  parameter int unsigned IFG_OCTETS      = 12,
  parameter int unsigned MIN_CLIENT_LEN  = 60
) (
  input  var logic       clk_i,
  input  var logic       rst_ni,

  input  var logic       b_valid_i,
  output      logic      b_ready_o,
  input  var logic [7:0] b_data_i,
  input  var logic       b_sof_i,
  input  var logic       b_eof_i,

  output      logic       oct_en_o,
  output      logic [7:0] oct_d_o
);

  localparam int unsigned BPW    = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  localparam logic [BPW-1:0] PHASE_LAST = BYTE_PERIOD[BPW-1:0] - BPW'(1);
  localparam int unsigned CNT_W  = SW_LEN_W + 1;

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
  assign crc_fin  = crc_q ^ SW_CRC32_XOROUT;
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
      crc_q      <= SW_CRC32_INIT;
    end else begin
      if (crc_clr)     crc_q <= SW_CRC32_INIT;
      else if (crc_en) crc_q <= sw_crc32_absorb_octet(crc_q, crc_din);

      if (tick) begin
        case (state_q)
          T_IDLE: begin
            oct_d_o <= '0;
            if (b_valid_i && b_sof_i) begin
              state_q    <= T_PRE;
              pre_idx    <= 4'd0;
              client_cnt <= '0;
              oct_d_o    <= SW_PL_PREAMBLE_OCTET;
            end
          end

          T_PRE: begin
            // T_IDLE already registered the first 0x55 on the edge that
            // raised oct_en_o.  T_PRE therefore emits the remaining six 0x55
            // octets (pre_idx 0..5) and then the SFD (pre_idx 6); emitting
            // seven more here would put eight preamble octets on the wire and
            // shift every subsequent field by one.
            if (pre_idx == 4'd6) begin
              oct_d_o <= SW_PL_SFD_OCTET;
              state_q <= T_DATA;
            end else begin
              oct_d_o <= SW_PL_PREAMBLE_OCTET;
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

`endif  // ES_MAC_BYTE_IF_SV
