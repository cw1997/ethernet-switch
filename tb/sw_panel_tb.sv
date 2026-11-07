// ============================================================================
//  File        : sw_panel_tb.sv
//  Description : Front-panel decode regression.
//
//                The panel is the only block that decides what a board switch
//                position means and what a lamp shows, so it is also the only
//                block where a board file could disagree with the fabric.  This
//                bench pins both halves of that contract:
//
//                  * switch positions decode to a forwarding policy, with the
//                    unused flood encoding clamped instead of propagated, the
//                    override position gating the two policy positions, and a
//                    *level* on the flush position producing exactly one
//                    one-clock request per movement;
//                  * PHY status, table occupancy and receive errors map onto the
//                    documented lamp bits, an unknown PHY falls back to the
//                    administrative enable instead of showing a stale link, and
//                    the lamp-test position lights every lamp including the
//                    per-port ones.
//
//                The clock frequency parameter is deliberately small: the
//                heartbeat and activity counters are the only things that use
//                it, and a bench that had to wait 100 ms of simulated time to
//                watch an activity lamp go out would be a bench nobody runs.
// ============================================================================
`timescale 1ns/1ps
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "panel/es_panel_defs.sv"

module sw_panel_tb;
  localparam int unsigned NUM_PORTS     = 2;
  localparam int unsigned CLK_FREQ      = 1_000_000;
  localparam int unsigned CAM_CAPACITY  = 512;
  localparam int unsigned ACT_HOLD_MS   = 1;
  /// (CLK_FREQ / 1000) * ACT_HOLD_MS, i.e. the panel's own stretch length.
  localparam int unsigned ACT_HOLD      = (CLK_FREQ / 1000) * ACT_HOLD_MS;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  int checks = 0, errors = 0;

  logic [SW_PANEL_DIP_W-1:0] dip = '0;
  logic [NUM_PORTS-1:0]      link_up = '0;
  logic [NUM_PORTS*8-1:0]    phy_status = '0;
  logic [NUM_PORTS-1:0]      port_active = '0;
  logic [31:0]               rx_crc = 0, rx_runt = 0, rx_oversize = 0, rx_overflow = 0;
  logic [31:0]               cam_entries = 0;

  logic [1:0]  flood_mode;
  logic        learning_en, cfg_ovr, cam_flush;
  logic [NUM_PORTS-1:0]   led_link, led_act, led_duplex, led_fault;
  logic [NUM_PORTS*2-1:0] led_speed;
  logic [15:0]            led_stat;

  es_panel #(
    .NUM_PORTS    (NUM_PORTS),
    .CLK_FREQ_HZ  (CLK_FREQ),
    .CAM_CAPACITY (CAM_CAPACITY),
    .ACT_HOLD_MS  (ACT_HOLD_MS)
  ) dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .dip_i          (dip),
    .link_up_i      (link_up),
    .phy_status_i   (phy_status),
    .port_active_i  (port_active),
    .rx_crc_err_i   (rx_crc),
    .rx_runt_i      (rx_runt),
    .rx_oversize_i  (rx_oversize),
    .rx_overflow_i  (rx_overflow),
    .cam_entries_i  (cam_entries),
    .flood_mode_o   (flood_mode),
    .learning_en_o  (learning_en),
    .cfg_ovr_o      (cfg_ovr),
    .cam_flush_o    (cam_flush),
    .led_link_o     (led_link),
    .led_act_o      (led_act),
    .led_speed_o    (led_speed),
    .led_duplex_o   (led_duplex),
    .led_fault_o    (led_fault),
    .led_stat_o     (led_stat)
  );

  task check(input bit ok, input string label);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL %s", label);
    end else begin
      $display("PASS %s", label);
    end
  endtask

  /// Apply a switch position and let the two-stage sampler settle.  The
  /// positions are asynchronous inputs, so nothing may be observed in the same
  /// clock they change.
  task set_dip(input logic [SW_PANEL_DIP_W-1:0] value);
    dip = value;
    repeat (4) @(posedge clk);
    #1;
  endtask

  /// One PHY status byte: valid + link + full duplex + speed code.
  function automatic logic [7:0] phy_byte(input logic valid, link, full, input logic [1:0] speed);
    phy_byte = {2'b00, 1'b0, speed, full, link, valid};
  endfunction

  /// Number of clocks `cam_flush_o` was high during the last `measure_flush`.
  /// Module scope rather than a task output: Icarus is unreliable about
  /// non-array task outputs, and this bench reports the number, it does not
  /// pass it around.
  int unsigned flush_width;

  /// Watch `cam_flush_o` for 32 clocks.  A level that was passed through
  /// instead of edge detected would count every one of them.
  task measure_flush;
    flush_width = 0;
    for (int unsigned i = 0; i < 32; i++) begin
      @(posedge clk);
      #1;
      if (cam_flush) flush_width++;
    end
  endtask

  initial begin
    // ---- reset ------------------------------------------------------------
    rst_n = 0;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1;
    repeat (4) @(posedge clk);
    #1;
    check(!cfg_ovr, "reset leaves the configuration override off");
    check(!learning_en, "reset leaves learning off");
    check(flood_mode == SW_FLOOD_BCAST_ONLY, "reset decodes the least permissive policy");

    // ---- flooding policy decode ------------------------------------------
    set_dip(8'h01);
    check(flood_mode == SW_FLOOD_BCAST_UKN, "SW[1:0] = 1 selects unknown-unicast flooding");
    set_dip(8'h02);
    check(flood_mode == SW_FLOOD_ALL, "SW[1:0] = 2 selects group flooding as well");
    set_dip(8'h03);
    check(flood_mode == SW_FLOOD_ALL, "SW[1:0] = 3 is clamped, not propagated");

    // ---- learning and override -------------------------------------------
    set_dip(8'h04);
    check(learning_en, "SW[2] enables source learning");
    check(!cfg_ovr, "SW[3] low keeps the override off");
    set_dip(8'h0c);
    check(cfg_ovr, "SW[3] enables the configuration override");
    check(learning_en, "the override position does not clear the policy positions");

    // ---- flush is a request, not a level ---------------------------------
    // Raising the position must produce exactly one one-clock request.  A
    // design that passed the level through would request on every clock while
    // the switch is held up, and a design that only registered it once would
    // never request again after the first movement.
    set_dip(8'h0c);
    flush_width = 0;
    dip = 8'h1c;
    repeat (8) begin
      @(posedge clk);
      #1;
      if (cam_flush) flush_width++;
    end
    check(flush_width == 1, "moving the flush position on produces exactly one request");

    measure_flush;
    check(flush_width == 0, "holding the flush position up does not flush again");

    flush_width = 0;
    dip = 8'h0c;
    repeat (8) begin
      @(posedge clk);
      #1;
      if (cam_flush) flush_width++;
    end
    check(flush_width == 0, "releasing the flush position produces no request");

    // Moving it on again must request again, which is what makes the position
    // usable as a one-shot control rather than a single-use one.
    flush_width = 0;
    dip = 8'h1c;
    repeat (8) begin
      @(posedge clk);
      #1;
      if (cam_flush) flush_width++;
    end
    check(flush_width == 1, "a second movement produces a second request");

    // ---- lamp test lights everything -------------------------------------
    // With no link, no traffic and an empty table every lamp would be dark,
    // which is exactly the state the lamp test has to distinguish itself from.
    set_dip(8'h2c);
    check(led_link == 2'b11, "lamp test lights the per-port link lamps");
    check(led_act == 2'b11, "lamp test lights the per-port activity lamps");
    check(led_speed == 4'b1111, "lamp test lights every speed lamp");
    check(led_duplex == 2'b11, "lamp test lights the per-port duplex lamps");
    check(led_fault == 2'b11, "lamp test lights the per-port fault lamps");
    check(&led_stat == 1'b1, "lamp test lights every switch-wide status bit");

    // ---- link, speed and duplex lamps ------------------------------------
    set_dip(8'h0c);
    phy_status[0*8 +: 8] = phy_byte(1'b1, 1'b1, 1'b1, SW_PANEL_SPEED_100M);
    phy_status[1*8 +: 8] = phy_byte(1'b1, 1'b1, 1'b0, SW_PANEL_SPEED_1000M);
    @(posedge clk);
    #1;
    check(led_link == 2'b11, "a valid PHY with link up lights the link lamps");
    check(led_duplex[0] && !led_duplex[1], "the duplex lamp follows the PHY byte per port");
    check(led_speed[0] && !led_speed[1], "port 0 at 100 Mbit/s lights only the 100 lamp");
    check(!led_speed[2] && led_speed[3], "port 1 at 1000 Mbit/s lights only the 1000 lamp");

    phy_status[0*8 +: 8] = phy_byte(1'b1, 1'b1, 1'b1, SW_PANEL_SPEED_10M);
    @(posedge clk);
    #1;
    check(!led_speed[0] && !led_speed[1], "10 Mbit/s lights no speed lamp on port 0");

    // ---- an unknown PHY falls back to the administrative enable -----------
    phy_status[0*8 +: 8] = phy_byte(1'b0, 1'b0, 1'b0, 2'd0);
    link_up              = 2'b10;  // port 0 administratively disabled, port 1 enabled
    @(posedge clk);
    #1;
    check(!led_link[0], "an invalid PHY byte does not invent a link");
    check(led_link[1], "an invalid PHY byte falls back to the administrative enable");

    // ---- fault lamp -------------------------------------------------------
    phy_status[0*8 +: 8] = phy_byte(1'b1, 1'b0, 1'b0, SW_PANEL_SPEED_100M);
    phy_status[0*8 + SW_PANEL_PHY_MGMT] = 1'b1;
    @(posedge clk);
    #1;
    check(led_fault[0], "a management error lights the port's fault lamp");
    check(!led_fault[1], "a healthy port keeps its fault lamp dark");
    phy_status = '0;
    link_up    = '0;
    @(posedge clk);
    #1;

    // ---- utilisation bar and the full lamp -------------------------------
    cam_entries = 0;
    @(posedge clk);
    #1;
    check(led_stat[SW_PANEL_LED_CAM_BAR +: 4] == 4'b0000, "an empty table lights no bar segment");
    check(!led_stat[SW_PANEL_LED_CAM_USED], "an empty table keeps the used lamp dark");
    check(!led_stat[SW_PANEL_LED_CAM_FULL], "an empty table keeps the full lamp dark");

    cam_entries = 32'(CAM_CAPACITY / 4);
    @(posedge clk);
    #1;
    check(led_stat[SW_PANEL_LED_CAM_USED], "a non-empty table lights the used lamp");
    check(led_stat[SW_PANEL_LED_CAM_BAR +: 3] == 3'b001, "a quarter-full table lights one segment");

    cam_entries = 32'((CAM_CAPACITY * 3) / 4);
    @(posedge clk);
    #1;
    check(led_stat[SW_PANEL_LED_CAM_BAR +: 4] == 4'b0111, "a three-quarter table lights three segments");
    check(!led_stat[SW_PANEL_LED_CAM_FULL], "a three-quarter table is not full");

    cam_entries = 32'(CAM_CAPACITY);
    @(posedge clk);
    #1;
    check(led_stat[SW_PANEL_LED_CAM_BAR +: 4] == 4'b1111, "a full table lights every segment");
    check(led_stat[SW_PANEL_LED_CAM_FULL], "a full table lights the full lamp");
    cam_entries = 0;

    // ---- configuration echo ----------------------------------------------
    // SW[1:0] = 1 and SW[2] = 1 with the override *off*: the switch positions
    // are moved but the fabric is not acting on them, so the lamps must not say
    // that it is.
    set_dip(8'h05);
    check(!led_stat[SW_PANEL_LED_CFG_OVR], "the override lamp is dark while the override is off");
    check(!led_stat[SW_PANEL_LED_FLOOD0], "a moved flood switch is not echoed while the override is off");
    check(!led_stat[SW_PANEL_LED_LEARN], "a moved learning switch is not echoed while the override is off");

    set_dip(8'h0d);
    check(led_stat[SW_PANEL_LED_CFG_OVR], "the override lamp echoes the decoded override");
    check(led_stat[SW_PANEL_LED_FLOOD0], "the flood lamp echoes the decoded policy while the override is on");

    // ---- receive-error lamp ----------------------------------------------
    rx_runt = 32'd1;
    @(posedge clk);
    #1;
    check(led_stat[SW_PANEL_LED_RX_ERROR], "a runt lights the receive-error lamp");
    rx_runt = 32'd0;
    rx_overflow = 32'd1;
    @(posedge clk);
    #1;
    check(led_stat[SW_PANEL_LED_RX_ERROR], "an ingress overflow lights the receive-error lamp");
    rx_overflow = 32'd0;
    @(posedge clk);
    #1;
    check(!led_stat[SW_PANEL_LED_RX_ERROR], "a clean switch clears the receive-error lamp");

    // ---- activity stretch -------------------------------------------------
    port_active = 2'b01;
    @(posedge clk);
    #1;
    port_active = 2'b00;
    check(led_act[0], "an octet lights the activity lamp immediately");
    // The stretch is ACT_HOLD clocks; sample well inside it, then well after.
    repeat (ACT_HOLD / 2) @(posedge clk);
    #1;
    check(led_act[0], "the activity lamp is still lit inside the stretch window");
    repeat (ACT_HOLD + 4) @(posedge clk);
    #1;
    check(!led_act[0], "the activity lamp goes out after the stretch window");
    check(!led_act[1], "a quiet port keeps its activity lamp dark");

    // ---- heartbeat --------------------------------------------------------
    // Two full half-periods have to pass before the slowest bit of the counter
    // toggles; measuring the lamp itself would need 4 Hz of simulated time, so
    // the check is only that it is driven and starts low.
    check(led_stat[SW_PANEL_LED_HEARTBEAT] == 1'b0, "the heartbeat starts low after reset");

    $display("sw_panel_tb: %0d checks, %0d errors", checks, errors);
    if (errors != 0) $fatal(1, "sw_panel_tb FAILED");
    $display("PASS: sw_panel_tb");
    $finish;
  end

  // A hung bench must fail, not sit until the CI timeout.
  initial begin
    #2_000_000;
    $fatal(1, "sw_panel_tb timed out");
  end
endmodule
