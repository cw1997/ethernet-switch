// ============================================================================
//  File        : es_switch_tx_writer.sv
//  Description : S4 - one copy engine per source port, all running in parallel.
//
//                Parallelism and the single egress write port
//                --------------------------------------------
//                Each engine reads its own ingress byte FIFO (one read port per
//                source port, so no RAM arbitration is needed) and can write
//                every egress queue in the same clock.  An egress queue has
//                exactly one write port, so engines contend for it: for each
//                destination q the lowest-numbered requesting engine wins.
//                An engine only proceeds when it wins ALL of its destinations
//                in that clock, which is what prevents a frame from being
//                written to port 1 but not port 2.  Losing engines simply
//                stall with their byte still unread - valid/ready makes that
//                lossless.
//
//                A frame whose mask is zero is still read out byte by byte and
//                discarded, because its bytes occupy the head of the ingress
//                FIFO and the next descriptor must start at the right offset.
//
//                Switch-domain style (AGENTS.md 3.3.1): no procedural block
//                in this file - each engine's four registers are es_mems_reg_bank
//                instances and everything else is a `logic`/`assign` cloud.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_TX_WRITER_SV
`define ES_SWITCH_TX_WRITER_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_tx_writer #(
  parameter int unsigned NUM_PORTS = 4
) (
  input  var logic                                    clk_i,
  input  var logic                                    rst_ni,

  // ---- descriptors from the decide level --------------------------------
  input  var logic [NUM_PORTS-1:0]                    i_valid,
  output      logic [NUM_PORTS-1:0]                   i_ready,
  input  var logic [NUM_PORTS*(NUM_PORTS+SW_LEN_W)-1:0] i_pkg,

  // ---- ingress byte FIFO read ports (FWFT) ------------------------------
  output      logic [NUM_PORTS-1:0]                   buf_rd_en,
  input  var logic [NUM_PORTS*8-1:0]                  buf_rd_data,
  input  var logic [NUM_PORTS-1:0]                    buf_empty,

  // ---- egress queue write ports -----------------------------------------
  input  var logic [NUM_PORTS-1:0]                    tx_ready,
  output      logic [NUM_PORTS-1:0]                   tx_wr_en,
  output      logic [NUM_PORTS*8-1:0]                 tx_wr_data,
  output      logic [NUM_PORTS-1:0]                   tx_wr_sof,
  output      logic [NUM_PORTS-1:0]                   tx_wr_eof
);

  localparam int unsigned PW       = sw_port_w(NUM_PORTS);
  // The writer only needs the egress mask and the frame length, so its input
  // package is deliberately narrower than the full descriptor.  Passing the
  // whole descriptor would leave the dst/src MAC bits unread, which -Wall
  // reports as UNUSEDSIGNAL (AGENTS.md 2.2: fix the code, never add a waiver).
  localparam int unsigned LW       = NUM_PORTS + SW_LEN_W;
  localparam int unsigned MASK_LSB = SW_LEN_W;
  localparam int unsigned IDX_W    = SW_LEN_W;

  /// Lowest set bit as a one-hot; a function, not a combinational process.
  function automatic logic [NUM_PORTS-1:0] pick_low(
      input logic [NUM_PORTS-1:0] v);
    logic [NUM_PORTS-1:0] r;
    logic                 found;
    int unsigned           i;
    r     = '0;
    found = 1'b0;
    for (i = 0; i < NUM_PORTS; i++) begin
      if (!found && v[i]) begin r[i] = 1'b1; found = 1'b1; end
    end
    pick_low = r;
  endfunction

  /// Binary index of the lowest set bit (0 when the vector is empty).
  function automatic logic [PW-1:0] pick_idx(
      input logic [NUM_PORTS-1:0] v);
    logic [NUM_PORTS-1:0] onehot;
    logic [PW-1:0]        r;
    int unsigned           i;
    onehot = pick_low(v);
    r      = '0;
    for (i = 0; i < NUM_PORTS; i++) begin
      if (onehot[i]) r = PW'(i);
    end
    pick_idx = r;
  endfunction

  /// True when every destination in `mask` has its queue ready.
  function automatic logic dests_ready(
      input logic [NUM_PORTS-1:0] mask,
      input logic [NUM_PORTS-1:0] rdy);
    logic ok;
    int unsigned q;
    ok = 1'b1;
    for (q = 0; q < NUM_PORTS; q++) begin
      if (mask[q] && !rdy[q]) ok = 1'b0;
    end
    dests_ready = ok;
  endfunction

  /// True when this engine won the arbitration on every destination it needs.
  function automatic logic won_all(
      input logic [NUM_PORTS-1:0]    mask,
      input logic [PW-1:0]           me,
      input logic [NUM_PORTS*PW-1:0] sel);
    logic ok;
    int unsigned q;
    ok = 1'b1;
    for (q = 0; q < NUM_PORTS; q++) begin
      if (mask[q] && sel[q*PW +: PW] != me) ok = 1'b0;
    end
    won_all = ok;
  endfunction

  logic [NUM_PORTS-1:0]           copy;
  logic [NUM_PORTS*NUM_PORTS-1:0] mask_flat;
  logic [NUM_PORTS*IDX_W-1:0]     idx_flat;
  logic [NUM_PORTS*SW_LEN_W-1:0]  len_flat;
  logic [NUM_PORTS-1:0]           want;
  logic [NUM_PORTS-1:0]           grant;
  logic [NUM_PORTS*NUM_PORTS-1:0] req_mat;   // [q*N + p]
  logic [NUM_PORTS*PW-1:0]        sel_idx;
  logic [NUM_PORTS-1:0]           any_req;

  genvar gp;
  genvar gq;

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_engine
      logic [NUM_PORTS-1:0] mask_q;
      logic [IDX_W-1:0]     idx_q;
      logic [SW_LEN_W-1:0]  len_q;
      logic                 copy_q;
      logic                 accept;
      logic                 finish;
      logic                 idx_ena;

      assign copy[gp]                              = copy_q;
      assign mask_flat[gp*NUM_PORTS +: NUM_PORTS] = mask_q;
      assign idx_flat[gp*IDX_W +: IDX_W]          = idx_q;
      assign len_flat[gp*SW_LEN_W +: SW_LEN_W]    = len_q;

      assign accept      = !copy_q && i_valid[gp];
      assign i_ready[gp] = !copy_q;
      // FWFT: a byte is present whenever !buf_empty[gp].
      assign finish = copy_q && grant[gp] &&
                      (idx_q == IDX_W'(len_q - SW_LEN_W'(1)));
      assign buf_rd_en[gp] = grant[gp];

      // Per-engine registers, each a DEPTH=1 es_mems_reg_bank entry
      // (switch-domain style, AGENTS.md).  The priority matches the
      // single-process form this came from: accept > finish > advance.
      // accept and finish are mutually exclusive (accept requires !copy_q,
      // finish requires copy_q), so the busy flag's next value is simply
      // accept.
      es_mems_reg_bank #(
        .WIDTH       (1),
        .DEPTH       (1),
        .RESET_VALUE ('0)
      ) u_copy_q (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (1'b0),
        .wr_en_i   (accept || finish),
        .wr_data_i (accept),
        .data_o    (copy_q)
      );

      // Egress mask and frame length load together on accept and hold until
      // the next frame is accepted.
      es_mems_reg_bank #(
        .WIDTH       (NUM_PORTS),
        .DEPTH       (1),
        .RESET_VALUE ('0)
      ) u_mask_q (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (1'b0),
        .wr_en_i   (accept),
        .wr_data_i (i_pkg[gp*LW + MASK_LSB +: NUM_PORTS]),
        .data_o    (mask_q)
      );

      es_mems_reg_bank #(
        .WIDTH       (SW_LEN_W),
        .DEPTH       (1),
        .RESET_VALUE ('0)
      ) u_len_q (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (1'b0),
        .wr_en_i   (accept),
        .wr_data_i (i_pkg[gp*LW +: SW_LEN_W]),
        .data_o    (len_q)
      );

      // Byte index within the frame: cleared on accept and on finish,
      // advanced on every granted copy clock.
      assign idx_ena = accept || finish || grant[gp];
      es_mems_reg_bank #(
        .WIDTH       (IDX_W),
        .DEPTH       (1),
        .RESET_VALUE ('0)
      ) u_idx_q (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (1'b0),
        .wr_en_i   (idx_ena),
        .wr_data_i ((accept || finish) ? '0 : (idx_q + IDX_W'(1))),
        .data_o    (idx_q)
      );
    end
  endgenerate

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_want
      assign want[gp] = copy[gp] && !buf_empty[gp] &&
          dests_ready(mask_flat[gp*NUM_PORTS +: NUM_PORTS], tx_ready);
    end
  endgenerate

  generate
    for (gq = 0; gq < NUM_PORTS; gq++) begin : g_arb_dst
      for (gp = 0; gp < NUM_PORTS; gp++) begin : g_arb_src
        assign req_mat[gq*NUM_PORTS + gp] =
            want[gp] && mask_flat[gp*NUM_PORTS + gq];
      end
      assign any_req[gq] = |req_mat[gq*NUM_PORTS +: NUM_PORTS];
      assign sel_idx[gq*PW +: PW] =
          pick_idx(req_mat[gq*NUM_PORTS +: NUM_PORTS]);
    end
  endgenerate

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_grant
      assign grant[gp] = want[gp] &&
          won_all(mask_flat[gp*NUM_PORTS +: NUM_PORTS], PW'(gp), sel_idx);
    end
  endgenerate

  generate
    for (gq = 0; gq < NUM_PORTS; gq++) begin : g_tx
      logic [PW-1:0] s;
      assign s = sel_idx[gq*PW +: PW];
      // The selected engine must itself have been granted; otherwise an
      // engine that lost arbitration elsewhere would inject a byte here.
      assign tx_wr_en[gq]      = any_req[gq] && grant[s];
      assign tx_wr_data[gq*8 +: 8] = buf_rd_data[s*8 +: 8];
      assign tx_wr_sof[gq]     = any_req[gq] && grant[s] &&
                                 (idx_flat[s*IDX_W +: IDX_W] == '0);
      assign tx_wr_eof[gq]     = any_req[gq] && grant[s] &&
                                 (idx_flat[s*IDX_W +: IDX_W] ==
                                  IDX_W'(len_flat[s*SW_LEN_W +: SW_LEN_W] -
                                         SW_LEN_W'(1)));
    end
  endgenerate

endmodule : es_switch_tx_writer

`default_nettype wire

`endif  // ES_SWITCH_TX_WRITER_SV
