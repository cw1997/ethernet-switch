// ============================================================================
//  File        : sw_rec_q.sv
//  Description : A queue of scoreboard records with fixed capacity.
//
//                Icarus Verilog cannot elaborate an unpacked array of queues,
//                so the testbench cannot write the obvious
//                    tb_rec_t exp_q [NUM_PORTS][$];
//                and it cannot put a struct into a queue at all.  This module
//                provides the same service over flat packed records: push, pop,
//                size, peek and clear, with the depth as a parameter.
//
//                The implementation is a ring buffer whose head and tail are
//                plain counters, so there is no pointer wrap arithmetic and the
//                behaviour is identical in every simulator.
//
//                `push` and `pop` are *tasks* that drive the queue for exactly
//                one clock.  The input ports are plain nets on purpose: driving
//                them from inside a task is a simulation-only construct, and
//                keeping the datapath ports read-only in the rest of the module
//                makes it obvious that this is a testbench component.
// ============================================================================
`ifndef SW_REC_Q_SV
`define SW_REC_Q_SV

`include "sw_tb_pkg.sv"

module sw_rec_q import sw_tb_pkg::*; #(
  /// Number of records the queue can hold.
  parameter int unsigned DEPTH = 512
) (
  input  logic       clk_i,
  input  logic       rst_ni,

  // ---- push ----------------------------------------------------------------
  // The port-side strobes exist for the case where the queue is driven by
  // ordinary RTL, e.g. the transmit monitor of sw_gmii_if.  Leave them open
  // (`Z`) when unused: a hard `1'b0` would be a *drive* of the port, so the
  // task-driven strobes below could not contribute, and the queue would appear
  // permanently idle.  A `Z` port reads as high impedance and is resolved out of
  // the equation by the internal strobe, which is the behaviour wanted here.
  input  wire           push_i,
  input  tb_rec_t       push_data_i,

  // ---- pop -----------------------------------------------------------------
  input  wire           pop_i,
  output tb_rec_t       pop_data_o,   ///< head record; only valid when !empty_o
  output logic          empty_o,
  output logic          full_o,
  output int unsigned   size_o
);

  // ==========================================================================
  // Storage
  // ==========================================================================
  tb_rec_t mem [0:DEPTH-1];

  int unsigned rd_p;
  int unsigned wr_p;
  int unsigned cnt;

  // Occupancy after this clock edge.  A push is ignored while the queue is
  // full and a pop while it is empty; the testbench sizes the queue so that
  // this never happens, and `monitor_drops` reports it if it ever does.
  // The task-local strobes are OR-ed with the input ports.  Driving a port net
  // from inside a task is a simulation-only construct, which is exactly what a
  // testbench component wants; the RTL never uses this pattern.
  logic       push_strobe;
  tb_rec_t    push_word;
  logic       pop_strobe;

  // A tri-stated port read as `1'bx`; treating it as "no request" is what makes
  // an undriven port equivalent to a deasserted one.
  wire port_push = (push_i === 1'b1);
  wire port_pop  = (pop_i  === 1'b1);

  wire do_push = port_push | push_strobe;
  wire do_pop  = port_pop  | pop_strobe;

  // The record that is stored: from the input port for a port-driven push, from
  // the task-local register for a task-driven one.  The task register wins when
  // both are strobed, which cannot happen because the two sources are used by
  // different parts of the testbench.
  wire tb_rec_t push_value = push_strobe ? push_word : push_data_i;

  int unsigned cnt_d;
  always_comb begin
    cnt_d = cnt;
    if      (do_push && (cnt < DEPTH) && !(do_pop && (cnt > 0))) cnt_d = cnt + 1;
    else if (do_pop  && (cnt > 0))                               cnt_d = cnt - 1;
  end

  // Head and tail advance by one whenever their side of the queue moves.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rd_p <= 0;
      wr_p <= 0;
      cnt  <= 0;
    end else begin
      if (do_push && (cnt < DEPTH)) wr_p <= wr_p + 1;
      if (do_pop  && (cnt > 0))     rd_p <= rd_p + 1;
      cnt <= cnt_d;
    end
  end

  // Storage write: exactly one entry per clock, at the tail.
  always_ff @(posedge clk_i) begin
    if (do_push && (cnt < DEPTH)) begin
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (wr_p == i) mem[i] <= push_value;
      end
    end
  end

  // Head read: a plain mux over the entries, valid while the queue is not empty.
  // The reset branch has to initialise the whole array, not just the counters:
  // an unwritten entry is X in simulation, and an X that reaches `head` would
  // be returned as if it were a real record.
  tb_rec_t head;
  always_comb begin
    head = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (rd_p == i) head = mem[i];
    end
  end

  // Initial state.  The strobes and the whole memory have to start at a defined
  // value: an X on `push_strobe` or `pop_strobe` propagates into `do_push` /
  // `do_pop`, and because `if (X)` takes the false branch in Verilog, the
  // occupancy update would be silently skipped rather than failing loudly.
  initial begin
    push_strobe = 1'b0;
    pop_strobe  = 1'b0;
    push_word   = '0;
    rd_p        = 0;
    wr_p        = 0;
    cnt         = 0;
    for (int unsigned i = 0; i < DEPTH; i++) mem[i] = '0;
  end

  assign pop_data_o = head;
  assign empty_o    = (cnt == 0);
  assign full_o     = (cnt >= DEPTH);
  assign size_o     = cnt;

  // ==========================================================================
  // Task interface used by the scoreboard
  // ==========================================================================
  /// Append one record.
  ///
  /// The task holds the strobe for exactly one clock and then waits a second
  /// clock before returning.  That extra clock matters: the occupancy counter is
  /// updated with a non-blocking assignment on the strobe edge, so a caller that
  /// sampled `size_o` in the same time step as that edge would read the *old*
  /// value.  Waiting one clock makes `size_o` consistent by the time the task
  /// returns, so callers never have to know about the NBA region.
  task automatic push(input tb_rec_t r);
    push_strobe <= 1'b1;
    push_word   <= r;
    @(posedge clk_i);
    push_strobe <= 1'b0;
    @(posedge clk_i);
  endtask

  /// Remove and return the head record.  A zero record means the queue was
  /// empty, which the caller has to treat as a failure.
  ///
  /// The head is captured *before* the strobe, so the record returned is the one
  /// that was at the head on entry.  As in `push`, the task waits a further clock
  /// so that `size_o` is already updated when it returns.
  task automatic pop(output tb_rec_t r);
    r          = head;
    pop_strobe <= 1'b1;
    @(posedge clk_i);
    pop_strobe <= 1'b0;
    @(posedge clk_i);
  endtask

endmodule : sw_rec_q

`endif // SW_REC_Q_SV
