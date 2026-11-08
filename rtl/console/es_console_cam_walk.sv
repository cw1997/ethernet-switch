// ============================================================================
//  File        : es_console_cam_walk.sv
//  Description : Forwarding-table traversal shared by the `mac all` and
//                `mac <n>` console commands.
//
//                A traversal claims the switch's single forwarding-table read
//                port, walks the table from index zero to `CAM_CAPACITY`, and
//                emits the entries that match the filter.  `mac all` keeps every
//                valid entry (`FILTER_ALL = 1`); `mac <n>` keeps only the
//                entries learned on port n (`FILTER_ALL = 0`, filter against
//                `arg_i`).  Each match is reported as two response lines - the
//                high half of the address with the learned port, then the low
//                half - so one 32-bit value carries both fields without a third
//                line.
//
//                Handshake
//                ---------
//                `start_i` begins a traversal.  `line_valid_o` is held high with
//                a fully rendered `line_text_o` until the dispatcher accepts it
//                with a one-clock `line_ack_i`; `done_o` is held high once the
//                whole table has been walked and the last line accepted.  The
//                read port is claimed for the entire traversal and released when
//                it completes, exactly as the original single-FSM console did.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_CAM_WALK_SV
`define ES_CONSOLE_CAM_WALK_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "console/es_console_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_console_cam_walk #(
  /// Number of forwarding-table entries to scan.
  parameter int unsigned CAM_CAPACITY = 512,
  /// 1 = every valid entry matches; 0 = only entries learned on `arg_i`.
  parameter logic        FILTER_ALL   = 1'b1
) (
  /// Clock and synchronous active-low reset.
  input var logic clk_i,
  input var logic rst_ni,

  // ---- control -------------------------------------------------------------
  /// One-clock pulse to begin a traversal; `arg_i` is sampled while active.
  input var logic       start_i,
  /// Port filter when `FILTER_ALL == 0`; ignored otherwise.
  input var logic [3:0] arg_i,
  /// One-clock pulse: the offered line was accepted.
  input var logic       line_ack_i,

  // ---- response ------------------------------------------------------------
  /// Held high while `line_text_o` describes the next line to emit.
  output logic line_valid_o,
  /// A fully rendered line; see the module header for its two shapes.
  output logic [SW_CONSOLE_LINE_BYTES*8-1:0] line_text_o,
  /// Held high once the whole table has been walked and the last line accepted.
  output logic done_o,

  // ---- shared forwarding-table read port -----------------------------------
  /// Claim the table read port for the duration of the traversal.
  output logic        cam_claim_o,
  input  var logic    cam_grant_i,
  /// Registered read request and its one-clock-later response.
  output logic        cam_rd_req_o,
  output logic [31:0] cam_rd_index_o,
  input  var logic    cam_rd_valid_i,
  input  var logic [127:0] cam_rd_entry_i
);

  // --------------------------------------------------------------------------
  // Traversal state
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,   ///< waiting for `start_i`
    S_WAIT,   ///< claiming the table read port
    S_REQ,    ///< issuing one table read
    S_EVAL,   ///< filtering the returned entry
    S_OFFER,  ///< offering one of the two lines for a match
    S_NEXT,   ///< advancing the cursor
    S_DONE    ///< traversal complete
  } state_e;

  state_e      state_q;
  logic [31:0] cursor_q;   ///< table index under inspection
  logic [3:0]  port_q;     ///< learned port of the entry being reported
  logic [47:0] addr_q;     ///< MAC address of the entry being reported
  logic        sub_q;      ///< 0 = high half + port, 1 = low half

  // A forwarding-table entry carries reserved fields that the table's read
  // interface defines and no reader needs.  Reducing the whole word keeps
  // "nothing observes these bits" an explicit decision rather than a dangling
  // input, and costs one XOR tree.
  logic unused_entry;
  assign unused_entry = ^cam_rd_entry_i;

  /// Does the entry the table just returned match the filter?  Evaluated
  /// combinationally so the transition out of S_EVAL can be decided in the same
  /// clock the entry is latched.  The entry layout is
  /// `{31'd0, valid, port[31:0], 16'd0, mac[47:0]}`.
  logic hit_w;
  assign hit_w = cam_rd_entry_i[96] &&
                 (FILTER_ALL || (cam_rd_entry_i[95:64] == 32'(arg_i)));

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q       <= S_IDLE;
      cursor_q      <= '0;
      port_q        <= '0;
      addr_q        <= '0;
      sub_q         <= 1'b0;
      line_valid_o  <= 1'b0;
      line_text_o   <= '0;
      done_o        <= 1'b0;
      cam_claim_o   <= 1'b0;
      cam_rd_req_o  <= 1'b0;
      cam_rd_index_o<= '0;
    end else begin
      // The read request is a one-clock pulse; the index stays put so the table
      // sees a stable address for the whole transaction.
      cam_rd_req_o <= 1'b0;

      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            cursor_q <= '0;
            sub_q    <= 1'b0;
            done_o   <= 1'b0;
            state_q  <= S_WAIT;
          end
        end

        S_WAIT: begin
          cam_claim_o <= 1'b1;
          if (cam_grant_i) state_q <= S_REQ;
        end

        S_REQ: begin
          if (32'(cursor_q) >= 32'(CAM_CAPACITY)) begin
            cam_claim_o <= 1'b0;
            done_o      <= 1'b1;
            state_q     <= S_DONE;
          end else begin
            cam_rd_index_o <= cursor_q;
            cam_rd_req_o   <= 1'b1;
            state_q        <= S_EVAL;
          end
        end

        S_EVAL: begin
          if (cam_rd_valid_i) begin
            port_q  <= cam_rd_entry_i[67:64];
            addr_q  <= cam_rd_entry_i[47:0];
            sub_q   <= 1'b0;
            state_q <= hit_w ? S_OFFER : S_NEXT;
          end
        end

        S_OFFER: begin
          line_valid_o <= 1'b1;
          if (!sub_q) begin
            // High half of the address together with the learned port, so one
            // 32-bit value carries both fields without a third line.
            line_text_o <= sw_console_value_line("mac_hi_port",
                            {addr_q[47:32], 12'd0, port_q});
          end else begin
            line_text_o <= sw_console_value_line("mac_lo", addr_q[31:0]);
          end
          if (line_ack_i) begin
            if (sub_q) begin
              // The low half just left; the entry is fully reported.
              line_valid_o <= 1'b0;
              state_q      <= S_NEXT;
            end else begin
              sub_q <= 1'b1;
            end
          end
        end

        S_NEXT: begin
          cursor_q <= cursor_q + 32'd1;
          state_q  <= S_REQ;
        end

        S_DONE: begin
          cam_claim_o <= 1'b0;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : es_console_cam_walk

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_CONSOLE_CAM_WALK_SV
