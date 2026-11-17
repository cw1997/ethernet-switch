// ============================================================================
//  File        : es_mac_frame_rx.sv
//  Description : Receive framer: PHY octets (preamble + client + FCS) to the
//                canonical 8-bit client byte stream for the staged switch.
//
//                D5 contract: the framer ITSELF hunts for 7 x 0x55 + 0xD5; the
//                PHY is not assumed to strip the preamble.  A broken run
//                produces no bytes.  RX samples on the last clock of an octet
//                window, so existing bus functional models drive it unchanged.
//                The PHY cannot stall: a frame is dropped wholesale if the
//                switch declines its first beat.  The original FCS is exported
//                as a sideband on EOF for the checksum stage.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_FRAME_RX_SV
`define ES_MAC_FRAME_RX_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_mac_frame_rx #(
  parameter int unsigned BYTE_PERIOD = 1
) (
  input  var logic        clk_i,  ///< core clock
  input  var logic        rst_ni,  ///< active-low synchronous reset
  input  var logic        oct_en_i,  ///< PHY octet enable
  input  var logic [7:0]  oct_d_i,  ///< PHY octet
  input  var logic        oct_er_i,  ///< PHY octet error

  output     logic        b_valid_o,  ///< client byte valid
  input  var logic        b_ready_i,  ///< client byte ready
  output     logic [7:0]  b_data_o,  ///< client byte
  output     logic        b_sof_o,  ///< start of frame
  output     logic        b_eof_o,  ///< end of frame
  output     logic        b_err_o,  ///< frame carried an error
  output     logic [31:0] b_fcs_o  ///< received FCS sideband, first octet in bits 7:0
);

  localparam int unsigned BPW    = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  localparam logic [BPW-1:0] PHASE_LAST = BYTE_PERIOD[BPW-1:0] - BPW'(1);
  localparam int unsigned CNT_W  = 3; // saturates after the first client byte

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
  logic                discard_q;
  logic                fend;

  assign fend = !oct_en_i && in_frame_q && (state_q == S_DATA);
  // Four trailing octets stay in the delay line. The fifth is the last
  // client octet and shares its EOF with the FCS sideband.
  assign b_fcs_o = {dl_q[7:0], dl_q[15:8], dl_q[23:16], dl_q[31:24]};
  always_comb begin
    b_valid_o = 1'b0;
    b_data_o  = dl_q[39:32];
    b_sof_o   = 1'b0;
    b_eof_o   = 1'b0;
    b_err_o   = 1'b0;
    case (state_q)
      S_DATA: begin
        if (sample && !discard_q && (cnt_q >= CNT_W'(5))) begin
          b_valid_o = 1'b1;
          b_sof_o   = (cnt_q == CNT_W'(5));
          b_err_o   = er_q || oct_er_i;
        end
      end
      S_TAIL: begin
        b_valid_o = 1'b1;
        b_eof_o   = 1'b1;
        b_sof_o   = (cnt_q == CNT_W'(5));
        b_err_o   = er_q;
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
      discard_q  <= 1'b0;
    end else begin
      if ((state_q == S_HUNT) && !oct_en_i) er_q <= 1'b0;
      // MII can suppress the errored octet, so there may be no sample
      // strobe on the clock that reports RX_ER.
      else if (oct_er_i) er_q <= 1'b1;

      case (state_q)
        S_HUNT: begin
          if (!oct_en_i) begin
            in_frame_q <= 1'b0;
            pre_cnt    <= '0;
            cnt_q      <= '0;
            dl_q       <= '0;
          end else if (sample) begin
            in_frame_q <= 1'b1;
            if (oct_d_i == ES_PL_PREAMBLE_OCTET) begin
              if (pre_cnt != 4'd7) pre_cnt <= pre_cnt + 4'd1;
            end else if ((oct_d_i == ES_PL_SFD_OCTET) && (pre_cnt == 4'd7)) begin
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
            if (cnt_q < CNT_W'(6)) cnt_q <= cnt_q + CNT_W'(1);
            if (b_valid_o && b_sof_o && !b_ready_i) discard_q <= 1'b1;
          end else if (fend) begin
            // A one-byte client frame still has a SOF/EOF beat. With
            // fewer octets there is no client byte to expose.
            if (!discard_q && (cnt_q >= CNT_W'(5))) begin
              state_q <= S_TAIL;
            end else begin
              state_q    <= S_HUNT;
              in_frame_q <= 1'b0;
              pre_cnt    <= '0;
              cnt_q      <= '0;
              dl_q       <= '0;
              discard_q  <= 1'b0;
              er_q       <= 1'b0;
            end
          end
        end

        S_TAIL: begin
          // An admitted frame accepts EOF on this edge. If SOF is also
          // here, the capacity decision applies to the entire one-byte frame.
          state_q    <= S_HUNT;
          in_frame_q <= 1'b0;
          pre_cnt    <= '0;
          cnt_q      <= '0;
          dl_q       <= '0;
          discard_q  <= 1'b0;
          er_q       <= 1'b0;
        end

        default: begin
          state_q <= S_HUNT;
        end
      endcase
    end
  end

endmodule : es_mac_frame_rx

`default_nettype wire

`endif  // ES_MAC_FRAME_RX_SV
