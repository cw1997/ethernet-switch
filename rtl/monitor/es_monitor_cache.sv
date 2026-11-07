// ============================================================================
//  File        : es_monitor_cache.sv
//  Description : Low-priority coherent telemetry scanner.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                The sequence word is read before and after the image, and only
//                two matching reads publish.  Console arbitration pauses the
//                scanner without it holding the CSR bus.
//
//                req/ready accepts one byte-addressed CSR read and valid
//                qualifies its response.  image holds aggregate record zero
//                followed by NUM_PORTS port records.  pause blocks new
//                requests; idle marks a safe arbitration boundary, not the
//                completion of a full scan.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MONITOR_CACHE_SV
`define ES_MONITOR_CACHE_SV

`default_nettype none

`include "es_defs.sv"
`include "monitor/es_monitor_defs.sv"
`default_nettype none

module es_monitor_cache #(
  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS
) (
  /// Clock, synchronous active-low reset, and pause on new read requests.
  input var logic clk_i, rst_ni, pause_i,
  /// Byte-addressed CSR read request and selected address.
  output    logic                                 req_o,
  output    logic [31:0] addr_o,
  /// CSR ready/valid response handshake and returned word.
  input var logic ready_i, valid_i,
  input var logic [31:0] data_i,
  /// Safe ownership boundary and coherent aggregate-plus-port image.
  output    logic idle_o,
  output    logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image_o
);

  /// Total number of 32-bit words in a complete image.
  localparam int unsigned TOTAL = (NUM_PORTS + 1) * SW_MON_WORDS;

  /// Byte address of the aggregate sequence word: the first and last word of
  /// every scan, and the only field a reader can use to detect a torn image.
  localparam logic [31:0] SEQ_ADDR = 32'(SW_MON_SEQUENCE_WORD) * 32'd4;

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_BEGIN,        ///< request the opening sequence read
    S_BEGIN_WAIT,   ///< wait for its response
    S_SEND,         ///< request the next image word
    S_WAIT,         ///< wait for its response
    S_CHECK,        ///< request the closing sequence read
    S_CHECK_WAIT    ///< wait for it and decide whether to publish
  } state_e;

  state_e state_q;

  /// Each scan begins and ends with the sequence word.  A mismatch discards the
  /// staging image rather than exposing a mixture of two publications.
  logic [31:0] index_q;
  logic [31:0] start_sequence_q;

  /// An unchanged sequence can be skipped only after a coherent image was loaded.
  logic loaded_q;

  logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] staging_q;

  // --------------------------------------------------------------------------
  // CSR scan and arbitration
  //
  // Idle denotes a request boundary where the console may take ownership.
  // Outstanding read responses must complete before that boundary; staging is
  // published only after the sequence is checked again.
  // --------------------------------------------------------------------------
  assign idle_o = (state_q == S_BEGIN) || (state_q == S_SEND) || (state_q == S_CHECK);
  assign req_o  = idle_o && !pause_i;

  // The sequence word is re-read at both ends of the scan; every other word is
  // addressed linearly through the aggregate image and then the port records.
  assign addr_o = ((state_q == S_CHECK) || (state_q == S_BEGIN)) ? SEQ_ADDR :
                  (index_q < 32'(SW_MON_WORDS)) ? (index_q * 32'd4) :
                  (SW_MON_PORT_BASE + (index_q - 32'(SW_MON_WORDS)) * 32'd4);

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q          <= S_BEGIN;
      index_q          <= '0;
      start_sequence_q <= '0;
      loaded_q         <= 1'b0;
      for (int unsigned p = 0; p <= NUM_PORTS; p++) begin
        image_o[p*SW_MON_BITS +: SW_MON_BITS]   <= '0;
        staging_q[p*SW_MON_BITS +: SW_MON_BITS] <= '0;
      end
    end else begin
      case (state_q)
        S_BEGIN: if (req_o && ready_i) state_q <= S_BEGIN_WAIT;
        S_BEGIN_WAIT: if (valid_i) begin
          // Poll one stable word between publications instead of continuously
          // switching the entire read mux for an unchanged 500 ms snapshot.
          if (!loaded_q || (data_i != image_o[SW_MON_SEQUENCE_WORD*32 +: 32])) begin
            start_sequence_q <= data_i;
            state_q          <= S_SEND;
          end else state_q <= S_BEGIN;
        end
        S_SEND: if (req_o && ready_i) state_q <= S_WAIT;
        S_WAIT: if (valid_i) begin
          staging_q[index_q*32'd32 +: 32] <= data_i;
          if (index_q == 32'(TOTAL - 1)) state_q <= S_CHECK;
          else begin
            index_q <= index_q + 32'd1;
            state_q <= S_SEND;
          end
        end
        S_CHECK: if (req_o && ready_i) state_q <= S_CHECK_WAIT;
        S_CHECK_WAIT: if (valid_i) begin
          // Both ends must agree with each other and with the word the image
          // itself was built from.
          if ((data_i == start_sequence_q) &&
              (data_i == staging_q[SW_MON_SEQUENCE_WORD*32 +: 32])) begin
            image_o  <= staging_q;
            loaded_q <= 1'b1;
          end
          index_q <= '0;
          state_q <= S_BEGIN;
        end
        default: state_q <= S_SEND;
      endcase
    end
  end

endmodule : es_monitor_cache

`default_nettype wire

`endif  // ES_MONITOR_CACHE_SV
