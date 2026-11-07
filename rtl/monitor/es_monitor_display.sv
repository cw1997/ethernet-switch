// ============================================================================
//  File        : es_monitor_display.sv
//  Description : Telemetry formatting for seven-segment and LCD outputs.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                A page is latched before the serial ratio and decimal
//                conversions run, so the displayed fields cannot mix snapshots.
//                An invalid record displays placeholders rather than zeros.
//
//                image_i holds aggregate record zero followed by the port
//                records.  page_i selects one of them.  The HEX outputs are
//                active-low segment patterns and text_o holds two packed
//                16-character LCD rows.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MONITOR_DISPLAY_SV
`define ES_MONITOR_DISPLAY_SV

`default_nettype none

`include "es_defs.sv"
`include "monitor/es_monitor_defs.sv"
`default_nettype none

module es_monitor_display #(
  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS
) (
  /// Clock and synchronous active-low reset for the display pipeline.
  input var logic clk_i, rst_ni,
  /// Page selected by the monitor controls; the owner supplies a page in
  /// [0, NUM_PORTS], and zero selects the aggregate record.
  input var logic [31:0] page_i,
  /// Coherent aggregate-plus-port image from the telemetry cache.
  input var logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image_i,
  /// Active-low seven-segment patterns and packet-rate scale indicators.
  output    logic [55:0] hex_o,
  output    logic rx_kpps_o, tx_kpps_o,
  /// Two packed 16-character LCD rows in left-to-right ASCII order.
  output    logic [255:0] text_o
);

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,        ///< wait for a new page or a new sequence
    S_SCALE_WAIT,  ///< load one field and decide whether it needs scaling
    S_SCALE,       ///< run the serial divide that turns a rate into k-units
    S_DEC_WAIT,    ///< wait for the scaled value
    S_DEC,         ///< start the BCD conversion of the final value
    S_PUBLISH      ///< latch the converted digit group and move on
  } state_e;

  state_e state_q;

  /// Freeze the selected record while the serial converters process its fields.
  logic [SW_MON_BITS-1:0] record_q;

  logic [31:0] sequence_q;
  logic [31:0] page_q;
  logic [ 1:0] field_q;  ///< which of the four rate fields is being formatted

  logic [63:0] value_q;
  logic [63:0] ratio_result;
  logic        ratio_busy;
  logic        ratio_valid;
  logic        decimal_valid;
  logic [79:0] decimal_result;

  /// Four packed 20-digit BCD results: RX/TX packet rates then RX/TX bit rates.
  logic [319:0] digits_q;

  logic rx_k_q;   ///< RX packet rate is displayed in k-units
  logic tx_k_q;   ///< TX packet rate is displayed in k-units
  logic valid_q;  ///< the latched record carries a valid PHY sample

  // --------------------------------------------------------------------------
  // Segment and LCD formatting
  //
  // Both run off the held record and its converted digits, so a new snapshot
  // arriving mid-format cannot change what is on the panel.  Placeholders mark
  // an unavailable sample instead of showing a plausible zero.
  // --------------------------------------------------------------------------
  function automatic logic [255:0] screen(input var logic [31:0] page,
                                          input var logic valid,
                                          input var logic [319:0] digits);
    logic [255:0] t;
    logic [31:0]  port_index;
    t          = "     ALLR000000k     ALLT000000k";
    port_index = page - 32'd1;
    for (int unsigned row = 0; row < 2; row++) begin
      // Page zero keeps the "ALL" tag; a port page replaces it with the index.
      if (page != 32'd0)
        for (int unsigned h = 0; h < 8; h++)
          t[255-(row*16+h)*8 -: 8] = sw_hexchar(port_index[31-h*4 -: 4]);
      if (!valid) begin
        for (int unsigned d = 0; d < 6; d++) t[255-(row*16+9+d)*8 -: 8] = "-";
      end else begin
        // Row zero shows the RX bit rate, row one the TX bit rate.
        for (int unsigned d = 0; d < 6; d++)
          t[255-(row*16+9+d)*8 -: 8] = 8'd48 + {4'd0, digits[(row+2)*80+(5-d)*4 +: 4]};
      end
    end
    screen = t;
  endfunction

  // --------------------------------------------------------------------------
  // Serial converters
  //
  // One divider and one BCD converter are shared by all four fields; both are
  // slow by design and nothing outside this block waits on them.
  // --------------------------------------------------------------------------
  es_common_ratio u_scale (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .start_i   (state_q == S_SCALE),
    .value_i   (value_q),
    .scale_i   (64'd1),
    .divisor_i (64'd1000),
    .busy_o    (ratio_busy),
    .valid_o   (ratio_valid),
    .result_o  (ratio_result)
  );

  es_common_bin_to_bcd u_decimal (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .start_i (state_q == S_DEC),
    .value_i (value_q),
    .valid_o (decimal_valid),
    .bcd_o   (decimal_result)
  );

  // The divider's busy flag is not needed: S_SCALE is left on `ratio_valid`.
  logic unused_busy;
  assign unused_busy = ratio_busy;

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q    <= S_IDLE;
      record_q   <= '0;
      sequence_q <= '1;
      page_q     <= '1;
      field_q    <= '0;
      value_q    <= '0;
      digits_q   <= '0;
      rx_k_q     <= 1'b0;
      tx_k_q     <= 1'b0;
      valid_q    <= 1'b0;
      hex_o      <= '1;
      text_o     <= "     ALLR------k     ALLT------k";
      rx_kpps_o  <= 1'b0;
      tx_kpps_o  <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: if ((page_i != page_q) ||
                    (sequence_q != image_i[SW_MON_SEQUENCE_WORD*32 +: 32])) begin
          record_q   <= image_i[page_i*32'(SW_MON_BITS) +: SW_MON_BITS];
          sequence_q <= image_i[SW_MON_SEQUENCE_WORD*32 +: 32];
          page_q     <= page_i;
          valid_q    <= image_i[SW_MON_VALID_WORD*32];
          field_q    <= '0;
          state_q    <= S_SCALE_WAIT;
        end
        S_SCALE_WAIT: begin
          value_q <= record_q[SW_MON_RATE*32 + 32'(field_q)*32'd64 +: 64];
          // The k-indicator tracks the packet rates only, not the bit rates.
          if (field_q == 2'd0) rx_k_q <= (record_q[SW_MON_RATE*32 +: 64] >= 64'd10000);
          if (field_q == 2'd1) tx_k_q <= (record_q[(SW_MON_RATE+2)*32 +: 64] >= 64'd10000);
          // Only the packet rates are divided by 1000; the bit rates are shown
          // as they are, so a large value simply fills the display.
          if ((field_q >= 2'd2) ||
              (record_q[SW_MON_RATE*32 + 32'(field_q)*32'd64 +: 64] >= 64'd10000))
            state_q <= S_SCALE;
          else state_q <= S_DEC;
        end
        S_SCALE: state_q <= S_DEC_WAIT;
        S_DEC_WAIT: if (ratio_valid) begin
          value_q <= ratio_result;
          state_q <= S_DEC;
        end
        S_DEC: state_q <= S_PUBLISH;
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
    end
    // Publish all fields together once the last formatter result has landed:
    // the panel and the two LCD rows must not show digits from two snapshots.
    if (rst_ni && (state_q == S_IDLE)) begin
      text_o    <= screen(page_q, valid_q, digits_q);
      rx_kpps_o <= rx_k_q;
      tx_kpps_o <= tx_k_q;
      for (int unsigned d = 0; d < 4; d++) begin
        hex_o[d*7 +: 7]     <= valid_q ? sw_sevenseg_digit(digits_q[80+d*4 +: 4]) : 7'b0111111;
        hex_o[(d+4)*7 +: 7] <= valid_q ? sw_sevenseg_digit(digits_q[d*4 +: 4])  : 7'b0111111;
      end
    end
  end

endmodule : es_monitor_display

`default_nettype wire

`endif  // ES_MONITOR_DISPLAY_SV
