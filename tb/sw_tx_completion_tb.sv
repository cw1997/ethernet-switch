// ============================================================================
//  File        : tb/sw_tx_completion_tb.sv
//  Description : Transmit-completion pulse and length regression of
//                `es_mac_tx_frame`.
//
//                The block owns the transmit side of the frame contract: it
//                serialises a frame of `fr_len_i` MAC client octets onto the
//                wire at BYTE_PERIOD clocks per octet - preamble and SFD
//                included, FCS appended - and reports one `done_o` pulse with
//                the client length on `done_len_o`.  This bench verifies
//                exactly that contract at three link rates:
//
//                  * counts the enabled wire-octet clocks for 64- and
//                    100-octet client frames at BYTE_PERIOD 1, 4 and 40,
//                  * checks that `done_o` rises in the final FCS window, with
//                    the reported client length,
//                  * checks that the completion is a one-clock pulse: the
//                    enable and the done strobe are both low again three
//                    clocks later, before the inter-frame gap is out.
//
//                The payload input is a constant, so the bench deliberately
//                makes no payload or FCS comparison - the wire content is
//                checked by the GMII/MII/RMII monitors of the system
//                regressions.  What this bench owns is the *timing* of the
//                frame: a completion that fires early or late, or a length
//                report that does not match the request, passes every other
//                testbench and still breaks the egress descriptor stream.
//
//                Structure: `sw_tx_completion_case` is one rate configuration,
//                self-contained and self-checking; the top module forks three
//                of them in parallel and waits for all three `finished` flags,
//                so the three rates run concurrently rather than serially.
// ============================================================================
`timescale 1ns/1ps
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "console/es_console_defs.sv"

// The RTL declarations (`SW_LEN_W`, `sw_speed_e`, ...) arrive at
// compilation-unit scope through the includes above and need no import - the
// same declaration set the DUT uses, so the bench cannot disagree with it.
module sw_tx_completion_case #(
  /// Octet period used to check completion timing at multiple link rates.
  parameter int BP = 1
) (
  /// Completion flag for the enclosing parallel regression.
  output    logic finished = 0
);

  // --------------------------------------------------------------------------
  // Clock, reset and DUT wiring
  //
  // The DUT reset is active low, so `rst = 0` holds it in reset and the
  // stimulus releases it after four clocks.  All stimulus edges are taken on
  // the falling edge, which keeps the drive point unambiguous with respect to
  // the DUT's own `always_ff` blocks.
  // --------------------------------------------------------------------------
  logic clk = 0, rst = 0, start = 0;
  always #5 clk = ~clk;
  logic busy, done, en, rd;
  logic [7:0] data;
  logic [SW_LEN_W-1:0] length = SW_LEN_W'(64), done_len;
  int octet_clocks = 0, completions = 0, expected_octets = 76, expected_length = 64;

  es_mac_tx_frame #(
    .BYTE_PERIOD(BP)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rst),
    .fr_start_i   (start),
    .fr_len_i     (length),
    .done_o       (done),
    .done_len_o   (done_len),
    .tx_busy_o    (busy),
    .beat_valid_i (1'b1),
    .beat_data_i  (64'd0),
    .beat_rd_o    (rd),
    .oct_en_o     (en),
    .oct_d_o      (data)
  );

  // --------------------------------------------------------------------------
  // Cycle-accurate completion checker
  //
  // The octet counter advances on every clock the wire enable is high, and the
  // completion is judged in the same clock `done_o` rises:
  //
  //   * the enable must still be high - the done pulse belongs to the final
  //     FCS window, not to a later idle clock,
  //   * the count must be exactly `expected_octets * BP` - eight preamble
  //     octets plus the client data plus the four FCS octets, one window of
  //     BP clocks each - so a frame that starts or ends one window off fails
  //     by name,
  //   * the reported length must be the client length that was requested,
  //     not the wire length.
  //
  // After a completion the counter restarts, so the second frame is judged on
  // its own octets rather than on a running total.
  // --------------------------------------------------------------------------
  always @(posedge clk)
    if (rst) begin
      if (en) octet_clocks++;
      if (done) begin
        if (!en || octet_clocks != expected_octets * BP || int'(done_len) != expected_length)
          $fatal(1, "completion wrong BP=%0d clocks=%0d len=%0d", BP, octet_clocks, done_len);
        completions++;
        octet_clocks = 0;
        $display("PASS TX completion BP=%0d after all %0d wire octets len=%0d", BP,
                 expected_octets, done_len);
      end
    end

  // --------------------------------------------------------------------------
  // Stimulus and expected results
  //
  // Two frames back to back: a 64-octet client frame, then - after the first
  // completion has been observed and the transmit path has gone idle - a
  // 100-octet one.  The expectations are updated together with the request, so
  // the checker above can never judge frame two against frame one's numbers.
  // --------------------------------------------------------------------------
  initial begin
    repeat (4) @(negedge clk);
    rst = 1;
    repeat (3) @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;
    wait (completions == 1);
    wait (!busy);
    @(negedge clk);
    length = SW_LEN_W'(100);
    expected_length = 100;
    expected_octets = 112;
    start = 1;
    @(negedge clk);
    start = 0;
    wait (completions == 2);
    repeat (3) @(negedge clk);
    if (en || done) $fatal(1, "completion must be a one-cycle pulse before IFG");
    finished = 1;
  end
endmodule : sw_tx_completion_case

// ---------------------------------------------------------------------------
// Top module: one case per octet period, all three in parallel.
//
// BP = 1 is 1000 Mbit/s, BP = 4 a fast 100 Mbit/s, BP = 40 the 10 Mbit/s
// cadence; the slow case is the one that turns an off-by-one octet window
// into a count the checker can see.
// ---------------------------------------------------------------------------
module sw_tx_completion_tb;

  /// One bit per case module; the run ends when all three are set.
  logic [2:0] finished;
  sw_tx_completion_case #(.BP(1)) c1 (finished[0]);
  sw_tx_completion_case #(.BP(4)) c4 (finished[1]);
  sw_tx_completion_case #(.BP(40)) c40 (finished[2]);
  initial begin
    wait (&finished);
    $display("sw_tx_completion_tb: PASS, 6 frames, 0 errors");
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
    $fatal(1, "TX completion timeout");
  end
endmodule : sw_tx_completion_tb
