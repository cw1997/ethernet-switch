// ============================================================================
//  File        : es_monitor_display.sv
//  Description : Telemetry formatting for seven-segment and LCD outputs.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Latches a page before serial ratio and decimal conversion so displayed fields
//                cannot mix snapshots. Invalid records display placeholders.
//  Interface   : image_i contains aggregate record zero followed by port records.
//                page_i selects one record. HEX outputs are active-low segment
//                patterns; text_o holds two packed 16-character LCD rows.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_MONITOR_DISPLAY_SV
`define ES_MONITOR_DISPLAY_SV
`default_nettype none
`include "es_defs.sv"
`include "monitor/es_monitor_defs.sv"
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module es_monitor_display #(
  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS
) (
  input var logic clk_i, rst_ni,
  input var logic [31:0] page_i,
  input var logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image_i,
  output logic [55:0] hex_o,
  output logic rx_kpps_o, tx_kpps_o,
  output logic [255:0] text_o
);

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_SCALE,
    S_SCALE_WAIT,
    S_DEC,
    S_DEC_WAIT,
    S_PUBLISH
  } state_e;
  state_e state_q;
  // Freeze the selected record while the serial converters process its fields.
  logic [SW_MON_BITS-1:0] record_q;
  logic [31:0] sequence_q, page_q;
  logic [1:0] field_q;
  logic [63:0] value_q, ratio_result;
  logic ratio_busy, ratio_valid, decimal_valid;
  logic [ 79:0] decimal_result;
  logic [319:0] digits_q;
  logic rx_k_q, tx_k_q, valid_q;
  // --------------------------------------------------------------------------
  // Segment and LCD formatting
  //
  // Formatting uses the held record; placeholders represent unavailable
  // samples rather than zero traffic.
  // --------------------------------------------------------------------------

  function automatic logic [255:0] screen(input var logic [31:0] page,
                                          input var logic valid,
                                          input var logic [319:0] digits);
    logic [255:0] t;
    logic [ 31:0] port_index;
    t = "     ALLR000000k     ALLT000000k";
    port_index = page - 32'd1;
    for (int unsigned row = 0; row < 2; row++) begin
      if (page != 32'd0)
        for (int unsigned h = 0; h < 8; h++)
          t[255-(row*16+h)*8 -: 8] = sw_hexchar(port_index[31-h*4 -: 4]);
      if (!valid) begin
        for (int unsigned d = 0; d < 6; d++) t[255-(row*16+9+d)*8 -: 8] = "-";
      end else begin
        for (int unsigned d = 0; d < 6; d++)
          t[255-(row*16+9+d)*8 -: 8] = 8'd48 + {4'd0, digits[(row+2)*80+(5-d)*4 +: 4]};
      end
    end
    screen = t;
  endfunction
  es_common_ratio u_scale (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .start_i(state_q == S_SCALE),
    .value_i(value_q),
    .scale_i(64'd1),
    .divisor_i(64'd1000),
    .busy_o(ratio_busy),
    .valid_o(ratio_valid),
    .result_o(ratio_result)
  );
  es_common_bin_to_bcd u_decimal (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .start_i(state_q == S_DEC),
    .value_i(value_q),
    .valid_o(decimal_valid),
    .bcd_o  (decimal_result)
  );
  logic unused_busy;
  assign unused_busy = ratio_busy;

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      record_q <= '0;
      sequence_q <= '1;
      page_q <= '1;
      field_q <= '0;
      value_q <= '0;
      digits_q <= '0;
      rx_k_q <= 1'b0;
      tx_k_q <= 1'b0;
      valid_q <= 1'b0;
      hex_o <= '1;
      text_o <= "     ALLR------k     ALLT------k";
      rx_kpps_o <= 1'b0;
      tx_kpps_o <= 1'b0;
    end else
      case (state_q)
        S_IDLE: if ((page_i != page_q) || (sequence_q != image_i[49*32 +: 32])) begin
          record_q <= image_i[page_i*32'(SW_MON_BITS) +: SW_MON_BITS];
          sequence_q <= image_i[49*32 +: 32];
          page_q <= page_i;
          valid_q <= image_i[50*32];
          field_q <= '0;
          state_q <= S_SCALE_WAIT;
        end
        S_SCALE_WAIT: begin
          value_q <= record_q[SW_MON_RATE*32+32'(field_q)*32'd64 +: 64];
          if (field_q == 2'd0) rx_k_q <= record_q[SW_MON_RATE*32 +: 64] >= 64'd10000;
          if (field_q == 2'd1) tx_k_q <= record_q[(SW_MON_RATE+2)*32 +: 64] >= 64'd10000;
          if ((field_q >= 2'd2) || (record_q[SW_MON_RATE*32+32'(field_q)*32'd64 +: 64] >= 64'd10000))
            state_q <= S_SCALE;
          else state_q <= S_DEC;
        end
        S_SCALE: state_q <= S_DEC_WAIT;
        S_DEC_WAIT: if (ratio_valid) begin
          value_q <= ratio_result;
          state_q <= S_DEC;
        end
        S_DEC:   state_q <= S_PUBLISH;
        S_PUBLISH: if (decimal_valid) begin
          digits_q[32'(field_q)*32'd80 +: 80] <= decimal_result;
          if (field_q == 2'd3) state_q <= S_IDLE;
          else begin
            field_q <= field_q + 2'd1;
            state_q <= S_SCALE_WAIT;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    // Publish all fields together after the last formatter result landed.
    if (rst_ni && (state_q == S_IDLE)) begin
      text_o <= screen(page_q, valid_q, digits_q);
      rx_kpps_o <= rx_k_q;
      tx_kpps_o <= tx_k_q;
      for (int unsigned d = 0; d < 4; d++) begin
        hex_o[d*7 +: 7] <= valid_q ? sw_sevenseg_digit(digits_q[80+d*4 +: 4]) : 7'b0111111;
        hex_o[(d+4)*7 +: 7] <= valid_q ? sw_sevenseg_digit(digits_q[d*4 +: 4]) : 7'b0111111;
      end
    end
  end
endmodule
`default_nettype wire
`endif
