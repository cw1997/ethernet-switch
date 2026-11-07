// ============================================================================
//  File        : sw_console_tb.sv
//  Description : UART command, snapshot and CSR arbitration regression.
//
//                Drives ASCII commands as UART bits and decodes response characters into a
//                transcript. A synthetic CAM responder supplies entries; checks cover
//                startup, CTS stalls, snapshot consistency and malformed commands. This is a
//                synchronous integration test, not board timing verification.
// ============================================================================
// End-to-end UART -> command parser -> cache/CSR arbitration -> text response.
`timescale 1ns/1ps
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "monitor/es_monitor_defs.sv"
`include "console/es_console_defs.sv"
module sw_console_tb;
  localparam int N = 4, PERIOD = 40;
  logic clk = 0, rst = 0;
  always #5 clk = ~clk;
  logic rx = 1, tx, cts = 0, rts, fault;
  logic [N*32*SW_STAT_COUNT-1:0] stat = '0;
  logic req, ready, valid, cache_req, cache_idle, claim, console_req, cam_req, cam_valid = 0;
  logic [31:0] addr, data, cache_addr, console_addr, cam_index;
  logic [127:0] cam_entry = 0;
  logic [(N+1)*SW_MON_BITS-1:0] image;
  string transcript = "";
  int errors = 0, checks = 0;
  logic [31:0] before_sequence;
  es_monitor_core #(
    .CLK_FREQ_HZ(4_000_000),
    .REFRESH_INTERVAL_MS(2),
    .CAM_CAPACITY(2)
  ) monitor_dut (
    .clk_i(clk),
    .rst_ni(rst),
    .port_stat_i(stat),
    .tx_done_i(N'(0)),
    .tx_len_i('0),
    .phy_status_i({N{8'h0f}}),
    .rx_used_i('0),
    .tx_used_i('0),
    .busy_i(1'b0),
    .flush_i(1'b0),
    .cam_entries_i(32'd1),
    .req_i(req),
    .addr_i(addr),
    .ready_o(ready),
    .valid_o(valid),
    .data_o(data),
    .cam_req_o(cam_req),
    .cam_index_o(cam_index),
    .cam_valid_i(cam_valid),
    .cam_entry_i(cam_entry)
  );
  always @(posedge clk) begin
    cam_valid <= cam_req;
    if (cam_req) cam_entry <= (cam_index == 0) ? {32'd1, 32'd1, 16'd0, 48'h021122334455} : 128'd0;
  end
  es_monitor_cache cache_dut (
    .clk_i  (clk),
    .rst_ni (rst),
    .pause_i(claim),
    .req_o  (cache_req),
    .addr_o (cache_addr),
    .ready_i(ready && !claim),
    .valid_i(valid && !claim),
    .data_i (data),
    .idle_o (cache_idle),
    .image_o(image)
  );
  es_console_core #(
    .CLK_FREQ_HZ(4_000_000),
    .UART_BAUD_RATE(100000),
    .UART_FLOW_CONTROL(SW_UART_FLOW_RTS_CTS)
  ) console_dut (
    .clk_i(clk),
    .rst_ni(rst),
    .rx_i(rx),
    .cts_ni(cts),
    .tx_o(tx),
    .rts_no(rts),
    .image_i(image),
    .cache_idle_i(cache_idle),
    .bus_claim_o(claim),
    .req_o(console_req),
    .addr_o(console_addr),
    .ready_i(ready && claim),
    .valid_i(valid && claim),
    .data_i(data),
    .fault_o(fault)
  );
  assign req  = claim ? console_req : cache_req;
  assign addr = claim ? console_addr : cache_addr;
  initial
    forever begin
      logic [7:0] ch;
      @(negedge tx);
      repeat (PERIOD / 2) @(negedge clk);
      if (tx !== 0) $fatal(1, "console TX bad start");
      for (int b = 0; b < 8; b++) begin
        repeat (PERIOD) @(negedge clk);
        ch[b] = tx;
      end
      repeat (PERIOD) @(negedge clk);
      if (tx !== 1) $fatal(1, "console TX bad stop");
      transcript = {transcript, string'(ch)};
    end
  // --------------------------------------------------------------------------
  // Reference and checking helpers
  // --------------------------------------------------------------------------
  function automatic bit contains(input string text, input string needle);
    bit found;
    found = 0;
    for (int i = 0; i + needle.len() <= text.len(); i++)
      if (text.substr(i, i + needle.len() - 1) == needle) found = 1;
    return found;
  endfunction
  // Return the first matching offset so the wire transcript can verify order,
  // independently of the command engine's internal line or state numbering.
  function automatic int position(input string text, input string needle);
    for (int i = 0; i + needle.len() <= text.len(); i++)
      if (text.substr(i, i + needle.len() - 1) == needle) return i;
    return -1;
  endfunction
  task check(input bit ok, input string label);
    checks++;
    if (ok) $display("PASS console %s", label);
    else begin
      errors++;
      $display("FAIL console %s\n%s", label, transcript);
    end
  endtask
  task send(input string command);
    for (int c = 0; c < command.len(); c++) begin
      rx = 0;
      repeat (PERIOD) @(negedge clk);
      for (int b = 0; b < 8; b++) begin
        rx = (command[c] >> b) & 1;
        repeat (PERIOD) @(negedge clk);
      end
      rx = 1;
      repeat (PERIOD) @(negedge clk);
    end
  endtask
  task settle;
    wait (!rts);
    repeat (12 * PERIOD) @(negedge clk);
  endtask
  task check_snapshot_consistency;
    string sequence_text, candidate;
    int count;
    bit consistent;
    count = 0;
    consistent = 1;
    sequence_text = "";
    for (int i = 0; i + 31 <= transcript.len(); i++) begin
      if (transcript.substr(i, i + 14) == "snapshot_seq=0x") begin
        candidate = transcript.substr(i + 15, i + 30);
        if (count == 0) sequence_text = candidate;
        else if (candidate != sequence_text) consistent = 0;
        count++;
      end
    end
    check(consistent && count == N + 1,
          "long status response preserves one snapshot across all records");
  endtask
  // --------------------------------------------------------------------------
  // Stimulus and expected results
  // --------------------------------------------------------------------------
  initial begin
    repeat (4) @(negedge clk);
    rst = 1;
    stat[(SW_STAT_COUNT+int'(SW_STAT_RX_FRAMES))*32 +: 32] = 32'd7;
    stat[(SW_STAT_COUNT+int'(SW_STAT_RX_OCTETS))*32 +: 32] = 32'd700;
    send("mac 1\015");
    settle();
    check(contains(transcript, "ERR sample_not_ready"),
          "startup cannot misreport an unavailable table as empty");
    transcript = "";
    wait (image[50*32]);
    repeat (10) @(negedge clk);
    send("help\015\n");
    settle();
    check(contains(transcript, "port <n>"), "help and CRLF accepted");
    transcript = "";
    cts = 1;
    repeat (4) @(negedge clk);
    send("port 1\015");
    repeat (2000) @(negedge clk);
    check(tx && rts && transcript.len() == 0,
          "CTS pauses full response while RTS refuses new commands");
    cts = 0;
    settle();
    check(contains(transcript, "page_0_all_else_port+1=0x0000000000000002"),
          "decimal port selector");
    check(contains(transcript, "rx_frames=0x0000000000000007"), "complete cumulative statistic");
    check(contains(transcript, "refresh_ms=0x0000000000000002"), "configured refresh reported");
    check(contains(transcript, "speed_mbit=0x0000000000000064") && contains(
          transcript, "full_duplex=0x0000000000000001"), "actual PHY speed and duplex decoded");
    transcript = "";
    send("port 4\015");
    settle();
    check(contains(transcript, "ERR command_or_port_or_length"), "invalid port rejected");
    transcript = "";
    send("port 3\015");
    settle();
    check(contains(transcript, "page_0_all_else_port+1=0x0000000000000004"),
          "default fourth port accepted");
    transcript = "";
    cts = 1;
    repeat (4) @(negedge clk);
    before_sequence = image[49*32 +: 32];
    send("mac 1\015");
    repeat (20_000) @(negedge clk);
    check(image[49*32 +: 32] > before_sequence,
          "MAC console paused by CTS does not freeze display refresh");
    cts = 0;
    settle();
    check(contains(transcript, "mac_address=0x0000021122334455"), "MAC filtered enumeration");
    check(contains(transcript, "mac_port=0x0000000000000001"), "MAC entry ownership");
    check(contains(transcript, "mac_start_clock") && contains(transcript, "mac_end_clock"
          ) && contains(transcript, "mac_end_flushes"),
          "live traversal timestamps and flush generation");
    transcript = "";
    // The unfiltered form must include the entry even though its owner is port 1.
    send("mac all\015");
    settle();
    check(contains(transcript, "mac_address=0x0000021122334455") &&
          contains(transcript, "mac_port=0x0000000000000001") &&
          contains(transcript, "mac_start_clock") && contains(transcript, "mac_end_clock"),
          "MAC all enumerates entries with traversal metadata");
    check(position(transcript, "mac_start_clock") >= 0 &&
          position(transcript, "mac_start_clock") < position(transcript, "mac_start_flushes") &&
          position(transcript, "mac_start_flushes") < position(transcript, "mac_address") &&
          position(transcript, "mac_address") < position(transcript, "mac_port") &&
          position(transcript, "mac_port") < position(transcript, "mac_end_clock") &&
          position(transcript, "mac_end_clock") < position(transcript, "mac_end_flushes"),
          "MAC metadata and entries preserve wire order");
    transcript = "";
    send("mac 0\015");
    settle();
    check(!contains(transcript, "mac_address"), "MAC filter excludes other ports");
    transcript = "";
    send("012345678901234567890123456789012345\015");
    settle();
    check(fault && contains(transcript, "ERR command_or_port_or_length"),
          "long line drained and diagnosed");
    transcript = "";
    send("status\015");
    repeat (5000) @(negedge clk);
    send("bad\015");
    settle();
    repeat (30_000) @(negedge clk);
    check(contains(transcript, "page_0_all_else_port+1=0x0000000000000000") && contains(
          transcript, "page_0_all_else_port+1=0x0000000000000002"),
          "status includes aggregate and all ports");
    check_snapshot_consistency();
    check(contains(transcript, "ERR busy_or_uart_frame_or_overflow"),
          "busy input explicitly diagnosed");
    $display("sw_console_tb: %0d checks %0d errors", checks, errors);
    if (errors) $fatal(1, "console failed");
    $finish;
  end
  // --------------------------------------------------------------------------
  // Watchdog
  //
  // Bounds stalled handshakes and missing completion; expiration is a test
  // failure.
  // --------------------------------------------------------------------------
  initial begin
    #100_000_000;
    $fatal(1, "console timeout transcript=%s", transcript);
  end
endmodule
