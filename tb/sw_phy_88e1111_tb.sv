// ============================================================================
//  File        : sw_phy_88e1111_tb.sv
//  Description : Clause-22 PHY discovery and link-policy regression.
//
//                An independent MDC-edge model decodes management commands and drives read
//                turnaround/data for PHY address 16. Stimulus checks advertised modes, link
//                loss, unsupported speed/duplex and recovery after missing acknowledgements.
// ============================================================================
// A wire-level Clause 22 PHY model, rather than calls into manager internals.
`timescale 1ns/1ps
module sw_phy_88e1111_tb;
  logic clk = 0, rst = 0;
  always #5 clk = ~clk;
  logic mdc, out_pin, oe, mdio = 1, enabled;
  logic [7:0] status;
  logic present = 1, link_up = 1, full = 1;
  logic [ 1:0] speed = 1;
  logic [63:0] command = 0;
  logic [15:0] reply = 0, advertisement = 16'h0de1, gigabit = 16'h0300, control = 0;
  int bit_index = 0, errors = 0, checks = 0;
  logic read_cmd = 0, selected = 0;
  logic [4:0] reg_addr = 0;
  es_perips_phy_88e1111 #(
    .CLK_FREQ_HZ      (10_000_000),
    .POLL_INTERVAL_MS (1),
    .RESET_WAIT_MS    (0)
  ) dut (
    .clk_i     (clk),
    .rst_ni    (rst),
    .mdio_i    (oe ? out_pin : mdio),
    .mdc_o     (mdc),
    .mdio_o    (out_pin),
    .mdio_oe_o (oe),
    .status_o  (status),
    .enabled_o (enabled)
  );
  always @(posedge mdc) begin
    command = {command[62:0], oe ? out_pin : mdio};
    if (bit_index == 45) begin
      read_cmd = command[13:10] == 4'b0110;
      selected = present && (command[9:5] == 5'd16);
      reg_addr = command[4:0];
      case (reg_addr)
        5'd2: reply = 16'h0141;
        5'd3: reply = 16'h0cc1;
        5'd4: reply = advertisement;
        5'd9: reply = gigabit;
        5'd1: reply = link_up ? 16'h0024 : 16'h0000;
        5'd17: reply = {speed, full, 1'b0, 1'b1, link_up, 10'd0};
        default: reply = 0;
      endcase
    end
    if (bit_index == 63) begin
      if (selected && !read_cmd)
        case (reg_addr)
          5'd4: advertisement = command[15:0];
          5'd9: gigabit = command[15:0];
          5'd0: control = command[15:0];
          default: ;
        endcase
      bit_index = 0;
    end else bit_index++;
  end
  always @(negedge mdc) begin
    mdio = 1;
    if (read_cmd && selected) begin
      if (bit_index == 47) mdio = 0;
      else if (bit_index >= 48) mdio = reply[63-bit_index];
    end
  end
  // --------------------------------------------------------------------------
  // Reference and checking helpers
  // --------------------------------------------------------------------------
  task check(input bit ok, input string label);
    checks++;
    if (ok) $display("PASS PHY %s", label);
    else begin
      errors++;
      $display("FAIL PHY %s status=%h", label, status);
    end
  endtask
  // --------------------------------------------------------------------------
  // Stimulus and expected results
  // --------------------------------------------------------------------------
  initial begin
    repeat (4) @(negedge clk);
    rst = 1;
    wait (status[0]);
    @(negedge clk);
    check(enabled && status[4:3] == 1 && status[2], "discovers PHY at address16 and reports 100FD");
    check(advertisement == 16'h0101 && gigabit == 0 && control == 16'h1200,
          "only 100FD advertised and negotiation restarted");
    link_up = 0;
    repeat (14000) @(negedge clk);
    check(status[0] && !enabled && !status[1], "cable unplug detected");
    link_up = 1;
    speed   = 0;
    repeat (14000) @(negedge clk);
    check(status[0] && !enabled && status[4:3] == 0, "unsupported 10M reported and disabled");
    speed = 1;
    full  = 0;
    repeat (14000) @(negedge clk);
    check(!enabled && !status[2], "half duplex reported and disabled");
    full = 1;
    repeat (14000) @(negedge clk);
    check(enabled, "100FD recovery");
    present = 0;
    repeat (18000) @(negedge clk);
    check(!enabled && status[5] && !status[0], "missing MDIO ack invalidates status");
    present = 1;
    repeat (60000) @(negedge clk);
    check(enabled, "management retries and recovers");
    $display("sw_phy_88e1111_tb: %0d checks %0d errors", checks, errors);
    if (errors) $fatal(1, "PHY failed");
    $finish;
  end
  // --------------------------------------------------------------------------
  // Watchdog
  //
  // Bounds stalled handshakes and missing completion; expiration is a test
  // failure.
  // --------------------------------------------------------------------------
  initial begin
    #3_000_000;
    $fatal(1, "PHY timeout");
  end
endmodule
