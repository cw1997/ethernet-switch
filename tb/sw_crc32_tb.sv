// ============================================================================
//  File        : tb/sw_crc32_tb.sv
//  Description : Unit testbench of the Ethernet CRC-32 engine (`sw_crc32`).
//
//                The block is verified in both of its roles:
//
//                  * transmitter - the value it produces for a known message
//                    must match the standard CRC-32 check value,
//                  * receiver - running the LFSR over a message *including* the
//                    correct FCS must leave the magic residue 0xC704DD1B, while
//                    a single flipped bit anywhere must not,
//                  * idle - the LFSR must hold its value while the clock enable
//                    is low.
//
//                The reference values come from the independent bit-serial model
//                in `sw_tb_pkg`; the "123456789" check value is the textbook
//                CRC-32/ISO-HDLC result, which pins polynomial, seed, reflection
//                and final complement in one shot.
// ============================================================================
`timescale 1ns/1ps

module sw_crc32_tb;

  // The verification helpers live in sw_tb_pkg.  The RTL declarations are at
  // compilation-unit scope (`rtl/sw_defs.sv`) and so need no import.
  import sw_tb_pkg::*;

  logic        clk   = 1'b0;
  logic        rst_n = 1'b0;
  logic        en;
  logic [7:0]  din;
  logic        clr;
  logic [31:0] crc_fin;
  logic        resid_ok;

  int unsigned errors;
  int unsigned checks;

  always #5 clk = ~clk;   // 100 MHz - the block is clock enabled, not clock bound

  sw_crc32 u_dut (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .en_i      (en),
      .din_i     (din),
      .clr_i     (clr),
      .crc_fin_o (crc_fin),
      .resid_ok_o(resid_ok)
  );

  // --------------------------------------------------------------------------
  // Message buffers, standard testbench width so that the helpers in
  // `sw_tb_pkg` can be used unchanged.  Octet 0 is the first one on the wire.
  // --------------------------------------------------------------------------
  tb_frame_buf_t msg9;         // "123456789"
  tb_frame_buf_t msg64;        // 64 octet counting pattern
  tb_frame_buf_t msg68;        // the same 64 octets with the correct FCS appended
  logic [31:0]    fcs;

  // --------------------------------------------------------------------------
  // Local helpers
  //
  // These build the two buffers the test needs.  They are defined here rather
  // than in `sw_tb_pkg` because they are specific to this block: the package
  // deliberately carries no CRC-append helper, since a frame builder there
  // would be an incomplete duplicate of `tb_build_frame`.
  // --------------------------------------------------------------------------
  /// The FCS of the first `n` octets of `msg`, transmitted least significant
  /// octet first, appended at image offset `off`.
  function automatic tb_frame_buf_t append_fcs(
      input tb_frame_buf_t msg, input int unsigned n, input int unsigned off);
    tb_frame_buf_t b;
    logic [31:0]    c;
    c = tb_crc32(msg, n, 0);
    b = tb_put_octet(msg, off + 0, c[ 7: 0]);
    b = tb_put_octet(b,   off + 1, c[15: 8]);
    b = tb_put_octet(b,   off + 2, c[23:16]);
    b = tb_put_octet(b,   off + 3, c[31:24]);
    return b;
  endfunction

  /// Flip one bit of the FCS octet at image offset `off`, i.e. corrupt the frame
  /// check sequence the way a transmission error would.
  function automatic tb_frame_buf_t corrupt_fcs_at(
      input tb_frame_buf_t msg, input int unsigned off);
    return tb_put_octet(msg, off, tb_get_octet(msg, off) ^ 8'h01);
  endfunction

  // --------------------------------------------------------------------------
  // Stimulus / check helpers
  // --------------------------------------------------------------------------
  // --------------------------------------------------------------------------
  // Stimulus / check helpers
  //
  // All inputs are driven on the falling edge and sampled by the DUT on the
  // following rising edge.  Driving them at the same timestamp as `@(posedge clk)`
  // would race the DUT's `always_ff`, and the resulting one-clock skew shows up
  // as a silently wrong result rather than as a timing error, so the negative
  // edge is used as the (unambiguous) drive point throughout this testbench.
  // --------------------------------------------------------------------------

  /// Absorb `n` octets of `msg` and return the resulting FCS in `result`.
  /// A task, not a function: the engine is clocked, so the result is only valid
  /// one clock after the last octet was presented.
  task automatic run_tx(input tb_frame_buf_t msg, input int unsigned n,
                        output logic [31:0] result);
    int unsigned k;
    begin
      // Re-seed the LFSR for exactly one clock.
      @(negedge clk);
      clr = 1'b1;
      @(negedge clk);
      clr = 1'b0;
      en  = 1'b0;
      // One octet per clock; the loop's trailing edge waits out the rising edge
      // that absorbs the octet written at its head.
      for (k = 0; k < n; k++) begin
        din = tb_get_octet(msg, k);
        en  = 1'b1;
        @(negedge clk);
      end
      en  = 1'b0;
      din = 8'h00;
      @(posedge clk);
      result = crc_fin;
    end
  endtask

  /// Absorb `n` octets (FCS included) and report the residue verdict.
  task automatic run_rx(input tb_frame_buf_t msg, input int unsigned n,
                        output logic result);
    int unsigned k;
    begin
      @(negedge clk);
      clr = 1'b1;
      @(negedge clk);
      clr = 1'b0;
      en  = 1'b0;
      for (k = 0; k < n; k++) begin
        din = tb_get_octet(msg, k);
        en  = 1'b1;
        @(negedge clk);
      end
      en     = 1'b0;
      din    = 8'h00;
      @(posedge clk);
      result = resid_ok;
    end
  endtask

  task automatic expect_eq32(input logic [31:0] got, input logic [31:0] exp,
                             input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %08x, expected %08x", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %08x", $time, what, got);
    end
  endtask

  task automatic expect_eq1(input logic got, input logic exp, input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %b, expected %b", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %b", $time, what, got);
    end
  endtask

  // --------------------------------------------------------------------------
  // Test sequence
  // --------------------------------------------------------------------------
  initial begin
    en     = 1'b0;
    din    = 8'h00;
    clr    = 1'b0;
    errors = 0;
    checks = 0;

    // ASCII "123456789", octet 0 = '1'.  Verilator cannot index a string
    // literal, so the characters are written out explicitly.
    msg9 = '0;
    msg9 = tb_put_octet(msg9, 0, 8'h31);   // '1'
    msg9 = tb_put_octet(msg9, 1, 8'h32);   // '2'
    msg9 = tb_put_octet(msg9, 2, 8'h33);   // '3'
    msg9 = tb_put_octet(msg9, 3, 8'h34);   // '4'
    msg9 = tb_put_octet(msg9, 4, 8'h35);   // '5'
    msg9 = tb_put_octet(msg9, 5, 8'h36);   // '6'
    msg9 = tb_put_octet(msg9, 6, 8'h37);   // '7'
    msg9 = tb_put_octet(msg9, 7, 8'h38);   // '8'
    msg9 = tb_put_octet(msg9, 8, 8'h39);   // '9'

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    $display("=====================================================================");
    $display(" sw_crc32_tb: byte-serial Ethernet CRC-32 (IEEE 802.3)");
    $display("=====================================================================");

    // ---- transmitter known answer ----------------------------------------
    // CRC-32/ISO-HDLC of "123456789" is 0xCBF43926.
    run_tx(msg9, 9, fcs);
    expect_eq32(fcs, 32'hCBF4_3926, "FCS of \"123456789\"");

    // A longer structured message has to match the software model.
    msg64 = '0;
    for (int unsigned k = 0; k < 64; k++) msg64 = tb_put_octet(msg64, k, 8'((k * 31) + 7));
    run_tx(msg64, 64, fcs);
    expect_eq32(fcs, tb_crc32(msg64, 64), "FCS of a 64 octet pattern");

    // An empty message must reproduce the seed complement.
    run_tx(msg64, 0, fcs);
    expect_eq32(fcs, 32'h0000_0000, "FCS of an empty message");

    // ---- receiver residue check --------------------------------------------
    // The FCS is appended to the message itself, so the buffer holds 68 octets
    // of client data and the engine absorbs all of them.
    msg68 = append_fcs(msg64, 64, 64);
    begin
      logic r;
      run_rx(msg68, 68, r);
      expect_eq1(r, 1'b1, "residue after a valid frame");
    end

    // One flipped payload bit must be detected.
    begin
      logic r;
      tb_frame_buf_t bad;
      bad = tb_put_octet(msg68, 10, tb_get_octet(msg68, 10) ^ 8'h01);
      run_rx(bad, 68, r);
      expect_eq1(r, 1'b0, "residue after a corrupted payload");
    end

    // One flipped FCS bit must be detected as well.
    begin
      logic r;
      tb_frame_buf_t bad;
      bad = corrupt_fcs_at(msg68, 64);
      run_rx(bad, 68, r);
      expect_eq1(r, 1'b0, "residue after a corrupted FCS");
    end

    // ---- idle behaviour ----------------------------------------------------
    // The LFSR must hold its value while the clock enable is low.
    begin
      logic [31:0] hold;
      logic [31:0] after;
      run_tx(msg64, 8, hold);
      @(negedge clk);
      din = 8'h00;
      en  = 1'b0;
      repeat (8) @(posedge clk);
      after = crc_fin;
      expect_eq32(after, hold, "LFSR holds while en is low");
    end

    $display("-----------------------------------------------------------------------");
    if (errors == 0) begin
      $display(" sw_crc32_tb: PASSED (%0d checks)", checks);
      $finish;
    end else begin
      $fatal(1, " sw_crc32_tb: FAILED (%0d of %0d checks failed)", errors, checks);
    end
  end

  // Watchdog: the testbench must finish in a few microseconds.
  initial begin
    #1_000_000;
    $fatal(1, "sw_crc32_tb: timeout");
  end

endmodule : sw_crc32_tb
