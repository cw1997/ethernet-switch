// ============================================================================
//  File        : tb/sw_rmii_tb.sv
//  Description : Unit testbench of the RMII symbol adapter (`sw_rmii`).
//
//                Verified here, against the contract stated in the module
//                header:
//
//                  1. RX assembly - the four 2-bit chunks of an octet are
//                     reassembled in ascending bit order and presented as one
//                     octet per full BYTE_PERIOD window, one octet behind the
//                     wire,
//                  2. RX self-synchronisation - a frame that does *not* start
//                     on any grid boundary is still assembled correctly (the
//                     adapter counts every frame's windows from its own
//                     CRS_DV rise),
//                  3. frame end - the enable stays high for exactly one more
//                     octet time after the last octet and then drops,
//                  4. truncation - a CRS_DV that drops mid-octet never yields
//                     a partial octet: the enable simply stays low,
//                  5. TX serialisation - the canonical octet stream is split
//                     into four 2-bit chunks per octet time, on the reset
//                     grid the adapter shares with sw_gmii_tx,
//                  6. the BYTE_PERIOD = 4 edge case (one clock per chunk).
//
//                RMII has no RX_ER, so there is no error-suppression test
//                here; corrupt octets are rejected by the fabric's FCS check.
//
//                Self-checking: every expectation prints PASS/FAIL, the run
//                ends with an explicit verdict, and a watchdog aborts a hung
//                simulation.
// ============================================================================
`timescale 1ns/1ps

module sw_rmii_tb;

  // ---------------------------------------------------------------------------
  // Clock and reset.  50 MHz - the natural RMII core clock (REF_CLK = clk_i).
  // Reset is released on a negedge so that the first posedge with rst_n high -
  // grid cycle 0 for the DUTs' free-running transmit counters - is unambiguous.
  // ---------------------------------------------------------------------------
  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #10 clk = ~clk;

  /// Grid cycle number of the cycle currently in progress (0 = the first cycle
  /// after reset release).  Read only just after a posedge, where it still
  /// holds the number of the cycle that has just *ended* - the cycle starting
  /// at that edge is cyc+1.
  int unsigned cyc;

  always @(posedge clk) begin
    if (rst_n) cyc <= cyc + 1;
  end

  // ---------------------------------------------------------------------------
  // DUT 1: the main instance, BYTE_PERIOD = 8 (chunk window 2 clocks).
  // ---------------------------------------------------------------------------
  localparam int unsigned BP  = 8;
  localparam int unsigned CPK = BP / 4;

  logic       rx_dv;
  logic [1:0] rxd;
  logic       tx_en;
  logic [1:0] txd;
  logic       oct_en_o;
  logic [7:0] oct_d_o;
  logic       oct_en_i;
  logic [7:0] oct_d_i;

  sw_rmii #(
      .BYTE_PERIOD (BP)
  ) u_rmii (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .rmii_crs_dv_i (rx_dv),
      .rmii_rxd_i    (rxd),
      .rmii_tx_en_o  (tx_en),
      .rmii_txd_o    (txd),
      .oct_en_o      (oct_en_o),
      .oct_d_o       (oct_d_o),
      .oct_en_i      (oct_en_i),
      .oct_d_i       (oct_d_i)
  );

  // ---------------------------------------------------------------------------
  // DUT 2: the edge configuration, BYTE_PERIOD = 4 (one clock per chunk).
  // ---------------------------------------------------------------------------
  localparam int unsigned BP2  = 4;
  localparam int unsigned CPK2 = BP2 / 4;

  logic       f_rx_dv;
  logic [1:0] f_rxd;
  logic       f_tx_en;
  logic [1:0] f_txd;
  logic       f_oct_en_o;
  logic [7:0] f_oct_d_o;
  logic       f_oct_en_i;
  logic [7:0] f_oct_d_i;

  sw_rmii #(
      .BYTE_PERIOD (BP2)
  ) u_fast (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .rmii_crs_dv_i (f_rx_dv),
      .rmii_rxd_i    (f_rxd),
      .rmii_tx_en_o  (f_tx_en),
      .rmii_txd_o    (f_txd),
      .oct_en_o      (f_oct_en_o),
      .oct_d_o       (f_oct_d_o),
      .oct_en_i      (f_oct_en_i),
      .oct_d_i       (f_oct_d_i)
  );

  // ---------------------------------------------------------------------------
  // Checking helpers (the sw_sync_fifo_tb convention).
  // ---------------------------------------------------------------------------
  int unsigned errors;
  int unsigned checks;

  task automatic expect_eq(input int unsigned got, input int unsigned exp,
                           input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %0d, expected %0d", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %0d", $time, what, got);
    end
  endtask

  task automatic expect_data(input logic [7:0] got,
                             input logic [7:0] exp, input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %02x, expected %02x", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %02x", $time, what, got);
    end
  endtask

  task automatic expect_1bit(input logic got, input logic exp,
                             input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[%0t] ERROR %s: got %b, expected %b", $time, what, got, exp);
    end else begin
      $display("[%0t] PASS  %s = %b", $time, what, got);
    end
  endtask

  /// Octet k (0..7) of a packed MSB-first octet vector.
  function automatic logic [7:0] get_oct(input logic [63:0] v,
                                         input int unsigned k);
    get_oct = v[63 - k*8 -: 8];
  endfunction

  /// Chunk c (0..3) of octet k: Ethernet is LSB-first on the wire, so chunk 0
  /// carries bits [1:0] and chunk 3 bits [7:6].  Icarus Verilog cannot take a
  /// part-select of a function call result, so the octet is staged first.
  function automatic logic [1:0] get_chk(input logic [63:0] v,
                                         input int unsigned k,
                                         input int unsigned c);
    logic [7:0] o;
    o = get_oct(v, k);
    case (c)
      0:       get_chk = o[1:0];
      1:       get_chk = o[3:2];
      2:       get_chk = o[5:4];
      default: get_chk = o[7:6];
    endcase
  endfunction

  /// Advance exactly one cycle and land on a negedge: the mid-cycle sample
  /// point, after every non-blocking update of the clock edge has settled.
  task automatic step1();
    @(posedge clk);
    @(negedge clk);
  endtask

  /// Wait for the next octet-window boundary of the reset grid.  Returns in
  /// the timestep of the posedge that opens a cycle whose number is a multiple
  /// of `bp`; the caller drives its octet enable in that same timestep (the
  /// non-blocking update lands on the pins for exactly that aligned window),
  /// which is what sw_gmii_tx guarantees for its own stream.
  task automatic align_to_grid(input int unsigned bp);
    int unsigned guard;
    guard = 0;
    @(posedge clk);
    while ((((cyc + 1) % bp) != 0) && (guard < 1_000_000)) begin
      @(posedge clk);
      guard = guard + 1;
    end
    checks++;
    if (((cyc + 1) % bp) != 0) begin
      errors++;
      $display("[%0t] ERROR align_to_grid: no window boundary found", $time);
    end
  endtask

  // ---------------------------------------------------------------------------
  // RX drive: present a frame as chunk windows counted from the CRS_DV rise.
  //
  // `start_off` delays the frame start by that many clocks - a non-multiple of
  // BYTE_PERIOD proves that the adapter self-synchronises instead of requiring
  // grid alignment.  `chunks` limits how many chunks of the *last* octet are
  // presented (4 = a complete frame; fewer truncates it mid-octet).  The task
  // returns after the CRS_DV has dropped.
  // ---------------------------------------------------------------------------
  task automatic rmii_drive(input logic [63:0] octs,
                            input int unsigned n,
                            input int unsigned start_off,
                            input int unsigned chunks);
    int unsigned last;
    repeat (start_off) @(posedge clk);
    @(posedge clk);                       // edge E0: the first chunk window opens
    for (int unsigned k = 0; k < n; k++) begin
      last  = (k == n - 1) ? chunks : 4;
      for (int unsigned c = 0; c < 4; c++) begin
        if (c == 0) begin
          rx_dv <= 1'b1;
        end else if (c == last) begin
          rx_dv <= 1'b0;                  // truncate: CRS_DV drops mid-octet
          rxd   <= 2'h0;
        end
        if (c < last) begin
          rxd <= get_chk(octs, k, c);
        end
        repeat (CPK) @(posedge clk);
      end
    end
    rx_dv <= 1'b0;                        // idle from the cycle after the frame
    rxd   <= 2'h0;
  endtask

  // ---------------------------------------------------------------------------
  // RX check: wait for the enable to rise, then walk the presentation windows.
  // Each window must be BYTE_PERIOD long with a stable octet; after the last
  // one the enable must drop.
  // ---------------------------------------------------------------------------
  task automatic check_presentation(input logic [63:0] octs,
                                    input int unsigned n,
                                    input string       tag);
    int unsigned waited;
    waited = 0;
    while (oct_en_o !== 1'b1 && waited < 5000) begin
      @(negedge clk);
      waited++;
    end
    checks++;
    if (oct_en_o !== 1'b1) begin
      errors++;
      $display("[%0t] ERROR %s: the canonical enable never rose", $time, tag);
    end else begin
      $display("[%0t] PASS  %s: enable rose", $time, tag);
    end

    for (int unsigned k = 0; k < n; k++) begin
      // first clock of the window
      expect_1bit(oct_en_o, 1'b1, $sformatf("%s: window start en (octet %0d)", tag, k));
      expect_data(oct_d_o, get_oct(octs, k), $sformatf("%s: window start octet %0d", tag, k));
      // walk to the last clock of the window: the octet must be stable all the
      // way through, which is what sw_gmii_rx relies on.
      repeat (BP - 1) step1();
      expect_1bit(oct_en_o, 1'b1, $sformatf("%s: window end en (octet %0d)", tag, k));
      expect_data(oct_d_o, get_oct(octs, k), $sformatf("%s: window end octet %0d", tag, k));
      // step to the first clock of the next window
      step1();
    end
    expect_1bit(oct_en_o, 1'b0, {tag, ": enable dropped after the frame"});
  endtask

  /// The enable must stay low for `cycles` more clocks (suppression check).
  task automatic check_stays_idle(input int unsigned cycles, input string tag);
    for (int unsigned k = 0; k < cycles; k++) begin
      @(negedge clk);
      checks++;
      if (oct_en_o !== 1'b0) begin
        errors++;
        $display("[%0t] ERROR %s: enable high at clock %0d of the idle period", $time, tag, k);
      end
    end
    $display("[%0t] PASS  %s: enable stayed low for %0d clocks", $time, tag, cycles);
  endtask

  // ---------------------------------------------------------------------------
  // TX drive and check.  The canonical octet stream is presented aligned to
  // the reset grid (as sw_gmii_tx guarantees), one octet per BYTE_PERIOD
  // clocks; the chunks on the pins are checked in the first clock of each
  // chunk window.  `octets_skew` starts the frame that many octet times
  // later, which must not change anything: the adapter's transmit counter
  // free-runs from reset and every whole octet time is on the grid.
  // ---------------------------------------------------------------------------
  task automatic tx_frame_and_check(input logic [63:0] octs,
                                    input int unsigned n,
                                    input int unsigned octets_skew,
                                    input string       tag);
    repeat (octets_skew * BP) @(posedge clk);
    align_to_grid(BP);
    for (int unsigned k = 0; k < n; k++) begin
      oct_en_i <= 1'b1;                     // the octet window opens at this edge
      oct_d_i  <= get_oct(octs, k);
      for (int unsigned c = 0; c < 4; c++) begin
        @(negedge clk);
        expect_1bit(tx_en, 1'b1, $sformatf("%s: tx en (octet %0d chunk %0d)", tag, k, c));
        expect_data({6'h0, txd}, {6'h0, get_chk(octs, k, c)},
                    $sformatf("%s: tx chunk %0d (octet %0d)", tag, c, k));
        repeat (CPK) @(posedge clk);        // to the next chunk window edge
      end
    end
    oct_en_i <= 1'b0;                       // the enable drops at this boundary
    oct_d_i  <= 8'h00;
    @(negedge clk);
    expect_1bit(tx_en, 1'b0, {tag, ": tx en dropped after the frame"});
  endtask

  // ---------------------------------------------------------------------------
  // RX drive for the BYTE_PERIOD = 4 instance: one clock per chunk.
  // ---------------------------------------------------------------------------
  task automatic fast_drive(input logic [63:0] octs, input int unsigned n);
    for (int unsigned k = 0; k < n; k++) begin
      for (int unsigned c = 0; c < 4; c++) begin
        @(posedge clk);
        f_rx_dv <= 1'b1;
        f_rxd   <= get_chk(octs, k, c);
      end
    end
    @(posedge clk);
    f_rx_dv <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  initial begin
    errors     = 0;
    checks     = 0;
    cyc        = 0;
    rx_dv      = 1'b0;
    rxd        = 2'h0;
    oct_en_i   = 1'b0;
    oct_d_i    = 8'h00;
    f_rx_dv    = 1'b0;
    f_rxd      = 2'h0;
    f_oct_en_i = 1'b0;
    f_oct_d_i  = 8'h00;

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    $display("=====================================================================");
    $display(" sw_rmii_tb: RMII symbol adapter (BYTE_PERIOD = %0d and %0d)", BP, BP2);
    $display("=====================================================================");

    // ---- 1. grid-aligned frame through the main instance -----------------
    // start_off = 2*BP-1 puts the first CRS_DV-high cycle on a grid boundary,
    // which is what a synchronous outer shell would produce.
    fork
      rmii_drive(64'hA5_3C_00_FF_11_22_33_44, 4, 2*BP - 1, 4);
      check_presentation(64'hA5_3C_00_FF_11_22_33_44, 4, "aligned");
    join
    check_stays_idle(2*BP, "aligned: idle after the frame");

    // ---- 2. unaligned frame: self-synchronisation ------------------------
    // The frame starts 3 clocks into an octet time - no grid boundary.  The
    // adapter must still assemble it correctly.
    fork
      rmii_drive(64'h12_34_56_78_9A_BC_DE_F0, 4, 3, 4);
      check_presentation(64'h12_34_56_78_9A_BC_DE_F0, 4, "unaligned");
    join
    check_stays_idle(2*BP, "unaligned: idle after the frame");

    // ---- 3. truncated octet: nothing is presented ------------------------
    // The single octet only gets two of its four chunks before CRS_DV drops;
    // a partial octet must never reach the canonical stream.
    fork
      rmii_drive(64'hAA_BB_CC_DD_11_22_33_44, 1, 2*BP, 2);
      check_stays_idle(8*BP, "truncated octet");
    join

    // ---- 4. TX serialisation on the reset grid ---------------------------
    tx_frame_and_check(64'h55_D5_A5_3C_00_FF_0F_F0, 4, 2, "tx grid-aligned");
    // a second frame later on: the free-running counter must still line up
    tx_frame_and_check(64'hC1_02_03_04_05_06_07_08, 2, 4, "tx later frame");

    // ---- 5. BYTE_PERIOD = 4 edge case ------------------------------------
    fork
      fast_drive(64'h5A_C3_00_00_00_00_00_00, 2);
      begin
        int unsigned waited;
        waited = 0;
        while (f_oct_en_o !== 1'b1 && waited < 5000) begin
          @(negedge clk);
          waited++;
        end
        expect_1bit(f_oct_en_o, 1'b1, "fast: enable rose");
        expect_data(f_oct_d_o, 8'h5A, "fast: octet 0");
        repeat (BP2 - 1) step1();
        expect_1bit(f_oct_en_o, 1'b1, "fast: octet 0 window end en");
        expect_data(f_oct_d_o, 8'h5A, "fast: octet 0 window end value");
        step1();
        expect_1bit(f_oct_en_o, 1'b1, "fast: octet 1 window en");
        expect_data(f_oct_d_o, 8'hC3, "fast: octet 1");
        repeat (BP2 - 1) step1();
        expect_1bit(f_oct_en_o, 1'b1, "fast: octet 1 window end en");
        expect_data(f_oct_d_o, 8'hC3, "fast: octet 1 window end value");
        step1();
        expect_1bit(f_oct_en_o, 1'b0, "fast: enable dropped after the frame");
      end
    join

    // fast TX: two octets, one clock per chunk, aligned to its own grid
    align_to_grid(BP2);
    for (int unsigned k = 0; k < 2; k++) begin
      f_oct_en_i <= 1'b1;
      f_oct_d_i  <= get_oct(64'h9C_4E_00_00_00_00_00_00, k);
      for (int unsigned c = 0; c < 4; c++) begin
        @(negedge clk);
        expect_1bit(f_tx_en, 1'b1, $sformatf("fast tx: en (octet %0d chunk %0d)", k, c));
        expect_data({6'h0, f_txd}, {6'h0, get_chk(64'h9C_4E_00_00_00_00_00_00, k, c)},
                    $sformatf("fast tx: chunk %0d (octet %0d)", c, k));
        @(posedge clk);                     // the next chunk window opens here
      end
    end
    f_oct_en_i <= 1'b0;
    @(negedge clk);
    expect_1bit(f_tx_en, 1'b0, "fast tx: en dropped after the frame");

    // ---- verdict ----------------------------------------------------------
    $display("-----------------------------------------------------------------------");
    if (errors == 0) begin
      $display(" sw_rmii_tb: PASSED (%0d checks)", checks);
      $finish;
    end else begin
      $fatal(1, " sw_rmii_tb: FAILED (%0d of %0d checks failed)", errors, checks);
    end
  end

  initial begin
    #40_000_000;
    $fatal(1, "sw_rmii_tb: timeout");
  end

endmodule : sw_rmii_tb
