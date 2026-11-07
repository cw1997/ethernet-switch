// ============================================================================
//  File        : es_monitor_page.sv
//  Description : Debounced monitoring page and flush controls.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Page zero selects the aggregate; pages 1..NUM_PORTS select
//                ports 0..N-1.
//                Explicit wrap preserves non-power-of-two port configurations.
//  Interface   : key_ni is active low and sampled/debounced in clk_i's domain.
//                page_o ranges from zero through NUM_PORTS. flush_o is a single
//                clock pulse per qualified press, not a held flush request.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_MONITOR_PAGE_SV
`define ES_MONITOR_PAGE_SV
`default_nettype none
`include "es_defs.sv"
`include "monitor/es_monitor_defs.sv"
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module es_monitor_page #(
  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS   = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// Required stable key interval, in milliseconds.
  parameter int unsigned DEBOUNCE_MS = 20
) (
  input var logic clk_i, rst_ni,
  input var logic [2:0] key_ni,  // flush, previous, next
  output logic flush_o,
  output logic [31:0] page_o
);
  logic [2:0] stable_keys, keys, pressed;
  logic unused_stable;
  assign unused_stable = ^{stable_keys, keys[0]};
  es_perips_key_debounce #(
    .WIDTH(3), .CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)
  ) u_keys (
    .clk_i(clk_i), .rst_ni(rst_ni), .key_ni(key_ni),
    .stable_no(stable_keys), .value_no(keys), .pressed_o(pressed)
  );
  // Navigation policy stays here; events are consumed on the original commit
  // edge. Simultaneous previous and next presses do not change the page.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      page_o <= '0;
      flush_o <= 1'b0;
    end else begin
      flush_o <= pressed[0];
      if ((keys[2:1] == 2'b10) && pressed[1])
        page_o <= (page_o == 32'd0) ? 32'(NUM_PORTS) : page_o - 32'd1;
      else if ((keys[2:1] == 2'b01) && pressed[2])
        page_o <= (page_o == 32'(NUM_PORTS)) ? 32'd0 : page_o + 32'd1;
    end
  end
endmodule
`default_nettype wire
`endif
