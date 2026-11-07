// ============================================================================
//  File        : es_panel_defs.sv
//  Description : Panel declarations: which board switch does what, and what
//                each bit of the semantic status-lamp bus means.
//
//                The panel is the only place that knows how an operator's switch
//                positions map onto a forwarding policy.  Naming the positions
//                here instead of in a board shell is what keeps the board files
//                down to pin assignments: a board that wires `dip_i` to its
//                switches gets the same behaviour as every other board, and a
//                new board cannot invent a different meaning for the same bits.
//
//                Declarations are at compilation-unit scope, not in a package;
//                see es_defs.sv for why.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_PANEL_DEFS_SV
`define ES_PANEL_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  Board switch encoding
// ============================================================================
/// Width of the `dip_i` vector.  Eight positions cover every function the panel
/// offers; a board with more switches ties the surplus low.
localparam int unsigned SW_PANEL_DIP_W = 8;

/// Flooding policy, two positions.  Decoded into `sw_flood_mode_e`; the value 3
/// is not a policy, so it is clamped to the most permissive one rather than
/// producing an undefined select.
localparam int unsigned SW_PANEL_DIP_FLOOD_LSB = 0;

/// Source-address learning enable.
localparam int unsigned SW_PANEL_DIP_LEARN     = 2;

/// Run-time configuration override.  When this position is off the switch runs
/// on the elaboration-time `FLOOD_MODE` / `LEARNING_EN` values and the two
/// policy positions above are ignored, which is what makes a board come up in a
/// known state even with every other switch moved.
localparam int unsigned SW_PANEL_DIP_CFG_OVR   = 3;

/// Flush the forwarding table.  Level-sensitive on the switch, so the panel
/// turns it into a single-clock pulse on the rising edge.
localparam int unsigned SW_PANEL_DIP_FLUSH     = 4;

/// Lamp test: every lamp on, per-port and switch-wide.  It is the only way to
/// tell a dark lamp from a lamp that is correctly reporting "nothing to report",
/// and it works without a PHY, a link or any traffic.
localparam int unsigned SW_PANEL_DIP_LED_TEST  = 5;

// ============================================================================
// 2.  Semantic status-lamp bus
// ============================================================================
// `led_stat_o` is the panel-wide (rather than per-port) half of the indicator
// set.  Per-port link / activity / speed / duplex / fault travel on their own
// buses, because their meaning depends on the port and their count on
// NUM_PORTS; these bits are the same for the whole switch.
localparam int unsigned SW_PANEL_LED_HEARTBEAT = 0;   ///< free-running blink
localparam int unsigned SW_PANEL_LED_ANY_LINK  = 1;   ///< at least one port up
localparam int unsigned SW_PANEL_LED_CAM_USED  = 2;   ///< forwarding table non-empty
localparam int unsigned SW_PANEL_LED_CAM_FULL  = 3;   ///< forwarding table full
/// Four-bit utilisation bar, least-significant step at bit 4.
localparam int unsigned SW_PANEL_LED_CAM_BAR   = 4;
/// Echo of the decoded configuration, so the front panel shows what the switch
/// believes it was asked to do rather than what the switches currently say.
localparam int unsigned SW_PANEL_LED_FLOOD0    = 8;
localparam int unsigned SW_PANEL_LED_LEARN     = 9;
localparam int unsigned SW_PANEL_LED_CFG_OVR   = 10;
localparam int unsigned SW_PANEL_LED_FLUSH     = 11;
/// A receive-side error counter is non-zero somewhere in the switch.
localparam int unsigned SW_PANEL_LED_RX_ERROR  = 12;

// ============================================================================
// 3.  PHY status byte
// ============================================================================
// The board's management block (es_perips_phy_88e1111) reports one byte per
// port.  The panel reads it for the link, duplex and speed lamps; an invalid
// byte leaves those lamps dark rather than showing a stale link.
localparam int unsigned SW_PANEL_PHY_VALID  = 0;
localparam int unsigned SW_PANEL_PHY_LINK   = 1;
localparam int unsigned SW_PANEL_PHY_DUPLEX = 2;
localparam int unsigned SW_PANEL_PHY_SPEED  = 3;  ///< two bits at [4:3]
localparam int unsigned SW_PANEL_PHY_MGMT   = 5;  ///< management error

/// Speed codes carried in `phy_status_i[4:3]`.
localparam logic [1:0] SW_PANEL_SPEED_10M   = 2'd0;
localparam logic [1:0] SW_PANEL_SPEED_100M  = 2'd1;
localparam logic [1:0] SW_PANEL_SPEED_1000M = 2'd2;

`default_nettype wire

`endif  // ES_PANEL_DEFS_SV
