// ============================================================================
//  File        : sw_page_reference.sv
//  Description : Frozen pre-extraction cycle reference for page/flush policy.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Page zero selects the aggregate; pages 1..NUM_PORTS select ports 0..N-1.
//                Explicit wrap preserves non-power-of-two port configurations.
//  Interface   : key_ni is active low and sampled/debounced in clk_i's domain.
//                page_o ranges from zero through NUM_PORTS. flush_o is a single
//                clock pulse per qualified press, not a held flush request.
// ============================================================================
`timescale 1ns/1ps
`ifndef SW_PAGE_REFERENCE_SV
`define SW_PAGE_REFERENCE_SV
`default_nettype none
`include "es_defs.sv"
`include "monitor/es_monitor_defs.sv"
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module sw_page_reference #(

  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS   = SW_DEFAULT_NUM_PORTS,

  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,

  /// Required stable key interval, in milliseconds.
  parameter int unsigned DEBOUNCE_MS = 20
) (
  /// Clock and synchronous active-low reset for the independent page model.
  input var logic clk_i, rst_ni,
  /// Active-low flush, previous-page, and next-page key vector.
  input var logic [2:0] key_ni,  // flush, previous, next
  /// Single-cycle flush pulse and selected aggregate/port page.
  output    logic        flush_o,
  output    logic [31:0] page_o
);
  localparam logic [63:0] DEBOUNCE = (64'(CLK_FREQ_HZ) * 64'(DEBOUNCE_MS) + 64'd999) / 64'd1000;
  // --------------------------------------------------------------------------
  // Key sampling and debounce
  //
  // The complete sampled key vector must remain unchanged for DEBOUNCE
  // clocks. Bit 0 requests flush, bit 1 selects previous and bit 2 selects
  // next; simultaneous navigation presses do not change the page.
  // --------------------------------------------------------------------------
  logic [2:0] meta_q, sync_q, candidate_q, stable_q;
  logic [63:0] timer_q;

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      meta_q <= '1;
      sync_q <= '1;
      candidate_q <= '1;
      stable_q <= '1;
      timer_q <= '0;
      page_o <= '0;
      flush_o <= 1'b0;
    end else begin
      meta_q  <= key_ni;
      sync_q  <= meta_q;
      flush_o <= 1'b0;
      if (sync_q != candidate_q) begin
        candidate_q <= sync_q;
        timer_q <= '0;
      end else if (timer_q < DEBOUNCE) timer_q <= timer_q + 64'd1;
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
