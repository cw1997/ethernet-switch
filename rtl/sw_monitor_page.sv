// Shared LCD/HEX page: zero is aggregate, p+1 selects physical port p.
// Debounce the key vector together so simultaneous presses cannot create two events.
`timescale 1ns/1ps
`ifndef SW_MONITOR_PAGE_SV
`define SW_MONITOR_PAGE_SV
`default_nettype none
module sw_monitor_page #(
  parameter int unsigned NUM_PORTS = 2,
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  parameter int unsigned DEBOUNCE_MS = 20
) (
  input logic clk_i, rst_ni,
  input logic [2:0] key_ni, // flush, previous, next
  output logic flush_o,
  output logic [31:0] page_o
);
  localparam logic [63:0] DEBOUNCE = (64'(CLK_FREQ_HZ)*64'(DEBOUNCE_MS)+64'd999)/64'd1000;
  logic [2:0] meta_q, sync_q, candidate_q, stable_q;
  logic [63:0] timer_q;
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
