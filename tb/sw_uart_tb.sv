// ============================================================================
//  File        : tb/sw_uart_tb.sv
//  Description : UART wire framing and receive-error regression of
//                `es_perips_uart`.
//
//                The bench drives raw UART bit timing into `rx_i` and decodes
//                `tx_o` with an independent bit-level model, so nothing below
//                the pins is assumed - exactly the property a console can
//                break without any register-level test noticing.  Six
//                parameter configurations run in parallel, covering:
//
//                  * 5..8 data bits, odd / even / no parity, one or two stop
//                    bits, with and without RTS/CTS flow control,
//                  * TX framing: the start edge, every data bit, the parity
//                    bit and the stop bits are each sampled at bit centre,
//                  * RX framing: independently driven start, data, parity and
//                    stop bits, with the received value checked against the
//                    wire value,
//                  * error injection: a bad parity bit, a bad stop bit and a
//                    receive overflow (backpressure with `rx_ready_i` low)
//                    must each be diagnosed on the sticky error outputs,
//                  * flow control: CTS gating between characters without
//                    truncating one, and RTS reflecting receive capacity.
//
//                The 10 ns test clock advances cycle-counted UART models; HZ
//                configures the DUT baud divider, so the bench also covers a
//                divider ratio different from the canonical one.
// ============================================================================
`timescale 1ns/1ps
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "console/es_console_defs.sv"

// One flow configuration: parameters select the character format, parity,
// stop bits and flow-control mode, and the whole case self-checks.
module sw_uart_case #(
  /// UART character width, parity mode, stop-bit count, and flow-control mode.
  /// Data bits on the wire; 5..8 per 16550-style programming.
  parameter int BITS = 8,
  /// Parity mode: 0 = none, 1 = odd, 2 = even.
  parameter int PAR = 0,
  /// Stop bits transmitted and expected (1 or 2).
  parameter int STOPS = 1,
  /// Flow control: 0 = none (CTS ignored), 1 = RTS/CTS honoured.
  parameter int FLOW = 0,
  /// Clock frequency and baud rate used by this UART instance.
  /// The divider ratio HZ/BAUD is deliberately not the board default.
  parameter int HZ = 1_600_000,
  parameter int BAUD = 100_000
) (
  /// Completion flag for the enclosing parallel regression.
  output    logic finished = 0
);

  // --------------------------------------------------------------------------
  // Clock, reset and DUT wiring
  //
  // Reset is active low: `rst = 0` holds the DUT in reset until the stimulus
  // releases it.  `rx` idles high (UART mark level) from time zero, so the
  // line is legal before the first start bit.
  // --------------------------------------------------------------------------
  logic clk = 0, rst = 0, rx = 1, cts = 0, tx, rts;
  always #5 clk = ~clk;
  logic send = 0, ready, got, parerr, frerr, overflow;
  logic [7:0] txdata = 8'ha5, rxdata;
  logic accept = 1;
  int errors = 0, received = 0;
  /// Core clocks per UART bit, rounded to nearest - the divider es_perips_uart
  /// itself computes from HZ and BAUD.
  localparam int PERIOD = (HZ + BAUD / 2) / BAUD;
  /// Bit mask of the low `BITS` data bits; the received byte is compared
  /// against the wire value through it, so unused upper bits are don't-care.
  localparam logic [7:0] MASK = 8'(255 >> (8 - BITS));

  es_perips_uart #(
    .CLK_FREQ_HZ  (HZ),
    .BAUD_RATE    (BAUD),
    .DATA_BITS    (BITS),
    .PARITY       (PAR),
    .STOP_BITS    (STOPS),
    .FLOW_CONTROL (FLOW)
  ) dut (
    .clk_i          (clk),
    .rst_ni         (rst),
    .rx_i           (rx),
    .cts_ni         (cts),
    .tx_o           (tx),
    .rts_no         (rts),
    .tx_valid_i     (send),
    .tx_data_i      (txdata),
    .tx_ready_o     (ready),
    .rx_valid_o     (got),
    .rx_data_o      (rxdata),
    .rx_ready_i     (accept),
    .parity_error_o (parerr),
    .frame_error_o  (frerr),
    .overflow_o     (overflow)
  );

  // --------------------------------------------------------------------------
  // Reference and checking helpers
  // --------------------------------------------------------------------------
  /// Print one PASS/FAIL line tagged with this case's configuration.  The tag
  /// names the format, so a failure is diagnosable from the log alone.
  task check(input bit ok, input string label);
    if (!ok) begin
      errors++;
      $display("FAIL UART %0d/%0d/%0d/%0d %s", BITS, PAR, STOPS, FLOW, label);
    end else $display("PASS UART %0d/%0d/%0d/%0d %s", BITS, PAR, STOPS, FLOW, label);
  endtask

  /// Hold `rx` at bit value `b` for exactly one bit period, advancing on the
  /// falling edge so the DUT samples near bit centre.
  task wirebit(input bit b);
    rx = b;
    repeat (PERIOD) @(negedge clk);
  endtask

  /// Shift one complete character onto `rx` as a wire-level model would.
  ///
  /// Start bit, `BITS` data bits LSB first, the parity bit when enabled, then
  /// `STOPS` stop bits and two idle bits of spacing.  `badpar` inverts the
  /// parity bit and `badstop` drives the stop slot low - each is how the bench
  /// injects a frame the receiver has to reject.
  task receive_frame(input logic [7:0] value, input bit badpar, input bit badstop);
    bit parity;
    parity = 0;
    wirebit(0);
    for (int b = 0; b < BITS; b++) begin
      wirebit(value[b]);
      parity ^= value[b];
    end
    if (PAR != 0) wirebit(parity ^ (PAR == 1) ^ badpar);
    repeat (STOPS) wirebit(!badstop);
    wirebit(1);
    wirebit(1);
  endtask

  /// Sticky latches for the three receive-error outputs; the errors are
  /// one-clock pulses, so they are captured here and checked after the fact.
  bit seenpar = 0, seenframe = 0, seenover = 0;
  always @(negedge clk) begin
    if (got) begin
      received++;
      check(rxdata == (8'h53 & MASK), "RX wire value");
    end
    if (parerr) seenpar = 1;
    if (frerr) seenframe = 1;
    if (overflow) seenover = 1;
  end

  /// Decode one transmitted character on `tx` at bit centre and check every
  /// slot against the request that produced it.
  ///
  /// The falling edge is the start bit; half a period later the first sample
  /// lands at its centre, and every following slot is one full period on.
  task decode_tx;
    bit parity;
    parity = 0;
    @(negedge tx);
    repeat (PERIOD / 2) @(negedge clk);
    check(tx == 0, "TX start");
    for (int b = 0; b < BITS; b++) begin
      repeat (PERIOD) @(negedge clk);
      check(tx == txdata[b], "TX data bit");
      parity ^= txdata[b];
    end
    if (PAR != 0) begin
      repeat (PERIOD) @(negedge clk);
      check(tx == (parity ^ (PAR == 1)), "TX parity");
    end
    repeat (STOPS) begin
      repeat (PERIOD) @(negedge clk);
      check(tx == 1, "TX stop");
    end
  endtask

  // --------------------------------------------------------------------------
  // Stimulus and expected results
  //
  // Phase order: one TX character decoded against its request (with CTS
  // raised mid-character for the flow cases, which must gate the *next*
  // character without truncating this one), the flow verdict, then a valid RX
  // frame, the parity / stop-bit / overflow injections, and the final verdict.
  // --------------------------------------------------------------------------
  initial begin
    repeat (4) @(negedge clk);
    rst = 1;
    repeat (4) @(negedge clk);
    fork
      decode_tx();
      begin
        send = 1;
        @(negedge clk);
        send = 0;
        repeat (5) @(negedge clk);
        cts = 1;
      end
    join
    repeat (PERIOD * 3) @(negedge clk);
    if (FLOW) check(!ready && tx, "CTS stops between characters without truncation");
    else check(ready, "None ignores CTS");
    cts = 0;
    repeat (4) @(negedge clk);
    receive_frame(8'h53, 0, 0);
    check(received == 1, "one valid frame delivered");
    if (PAR != 0) begin
      receive_frame(8'h53, 1, 0);
      check(seenpar && received == 1, "bad parity rejected");
    end
    receive_frame(8'h53, 0, 1);
    check(seenframe, "bad stop diagnosed");
    accept = 0;
    repeat (3) @(negedge clk);
    check(rts == (FLOW != 0), "RTS reflects receive capacity");
    receive_frame(8'h53, 0, 0);
    check(seenover, "receive overflow diagnosed");
    if (errors) $fatal(1, "UART case failed %0d errors", errors);
    $display("UART case done, 0 errors");
    finished = 1;
  end
endmodule : sw_uart_case

// ---------------------------------------------------------------------------
// Top module: six configurations in parallel.
//
// The set spans the corner cases: a fast divider (c0, 50 MHz / 115200), the
// full feature set with even parity and two stop bits (c1), the minimum 5-bit
// format (c2), no parity with two stops (c3), odd parity with two stops (c4)
// and the full set with even parity and single stop (c5).  All six must
// report completion before the run is a PASS.
// ---------------------------------------------------------------------------
module sw_uart_tb;

  /// One bit per case module; the run ends when all six are set.
  logic [5:0] finished;
  sw_uart_case #(
    .HZ   (50_000_000),
    .BAUD (115200)
  ) c0 (
    finished[0]
  );
  sw_uart_case #(
    .BITS  (7),
    .PAR   (2),
    .STOPS (2),
    .FLOW  (1)
  ) c1 (
    finished[1]
  );
  sw_uart_case #(
    .BITS  (5),
    .PAR   (1),
    .STOPS (1),
    .FLOW  (1)
  ) c2 (
    finished[2]
  );
  sw_uart_case #(
    .BITS  (6),
    .PAR   (0),
    .STOPS (2)
  ) c3 (
    finished[3]
  );
  sw_uart_case #(
    .BITS  (8),
    .PAR   (1),
    .STOPS (2)
  ) c4 (
    finished[4]
  );
  sw_uart_case #(
    .BITS  (8),
    .PAR   (2),
    .STOPS (1),
    .FLOW  (1)
  ) c5 (
    finished[5]
  );
  initial begin
    wait (&finished);
    $display("sw_uart_tb: PASS, 6 modes, 0 errors");
    $finish;
  end

  // --------------------------------------------------------------------------
  // Watchdog
  //
  // Bounds stalled handshakes and missing completion; expiration is a test
  // failure.
  // --------------------------------------------------------------------------
  initial begin
    #1_000_000;
    $fatal(1, "UART timeout");
  end
endmodule : sw_uart_tb
