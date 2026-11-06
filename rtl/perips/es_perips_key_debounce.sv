// ============================================================================
//  File        : es_perips_key_debounce.sv
//  Description : Active-low vector debounce; all keys share one stable interval.
//                Single clk_i domain; synchronous active-low rst_ni where present.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_PERIPS_KEY_DEBOUNCE_SV
`define ES_PERIPS_KEY_DEBOUNCE_SV
`default_nettype none
module es_perips_key_debounce #(
  /// Word width in bits (key/sampler width is the number of input bits).
  parameter int unsigned WIDTH = 3,
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  parameter int unsigned DEBOUNCE_MS = 20
) (
  input var logic clk_i, rst_ni,
  input var logic [WIDTH-1:0] key_ni,
  output logic [WIDTH-1:0] stable_no, value_no, pressed_o
);
  localparam logic [63:0] INTERVAL = (64'(CLK_FREQ_HZ)*64'(DEBOUNCE_MS)+64'd999)/64'd1000;
  logic [WIDTH-1:0] sync_keys, candidate_q, stable_q;
  logic [63:0] timer_q;
  logic commit;
  es_common_sync_2ff #(.WIDTH(WIDTH)) u_sync (
    .clk_i(clk_i), .rst_ni(rst_ni), .async_i(key_ni), .sync_o(sync_keys)
  );
  // Consumers sample this event on the same edge that commits the stable value.
  // Registering the pulse here would delay page/flush policy by one extra clock.
  assign commit = (sync_keys == candidate_q) && (timer_q >= INTERVAL) &&
                  (stable_q != candidate_q);
  assign stable_no = stable_q;
  assign value_no = commit ? candidate_q : stable_q;
  assign pressed_o = {WIDTH{commit}} & stable_q & ~candidate_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      candidate_q <= '1;
      stable_q <= '1;
      timer_q <= '0;
    end else if (sync_keys != candidate_q) begin
      candidate_q <= sync_keys;
      timer_q <= '0;
    end else if (timer_q < INTERVAL) timer_q <= timer_q + 64'd1;
    else if (commit) stable_q <= candidate_q;
  end
endmodule : es_perips_key_debounce
`default_nettype wire
`endif // ES_PERIPS_KEY_DEBOUNCE_SV
