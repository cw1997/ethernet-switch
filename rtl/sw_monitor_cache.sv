// Low-priority CSR scanner. Publish only if sequence is unchanged at both ends.
// Console entry reads briefly pause scanning; UART/CTS waits never hold the bus.
`timescale 1ns/1ps
`ifndef SW_MONITOR_CACHE_SV
`define SW_MONITOR_CACHE_SV
`default_nettype none
`include "sw_defs.sv"
module sw_monitor_cache #(
  parameter int unsigned NUM_PORTS = 2
) (
  input logic clk_i, rst_ni, pause_i,
  output logic req_o,
  output logic [31:0] addr_o,
  input logic ready_i, valid_i,
  input logic [31:0] data_i,
  output logic idle_o,
  output logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image_o
);
  localparam int unsigned TOTAL = (NUM_PORTS+1)*SW_MON_WORDS;
  typedef enum logic [2:0] {S_BEGIN, S_BEGIN_WAIT, S_SEND, S_WAIT, S_CHECK, S_CHECK_WAIT} state_e;
  state_e state_q;
  logic [31:0] index_q, start_sequence_q;
  logic loaded_q;
  logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] staging_q;
  assign idle_o = (state_q == S_BEGIN) || (state_q == S_SEND) || (state_q == S_CHECK);
  assign req_o = idle_o && !pause_i;
  assign addr_o = ((state_q == S_CHECK) || (state_q == S_BEGIN)) ? 32'd196 :
                  (index_q < 32'(SW_MON_WORDS)) ? index_q*32'd4 :
                  SW_MON_PORT_BASE+(index_q-32'(SW_MON_WORDS))*32'd4;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_BEGIN; index_q <= '0; start_sequence_q <= '0;
      loaded_q <= 1'b0;
      for (int unsigned p = 0; p <= NUM_PORTS; p++) begin
        image_o[p*SW_MON_BITS +: SW_MON_BITS] <= '0;
        staging_q[p*SW_MON_BITS +: SW_MON_BITS] <= '0;
      end
    end else begin
      case (state_q)
        S_BEGIN: if (req_o && ready_i) state_q <= S_BEGIN_WAIT;
        S_BEGIN_WAIT: if (valid_i) begin
          // Poll one stable word between publications instead of continuously
          // switching the entire read mux for an unchanged 500 ms snapshot.
          if (!loaded_q || (data_i != image_o[SW_MON_SEQUENCE_WORD*32 +: 32])) begin
            start_sequence_q <= data_i; state_q <= S_SEND;
          end else state_q <= S_BEGIN;
        end
        S_SEND: if (req_o && ready_i) state_q <= S_WAIT;
        S_WAIT: if (valid_i) begin
          staging_q[index_q*32'd32 +: 32] <= data_i;
          if (index_q == 32'(TOTAL-1)) state_q <= S_CHECK;
          else begin index_q <= index_q + 32'd1; state_q <= S_SEND; end
        end
        S_CHECK: if (req_o && ready_i) state_q <= S_CHECK_WAIT;
        S_CHECK_WAIT: if (valid_i) begin
          if ((data_i == start_sequence_q) && (data_i == staging_q[49*32 +: 32])) begin
            image_o <= staging_q; loaded_q <= 1'b1;
          end
          index_q <= '0; state_q <= S_BEGIN;
        end
        default: state_q <= S_SEND;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif
