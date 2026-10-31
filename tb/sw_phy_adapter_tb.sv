// ============================================================================
//  File        : tb/sw_phy_adapter_tb.sv
//  Description : Self-checking symbol-order and framing tests for the synchronous
//                GMII/MII/RMII/RGMII adapter.
//
//                The testbench models the already-captured PHY symbols.  It does
//                not model raw PHY clocks or DDR I/O cells; those belong in the
//                technology-specific shell described by sw_phy_adapter.
// ============================================================================
`timescale 1ns/1ps

`include "sw_defs.sv"

module sw_phy_adapter_tb;
  logic clk_i;
  logic rst_ni;
  integer errors;
  integer checks;

  logic gmii_rx_en_i, gmii_rx_er_i;
  logic [7:0] gmii_rx_data_i;
  logic gmii_rx_en_o;
  logic [7:0] gmii_rx_data_o;
  logic gmii_tx_en_i;
  logic [7:0] gmii_tx_data_i;
  logic gmii_tx_en_o;
  logic [7:0] gmii_tx_data_o;
  logic gmii_tx_er_o;

  logic mii_rx_en_i, mii_rx_er_i;
  logic [3:0] mii_rx_data_i;
  logic mii_rx_en_o;
  logic [7:0] mii_rx_data_o;
  logic [3:0] mii_tx_data_o;
  logic mii_tx_en_o, mii_tx_er_o;

  logic rmii_rx_dv_i, rmii_rx_er_i;
  logic [1:0] rmii_rx_data_i;
  logic rmii_rx_en_o;
  logic [7:0] rmii_rx_data_o;
  logic [1:0] rmii_tx_data_o;
  logic rmii_tx_en_o;

  logic rgmii_rx_ce_i;
  logic [3:0] rgmii_rx_rise_i, rgmii_rx_fall_i;
  logic rgmii_rx_ctl_rise_i, rgmii_rx_ctl_fall_i;
  logic rgmii_rx_en_o;
  logic [7:0] rgmii_rx_data_o;
  logic [3:0] rgmii_tx_rise_o, rgmii_tx_fall_o;
  logic rgmii_tx_ctl_rise_o, rgmii_tx_ctl_fall_o, rgmii_tx_ce_o;

  sw_phy_adapter #(
      .PHY_IF(SW_PHY_GMII), .BYTE_PERIOD(1)
  ) u_gmii (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .gmii_rx_en_i(gmii_rx_en_i), .gmii_rx_er_i(gmii_rx_er_i),
      .gmii_rx_data_i(gmii_rx_data_i),
      .mii_rx_en_i(1'b0), .mii_rx_er_i(1'b0), .mii_rx_data_i(4'h0),
      .rmii_rx_dv_i(1'b0), .rmii_rx_er_i(1'b0), .rmii_rx_data_i(2'b0),
      .rgmii_rx_ce_i(1'b0), .rgmii_rx_rising_data_i(4'h0),
      .rgmii_rx_falling_data_i(4'h0), .rgmii_rx_rising_ctl_i(1'b0),
      .rgmii_rx_falling_ctl_i(1'b0),
      .gmii_rx_en_o(gmii_rx_en_o), .gmii_rx_data_o(gmii_rx_data_o),
      .gmii_tx_en_i(gmii_tx_en_i), .gmii_tx_data_i(gmii_tx_data_i),
      .gmii_tx_en_o(gmii_tx_en_o), .gmii_tx_data_o(gmii_tx_data_o),
      .gmii_tx_er_o(gmii_tx_er_o), .mii_tx_en_o(), .mii_tx_data_o(),
      .mii_tx_er_o(), .rmii_tx_en_o(), .rmii_tx_data_o(),
      .rgmii_tx_ce_o(), .rgmii_tx_rising_data_o(),
      .rgmii_tx_falling_data_o(), .rgmii_tx_rising_ctl_o(),
      .rgmii_tx_falling_ctl_o()
  );

  sw_phy_adapter #(
      .PHY_IF(SW_PHY_MII), .BYTE_PERIOD(2), .PHY_RX_PREAMBLE(1'b1)
  ) u_mii (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .gmii_rx_en_i(1'b0), .gmii_rx_er_i(1'b0), .gmii_rx_data_i(8'h0),
      .mii_rx_en_i(mii_rx_en_i), .mii_rx_er_i(mii_rx_er_i),
      .mii_rx_data_i(mii_rx_data_i),
      .rmii_rx_dv_i(1'b0), .rmii_rx_er_i(1'b0), .rmii_rx_data_i(2'b0),
      .rgmii_rx_ce_i(1'b0), .rgmii_rx_rising_data_i(4'h0),
      .rgmii_rx_falling_data_i(4'h0), .rgmii_rx_rising_ctl_i(1'b0),
      .rgmii_rx_falling_ctl_i(1'b0),
      .gmii_rx_en_o(mii_rx_en_o), .gmii_rx_data_o(mii_rx_data_o),
      .gmii_tx_en_i(gmii_tx_en_i), .gmii_tx_data_i(gmii_tx_data_i),
      .gmii_tx_en_o(), .gmii_tx_data_o(), .gmii_tx_er_o(),
      .mii_tx_en_o(mii_tx_en_o), .mii_tx_data_o(mii_tx_data_o),
      .mii_tx_er_o(mii_tx_er_o), .rmii_tx_en_o(), .rmii_tx_data_o(),
      .rgmii_tx_ce_o(), .rgmii_tx_rising_data_o(),
      .rgmii_tx_falling_data_o(), .rgmii_tx_rising_ctl_o(),
      .rgmii_tx_falling_ctl_o()
  );

  sw_phy_adapter #(
      .PHY_IF(SW_PHY_RMII), .BYTE_PERIOD(10)
  ) u_rmii (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .gmii_rx_en_i(1'b0), .gmii_rx_er_i(1'b0), .gmii_rx_data_i(8'h0),
      .mii_rx_en_i(1'b0), .mii_rx_er_i(1'b0), .mii_rx_data_i(4'h0),
      .rmii_rx_dv_i(rmii_rx_dv_i), .rmii_rx_er_i(rmii_rx_er_i),
      .rmii_rx_data_i(rmii_rx_data_i),
      .rgmii_rx_ce_i(1'b0), .rgmii_rx_rising_data_i(4'h0),
      .rgmii_rx_falling_data_i(4'h0), .rgmii_rx_rising_ctl_i(1'b0),
      .rgmii_rx_falling_ctl_i(1'b0),
      .gmii_rx_en_o(rmii_rx_en_o), .gmii_rx_data_o(rmii_rx_data_o),
      .gmii_tx_en_i(gmii_tx_en_i), .gmii_tx_data_i(gmii_tx_data_i),
      .gmii_tx_en_o(), .gmii_tx_data_o(), .gmii_tx_er_o(),
      .mii_tx_en_o(), .mii_tx_data_o(), .mii_tx_er_o(),
      .rmii_tx_en_o(rmii_tx_en_o), .rmii_tx_data_o(rmii_tx_data_o),
      .rgmii_tx_ce_o(), .rgmii_tx_rising_data_o(),
      .rgmii_tx_falling_data_o(), .rgmii_tx_rising_ctl_o(),
      .rgmii_tx_falling_ctl_o()
  );

  sw_phy_adapter #(
      .PHY_IF(SW_PHY_RGMII), .BYTE_PERIOD(1)
  ) u_rgmii (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .gmii_rx_en_i(1'b0), .gmii_rx_er_i(1'b0), .gmii_rx_data_i(8'h0),
      .mii_rx_en_i(1'b0), .mii_rx_er_i(1'b0), .mii_rx_data_i(4'h0),
      .rmii_rx_dv_i(1'b0), .rmii_rx_er_i(1'b0), .rmii_rx_data_i(2'b0),
      .rgmii_rx_ce_i(rgmii_rx_ce_i),
      .rgmii_rx_rising_data_i(rgmii_rx_rise_i),
      .rgmii_rx_falling_data_i(rgmii_rx_fall_i),
      .rgmii_rx_rising_ctl_i(rgmii_rx_ctl_rise_i),
      .rgmii_rx_falling_ctl_i(rgmii_rx_ctl_fall_i),
      .gmii_rx_en_o(rgmii_rx_en_o), .gmii_rx_data_o(rgmii_rx_data_o),
      .gmii_tx_en_i(gmii_tx_en_i), .gmii_tx_data_i(gmii_tx_data_i),
      .gmii_tx_en_o(), .gmii_tx_data_o(), .gmii_tx_er_o(),
      .mii_tx_en_o(), .mii_tx_data_o(), .mii_tx_er_o(),
      .rmii_tx_en_o(), .rmii_tx_data_o(),
      .rgmii_tx_ce_o(rgmii_tx_ce_o),
      .rgmii_tx_rising_data_o(rgmii_tx_rise_o),
      .rgmii_tx_falling_data_o(rgmii_tx_fall_o),
      .rgmii_tx_rising_ctl_o(rgmii_tx_ctl_rise_o),
      .rgmii_tx_falling_ctl_o(rgmii_tx_ctl_fall_o)
  );

  // A reserved encoding (an interface the enum has not assigned yet) must hold
  // every output idle even when its pins are driven, so a not-yet-modelled
  // port can never inject traffic into the switch core.
  logic reserved_rx_en_o_unused;
  logic [7:0] reserved_rx_data_o_unused;

  sw_phy_adapter #(
      .PHY_IF(3'd4), .BYTE_PERIOD(1)
  ) u_reserved (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .gmii_rx_en_i(gmii_rx_en_i), .gmii_rx_er_i(gmii_rx_er_i),
      .gmii_rx_data_i(gmii_rx_data_i),
      .mii_rx_en_i(mii_rx_en_i), .mii_rx_er_i(mii_rx_er_i),
      .mii_rx_data_i(mii_rx_data_i),
      .rmii_rx_dv_i(rmii_rx_dv_i), .rmii_rx_er_i(rmii_rx_er_i),
      .rmii_rx_data_i(rmii_rx_data_i),
      .rgmii_rx_ce_i(rgmii_rx_ce_i),
      .rgmii_rx_rising_data_i(rgmii_rx_rise_i),
      .rgmii_rx_falling_data_i(rgmii_rx_fall_i),
      .rgmii_rx_rising_ctl_i(rgmii_rx_ctl_rise_i),
      .rgmii_rx_falling_ctl_i(rgmii_rx_ctl_fall_i),
      .gmii_rx_en_o(reserved_rx_en_o_unused),
      .gmii_rx_data_o(reserved_rx_data_o_unused),
      .gmii_tx_en_i(gmii_tx_en_i), .gmii_tx_data_i(gmii_tx_data_i),
      .gmii_tx_en_o(), .gmii_tx_data_o(), .gmii_tx_er_o(),
      .mii_tx_en_o(), .mii_tx_data_o(), .mii_tx_er_o(),
      .rmii_tx_en_o(), .rmii_tx_data_o(),
      .rgmii_tx_ce_o(), .rgmii_tx_rising_data_o(),
      .rgmii_tx_falling_data_o(), .rgmii_tx_rising_ctl_o(),
      .rgmii_tx_falling_ctl_o()
  );

  always #5 clk_i = ~clk_i;

  task automatic check(input logic condition, input string message);
    begin
      checks = checks + 1;
      if (condition) $display("PASS: %s", message);
      else begin
        errors = errors + 1;
        $display("FAIL: %s", message);
      end
    end
  endtask

  task automatic idle_inputs;
    begin
      gmii_rx_en_i = 1'b0; gmii_rx_er_i = 1'b0; gmii_rx_data_i = 8'h00;
      mii_rx_en_i = 1'b0; mii_rx_er_i = 1'b0; mii_rx_data_i = 4'h0;
      rmii_rx_dv_i = 1'b0; rmii_rx_er_i = 1'b0; rmii_rx_data_i = 2'b0;
      rgmii_rx_ce_i = 1'b0; rgmii_rx_rise_i = 4'h0; rgmii_rx_fall_i = 4'h0;
      rgmii_rx_ctl_rise_i = 1'b0; rgmii_rx_ctl_fall_i = 1'b0;
      gmii_tx_en_i = 1'b0; gmii_tx_data_i = 8'h00;
    end
  endtask

  task automatic reset_dut;
    begin
      idle_inputs();
      rst_ni = 1'b0;
      repeat (2) @(posedge clk_i);
      @(negedge clk_i);
      rst_ni = 1'b1;
    end
  endtask

  task automatic send_gmii_byte(input logic [7:0] d, input logic er);
    begin
      @(negedge clk_i); gmii_rx_en_i = 1'b1; gmii_rx_er_i = er; gmii_rx_data_i = d;
      @(posedge clk_i); #1;
    end
  endtask

  task automatic send_mii_byte(input logic [7:0] d, input logic er);
    begin
      @(negedge clk_i); mii_rx_en_i = 1'b1; mii_rx_er_i = er; mii_rx_data_i = d[3:0];
      @(posedge clk_i);
      @(negedge clk_i); mii_rx_er_i = er; mii_rx_data_i = d[7:4];
      @(posedge clk_i); #1;
    end
  endtask

  task automatic send_rmii_byte(input logic [7:0] d, input logic er);
    begin
      // At BYTE_PERIOD=10 the four symbol windows are 3, 2, 3, 2
      // clocks.  The symbol is changed only at each calculated boundary.
      @(negedge clk_i); rmii_rx_dv_i = 1'b1; rmii_rx_er_i = er; rmii_rx_data_i = d[1:0];
      repeat (3) @(posedge clk_i);
      @(negedge clk_i); rmii_rx_data_i = d[3:2];
      repeat (2) @(posedge clk_i);
      @(negedge clk_i); rmii_rx_data_i = d[5:4];
      repeat (3) @(posedge clk_i);
      @(negedge clk_i); rmii_rx_data_i = d[7:6];
      repeat (2) @(posedge clk_i); #1;
    end
  endtask

  task automatic send_rgmii_byte(input logic [7:0] d, input logic er);
    begin
      @(negedge clk_i);
      rgmii_rx_ce_i = 1'b1;
      rgmii_rx_ctl_rise_i = 1'b1;
      rgmii_rx_ctl_fall_i = !er;
      rgmii_rx_rise_i = d[3:0];
      rgmii_rx_fall_i = d[7:4];
      @(posedge clk_i); #1;
      rgmii_rx_ce_i = 1'b0;
      rgmii_rx_ctl_rise_i = 1'b0;
      rgmii_rx_ctl_fall_i = 1'b0;
    end
  endtask

  task automatic finish_gmii_rx;
    begin
      @(negedge clk_i); gmii_rx_en_i = 1'b0; gmii_rx_er_i = 1'b0;
      @(posedge clk_i); #1;
      check(!gmii_rx_en_o, "GMII RX drops enable after idle");
    end
  endtask

  task automatic finish_mii_rx;
    begin
      @(negedge clk_i); mii_rx_en_i = 1'b0; mii_rx_er_i = 1'b0;
      repeat (2) @(posedge clk_i);
      #1; check(!mii_rx_en_o, "MII RX drops enable after a byte boundary");
    end
  endtask

  task automatic finish_rmii_rx;
    begin
      @(negedge clk_i); rmii_rx_dv_i = 1'b0; rmii_rx_er_i = 1'b0;
      repeat (10) @(posedge clk_i);
      #1; check(!rmii_rx_en_o, "RMII RX drops enable after a byte boundary");
    end
  endtask

  initial begin
    clk_i = 1'b0;
    errors = 0;
    checks = 0;
    rst_ni = 1'b0;
    idle_inputs();

    // GMII pass-through and frame error suppression.
    reset_dut();
    send_gmii_byte(8'h12, 1'b0);
    check(gmii_rx_en_o && gmii_rx_data_o == 8'h12, "GMII RX passes an octet");
    send_gmii_byte(8'h34, 1'b1);
    check(!gmii_rx_en_o, "GMII RX suppresses an errored octet");
    finish_gmii_rx();

    // MII low nibble first, with the physical preamble and SFD removed.
    reset_dut();
    repeat (2) @(posedge clk_i);
    send_mii_byte(8'h55, 1'b0);
    send_mii_byte(8'h55, 1'b0);
    send_mii_byte(8'h55, 1'b0);
    send_mii_byte(8'h55, 1'b0);
    send_mii_byte(8'h55, 1'b0);
    send_mii_byte(8'h55, 1'b0);
    send_mii_byte(8'h55, 1'b0);
    send_mii_byte(8'hD5, 1'b0);
    check(!mii_rx_en_o, "MII RX suppresses preamble and SFD");
    send_mii_byte(8'hA6, 1'b0);
    check(mii_rx_en_o && mii_rx_data_o == 8'hA6, "MII RX reassembles low nibble first");
    finish_mii_rx();

    // RMII two-bit chunks are ordered bits [1:0], [3:2], [5:4], [7:6].
    // BYTE_PERIOD=10 exercises the rounded 3/2/3/2 symbol windows.
    reset_dut();
    @(negedge clk_i);
    while (u_rmii.phase != 0) @(negedge clk_i);
    rmii_rx_dv_i = 1'b1; rmii_rx_er_i = 1'b0; rmii_rx_data_i = 2'b01;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i); rmii_rx_data_i = 2'b00;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i); rmii_rx_data_i = 2'b11;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i); rmii_rx_data_i = 2'b10;
    repeat (2) @(posedge clk_i); #1;
    check(rmii_rx_en_o && rmii_rx_data_o == 8'hB1, "RMII RX reassembles four chunks");
    finish_rmii_rx();

    // RGMII combines the rising-edge low nibble and falling-edge high nibble.
    reset_dut();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i); rgmii_rx_ce_i = 1'b1; rgmii_rx_ctl_rise_i = 1'b1;
    rgmii_rx_ctl_fall_i = 1'b1; rgmii_rx_rise_i = 4'hC; rgmii_rx_fall_i = 4'h5;
    @(posedge clk_i); #1;
    check(rgmii_rx_en_o && rgmii_rx_data_o == 8'h5C, "RGMII RX combines rise/fall nibbles");
    @(negedge clk_i); rgmii_rx_ctl_rise_i = 1'b0; rgmii_rx_ctl_fall_i = 1'b0;
    @(posedge clk_i); #1;
    check(!rgmii_rx_en_o, "RGMII RX ends on an inactive capture event");

    // RGMII control XOR is an RX error and suppresses the complete symbol.
    reset_dut();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i); rgmii_rx_ce_i = 1'b1; rgmii_rx_ctl_rise_i = 1'b1;
    rgmii_rx_ctl_fall_i = 1'b0; rgmii_rx_rise_i = 4'hC; rgmii_rx_fall_i = 4'h5;
    @(posedge clk_i); #1;
    check(!rgmii_rx_en_o, "RGMII RX control XOR suppresses an errored byte");

    // Exact preamble/SFD removal on a separate MII instance is covered by a
    // temporary direct check through the mode-independent preamble contract in
    // the adapter instance below.
    // TX serialization checks use the same selected mode adapters.
    reset_dut();
    @(negedge clk_i);
    while (u_rmii.phase != 0) @(negedge clk_i);
    gmii_tx_en_i = 1'b1; gmii_tx_data_i = 8'hC3;
    #1;
    check(gmii_tx_en_o && gmii_tx_data_o == 8'hC3, "GMII TX passes enable and data");
    check(mii_tx_en_o && mii_tx_data_o == 4'h3, "MII TX launches low nibble first");
    check(rmii_tx_en_o && rmii_tx_data_o == 2'b11, "RMII TX launches lowest chunk first");
    check(rgmii_tx_ce_o && rgmii_tx_rise_o == 4'h3 && rgmii_tx_fall_o == 4'hC,
          "RGMII TX presents rise/fall nibbles with capture enable");
    @(posedge clk_i); #1;
    check(mii_tx_data_o == 4'hC, "MII TX launches high nibble second");
    repeat (2) @(posedge clk_i); #1;
    check(rmii_tx_data_o == 2'b00, "RMII TX advances to the second two-bit chunk");
    repeat (2) @(posedge clk_i); #1;
    check(rmii_tx_data_o == 2'b00, "RMII TX launches the third two-bit chunk");
    repeat (3) @(posedge clk_i); #1;
    check(rmii_tx_data_o == 2'b11, "RMII TX launches the fourth two-bit chunk");
    gmii_tx_en_i = 1'b0;
    @(posedge clk_i); #1;
    check(!gmii_tx_en_o && !mii_tx_en_o && !rmii_tx_en_o && !rgmii_tx_ctl_rise_o,
          "PHY TX outputs idle when GMII enable is low");

    // A reserved encoding stays idle even while its pins are driven with an
    // active GMII byte - the default arm of the mode case is what guarantees
    // a future interface is safe to elaborate before it is modelled.
    reset_dut();
    send_gmii_byte(8'h12, 1'b0);
    check(!reserved_rx_en_o_unused,
          "reserved PHY_IF encoding stays idle under driven pins");
    finish_gmii_rx();

    if (errors == 0) begin
      $display("PASS: sw_phy_adapter_tb (%0d checks)", checks);
    end else begin
      $display("FAIL: sw_phy_adapter_tb (%0d errors, %0d checks)", errors, checks);
      $fatal(1, "sw_phy_adapter_tb failed");
    end
    $finish;
  end
endmodule
