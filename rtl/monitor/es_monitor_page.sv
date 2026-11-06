// ============================================================================
//  File        : es_monitor_page.sv
//  Description : Debounced monitoring page and flush controls.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Page zero selects the aggregate; pages 1..NUM_PORTS select ports 0..N-1.
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
// ---- configuration and public interface -------------------------------------
module es_monitor_page #(
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS,
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  parameter int unsigned DEBOUNCE_MS = 20
) (
  input var logic clk_i, rst_ni,
  input var logic [2:0] key_ni, // flush, previous, next
  output logic flush_o,
  output logic [31:0] page_o
);
  localparam logic [63:0] DEBOUNCE = (64'(CLK_FREQ_HZ)*64'(DEBOUNCE_MS)+64'd999)/64'd1000;
  logic [2:0] meta_q, sync_q, candidate_q, stable_q;
  logic [63:0] timer_q;
  // ---- synchronous state and datapath ---------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      meta_q <= '1; sync_q <= '1; candidate_q <= '1; stable_q <= '1;
      timer_q <= '0; page_o <= '0; flush_o <= 1'b0;
    end else begin
      meta_q <= key_ni; sync_q <= meta_q; flush_o <= 1'b0;
      if (sync_q != candidate_q) begin candidate_q <= sync_q; timer_q <= '0; end
      else if (timer_q < DEBOUNCE) timer_q <= timer_q + 64'd1;
      else if (stable_q != candidate_q) begin
        stable_q <= candidate_q;
        if (stable_q[0] && !candidate_q[0]) flush_o <= 1'b1;
        if (candidate_q[2:1] == 2'b10 && stable_q[1])
          page_o <= (page_o == 32'd0) ? 32'(NUM_PORTS) : page_o - 32'd1;
        else if (candidate_q[2:1] == 2'b01 && stable_q[2])
          page_o <= (page_o == 32'(NUM_PORTS)) ? 32'd0 : page_o + 32'd1;
      end
    end
  end
endmodule
`default_nettype wire
`endif
