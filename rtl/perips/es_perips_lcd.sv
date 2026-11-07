// ============================================================================
//  File        : es_perips_lcd.sv
//  Description : Character LCD write sequencer.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                The formatted two-row text is serialised with clock-counted
//                initialisation and enable timing; the board owns the LCD pin
//                and voltage assignments.  CLK_FREQ_HZ is in hertz, and text_i
//                supplies the packed rows.  LCD access timing is counted in
//                clk_i cycles rather than expressed as RTL delays.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_PERIPS_LCD_SV
`define ES_PERIPS_LCD_SV

`default_nettype none

module es_perips_lcd #(
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000
) (
  /// Clock and synchronous active-low reset for the LCD pin sequencer.
  input var logic clk_i, rst_ni,
  /// Two 16-character ASCII rows; changes are captured between write passes.
  /// First row occupies [255:128], each row in left-to-right ASCII order.
  input var logic [255:0] text_i,
  /// Write-only data/control pins; power and backlight remain enabled.
  output    logic [7:0] data_o,
  output    logic       rs_o, rw_o, en_o, on_o, blon_o
);

  // --------------------------------------------------------------------------
  // Timing
  //
  // US is one microsecond in core clocks.  The sequencer only ever needs
  // microsecond granularity: setup and hold times are 1 us, a write cycle is
  // 50 us, and the two clear/home commands need 5 ms.
  // --------------------------------------------------------------------------
  localparam int unsigned US = (CLK_FREQ_HZ + 999_999) / 1_000_000;

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_WAIT,  ///< present data and RS, then wait out the setup time
    S_HIGH,  ///< raise E for one write cycle
    S_LOW,   ///< drop E and wait out the cycle time
    S_IDLE   ///< text matches the displayed image; wait for a change
  } state_e;

  state_e state_q;

  logic [31:0] timer_q;
  /// Write-pass step.  Indices 0..5 send setup commands, 6..21 write row one,
  /// 22 selects row two, and 23..38 write its characters.
  logic [ 5:0] index_q;
  /// Hold one two-row image throughout a write pass; changes wait until idle.
  logic [255:0] text_q;

  // Write-only panel: read/write is tied to write, display and backlight stay on.
  assign rw_o   = 1'b0;
  assign on_o   = 1'b1;
  assign blon_o = 1'b1;

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_WAIT;
      timer_q <= 32'(40_000 * US);
      index_q <= '0;
      data_o  <= '0;
      rs_o    <= 1'b0;
      en_o    <= 1'b0;
      text_q  <= '0;
    end else begin
      if (timer_q != 32'd0) timer_q <= timer_q - 32'd1;
      else
        case (state_q)
          S_WAIT: begin
            // RS is low for the command steps and high for character writes;
            // index 22 is the "set DDRAM address to row two" command.
            rs_o <= (index_q >= 6'd6) && (index_q != 6'd22);
            case (index_q)
              6'd0, 6'd1: data_o <= 8'h38;  // function set, 8-bit, two rows
              6'd2:       data_o <= 8'h0c;  // display on, cursor off
              6'd3:       data_o <= 8'h06;  // entry mode: increment, no shift
              6'd4:       data_o <= 8'h01;  // clear display
              6'd5:       data_o <= 8'h80;  // DDRAM address 0: row one
              6'd22:      data_o <= 8'hc0;  // DDRAM address 0x40: row two
              default:    data_o <= (index_q < 6'd22) ?
                  text_q[255-(32'(index_q)-32'd6)*32'd8 -: 8] :
                  text_q[127-(32'(index_q)-32'd23)*32'd8 -: 8];
            endcase
            // Data/RS setup for one microsecond before E rises.
            state_q <= S_HIGH;
            timer_q <= 32'(US);
          end
          S_HIGH: begin
            en_o    <= 1'b1;
            timer_q <= 32'(US);
            state_q <= S_LOW;
          end
          S_LOW: begin
            // The clear-display and return-home commands are the slow ones.
            en_o    <= 1'b0;
            timer_q <= ((index_q <= 6'd1) || (index_q == 6'd4)) ? 32'(5000 * US) : 32'(50 * US);
            if (index_q == 6'd38) state_q <= S_IDLE;
            else begin
              index_q <= index_q + 6'd1;
              state_q <= S_WAIT;
            end
          end
          S_IDLE: if (text_i != text_q) begin
            text_q  <= text_i;
            // A refresh starts at the row-one address command and rewrites both
            // rows; the panel keeps the mode the power-on pass configured, so
            // the function-set and clear steps are not repeated.
            index_q <= 6'd5;
            state_q <= S_WAIT;
          end
          default: state_q <= S_IDLE;
        endcase
    end
  end

endmodule : es_perips_lcd

`default_nettype wire

`endif  // ES_PERIPS_LCD_SV
