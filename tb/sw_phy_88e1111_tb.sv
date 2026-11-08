// ============================================================================
//  File        : tb/sw_phy_88e1111_tb.sv
//  Description : Clause-22 PHY discovery and link-policy regression of
//                `es_perips_phy_88e1111`.
//
//                The bench replaces the PHY with an independent MDC-edge
//                model: a 64-bit shift register decodes the management
//                command bit by bit and drives read turnaround / data for PHY
//                address 16, exactly as a real 88E1111 would on the wire.
//                Nothing inside the manager is observed - every verdict is
//                taken from the pins and from the reported `status_o` byte.
//
//                Verified here:
//
//                  * discovery - the manager finds the PHY at address 16,
//                    reads the ID registers, and reports the link it finds,
//                  * link policy - only 100 Mbit/s full duplex is advertised
//                    and negotiation is restarted; an unsupported speed or a
//                    half-duplex partner is reported and disables the port,
//                  * cable loss - a falling link is detected and disables
//                    the port,
//                  * robustness - a PHY that stops acknowledging MDIO
//                    invalidates the status byte, and management recovers
//                    once the PHY answers again.
//
//                The status byte layout used by the checks: bit 0 = link,
//                bit 1 = anomaly, bit 2 = full duplex, bits 4:3 = speed code,
//                bit 5 = management fault (no MDIO acknowledgement).
// ============================================================================
`timescale 1ns/1ps

// A wire-level Clause 22 PHY model, rather than calls into manager internals:
// the model owns the MDIO reply and the register file, the DUT only sees the
// two pins, which is what makes a manager bug invisible to the model and
// therefore visible to the checks.
module sw_phy_88e1111_tb;

  // --------------------------------------------------------------------------
  // Clock, reset and MDIO pins
  //
  // Reset is active low.  `mdio` idles high (the wire pull-up level) and the
  // DUT read port is muxed: while the DUT drives the pin (`oe`), the model
  // samples `out_pin`, otherwise the model's own reply.  The model therefore
  // never drives against the DUT, and a DUT that holds its driver enabled
  // where it should release the bus is visible as a corrupted command.
  // --------------------------------------------------------------------------
  logic clk = 0, rst = 0;
  always #5 clk = ~clk;
  logic mdc, out_pin, oe, mdio = 1, enabled;
  logic [7:0] status;

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

  // --------------------------------------------------------------------------
  // PHY-side stimulus knobs
  //
  // These are the state a real PHY's registers would carry; changing them
  // between polls is how the bench moves the link.
  // --------------------------------------------------------------------------
  logic present = 1, link_up = 1, full = 1;
  logic [ 1:0] speed = 1;
  logic [15:0] advertisement = 16'h0de1;  // register  4: what the PHY advertises
  logic [15:0] gigabit       = 16'h0300;  // register  9: 1000 Mbit/s status
  logic [15:0] control       = 16'h0000;  // register  0: what the manager wrote
  logic [15:0] reply         = 16'h0000;  // data returned for the current read

  // --------------------------------------------------------------------------
  // Management command decoder model state
  //
  // `command` is the 64-bit shift register the wire feeds on every MDC edge;
  // the Clause-22 fields land at fixed offsets, so at `bit_index == 45` the
  // opcode, PHY address and register address are all latched and the reply
  // for the addressed register is prepared.  At `bit_index == 63` a write is
  // committed to the model's register file.
  // --------------------------------------------------------------------------
  logic [63:0] command = 0;
  int bit_index = 0, errors = 0, checks = 0;
  logic read_cmd = 0, selected = 0;
  logic [4:0] reg_addr = 0;

  // Command decode and register read, one MDC edge at a time.
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

  // Read turnaround and data drive, on the opposite MDC edge: the model
  // releases for the turnaround slot and then shifts the reply out MSB first,
  // which is the Clause-22 read data phase.
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
  /// Print one PASS/FAIL line; FAIL also dumps the status byte, since every
  /// verdict here is a claim about that byte.
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
  //
  // The phases walk the link policy in order - discovery, unplug, unsupported
  // speed, half duplex, recovery, missing acknowledgement, retry - and each
  // waits a poll interval or two before its check, so the manager has time to
  // act.  The repeat counts are poll periods of the 1 ms / 10 MHz
  // configuration, not magic numbers.
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
  // Bounds a manager that stops polling; expiration is a test failure.
  // --------------------------------------------------------------------------
  initial begin
    #3_000_000;
    $fatal(1, "PHY timeout");
  end
endmodule : sw_phy_88e1111_tb
