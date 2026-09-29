// ============================================================================
//  File        : sw_if_array.sv
//  Description : Gathers the per-port GMII models and the per-port scoreboard
//                queues into two instances that the testbench drives with a
//                run-time port index.
//
//                Icarus Verilog cannot hold an unpacked array of module
//                instances, nor an unpacked array of queues, and the testbench
//                cannot call a task on an instance it only sees through a wire.
//                This module solves all three at once:
//
//                  * the four sw_gmii_if models are declared individually, each
//                    with the BYTE_PERIOD its link speed implies,
//                  * four sw_rec_q scoreboard queues are declared
//                    individually, one per port,
//                  * `send_on`, `expect_push`, `expect_count`, `expect_take`,
//                    `expect_clear`, `pop_on` and `pending_on` select the port
//                    with a case statement, which keeps the testbench itself
//                    completely port-agnostic.
//
//                The per-port link speeds are stated once, here, as
//                `sw_speed_e` codes.  The octet periods are derived with the
//                same `sw_byte_period` function the DUT uses, so the model and
//                the design can never disagree about the cadence.
// ============================================================================
`ifndef SW_IF_ARRAY_SV
`define SW_IF_ARRAY_SV

`include "sw_tb_pkg.sv"

// Both packages are named explicitly in the header import clause: a transitive
// import of the RTL package is not visible to a parameter default or a
// subroutine argument type in Icarus Verilog.
module sw_if_array import sw_tb_pkg::*, sw_switch_pkg::*; #(
  /// Number of switch ports under test.
  parameter int unsigned NUM_PORTS = 4,
  /// Core clock frequency in Hz, used to derive every octet period.
  parameter int unsigned CLK_FREQ  = 125_000_000,
  /// Capacity of one port's scoreboard queue.
  parameter int unsigned EXP_DEPTH = 256
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic [NUM_PORTS-1:0]    link_up,

  output logic [NUM_PORTS-1:0]    rx_en,
  output logic [NUM_PORTS*8-1:0]  rx_d,
  input  logic [NUM_PORTS-1:0]    tx_en,
  input  logic [NUM_PORTS*8-1:0]  tx_d
);

  // --------------------------------------------------------------------------
  // Per-port link speeds.
  //
  //   port 0 : 10 Mbit/s    port 1 : 100 Mbit/s
  //   port 2 : 1000 Mbit/s  port 3 : 1000 Mbit/s
  //
  // Three different rates sharing one clock domain is the configuration most
  // likely to expose a clock-enable bug, so it is the default configuration of
  // the whole regression.
  // --------------------------------------------------------------------------
  localparam int unsigned SPEED0 = 0;
  localparam int unsigned SPEED1 = 1;
  localparam int unsigned SPEED2 = 2;
  localparam int unsigned SPEED3 = 2;

  // `clk_i` cycles per GMII octet time, one per port.  The values come from the
  // same `sw_byte_period` function the DUT uses, evaluated as a localparam so
  // that the model and the design can never disagree about the cadence.  (A
  // constant function may not call a package function, so the result is
  // computed once here rather than inside `bp_of`.)
  localparam int unsigned BP0 = sw_byte_period(CLK_FREQ, sw_speed_e'(SPEED0));
  localparam int unsigned BP1 = sw_byte_period(CLK_FREQ, sw_speed_e'(SPEED1));
  localparam int unsigned BP2 = sw_byte_period(CLK_FREQ, sw_speed_e'(SPEED2));
  localparam int unsigned BP3 = sw_byte_period(CLK_FREQ, sw_speed_e'(SPEED3));

  // ==========================================================================
  // Per-port GMII models
  // ==========================================================================
  sw_gmii_if #(.PORT_ID(0), .BYTE_PERIOD(BP0)) u0 (
      .clk_i (clk_i), .rst_ni (rst_ni), .enable_i (link_up[0]),
      .gmii_rx_en (rx_en[0]), .gmii_rx_d (rx_d[0*8 +: 8]),
      .gmii_tx_en (tx_en[0]), .gmii_tx_d (tx_d[0*8 +: 8]));

  sw_gmii_if #(.PORT_ID(1), .BYTE_PERIOD(BP1)) u1 (
      .clk_i (clk_i), .rst_ni (rst_ni), .enable_i (link_up[1]),
      .gmii_rx_en (rx_en[1]), .gmii_rx_d (rx_d[1*8 +: 8]),
      .gmii_tx_en (tx_en[1]), .gmii_tx_d (tx_d[1*8 +: 8]));

  sw_gmii_if #(.PORT_ID(2), .BYTE_PERIOD(BP2)) u2 (
      .clk_i (clk_i), .rst_ni (rst_ni), .enable_i (link_up[2]),
      .gmii_rx_en (rx_en[2]), .gmii_rx_d (rx_d[2*8 +: 8]),
      .gmii_tx_en (tx_en[2]), .gmii_tx_d (tx_d[2*8 +: 8]));

  sw_gmii_if #(.PORT_ID(3), .BYTE_PERIOD(BP3)) u3 (
      .clk_i (clk_i), .rst_ni (rst_ni), .enable_i (link_up[3]),
      .gmii_rx_en (rx_en[3]), .gmii_rx_d (rx_d[3*8 +: 8]),
      .gmii_tx_en (tx_en[3]), .gmii_tx_d (tx_d[3*8 +: 8]));

  // ==========================================================================
  // Per-port scoreboard queues
  // ==========================================================================
  sw_rec_q #(.DEPTH(EXP_DEPTH)) q0 (.clk_i(clk_i), .rst_ni(rst_ni));
  sw_rec_q #(.DEPTH(EXP_DEPTH)) q1 (.clk_i(clk_i), .rst_ni(rst_ni));
  sw_rec_q #(.DEPTH(EXP_DEPTH)) q2 (.clk_i(clk_i), .rst_ni(rst_ni));
  sw_rec_q #(.DEPTH(EXP_DEPTH)) q3 (.clk_i(clk_i), .rst_ni(rst_ni));

  // ==========================================================================
  // Traffic injection
  // ==========================================================================
  /// Present a frame on `port`.  Blocks for the frame and its inter-frame gap.
  task automatic send_on(
      input int unsigned port,
      input sw_mac_t     dst,
      input sw_mac_t     src,
      input logic [15:0] l2type,
      input int unsigned total_len,
      input bit          vlan_en     = 1'b0,
      input bit          corrupt_fcs = 1'b0,
      input bit          drop_fcs    = 1'b0);
    case (port)
      0: u0.send(dst, src, l2type, total_len, vlan_en, corrupt_fcs, drop_fcs);
      1: u1.send(dst, src, l2type, total_len, vlan_en, corrupt_fcs, drop_fcs);
      2: u2.send(dst, src, l2type, total_len, vlan_en, corrupt_fcs, drop_fcs);
      3: u3.send(dst, src, l2type, total_len, vlan_en, corrupt_fcs, drop_fcs);
      default: ;
    endcase
  endtask

  // ==========================================================================
  // Scoreboard access
  // ==========================================================================
  /// Record that port `port` is expected to emit `r`.
  task automatic expect_push(input int unsigned port, input tb_rec_t r);
    case (port)
      0: q0.push(r);
      1: q1.push(r);
      2: q2.push(r);
      3: q3.push(r);
      default: ;
    endcase
  endtask

  /// Number of expectations still outstanding on `port`.
  function automatic int unsigned expect_count(input int unsigned port);
    case (port)
      0: return q0.size_o;
      1: return q1.size_o;
      2: return q2.size_o;
      3: return q3.size_o;
      default: return 0;
    endcase
  endfunction

  /// Take the oldest expectation of `port`; a zero record means "none left".
  ///
  /// This is a task rather than a function because removing an element from the
  /// queue takes a clock, and a function cannot contain a wait.
  task automatic expect_take(
      input  int unsigned port,
      output tb_rec_t     r);
    r = '0;
    case (port)
      0: begin if (q0.size_o > 0) q0.pop(r); end
      1: begin if (q1.size_o > 0) q1.pop(r); end
      2: begin if (q2.size_o > 0) q2.pop(r); end
      3: begin if (q3.size_o > 0) q3.pop(r); end
      default: ;
    endcase
  endtask

  /// Drop every expectation on `port`, so one test cannot leak into the next.
  task automatic expect_clear(input int unsigned port);
    tb_rec_t dummy;
    int      guard;
    guard = 0;
    while ((expect_count(port) > 0) && (guard < 4 * EXP_DEPTH)) begin
      expect_take(port, dummy);
      guard++;
    end
  endtask

  /// Pop the oldest frame the monitor of `port` saw; length 0 means "none".
  task automatic pop_on(
      input  int unsigned port,
      output tb_rec_t     r,
      input  int unsigned timeout = 20000);
    case (port)
      0: u0.pop_frame(r, timeout);
      1: u1.pop_frame(r, timeout);
      2: u2.pop_frame(r, timeout);
      3: u3.pop_frame(r, timeout);
      default: r = '0;
    endcase
  endtask

  /// Number of frames received on `port` that the scoreboard has not consumed.
  function automatic int unsigned pending_on(input int unsigned port);
    case (port)
      0: return u0.pending();
      1: return u1.pending();
      2: return u2.pending();
      3: return u3.pending();
      default: return 0;
    endcase
  endfunction

  /// Frames the monitors had to discard because a queue was full.  A non-zero
  /// result means the scoreboard itself lost data, which invalidates the run.
  ///
  /// A task rather than a function: a function body may not contain a wait, and
  /// Icarus Verilog does not resolve a function call on a hierarchical instance
  /// from inside another function.
  task automatic monitor_drops(output int unsigned n);
    n = u0.dropped() + u1.dropped() + u2.dropped() + u3.dropped();
  endtask

  /// Frames the switch emitted that were too short to be a legal Ethernet
  /// frame; any non-zero value is a transmit-path protocol violation.
  task automatic short_frames(output int unsigned n);
    n = u0.short_frames() + u1.short_frames() + u2.short_frames() + u3.short_frames();
  endtask

endmodule : sw_if_array

`endif // SW_IF_ARRAY_SV
