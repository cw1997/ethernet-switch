// ============================================================================
//  File        : es_console_defs.sv
//  Description : Console command catalogue, the value-source vocabulary, and
//                the text formatting / rendering helpers every console port
//                and command module shares.
//
//                One console port never talks to another.  What they do share is
//                this file: the names of the commands, the shape of a reply
//                line, and the functions that render a value line.  Keeping all
//                of it here is what makes a second console port a pure
//                instantiation rather than a second implementation.
//
//                A command is its own module - `es_console_command_<name>` -
//                that emits the sequence of response lines for exactly one
//                command.  This file carries the shared vocabulary those
//                modules use: the command and value-source enums, the line
//                geometry, and the pure rendering functions a dispatcher calls
//                to turn a value-source descriptor into a text line.  Adding a
//                field to a command is therefore an edit to that command's own
//                module and nothing else.
//
//                Declarations are at compilation-unit scope, not in a package;
//                see es_defs.sv for why.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_DEFS_SV
`define ES_CONSOLE_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  Commands
// ============================================================================
/// Decoded command.  Every command is a pure query: the console has no path
/// that writes into the switch, so a second console can never fight a first one
/// over a configuration register.
typedef enum logic [3:0] {
  SW_CMD_NONE      = 4'd0,   ///< not recognised
  SW_CMD_HELP      = 4'd1,
  SW_CMD_VERSION   = 4'd2,
  SW_CMD_STATUS    = 4'd3,   ///< aggregate summary plus one block per port
  SW_CMD_PORT      = 4'd4,   ///< one port in full
  SW_CMD_STAT      = 4'd5,   ///< aggregate counters
  SW_CMD_LINK      = 4'd6,   ///< one line per port
  SW_CMD_CFG       = 4'd7,   ///< run-time configuration as decoded
  SW_CMD_MAC_ALL   = 4'd8,
  SW_CMD_MAC_PORT  = 4'd9,   ///< `mac <n>`: entries learned on port n
  SW_CMD_MAC_COUNT = 4'd10
} sw_console_cmd_e;

// ============================================================================
// 2.  Where a response line's value comes from
// ============================================================================
/// Value source of one response line.
typedef enum logic [3:0] {
  SW_SRC_TEXT       = 4'd0,   ///< literal text; the value field is unused
  SW_SRC_ZERO       = 4'd1,
  SW_SRC_STAT_AGG   = 4'd2,   ///< `stat_i[32*id +: 32]`
  SW_SRC_STAT_PORT  = 4'd3,   ///< that port's counter, via the read port
  SW_SRC_PHY        = 4'd4,   ///< the port's PHY status byte
  SW_SRC_LINK_UP    = 4'd5,   ///< administrative enable of the port
  SW_SRC_SPEED      = 4'd6,   ///< line rate in Mbit/s, from the PHY byte
  SW_SRC_DUPLEX     = 4'd7,
  SW_SRC_CAM_ENT    = 4'd8,
  SW_SRC_CAM_CAP    = 4'd9,
  SW_SRC_NUM_PORTS  = 4'd10,
  SW_SRC_MAC_IF     = 4'd11,
  SW_SRC_CONSOLE_ID = 4'd12,  ///< which console port is answering
  SW_SRC_CFG_FLOOD  = 4'd13,
  SW_SRC_CFG_LEARN  = 4'd14,
  SW_SRC_CFG_OVR    = 4'd15
} sw_console_src_e;

// ============================================================================
// 3.  Line geometry
// ============================================================================
/// Bytes in one response line.  A line is rendered in full and then shifted out
/// one octet per accepted UART character, so the size is also the longest
/// response the console can produce in one go.
localparam int unsigned SW_CONSOLE_LINE_BYTES = 64;

/// Bytes available for a label before the `=0x` and the sixteen hex digits.
localparam int unsigned SW_CONSOLE_LABEL_BYTES = 24;

/// Longest command line accepted, and therefore the widest line buffer.
localparam int unsigned SW_CONSOLE_CMD_BYTES = 32;

// ============================================================================
// 4.  Formatting
// ============================================================================

/// Render `label = 0x<16 hex digits>` followed by CR/LF, zero padded.
///
/// The value is always shown as sixteen hex digits so that a reader can compare
/// two dumps by eye without counting digits.  The label field is padded by the
/// caller's constant width, so a short label leaves a gap before the `=`.
function automatic logic [SW_CONSOLE_LINE_BYTES*8-1:0] sw_console_value_line(
    input var logic [SW_CONSOLE_LABEL_BYTES*8-1:0] label,
    input var logic [31:0] value);
  logic [127:0] hextext;
  for (int unsigned h = 0; h < 16; h++) begin
    // Bit 31 is the most significant nibble, so the text reads left to right.
    hextext[127-h*8 -: 8] = sw_hexchar(value[31-h*2 -: 4]);
  end
  sw_console_value_line = {label, "=0x", hextext, 16'h0d0a, 152'd0};
endfunction

/// Render a literal text line, padded with zeros so that the first zero octet
/// terminates it.  The literal must not contain a zero byte of its own.
function automatic logic [SW_CONSOLE_LINE_BYTES*8-1:0] sw_console_text_line(
    input var logic [SW_CONSOLE_LINE_BYTES*8-1:0] text);
  sw_console_text_line = text;
endfunction

// ============================================================================
// 5.  Literal text lines
// ============================================================================
/// The four lines of the `help` banner, indexed by line number.
function automatic logic [SW_CONSOLE_LINE_BYTES*8-1:0] sw_console_help_line(
    input logic [3:0] i);
  case (i)
    4'd0: sw_console_help_line = "help     status    stat     port <n>\015\n";
    4'd1: sw_console_help_line = "link     cfg       version\015\n";
    4'd2: sw_console_help_line = "mac all  mac <n>   mac count\015\n";
    default: sw_console_help_line = "values are hex, port numbers are decimal\015\n";
  endcase
endfunction

// ============================================================================
// 6.  Labels
// ============================================================================
/// Name of a receive or transmit counter, indexed by `sw_stat_id_e`.
function automatic logic [SW_CONSOLE_LABEL_BYTES*8-1:0] sw_console_stat_label(
    input logic [3:0] id);
  case (id)
    4'(SW_STAT_RX_FRAMES):   sw_console_stat_label = "rx_frames";
    4'(SW_STAT_RX_OCTETS):   sw_console_stat_label = "rx_octets";
    4'(SW_STAT_RX_FILTERED): sw_console_stat_label = "rx_filtered";
    4'(SW_STAT_RX_CRC_ERR):  sw_console_stat_label = "rx_crc_error";
    4'(SW_STAT_RX_RUNT):     sw_console_stat_label = "rx_runt";
    4'(SW_STAT_RX_OVERSIZE): sw_console_stat_label = "rx_oversize";
    4'(SW_STAT_RX_OVERFLOW): sw_console_stat_label = "rx_overflow";
    4'(SW_STAT_TX_FRAMES):   sw_console_stat_label = "tx_frames";
    4'(SW_STAT_TX_OCTETS):   sw_console_stat_label = "tx_octets";
    4'(SW_STAT_TX_STALLED):  sw_console_stat_label = "tx_stalled";
    4'(SW_STAT_CAM_HIT):     sw_console_stat_label = "cam_hit";
    4'(SW_STAT_CAM_MISS):    sw_console_stat_label = "cam_miss";
    4'(SW_STAT_CAM_LEARN):   sw_console_stat_label = "cam_learn";
    4'(SW_STAT_CAM_FLUSH):   sw_console_stat_label = "cam_flush";
    default:                 sw_console_stat_label = "reserved";
  endcase
endfunction

/// Name of a line whose value does not come from the counter set.
function automatic logic [SW_CONSOLE_LABEL_BYTES*8-1:0] sw_console_named_label(
    input logic [3:0] sel);
  case (sel)
    4'd0:  sw_console_named_label = "phy_status";
    4'd1:  sw_console_named_label = "link_up";
    4'd2:  sw_console_named_label = "speed_mbit";
    4'd3:  sw_console_named_label = "full_duplex";
    4'd4:  sw_console_named_label = "cam_entries";
    4'd5:  sw_console_named_label = "cam_capacity";
    4'd6:  sw_console_named_label = "num_ports";
    4'd7:  sw_console_named_label = "mac_interface";
    4'd8:  sw_console_named_label = "stat_count";
    4'd9:  sw_console_named_label = "flood_mode";
    4'd10: sw_console_named_label = "learning_enable";
    4'd11: sw_console_named_label = "cfg_override";
    4'd12: sw_console_named_label = "console_port";
    default: sw_console_named_label = "value";
  endcase
endfunction

// ============================================================================
// 7.  Line rendering
// ============================================================================
/// Which fixed name a non-counter line carries, keyed by its value source.
function automatic logic [3:0] sw_console_named_label_sel(input logic [3:0] src);
  case (src)
    SW_SRC_PHY:        sw_console_named_label_sel = 4'd0;
    SW_SRC_LINK_UP:    sw_console_named_label_sel = 4'd1;
    SW_SRC_SPEED:      sw_console_named_label_sel = 4'd2;
    SW_SRC_DUPLEX:     sw_console_named_label_sel = 4'd3;
    SW_SRC_CAM_ENT:    sw_console_named_label_sel = 4'd4;
    SW_SRC_CAM_CAP:    sw_console_named_label_sel = 4'd5;
    SW_SRC_NUM_PORTS:  sw_console_named_label_sel = 4'd6;
    SW_SRC_MAC_IF:     sw_console_named_label_sel = 4'd7;
    SW_SRC_CONSOLE_ID: sw_console_named_label_sel = 4'd12;
    SW_SRC_CFG_FLOOD:  sw_console_named_label_sel = 4'd9;
    SW_SRC_CFG_LEARN:  sw_console_named_label_sel = 4'd10;
    SW_SRC_CFG_OVR:    sw_console_named_label_sel = 4'd11;
    default:           sw_console_named_label_sel = 4'd12;
  endcase
endfunction

/// Render the line a latched descriptor describes.
///
/// `desc` is the low byte of a response-line descriptor: `{src[3:0], id[3:0]}`
/// with the port field already stripped (it is only needed to select the value,
/// not to render it).  A text line ignores `value`; a counter line uses the
/// counter label; every other line uses its named label.
function automatic logic [SW_CONSOLE_LINE_BYTES*8-1:0] sw_console_render_line(
    input var logic [7:0]  desc,
    input var logic [31:0] value);
  logic [SW_CONSOLE_LABEL_BYTES*8-1:0] label;
  if (desc[7:4] == SW_SRC_TEXT) begin
    sw_console_render_line = sw_console_help_line(desc[3:0]);
  end else if ((desc[7:4] == SW_SRC_STAT_AGG) ||
               (desc[7:4] == SW_SRC_STAT_PORT)) begin
    label = sw_console_stat_label(desc[3:0]);
    sw_console_render_line = sw_console_value_line(label, value);
  end else begin
    label = sw_console_named_label(sw_console_named_label_sel(desc[7:4]));
    sw_console_render_line = sw_console_value_line(label, value);
  end
endfunction

`default_nettype wire

`endif  // ES_CONSOLE_DEFS_SV
