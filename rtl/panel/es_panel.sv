// ============================================================================
//  File        : es_panel.sv
//  Description : Front-panel companion of the switch: board switch positions in,
//                run-time configuration and semantic status lamps out.
//
//                Two independent jobs, deliberately kept in one module because
//                they share the same operator-facing vocabulary:
//
//                Decode.  `dip_i` is asynchronous and undebounced - slide
//                switches are level inputs, so no debounce is needed, but they
//                are not synchronous to `clk_i` either.  They are sampled
//                through a two-stage synchroniser and then decoded into the
//                forwarding policy.  A switch position only takes effect when
//                the override position is on, so a board powers up in the
//                elaboration-time configuration no matter where the other
//                positions happen to sit.
//
//                Indicate.  The per-port and switch-wide status buses are
//                reduced to lamp signals here rather than in a board shell,
//                which is what lets every board show the same thing without
//                writing any decoding logic.  The board's only decision is
//                which physical lamp shows which semantic signal.
//
//                Activity lamps
//                --------------
//                A lamp driven straight from the line pins would be invisible on
//                a 100 Mbit/s link: the frame is over long before the eye
//                registers it.  Each port therefore stretches its activity with
//                a hold counter, so the lamp stays lit for ACT_HOLD_MS after the
//                last octet and the brightness is roughly proportional to the
//                traffic rate.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_PANEL_SV
`define ES_PANEL_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "panel/es_panel_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_panel #(
  /// Number of switch ports the lamps cover.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in Hz, for the heartbeat and activity time bases.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// Forwarding table capacity, for the utilisation bar.
  parameter int unsigned CAM_CAPACITY = 512,
  /// How long an activity lamp stays lit after the last octet, in
  /// milliseconds.  Long enough to be visible at 10 Mbit/s, short enough that a
  /// quiet port goes dark before an operator gives up watching it.
  parameter int unsigned ACT_HOLD_MS = 100
) (
  /// Clock and synchronous active-low reset.
  input var logic clk_i,
  input var logic rst_ni,

  // ---- board switches ------------------------------------------------------
  /// Raw, asynchronous switch positions; see `es_panel_defs.sv` for the map.
  input var logic [SW_PANEL_DIP_W-1:0] dip_i,

  // ---- switch status -------------------------------------------------------
  /// Administrative port enable and the management block's per-port PHY byte.
  input var logic [NUM_PORTS-1:0]   link_up_i,
  input var logic [NUM_PORTS*8-1:0] phy_status_i,
  /// Recent line activity per port, taken from the PHY-facing pins.
  input var logic [NUM_PORTS-1:0] port_active_i,
  /// Receive-defect counters that drive the error lamp.  Only these four are
  /// inputs: a lamp that answered for all fourteen would have to invent a
  /// meaning for the traffic counters, and leaving them unconnected is cheaper
  /// than routing 448 bits to decide one bit.
  input var logic [31:0] rx_crc_err_i,
  input var logic [31:0] rx_runt_i,
  input var logic [31:0] rx_oversize_i,
  input var logic [31:0] rx_overflow_i,
  /// Forwarding-table occupancy.
  input var logic [31:0] cam_entries_i,

  // ---- decoded configuration ----------------------------------------------
  /// Forwarding policy for the core; only meaningful while `cfg_ovr_o` is high.
  output logic [1:0] flood_mode_o,
  output logic       learning_en_o,
  output logic       cfg_ovr_o,
  /// One-clock pulse: the flush position was just moved on.
  output logic       cam_flush_o,

  // ---- semantic status lamps ----------------------------------------------
  /// Per-port lamps.  The board maps each to one physical LED.
  output logic [NUM_PORTS-1:0]   led_link_o,
  output logic [NUM_PORTS-1:0]   led_act_o,
  output logic [NUM_PORTS*2-1:0] led_speed_o,   ///< [2p] = 100M, [2p+1] = 1000M
  output logic [NUM_PORTS-1:0]   led_duplex_o,
  output logic [NUM_PORTS-1:0]   led_fault_o,
  /// Switch-wide lamps; see the bit map in `es_panel_defs.sv`.
  output logic [15:0]            led_stat_o
);

  // --------------------------------------------------------------------------
  // Switch synchronisation and decoding
  //
  // Slide switches are level inputs, so a plain two-stage sampler is enough;
  // there is nothing to debounce and nothing to edge-detect except the flush
  // position, which is a request rather than a level.
  // --------------------------------------------------------------------------
  logic [SW_PANEL_DIP_W-1:0] dip_sync;

  es_common_sync_2ff #(
    .WIDTH       (SW_PANEL_DIP_W),
    .RESET_VALUE ('0)
  ) u_dip_sync (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .async_i(dip_i),
    .sync_o (dip_sync)
  );

  logic [1:0] dip_flood;
  logic       dip_learn;
  logic       dip_ovr;
  logic       dip_flush;
  logic       dip_led_test;

  assign dip_flood    = dip_sync[SW_PANEL_DIP_FLOOD_LSB +: 2];
  assign dip_learn    = dip_sync[SW_PANEL_DIP_LEARN];
  assign dip_ovr      = dip_sync[SW_PANEL_DIP_CFG_OVR];
  assign dip_flush    = dip_sync[SW_PANEL_DIP_FLUSH];
  assign dip_led_test = dip_sync[SW_PANEL_DIP_LED_TEST];

  // Position 3 is not a flooding policy.  Clamping it to the most permissive
  // value keeps the select inside `sw_flood_mode_e` instead of leaving the core
  // to interpret an encoding it never defines.
  assign flood_mode_o  = (dip_flood == 2'd3) ? 2'(SW_FLOOD_ALL) : dip_flood;
  assign learning_en_o = dip_learn;
  assign cfg_ovr_o     = dip_ovr;

  // The flush position is a level.  A request pulse on the rising edge is what
  // the core wants; holding the switch up must not flush continuously.
  logic dip_flush_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) dip_flush_q <= 1'b0;
    else         dip_flush_q <= dip_flush;
  end
  assign cam_flush_o = dip_flush & ~dip_flush_q;

  // --------------------------------------------------------------------------
  // Time bases
  // --------------------------------------------------------------------------
  /// Half period of the heartbeat, in clocks; about 4 Hz at 50 MHz.
  localparam int unsigned HB_HALF = (CLK_FREQ_HZ == 0) ? 1 : (CLK_FREQ_HZ / 8);
  localparam int unsigned HB_W    = (HB_HALF <= 2) ? 1 : $clog2(HB_HALF);
  localparam logic [HB_W-1:0] HB_LAST = HB_W'(HB_HALF - 1);

  /// Activity hold in clocks.
  localparam int unsigned ACT_HOLD = (CLK_FREQ_HZ == 0) ? 1 :
                                     ((CLK_FREQ_HZ / 1000) * ACT_HOLD_MS);
  localparam int unsigned AH_W     = (ACT_HOLD <= 2) ? 1 : $clog2(ACT_HOLD + 1);
  localparam logic [AH_W-1:0] AH_LAST = AH_W'(ACT_HOLD - 1);

  logic [HB_W-1:0] hb_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                hb_q <= '0;
    else if (hb_q == HB_LAST)   hb_q <= '0;
    else                        hb_q <= hb_q + HB_W'(1);
  end

  logic heartbeat;
  assign heartbeat = hb_q[HB_W-1];

  // --------------------------------------------------------------------------
  // Per-port lamps
  //
  // One generate arm per port so that every register is written by its own
  // always_ff with a constant index - a loop-indexed store into an array is
  // dropped silently by Icarus (AGENTS.md 3.3).
  // --------------------------------------------------------------------------
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_port
      logic       phy_valid;
      logic       phy_link;
      logic       phy_duplex;
      logic [1:0] phy_speed;
      logic       phy_mgmt;
      logic [AH_W-1:0] act_cnt_q;

      assign phy_valid  = phy_status_i[g*8 + SW_PANEL_PHY_VALID];
      assign phy_link   = phy_status_i[g*8 + SW_PANEL_PHY_LINK];
      assign phy_duplex = phy_status_i[g*8 + SW_PANEL_PHY_DUPLEX];
      assign phy_speed  = phy_status_i[g*8 + SW_PANEL_PHY_SPEED +: 2];
      assign phy_mgmt   = phy_status_i[g*8 + SW_PANEL_PHY_MGMT];

      // A port is lit when the management block says the link is up.  Before the
      // first successful poll there is no trustworthy answer, so the
      // administrative enable stands in - a port that was never brought up must
      // not look like a link failure.
      //
      // The lamp-test position lights every per-port lamp as well as the
      // switch-wide ones, so a board can be checked for dead LEDs without
      // traffic and without a PHY.  It is ORed in here rather than applied to
      // the board's pin bundle, because the panel is where the meaning of a lamp
      // lives.
      assign led_link_o[g]   = dip_led_test | (phy_valid ? phy_link : link_up_i[g]);
      assign led_duplex_o[g] = dip_led_test | (phy_valid & phy_link & phy_duplex);
      assign led_speed_o[g*2]     = dip_led_test | (phy_valid & phy_link &
                                    (phy_speed == SW_PANEL_SPEED_100M));
      assign led_speed_o[g*2 + 1] = dip_led_test | (phy_valid & phy_link &
                                    (phy_speed == SW_PANEL_SPEED_1000M));

      // Fault means "this port cannot be trusted right now": either management
      // is failing, or a PHY that used to answer has stopped.
      assign led_fault_o[g]  = dip_led_test | phy_mgmt;

      // Activity stretching; reloading on activity makes brightness track rate.
      always_ff @(posedge clk_i) begin
        if (!rst_ni)                    act_cnt_q <= '0;
        else if (port_active_i[g])      act_cnt_q <= AH_LAST;
        else if (act_cnt_q != '0)       act_cnt_q <= act_cnt_q - AH_W'(1);
      end

      assign led_act_o[g] = dip_led_test | port_active_i[g] | (act_cnt_q != '0);
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Switch-wide lamps
  // --------------------------------------------------------------------------
  /// Utilisation-bar thresholds.  Elaboration-time constants, so this is four
  /// comparators and not a divider.
  localparam int unsigned BAR1 = CAM_CAPACITY / 4;
  localparam int unsigned BAR2 = CAM_CAPACITY / 2;
  localparam int unsigned BAR3 = (CAM_CAPACITY * 3) / 4;

  logic cam_used;
  logic cam_full;
  logic [3:0] cam_bar;
  logic rx_error;

  assign cam_used = (cam_entries_i != '0);
  assign cam_full = (cam_entries_i >= 32'(CAM_CAPACITY));
  assign cam_bar[0] = (cam_entries_i >= 32'(BAR1));
  assign cam_bar[1] = (cam_entries_i >= 32'(BAR2));
  assign cam_bar[2] = (cam_entries_i >= 32'(BAR3));
  assign cam_bar[3] = cam_full;

  // Any receive-side defect at all.  These are aggregate counters, so the lamp
  // says "something was rejected somewhere" rather than naming a port; the
  // console is the place to find out which.  Overflow is kept in the set
  // because a port whose ingress buffer ran dry is losing frames without any of
  // the other three moving.
  assign rx_error = (rx_crc_err_i  != '0) |
                    (rx_runt_i     != '0) |
                    (rx_oversize_i != '0) |
                    (rx_overflow_i != '0);

  always_comb begin
    led_stat_o = 16'd0;
    led_stat_o[SW_PANEL_LED_HEARTBEAT] = heartbeat;
    led_stat_o[SW_PANEL_LED_ANY_LINK]  = |led_link_o;
    led_stat_o[SW_PANEL_LED_CAM_USED]  = cam_used;
    led_stat_o[SW_PANEL_LED_CAM_FULL]  = cam_full;
    led_stat_o[SW_PANEL_LED_CAM_BAR +: 4] = cam_bar;
    // Echo the decoded configuration, not the raw positions: an operator who
    // moved a policy switch while the override is off should see that the
    // switch is not acting on it.
    led_stat_o[SW_PANEL_LED_FLOOD0]  = cfg_ovr_o & flood_mode_o[0];
    led_stat_o[SW_PANEL_LED_LEARN]   = cfg_ovr_o & learning_en_o;
    led_stat_o[SW_PANEL_LED_CFG_OVR] = cfg_ovr_o;
    led_stat_o[SW_PANEL_LED_FLUSH]   = cam_flush_o;
    led_stat_o[SW_PANEL_LED_RX_ERROR] = rx_error;

    // Lamp test overrides everything, including the reserved bits, so a board
    // can be checked for dead LEDs without generating traffic.
    if (dip_led_test) led_stat_o = 16'hffff;
  end

endmodule : es_panel

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_PANEL_SV
