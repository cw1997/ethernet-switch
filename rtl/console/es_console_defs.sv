// ============================================================================
//  File        : es_console_defs.sv
//  Description : Console command catalogue, response-line description and the
//                text formatting helpers every console port shares.
//
//                One console port never talks to another.  What they do share is
//                this file: the names of the commands, the shape of the reply
//                and the function that renders a value line.  Keeping all three
//                here is what makes a second console port a pure instantiation
//                rather than a second implementation - and therefore what makes
//                "add another UART" a one-line change.
//
//                A response is a sequence of lines.  A line is either a literal
//                text line (the help banner, an error) or a "label = value"
//                line whose value comes from somewhere in the switch.  The
//                sequencer asks `sw_console_line_info` what line N of command X
//                is and `sw_console_label` what it is called, so adding a field
//                to a command is an edit to two functions and nothing else.
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
// 5.  Response shape
// ============================================================================
/// Number of lines a command answers with.  `mac` answers with a variable count
/// and reports completion through the traversal instead.
function automatic int unsigned sw_console_line_count(input var logic [3:0] cmd,
                                                     input int unsigned num_ports);
  int unsigned n;
  n = 0;
  case (cmd)
    SW_CMD_HELP:    n = 4;
    SW_CMD_VERSION: n = 4;
    // Two switch-wide lines, then four per port: link, rate, receive frames and
    // transmit frames - the four numbers an operator looks at first.
    SW_CMD_STATUS:  n = 2 + 4*num_ports;
    SW_CMD_PORT:    n = 4 + SW_STAT_COUNT;
    SW_CMD_STAT:    n = SW_STAT_COUNT + 2;
    SW_CMD_LINK:    n = num_ports;
    SW_CMD_CFG:     n = 4;
    SW_CMD_MAC_COUNT: n = 2;
    default:        n = 0;
  endcase
  sw_console_line_count = n;
endfunction

/// Describe line `idx` of command `cmd`: where its value comes from, which
/// counter or port it refers to, and whether it is the last line.
///
/// `{last, port, src, id}` - `port` is meaningful for the per-port sources and
/// `id` for the counter sources.  `arg` is the command's own decimal argument,
/// so `port <n>` and `mac <n>` describe their lines for port n while `status`
/// derives the port from the line index.
function automatic logic [12:0] sw_console_line_info(
    input var logic [3:0]  cmd,
    input logic [6:0]      idx,
    input logic [3:0]      arg,
    input int unsigned     num_ports);
  logic        last;
  logic [3:0]  port;
  sw_console_src_e src;
  logic [3:0]  id;
  int unsigned n;

  n    = sw_console_line_count(cmd, num_ports);
  last = (n == 0) || (32'(idx) == 32'(n - 1));
  port = 4'd0;
  id   = 4'd0;
  src  = SW_SRC_ZERO;

  case (cmd)
    SW_CMD_HELP: begin
      src = SW_SRC_TEXT;
      id  = idx[3:0];
    end
    SW_CMD_VERSION: begin
      case (idx)
        7'd0:    begin src = SW_SRC_NUM_PORTS;  end
        7'd1:    begin src = SW_SRC_CAM_CAP;    end
        7'd2:    begin src = SW_SRC_MAC_IF;     end
        default: begin src = SW_SRC_CONSOLE_ID; end
      endcase
    end
    SW_CMD_STAT: begin
      if (idx < 7'(SW_STAT_COUNT)) begin
        src = SW_SRC_STAT_AGG;
        id  = idx[3:0];
      end else if (idx == 7'(SW_STAT_COUNT)) begin
        src = SW_SRC_CAM_ENT;
      end else begin
        src = SW_SRC_CAM_CAP;
      end
    end
    // `mac count` is a two-line answer: occupancy then capacity.  It shares the
    // command family with `stat` but not its line table, so it is decoded here
    // rather than falling through the counter range.
    SW_CMD_MAC_COUNT: begin
      if (idx == 7'd0) src = SW_SRC_CAM_ENT;
      else             src = SW_SRC_CAM_CAP;
    end
    SW_CMD_PORT: begin
      port = arg;
      case (idx)
        7'd0:    src = SW_SRC_PHY;
        7'd1:    src = SW_SRC_LINK_UP;
        7'd2:    src = SW_SRC_SPEED;
        7'd3:    src = SW_SRC_DUPLEX;
        default: begin
          src = SW_SRC_STAT_PORT;
          id  = 4'(idx - 7'd4);
        end
      endcase
    end
    SW_CMD_STATUS: begin
      if (idx < 7'd2) begin
        // Written as an if/else rather than a conditional expression: Icarus
        // will not infer the enum type of a `?:` result even with both arms
        // cast, and the plain assignment form is unambiguous everywhere.
        if (idx == 7'd0) src = SW_SRC_CAM_ENT;
        else             src = SW_SRC_CAM_CAP;
      end else begin
        port = 4'((idx - 7'd2) >> 2);
        case ((idx - 7'd2) & 7'd3)
          7'd0: src = SW_SRC_LINK_UP;
          7'd1: src = SW_SRC_SPEED;
          7'd2: begin src = SW_SRC_STAT_PORT; id = 4'(SW_STAT_RX_FRAMES); end
          default: begin src = SW_SRC_STAT_PORT; id = 4'(SW_STAT_TX_FRAMES); end
        endcase
      end
    end
    SW_CMD_LINK: begin
      port = 4'(idx);
      src  = SW_SRC_PHY;
    end
    SW_CMD_CFG: begin
      case (idx)
        7'd0:    src = SW_SRC_CFG_FLOOD;
        7'd1:    src = SW_SRC_CFG_LEARN;
        7'd2:    src = SW_SRC_CFG_OVR;
        default: src = SW_SRC_CAM_CAP;
      endcase
    end
    default: begin
      src = SW_SRC_ZERO;
    end
  endcase

  sw_console_line_info = {last, port, src, id};
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

`default_nettype wire

`endif  // ES_CONSOLE_DEFS_SV
