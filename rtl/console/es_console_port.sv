// ============================================================================
//  File        : es_console_port.sv
//  Description : One complete console port: UART, line editor, command parser,
//                dispatcher and response sequencer.
//
//                Self-contained by design
//                ------------------------
//                Everything this port needs is either one of its own ports or a
//                function in `es_console_defs.sv`.  It holds no state another
//                console port can see, drives no shared bus, and takes its own
//                reset.  Adding a second console is therefore an instantiation,
//                not a redesign - and a port whose cable is missing, babbling,
//                or being plugged in cannot disturb any other port, which is
//                what "hot plug" has to mean for a UART.
//
//                The only shared resource in the console subsystem is the
//                forwarding-table read port.  A port asks for it with
//                `cam_claim_o` and waits for `cam_grant_i`; without the grant it
//                touches nothing, so a stalled console cannot wedge a peer.
//
//                Response model
//                --------------
//                A command answers with a fixed number of lines, described by
//                `sw_console_line_info`.  A line is rendered in full into
//                `text_q` and shifted out one octet per accepted character; the
//                first zero octet ends it.  A line's value is fetched one clock
//                before it is rendered, so "one line, one counter" means a
//                counter cannot update in the middle of a number.
//
//                Commands are pure queries.  There is no path from here into the
//                switch configuration, so two consoles can never disagree about
//                what the configuration is.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_PORT_SV
`define ES_CONSOLE_PORT_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "console/es_console_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_console_port #(
  /// Number of switch ports the commands can address (at most 16).
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS,
  /// Console index, echoed as `console_port` so a host knows which cable it is
  /// talking to when more than one is plugged in.
  parameter int unsigned PORT_INDEX = 0,
  /// Core clock frequency in Hz.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// Console UART bit rate in bits per second.
  parameter int unsigned UART_BAUD_RATE = 115200,
  /// Console character width; the ASCII console requires seven or eight.
  parameter int unsigned UART_DATA_BITS = 8,
  /// Parity encoding from es_perips_defs.sv.
  parameter int unsigned UART_PARITY = SW_UART_PARITY_NONE,
  /// Stop bits per character.
  parameter int unsigned UART_STOP_BITS = 1,
  /// CTS/RTS policy from es_perips_defs.sv.
  parameter int unsigned UART_FLOW_CONTROL = SW_UART_FLOW_NONE,
  /// Forwarding table capacity, reported by `version`, `cfg` and `stat`.
  parameter int unsigned CAM_CAPACITY = 512,
  /// Line interface this switch was built for, reported by `version`.
  parameter int unsigned MAC_IF = int'(SW_MAC_IF_GMII)
) (
  /// Clock and synchronous active-low reset for this port alone.
  input var logic clk_i,
  input var logic rst_ni,
  /// UART pins; CTS is active low and RTS is the active-low permission to send.
  input var logic rx_i,
  input var logic cts_ni,
  output logic    tx_o,
  output logic    rts_no,
  /// Port presence.  While low the port transmits nothing and claims nothing -
  /// an unplugged console.
  input var logic present_i,

  // ---- switch observability ------------------------------------------------
  /// Aggregate counters, and the per-port read port this console drives.
  input var logic [32*SW_STAT_COUNT-1:0] stat_agg_i,
  output logic [sw_port_w(NUM_PORTS)-1:0] stat_port_o,
  output logic [3:0]                     stat_id_o,
  input var logic [31:0]                 stat_data_i,
  /// Administrative enable and PHY status, one entry per port.
  input var logic [NUM_PORTS-1:0]   link_up_i,
  input var logic [NUM_PORTS*8-1:0] phy_status_i,
  /// Forwarding table occupancy.
  input var logic [31:0] cam_entries_i,
  /// Configuration actually in force, as decoded by the panel.
  input var logic [1:0] cfg_flood_mode_i,
  input var logic       cfg_learning_en_i,
  input var logic       cfg_ovr_i,

  // ---- shared forwarding-table read port -----------------------------------
  /// Claim the table read port; granted to one console at a time.
  output logic        cam_claim_o,
  input var logic     cam_grant_i,
  /// Registered read request and its one-clock-later response.
  output logic        cam_rd_req_o,
  output logic [31:0] cam_rd_index_o,
  input var logic     cam_rd_valid_i,
  input var logic [127:0] cam_rd_entry_i,

  /// Sticky diagnostic: invalid input was seen on this port.
  output logic fault_o
);

  localparam int unsigned PW = sw_port_w(NUM_PORTS);

  // A forwarding-table entry carries reserved fields that the table's read
  // interface defines and no reader needs.  Reducing the whole word keeps
  // "nothing observes these bits" an explicit decision rather than a dangling
  // input, and costs one XOR tree.
  logic unused_entry;
  assign unused_entry = ^cam_rd_entry_i;

  // --------------------------------------------------------------------------
  // Parameter checks
  //
  // The response-line descriptor carries a four-bit port index, so a fabric with
  // more than sixteen ports would alias two onto one descriptor.  Excluded from
  // synthesis because yosys has no `$error` (AGENTS.md 3.4).
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (NUM_PORTS > 16) begin
      $error("es_console_port: NUM_PORTS (%0d) exceeds the 4-bit descriptor field",
             NUM_PORTS);
    end
    if (UART_DATA_BITS < 7) begin
      $error("es_console_port: the ASCII console needs 7 or 8 data bits");
    end
  end
`endif

  typedef enum logic [3:0] {
    S_RX,       ///< accumulate characters until a line ending
    S_PARSE,    ///< decode the line and start a response
    S_NEXT,     ///< wait for the buffer, then select the next line
    S_LOAD,     ///< render the selected line into the transmit buffer
    S_MAC_WAIT, ///< waiting for the shared table read port
    S_MAC_REQ,  ///< issue one table read
    S_MAC_EVAL, ///< filter the returned entry
    S_MAC_EMIT, ///< render one of the two lines describing a match
    S_MAC_NEXT, ///< advance the table cursor
    S_END       ///< drain the last line before returning to S_RX
  } state_e;

  state_e state_q;

  // --------------------------------------------------------------------------
  // UART
  // --------------------------------------------------------------------------
  logic       rx_valid;
  logic [7:0] rx_data;
  logic       tx_ready;
  logic       parity_error;
  logic       frame_error;
  logic       overflow;
  logic       unused_rts;

  // --------------------------------------------------------------------------
  // Command buffer and response text
  // --------------------------------------------------------------------------
  logic [SW_CONSOLE_CMD_BYTES*8-1:0]  command_q;
  logic [5:0]                         length_q;
  logic                               long_q;

  logic [SW_CONSOLE_LINE_BYTES*8-1:0] text_q;
  logic [6:0]                         text_left_q;

  /// The transmit buffer is free once its last octet has been shifted out.
  logic text_free;
  assign text_free = (text_left_q == 7'd0);


  // Sticky console diagnostics.
  logic [31:0] parity_errors_q;
  logic [31:0] frame_errors_q;
  logic [31:0] overflow_errors_q;
  logic [31:0] busy_errors_q;
  logic [31:0] long_errors_q;

  // --------------------------------------------------------------------------
  // Response sequencer state
  // --------------------------------------------------------------------------
  /// Command being answered, in its `sw_console_cmd_e` encoding.  Held as a
  /// plain 4-bit value because casting a variable to an enum type is rejected
  /// by the synthesis frontend; the encoding is compared, never used as a type.
  logic [3:0]      cmd_q;
  logic [3:0]      arg_q;      ///< its decimal argument
  logic [6:0]      line_q;     ///< line index within the response
  logic [12:0]     desc_q;     ///< {last, port, src, id} of the line in flight

  logic [31:0] mac_cursor_q;   ///< table index under inspection
  /// Fields of the entry the table returned; only these three are meaningful,
  /// so only these three are stored - the entry's reserved bits would otherwise
  /// be state that nothing can ever read.
  logic [3:0]  mac_port_q;
  logic [47:0] mac_addr_q;
  logic        mac_sub_q;      ///< 0 = high half + port, 1 = low half
  logic        mac_hit_q;      ///< the entry matched the filter

  // --------------------------------------------------------------------------
  // Parsing
  //
  // Matching is by length plus little-endian byte constants - no ROM, no
  // package.  The decimal argument accumulates with shift-and-add rather than a
  // multiply: `number * 10` on 32-bit vectors is a real multiplier array in the
  // netlist (AGENTS.md 3.2), and the value can never exceed the port count.
  // --------------------------------------------------------------------------
  function automatic logic [7:0] console_parse(
      input var logic [SW_CONSOLE_CMD_BYTES*8-1:0] cmd,
      input var logic [5:0]                        len);
    logic [3:0]  kind;
    logic [8:0]  acc;
    logic        bad;
    int unsigned first;
    logic [7:0]  ch;
    int unsigned i;

    kind  = 4'(SW_CMD_NONE);
    acc   = 9'd0;
    bad   = 1'b0;
    first = 0;

    if ((len == 6'd4) && (cmd[31:0] == 32'h706c6568)) begin
      kind = 4'(SW_CMD_HELP);                        // "help"
    end else if ((len == 6'd7) && (cmd[55:0] == 56'h6e6f6973726576)) begin
      kind = 4'(SW_CMD_VERSION);                     // "version"
    end else if ((len == 6'd6) && (cmd[47:0] == 48'h737574617473)) begin
      kind = 4'(SW_CMD_STATUS);                      // "status"
    end else if ((len == 6'd4) && (cmd[31:0] == 32'h74617473)) begin
      kind = 4'(SW_CMD_STAT);                        // "stat"
    end else if ((len == 6'd4) && (cmd[31:0] == 32'h6b6e696c)) begin
      kind = 4'(SW_CMD_LINK);                        // "link"
    end else if ((len == 6'd3) && (cmd[23:0] == 24'h676663)) begin
      kind = 4'(SW_CMD_CFG);                         // "cfg"
    end else if ((len == 6'd9) && (cmd[71:0] == 72'h746e756f632063616d)) begin
      kind = 4'(SW_CMD_MAC_COUNT);                   // "mac count"
    end else if ((len == 6'd7) && (cmd[55:0] == 56'h6c6c612063616d)) begin
      kind = 4'(SW_CMD_MAC_ALL);                     // "mac all"
    end else if ((len > 6'd4) && (cmd[31:0] == 32'h2063616d)) begin
      kind  = 4'(SW_CMD_MAC_PORT);                   // "mac " <n>
      first = 4;
    end else if ((len > 6'd5) && (cmd[39:0] == 40'h2074726f70)) begin
      kind  = 4'(SW_CMD_PORT);                       // "port " <n>
      first = 5;
    end else begin
      kind = 4'(SW_CMD_NONE);
    end

    if ((first != 0) && !bad) begin
      for (i = 0; i < 4; i++) begin
        if ((32'(first) + 32'(i)) < 32'(len)) begin
          ch = cmd[(first+i)*8 +: 8];
          if ((ch < 8'd48) || (ch > 8'd57)) begin
            bad = 1'b1;
          end else if (!bad) begin
            // Guard before the shift-add: nine bits hold 31*10 + 9 exactly.
            if (acc > 9'd31) bad = 1'b1;
            else acc = {acc[5:0], 3'd0} + {acc[7:0], 1'd0} + {5'd0, ch[3:0]};
          end
        end
      end
      // A port number only means something inside the fabric.
      if (!bad && (acc >= 9'(NUM_PORTS))) bad = 1'b1;
      if (bad) kind = 4'(SW_CMD_NONE);
    end

    // `acc` was bounded above by the NUM_PORTS check, so four bits carry it
    // exactly; the narrow return is what keeps the parser's interface free of
    // padding nothing reads.
    console_parse = {kind, acc[3:0]};
  endfunction

  // --------------------------------------------------------------------------
  // Literal text lines
  // --------------------------------------------------------------------------
  function automatic logic [SW_CONSOLE_LINE_BYTES*8-1:0] help_line(input logic [3:0] i);
    case (i)
      4'd0: help_line = "help     status    stat     port <n>\015\n";
      4'd1: help_line = "link     cfg       version\015\n";
      4'd2: help_line = "mac all  mac <n>   mac count\015\n";
      default: help_line = "values are hex, port numbers are decimal\015\n";
    endcase
  endfunction

  // --------------------------------------------------------------------------
  // Value and label resolution
  //
  // `stat_data_i` follows `stat_port_o` / `stat_id_o` in the same clock, so by
  // the time this runs the selectors were latched one state earlier and the
  // value is already stable.
  // --------------------------------------------------------------------------
  logic [3:0] desc_port;
  logic [3:0] desc_src;
  logic [3:0] desc_id;
  logic       desc_last;
  logic [31:0] desc_value;
  logic [7:0]  desc_phy;
  logic [1:0]  desc_speed;

  assign desc_last  = desc_q[12];
  assign desc_port  = desc_q[11:8];
  assign desc_src   = desc_q[7:4];
  assign desc_id    = desc_q[3:0];
  assign desc_phy   = phy_status_i[32'(desc_port)*8 +: 8];
  assign desc_speed = desc_phy[4:3];

  always_comb begin
    desc_value = 32'd0;
    case (desc_src)
      SW_SRC_STAT_AGG:  desc_value = stat_agg_i[32'(desc_id)*32 +: 32];
      SW_SRC_STAT_PORT: desc_value = stat_data_i;
      SW_SRC_PHY:       desc_value = {24'd0, desc_phy};
      SW_SRC_LINK_UP:   desc_value = {31'd0, link_up_i[desc_port[PW-1:0]]};
      SW_SRC_SPEED: begin
        case (desc_speed)
          SW_PANEL_SPEED_10M:   desc_value = 32'd10;
          SW_PANEL_SPEED_100M:  desc_value = 32'd100;
          SW_PANEL_SPEED_1000M: desc_value = 32'd1000;
          default:              desc_value = 32'd0;
        endcase
      end
      SW_SRC_DUPLEX:    desc_value = {31'd0, desc_phy[2]};
      SW_SRC_CAM_ENT:   desc_value = cam_entries_i;
      SW_SRC_CAM_CAP:   desc_value = 32'(CAM_CAPACITY);
      SW_SRC_NUM_PORTS: desc_value = 32'(NUM_PORTS);
      SW_SRC_MAC_IF:    desc_value = 32'(MAC_IF);
      SW_SRC_CONSOLE_ID: desc_value = 32'(PORT_INDEX);
      SW_SRC_CFG_FLOOD: desc_value = {30'd0, cfg_flood_mode_i};
      SW_SRC_CFG_LEARN: desc_value = {31'd0, cfg_learning_en_i};
      SW_SRC_CFG_OVR:   desc_value = {31'd0, cfg_ovr_i};
      default:          desc_value = 32'd0;
    endcase
  end

  /// Which fixed name a non-counter line carries.
  function automatic logic [3:0] named_label_sel(input logic [3:0] src);
    case (src)
      SW_SRC_PHY:        named_label_sel = 4'd0;
      SW_SRC_LINK_UP:    named_label_sel = 4'd1;
      SW_SRC_SPEED:      named_label_sel = 4'd2;
      SW_SRC_DUPLEX:     named_label_sel = 4'd3;
      SW_SRC_CAM_ENT:    named_label_sel = 4'd4;
      SW_SRC_CAM_CAP:    named_label_sel = 4'd5;
      SW_SRC_NUM_PORTS:  named_label_sel = 4'd6;
      SW_SRC_MAC_IF:     named_label_sel = 4'd7;
      SW_SRC_CONSOLE_ID: named_label_sel = 4'd12;
      SW_SRC_CFG_FLOOD:  named_label_sel = 4'd9;
      SW_SRC_CFG_LEARN:  named_label_sel = 4'd10;
      SW_SRC_CFG_OVR:    named_label_sel = 4'd11;
      default:           named_label_sel = 4'd12;
    endcase
  endfunction

  /// Render the line the latched descriptor describes.
  function automatic logic [SW_CONSOLE_LINE_BYTES*8-1:0] render_line(
      input var logic [7:0]  desc,
      input var logic [31:0] value);
    logic [SW_CONSOLE_LABEL_BYTES*8-1:0] label;
    if (desc[7:4] == SW_SRC_TEXT) begin
      render_line = help_line(desc[3:0]);
    end else if ((desc[7:4] == SW_SRC_STAT_AGG) ||
                 (desc[7:4] == SW_SRC_STAT_PORT)) begin
      label = sw_console_stat_label(desc[3:0]);
      render_line = sw_console_value_line(label, value);
    end else begin
      label = sw_console_named_label(named_label_sel(desc[7:4]));
      render_line = sw_console_value_line(label, value);
    end
  endfunction

  // --------------------------------------------------------------------------
  // Combinational evaluation of the two tables
  //
  // Both are evaluated once as continuous assignments rather than at each use:
  // the parse result feeds three separate decisions in the same clock, and the
  // line descriptor feeds the read-port selectors and the renderer, so calling
  // the functions repeatedly would only obscure which value is authoritative.
  // --------------------------------------------------------------------------
  logic [7:0]  parse_w;
  logic [12:0] info_w;
  /// Descriptor port field, broken out because a chain of two range selects is
  /// rejected by Icarus and reads ambiguously everywhere else.
  logic [PW-1:0] info_port;

  assign parse_w   = console_parse(command_q, length_q);
  assign info_w    = sw_console_line_info(cmd_q, line_q, arg_q, int'(NUM_PORTS));
  // Truncation to the port-index width is deliberate: a NUM_PORTS-port fabric
  // cannot produce a descriptor whose port field needs more bits, and the
  // upper bits would otherwise be state nothing can read.
  assign info_port = PW'(info_w[11:8]);

  // --------------------------------------------------------------------------
  // UART instance
  // --------------------------------------------------------------------------
  es_perips_uart #(
    .CLK_FREQ_HZ  (CLK_FREQ_HZ),
    .BAUD_RATE    (UART_BAUD_RATE),
    .DATA_BITS    (UART_DATA_BITS),
    .PARITY       (UART_PARITY),
    .STOP_BITS    (UART_STOP_BITS),
    .FLOW_CONTROL (UART_FLOW_CONTROL)
  ) u_uart (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .rx_i           (rx_i),
    .cts_ni         (cts_ni),
    .tx_o           (tx_o),
    .rts_no         (unused_rts),
    .tx_valid_i     (present_i && !text_free &&
                     (text_q[SW_CONSOLE_LINE_BYTES*8-1 -: 8] != 8'd0)),
    .tx_data_i      (text_q[SW_CONSOLE_LINE_BYTES*8-1 -: 8]),
    .tx_ready_o     (tx_ready),
    .rx_valid_o     (rx_valid),
    .rx_data_o      (rx_data),
    .rx_ready_i     (1'b1),
    .parity_error_o (parity_error),
    .frame_error_o  (frame_error),
    .overflow_o     (overflow)
  );

  // RTS is deasserted whenever the console is not listening.  A console that is
  // absent also holds the host off, since it will never consume a character.
  assign rts_no = (UART_FLOW_CONTROL == SW_UART_FLOW_NONE) ? 1'b0 :
                  (!present_i || (state_q != S_RX));

  // --------------------------------------------------------------------------
  // Sequencer
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q        <= S_RX;
      command_q      <= '0;
      length_q       <= '0;
      long_q         <= 1'b0;
      fault_o        <= 1'b0;
      parity_errors_q <= '0;
      frame_errors_q <= '0;
      overflow_errors_q <= '0;
      busy_errors_q  <= '0;
      long_errors_q  <= '0;
      text_q         <= '0;
      text_left_q    <= '0;
      cmd_q          <= SW_CMD_NONE;
      arg_q          <= '0;
      line_q         <= '0;
      desc_q         <= '0;
      stat_port_o    <= '0;
      stat_id_o      <= '0;
      cam_claim_o    <= 1'b0;
      cam_rd_req_o   <= 1'b0;
      cam_rd_index_o <= '0;
      mac_cursor_q   <= '0;
      mac_port_q     <= '0;
      mac_addr_q     <= '0;
      mac_sub_q      <= 1'b0;
      mac_hit_q      <= 1'b0;
    end else begin
      // One octet leaves the buffer per accepted character; a zero octet is the
      // terminator and costs a clock without being transmitted.
      if (!text_free && ((text_q[SW_CONSOLE_LINE_BYTES*8-1 -: 8] == 8'd0) || tx_ready)) begin
        text_q      <= {text_q[SW_CONSOLE_LINE_BYTES*8-9:0], 8'd0};
        text_left_q <= text_left_q - 7'd1;
      end

      if (parity_error) parity_errors_q <= parity_errors_q + 32'd1;
      if (frame_error)  frame_errors_q  <= frame_errors_q + 32'd1;
      if (overflow)     overflow_errors_q <= overflow_errors_q + 32'd1;

      // Input while a response is streaming is rejected, not buffered; line
      // endings are exempt so a host can still terminate its line.
      if (rx_valid && (state_q != S_RX) && (rx_data != 8'd10) && (rx_data != 8'd13)) begin
        busy_errors_q <= busy_errors_q + 32'd1;
        fault_o       <= 1'b1;
      end
      if (parity_error || frame_error || overflow) fault_o <= 1'b1;

      // The table read request is a one-clock pulse; the index stays put so the
      // table sees a stable address for the whole transaction.
      cam_rd_req_o <= 1'b0;

      case (state_q)
        // ---- line editing --------------------------------------------------
        S_RX: begin
          if (present_i && rx_valid) begin
            if ((rx_data == 8'd13) || (rx_data == 8'd10)) begin
              if ((length_q != 6'd0) || long_q) state_q <= S_PARSE;
            end else if ((rx_data == 8'd8) || (rx_data == 8'd127)) begin
              if (length_q != 6'd0) begin
                length_q <= length_q - 6'd1;
                // (length-1)*8 written as a shift; `length_q * 8` on 32-bit
                // vectors would be a real multiplier (AGENTS.md 3.2).
                command_q[32'({length_q, 3'd0}) - 32'd8 +: 8] <= '0;
              end
            end else if (length_q < 6'(SW_CONSOLE_CMD_BYTES)) begin
              command_q[32'({length_q, 3'd0}) +: 8] <= rx_data;
              length_q <= length_q + 6'd1;
            end else begin
              long_q <= 1'b1;
              fault_o <= 1'b1;
              if (!long_q) long_errors_q <= long_errors_q + 32'd1;
            end
          end
        end

        // ---- decode --------------------------------------------------------
        //
        // A rejected line answers with one error line instead of a response, and
        // both the over-long case and an unrecognised command land here.
        S_PARSE: begin
          command_q <= '0;
          length_q  <= '0;
          long_q    <= 1'b0;
          line_q    <= '0;
          mac_cursor_q <= '0;
          mac_sub_q    <= 1'b0;
          cmd_q     <= parse_w[7:4];
          arg_q     <= parse_w[3:0];
          if (long_q || (parse_w[7:4] == SW_CMD_NONE)) begin
            text_q      <= {"ERR command or port\015\n", 344'd0};
            text_left_q <= 7'd64;
            // A rejected line is a diagnostic in its own right: it is the only
            // way a host can tell "the switch ignored me" from "the switch never
            // heard me".
            fault_o     <= 1'b1;
            state_q     <= S_END;
          end else if ((parse_w[7:4] == SW_CMD_MAC_ALL) ||
                       (parse_w[7:4] == SW_CMD_MAC_PORT)) begin
            state_q <= S_MAC_WAIT;
          end else begin
            state_q <= S_NEXT;
          end
        end

        // ---- fixed line sequence -------------------------------------------
        S_NEXT: begin
          if (text_free) begin
            desc_q      <= info_w;
            stat_port_o <= info_port;
            stat_id_o   <= info_w[3:0];
            state_q     <= S_LOAD;
          end
        end

        S_LOAD: begin
          text_q      <= render_line(desc_q[7:0], desc_value);
          text_left_q <= 7'd64;
          line_q      <= line_q + 7'd1;
          state_q     <= desc_last ? S_END : S_NEXT;
        end

        // ---- forwarding table traversal ------------------------------------
        S_MAC_WAIT: begin
          cam_claim_o <= present_i;
          if (cam_grant_i) state_q <= S_MAC_REQ;
        end

        S_MAC_REQ: begin
          if (32'(mac_cursor_q) >= 32'(CAM_CAPACITY)) begin
            cam_claim_o <= 1'b0;
            state_q     <= S_END;
          end else begin
            cam_rd_index_o <= mac_cursor_q;
            cam_rd_req_o   <= 1'b1;
            state_q        <= S_MAC_EVAL;
          end
        end

        S_MAC_EVAL: begin
          if (cam_rd_valid_i) begin
            // Entry layout: {31'd0, valid, port[31:0], 16'd0, mac[47:0]}.
            mac_port_q  <= cam_rd_entry_i[67:64];
            mac_addr_q  <= cam_rd_entry_i[47:0];
            mac_hit_q   <= cam_rd_entry_i[96] &&
                           ((cmd_q == SW_CMD_MAC_ALL) ||
                            (cam_rd_entry_i[95:64] == 32'(arg_q)));
            mac_sub_q   <= 1'b0;
            state_q     <= S_MAC_EMIT;
          end
        end

        S_MAC_EMIT: begin
          if (mac_hit_q) begin
            if (text_free) begin
              if (!mac_sub_q) begin
                // High half of the address together with the learned port, so
                // one 32-bit value carries both fields without a third line.
                text_q <= sw_console_value_line("mac_hi_port",
                            {mac_addr_q[47:32], 12'd0, mac_port_q});
              end else begin
                text_q <= sw_console_value_line("mac_lo", mac_addr_q[31:0]);
              end
              text_left_q <= 7'd64;
              mac_sub_q   <= ~mac_sub_q;
              if (mac_sub_q) state_q <= S_MAC_NEXT;
            end
          end else begin
            state_q <= S_MAC_NEXT;
          end
        end

        S_MAC_NEXT: begin
          if (text_free) begin
            mac_cursor_q <= mac_cursor_q + 32'd1;
            state_q      <= S_MAC_REQ;
          end
        end

        // ---- drain ----------------------------------------------------------
        S_END: begin
          cam_claim_o <= 1'b0;
          if (text_free) state_q <= S_RX;
        end

        default: state_q <= S_RX;
      endcase
    end
  end

endmodule : es_console_port

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_CONSOLE_PORT_SV
