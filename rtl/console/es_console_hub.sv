// ============================================================================
//  File        : es_console_hub.sv
//  Description : N independent console ports on one switch.
//
//                Each port is a complete `es_console_port` with its own UART,
//                line buffer, parser and response sequencer.  There is no shared
//                command engine, no shared address register and no shared text
//                buffer, so:
//
//                  * two operators can run a command at the same time without
//                    one seeing the other's characters;
//                  * a port whose cable is absent, or which is reset on its own,
//                    has no path by which it can stall a peer;
//                  * adding a third console is a parameter change.
//
//                That holds for everything except the forwarding-table read
//                port, which is a single physical mux inside the switch.  It is
//                granted to one console at a time here.  A traversal is short and
//                human-driven, so a fixed priority is sufficient and a rotating
//                arbiter would only add state to get wrong; the grant is held for
//                the whole traversal and released when the console drops its
//                claim.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_HUB_SV
`define ES_CONSOLE_HUB_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "console/es_console_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_console_hub #(
  /// Number of console ports.  One UART each; any value >= 1.
  parameter int unsigned NUM_CONSOLE = 1,
  /// Number of switch ports the commands can address.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS,
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
  /// Forwarding table capacity, reported by the queries.
  parameter int unsigned CAM_CAPACITY = 512,
  /// Line interface this switch was built for, reported by `version`.
  parameter int unsigned MAC_IF = int'(SW_MAC_IF_GMII)
) (
  /// Core clock; every port shares it but nothing else.
  input var logic clk_i,
  /// Per-port active-low reset.  A port can be reset without touching a peer.
  input var logic [NUM_CONSOLE-1:0] rst_ni,
  /// Per-port presence.  A port that is low is silent and claims nothing.
  input var logic [NUM_CONSOLE-1:0] present_i,
  /// Per-port UART pins, packed with console 0 in the least-significant bit.
  input var logic [NUM_CONSOLE-1:0] rx_i,
  input var logic [NUM_CONSOLE-1:0] cts_ni,
  output logic [NUM_CONSOLE-1:0]    tx_o,
  output logic [NUM_CONSOLE-1:0]    rts_no,
  /// Per-port sticky diagnostic.
  output logic [NUM_CONSOLE-1:0]    fault_o,

  // ---- switch observability ------------------------------------------------
  /// Aggregate counters, administrative enable and PHY status.
  input var logic [32*SW_STAT_COUNT-1:0] stat_agg_i,
  input var logic [NUM_PORTS-1:0]        link_up_i,
  input var logic [NUM_PORTS*8-1:0]      phy_status_i,
  input var logic [31:0]                 cam_entries_i,
  /// Configuration actually in force, as decoded by the panel.
  input var logic [1:0] cfg_flood_mode_i,
  input var logic       cfg_learning_en_i,
  input var logic       cfg_ovr_i,

  // ---- statistics read ports (packed, one slice per console) ---------------
  output logic [NUM_CONSOLE*sw_port_w(NUM_PORTS)-1:0] stat_port_o,
  output logic [NUM_CONSOLE*4-1:0]                    stat_id_o,
  input var logic [NUM_CONSOLE*32-1:0]                stat_data_i,

  // ---- shared forwarding-table read port -----------------------------------
  output logic        cam_rd_req_o,
  output logic [31:0] cam_rd_index_o,
  input var logic     cam_rd_valid_i,
  input var logic [127:0] cam_rd_entry_i
);

  localparam int unsigned PW = sw_port_w(NUM_PORTS);

  // --------------------------------------------------------------------------
  // Per-port requests to the shared table port
  // --------------------------------------------------------------------------
  logic [NUM_CONSOLE-1:0] cam_claim;
  logic [NUM_CONSOLE-1:0] cam_grant;
  logic [NUM_CONSOLE-1:0] port_req;
  logic [NUM_CONSOLE*32-1:0] port_index;

  // Quartus's parser rejects the SV inline form `for (genvar g = 0; ...)` and a
  // bare module-level `for`; every loop carries an explicit
  // `generate`/`endgenerate` wrapper (AGENTS.md 2.4).
  genvar g;

  generate
    for (g = 0; g < NUM_CONSOLE; g++) begin : g_console
      es_console_port #(
        .NUM_PORTS    (NUM_PORTS),
        .PORT_INDEX   (g),
        .CLK_FREQ_HZ  (CLK_FREQ_HZ),
        .UART_BAUD_RATE (UART_BAUD_RATE),
        .UART_DATA_BITS (UART_DATA_BITS),
        .UART_PARITY  (UART_PARITY),
        .UART_STOP_BITS (UART_STOP_BITS),
        .UART_FLOW_CONTROL (UART_FLOW_CONTROL),
        .CAM_CAPACITY (CAM_CAPACITY),
        .MAC_IF       (MAC_IF)
      ) u_port (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni[g]),
        .rx_i           (rx_i[g]),
        .cts_ni         (cts_ni[g]),
        .tx_o           (tx_o[g]),
        .rts_no         (rts_no[g]),
        .present_i      (present_i[g]),
        .stat_agg_i     (stat_agg_i),
        .stat_port_o    (stat_port_o[g*PW +: PW]),
        .stat_id_o      (stat_id_o[g*4 +: 4]),
        .stat_data_i    (stat_data_i[g*32 +: 32]),
        .link_up_i      (link_up_i),
        .phy_status_i   (phy_status_i),
        .cam_entries_i  (cam_entries_i),
        .cfg_flood_mode_i(cfg_flood_mode_i),
        .cfg_learning_en_i(cfg_learning_en_i),
        .cfg_ovr_i      (cfg_ovr_i),
        .cam_claim_o    (cam_claim[g]),
        .cam_grant_i    (cam_grant[g]),
        .cam_rd_req_o   (port_req[g]),
        .cam_rd_index_o (port_index[g*32 +: 32]),
        .cam_rd_valid_i (cam_rd_valid_i && cam_grant[g]),
        .cam_rd_entry_i (cam_rd_entry_i),
        .fault_o        (fault_o[g])
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Table-port grant
  //
  // The grant is held while the holder still claims it, so a traversal is not
  // interleaved with another console's reads.  When it is released the lowest
  // waiting console wins: `claim & (~claim + 1)` isolates that bit without a
  // priority chain and without a divider.
  // --------------------------------------------------------------------------
  logic [NUM_CONSOLE-1:0] next_grant;

  assign next_grant = cam_claim & (~cam_claim + NUM_CONSOLE'(1));

  always_ff @(posedge clk_i) begin
    if (!rst_ni[0]) begin
      cam_grant <= '0;
    end else if ((cam_grant & cam_claim) != '0) begin
      cam_grant <= cam_grant;
    end else begin
      cam_grant <= next_grant;
    end
  end

  // Only the granted console can be driving its request, so a bitwise OR is a
  // selector here rather than a merge of two live sources.
  always_comb begin
    cam_rd_req_o   = 1'b0;
    cam_rd_index_o = 32'd0;
    for (int unsigned c = 0; c < NUM_CONSOLE; c++) begin
      if (cam_grant[c]) begin
        cam_rd_req_o   = port_req[c];
        cam_rd_index_o = port_index[c*32 +: 32];
      end
    end
  end

endmodule : es_console_hub

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_CONSOLE_HUB_SV
