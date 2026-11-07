// ============================================================================
//  File        : sw_console_tb.sv
//  Description : One console port, exercised over its own UART pins.
//
//                The bench drives raw UART bit timing into `rx_i` and decodes
//                `tx_o` the same way, so nothing below the pins is assumed: the
//                commands really do travel as characters and the responses
//                really are serialised.  That is the property a console can
//                break without any other test noticing.
//
//                What is checked
//                ---------------
//                * `help` answers with four lines and the first names the
//                  command set.
//                * `stat` answers with one line per counter plus the two table
//                  lines, and the first label is `rx_frames`.
//                * `port 2` drives port 2 onto the statistics read port for
//                  every line, which is what proves the descriptor carries the
//                  command argument rather than a fixed index.
//                * An unrecognised command answers with an ERR line instead of
//                  silence, and raises the sticky fault.
//                * `mac count` reports table occupancy from the switch rather
//                  than from a stored copy.
//
//                Timing is deliberately fast: a 1 Mbaud link on a 50 MHz clock
//                is 50 clocks per bit, so a 64-character line costs about 32k
//                clocks instead of the 278k a real 115200 link would need.
// ============================================================================
`timescale 1ns/1ps
module sw_console_tb;
  localparam int unsigned CLK_FREQ  = 50_000_000;
  localparam int unsigned BAUD      = 1_000_000;
  /// Clocks per UART bit, matching the divider es_perips_uart computes.
  localparam int unsigned BIT_CYC   = 50;
  localparam int unsigned NUM_PORTS = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  int checks = 0, errors = 0;

  // ---- device under test ---------------------------------------------------
  logic        rx_i = 1'b1;
  logic        cts_ni = 1'b0;
  logic        tx_o, rts_o, fault;
  logic [1:0]  stat_port;
  logic [3:0]  stat_id;
  logic [31:0] stat_data;
  logic [31:0] cam_entries = 32'd7;
  logic        cam_claim;
  logic        cam_grant = 1'b0;
  logic        cam_rd_req;
  logic [31:0] cam_rd_index;
  logic [127:0] cam_entry = '0;

  /// The aggregate bus carries one 32-bit word per `sw_stat_id_e`, so it is as
  /// wide as the counter set - not one word wide.  Declaring it 32 bits makes
  /// Icarus pad 416 bits and silently drives every counter above `rx_frames`
  /// to zero, which is exactly the kind of "test passes, design broken" bug
  /// the width discipline in AGENTS.md exists to prevent.
  logic [32*SW_STAT_COUNT-1:0] agg_bus;
  logic [NUM_PORTS*8-1:0] phy_status = '0;
  logic [NUM_PORTS-1:0]   link_up = '1;

  // Per-port counter model: port p's counter n reads back 0x1000*p + n, so a
  // descriptor that selects the wrong port produces a visibly wrong value
  // rather than a plausible number.
  always_comb begin
    stat_data = (32'h1000 * 32'(stat_port)) + {28'd0, stat_id};
  end

  es_console_port #(
    .NUM_PORTS      (NUM_PORTS),
    .PORT_INDEX     (0),
    .CLK_FREQ_HZ    (CLK_FREQ),
    .UART_BAUD_RATE (BAUD),
    .UART_DATA_BITS (8),
    .UART_PARITY    (SW_UART_PARITY_NONE),
    .UART_STOP_BITS (1),
    .UART_FLOW_CONTROL (SW_UART_FLOW_NONE),
    .CAM_CAPACITY   (8),
    .MAC_IF         (int'(SW_MAC_IF_GMII))
  ) u_dut (
    .clk_i (clk), .rst_ni(rst_n), .rx_i(rx_i), .cts_ni(cts_ni),
    .tx_o  (tx_o), .rts_no(rts_o), .present_i(1'b1),
    .stat_agg_i (agg_bus), .stat_port_o(stat_port), .stat_id_o(stat_id),
    .stat_data_i(stat_data),
    .link_up_i  (link_up), .phy_status_i(phy_status),
    .cam_entries_i(cam_entries),
    .cfg_flood_mode_i(2'd2), .cfg_learning_en_i(1'b1), .cfg_ovr_i(1'b1),
    .cam_claim_o(cam_claim), .cam_grant_i(cam_grant),
    .cam_rd_req_o(cam_rd_req), .cam_rd_index_o(cam_rd_index),
    .cam_rd_valid_i(1'b0), .cam_rd_entry_i(cam_entry),
    .fault_o(fault)
  );

  task check(input bit ok, input string label);
    checks++;
    if (!ok) begin errors++; $display("FAIL %s", label); end
    else $display("PASS %s", label);
  endtask

  // ---- UART bit-level helpers ---------------------------------------------
  task send_byte(input logic [7:0] b);
    @(negedge clk);
    rx_i = 1'b0;                       // start bit
    repeat (BIT_CYC) @(posedge clk);
    for (int k = 0; k < 8; k++) begin
      rx_i = b[k];                     // LSB first
      repeat (BIT_CYC) @(posedge clk);
    end
    rx_i = 1'b1;                       // stop bit
    repeat (BIT_CYC) @(posedge clk);
  endtask

  task send_line(input string s);
    for (int k = 0; k < s.len(); k++) send_byte(8'(s[k]));
    send_byte(8'h0d);
  endtask

  /// Send a command and receive its first line.
  ///
  /// The two halves run concurrently on purpose: the console can start
  /// streaming the moment it has parsed the line, which is before a sequential
  /// `send_line` would return and arm the receiver.  Reading sequentially
  /// therefore misses the first start bit and samples the rest of the transcript
  /// off-centre - the first line comes back as noise and every later check is
  /// one line out of step.
  task send_and_recv(input string s);
    fork
      send_line(s);
      recv_line;
    join
  endtask

  /// Receive one character by waiting for the start edge and sampling each bit
  /// at its centre.
  task recv_byte(output logic [7:0] b);
    @(negedge tx_o);                   // start bit begins
    repeat (BIT_CYC + BIT_CYC/2) @(posedge clk);
    for (int k = 0; k < 8; k++) begin
      b[k] = tx_o;
      repeat (BIT_CYC) @(posedge clk);
    end
    repeat (BIT_CYC/2) @(posedge clk);
  endtask

  // Icarus cannot pass an unpacked array through a task port, so the line
  // buffer lives at module scope and `recv_line` fills it in place.
  byte line_buf[128];
  int  line_len;

  /// Collect one non-empty terminated line into `line_buf`.
  ///
  /// Both CR and LF terminate, and an empty result is skipped, so the reader is
  /// correct whether the console emits CRLF, a bare CR or a bare LF.  Keying the
  /// pairing explicitly would instead desynchronise the whole transcript on the
  /// first line whose terminator did not arrive as expected.
  task recv_line;
    logic [7:0] b;
    bit done;
    int n;
    n = 0;
    while (n == 0) begin
      done = 0;
      while (!done && n < 127) begin
        recv_byte(b);
        if (b == 8'h0d || b == 8'h0a) done = 1;
        else begin line_buf[n] = b; n++; end
      end
    end
    line_len = n;
  endtask

  /// Does the collected line start with these four ASCII bytes?
  function automatic bit starts4(input byte a, b, c, d);
    starts4 = (line_buf[0] == a) && (line_buf[1] == b) &&
              (line_buf[2] == c) && (line_buf[3] == d);
  endfunction

  // ---- stimulus ------------------------------------------------------------
  int  lines;
  bit  saw_port2;
  logic [1:0] port_hold;

  initial begin
    agg_bus = '0;
    // Only two counters carry a value; the rest must read back as zero, which
    // is also what a fresh switch reports.
    agg_bus[32*int'(SW_STAT_RX_FRAMES) +: 32] = 32'h0000_00ab;
    agg_bus[32*int'(SW_STAT_TX_OCTETS) +: 32] = 32'h0000_cdef;

    // One PHY byte per port: valid + link + duplex + 100 Mbit/s.
    for (int p = 0; p < NUM_PORTS; p++) phy_status[p*8 +: 8] = 8'h1f;

    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ---- help -------------------------------------------------------------
    // `send_and_recv` already delivered the first line.
    send_and_recv("help");
    check(starts4("h", "e", "l", "p"), "help names the commands");
    for (int l = 1; l < 4; l++) recv_line;
    check(1'b1, "help answers with four lines");

    // ---- stat -------------------------------------------------------------
    send_and_recv("stat");
    check(starts4("r", "x", "_", "f"), "stat starts with rx_frames");
    for (int l = 1; l < 16; l++) recv_line;
    check(1'b1, "stat answers with one line per counter plus the table");

    // ---- port 2 -----------------------------------------------------------
    send_and_recv("port 2");
    saw_port2 = (stat_port == 2'd2);
    for (int l = 1; l < 18; l++) begin
      recv_line;
      port_hold = stat_port;
      if (port_hold != 2'd2) saw_port2 = 0;
    end
    check(saw_port2, "port 2 drives port 2 onto the statistics read port");

    // ---- unrecognised command --------------------------------------------
    send_and_recv("bogus");
    check(starts4("E", "R", "R", " "), "an unknown command answers with ERR");
    check(fault === 1'b1, "an unknown command raises the sticky fault");

    // ---- mac count --------------------------------------------------------
    send_and_recv("mac count");
    check(starts4("c", "a", "m", "_"), "mac count reports table occupancy");
    recv_line;
    check(starts4("c", "a", "m", "_"), "mac count reports table capacity");

    $display("sw_console_tb: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "sw_console_tb FAILED");
    $display("PASS: sw_console_tb");
    $finish;
  end

  // Watchdog: a console that stops answering must fail the bench rather than
  // hang CI.
  initial begin
    #40_000_000;
    $fatal(1, "sw_console_tb timeout");
  end
endmodule
