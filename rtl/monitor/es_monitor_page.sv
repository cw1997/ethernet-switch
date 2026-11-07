// ============================================================================
//  File        : es_monitor_page.sv
//  Description : Debounced monitoring page and flush controls.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Page zero selects the aggregate; pages 1..NUM_PORTS select
//                ports 0..N-1.  The wrap is written out explicitly so that a
//                port count which is not a power of two still navigates the
//                full range instead of skipping an encoding.
//
//                key_ni is active low and sampled/debounced in the clk_i
//                domain.  page_o ranges from zero through NUM_PORTS.  flush_o is
//                a single-clock pulse per qualified press, not a held request.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MONITOR_PAGE_SV
`define ES_MONITOR_PAGE_SV

`default_nettype none

`include "es_defs.sv"
`include "monitor/es_monitor_defs.sv"
`default_nettype none

module es_monitor_page #(
  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// Required stable key interval, in milliseconds.
  parameter int unsigned DEBOUNCE_MS = 20
) (
  /// Core clock and synchronous active-low reset for debounce and page state.
  input var logic clk_i, rst_ni,
  /// Active-low keys, least-significant bit first: flush, previous, next.
  input var logic [2:0] key_ni,
  /// One clock pulse for each qualified flush-key press.
  output    logic flush_o,
  /// Current page: zero is aggregate; 1..NUM_PORTS select ports 0..N-1.
  output    logic [31:0] page_o
);

  // --------------------------------------------------------------------------
  // Debounced key vector
  // --------------------------------------------------------------------------
  logic [2:0] stable_keys;  ///< committed (debounced) vector
  logic [2:0] keys;         ///< vector including the press being committed
  logic [2:0] pressed;      ///< one pulse per active-low transition

  es_perips_key_debounce #(
    .WIDTH       (3),
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (DEBOUNCE_MS)
  ) u_keys (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .key_ni    (key_ni),
    .stable_no (stable_keys),
    .value_no  (keys),
    .pressed_o (pressed)
  );

  // `stable_keys` is carried for observability only: navigation acts on the
  // commit-edge vector, so the debounced copy is not read here.
  logic unused_stable;
  assign unused_stable = ^{stable_keys, keys[0]};

  // --------------------------------------------------------------------------
  // Navigation policy
  //
  // Events are consumed on the original commit edge.  Because the keys are
  // active low and ordered flush / previous / next, `keys[2:1] == 2'b10` reads
  // "previous held, next released": a simultaneous press of both page keys
  // therefore leaves the page unchanged instead of resolving an arbitrary way.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      page_o  <= '0;
      flush_o <= 1'b0;
    end else begin
      flush_o <= pressed[0];
      if ((keys[2:1] == 2'b10) && pressed[1]) begin
        page_o <= (page_o == 32'd0) ? 32'(NUM_PORTS) : (page_o - 32'd1);
      end else if ((keys[2:1] == 2'b01) && pressed[2]) begin
        page_o <= (page_o == 32'(NUM_PORTS)) ? 32'd0 : (page_o + 32'd1);
      end
    end
  end

endmodule : es_monitor_page

`default_nettype wire

`endif  // ES_MONITOR_PAGE_SV
