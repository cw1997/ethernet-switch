// ============================================================================
//  File        : es_switch_rx_engine.sv
//  Description : S0/S1 receive level of the staged switch - one instance per
//                ingress port.  Structural stage wrapper: it joins the control
//                slice (es_switch_rx_ctrl: FSM, admission, octet count,
//                verdict latch), the header slice (es_switch_rx_parse), the
//                combinational verdict (es_switch_rx_check) and the frame
//                buffer (es_switch_frame_buf) into the per-port stage.  The
//                wrapper itself holds no state - all registers live in the
//                slices as es_mems_reg_bank instances (AGENTS.md,
//                switch-domain style).
//
//                Frame-level atomicity
//                ---------------------
//                A frame is admitted only when the byte FIFO can hold a whole
//                maximum-length frame and the descriptor FIFO has a slot.
//                Once admitted, `b_ready_o` never drops mid-frame, so a
//                valid/ready handshake can never lose a byte.  A corrupt,
//                runt, over-MTU or otherwise malformed frame is removed with a
//                single rewind of the byte FIFO's write pointer and produces
//                NO descriptor; the CAM and egress levels therefore cannot see
//                a frame that should have been dropped.
//
//                The eight rejection classes live in es_switch_rx_check.  FCS
//                itself is checked once, in the MAC adapter; this level only
//                consumes the verdict, so the CRC LFSR is never instantiated
//                twice on the same bytes.
//
//                MIN_FRAME_LEN / MAX_FRAME_LEN count MAC client octets
//                (preamble/SFD and FCS excluded), matching tb_build_frame's
//                `total_len`.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_RX_ENGINE_SV
`define ES_SWITCH_RX_ENGINE_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_rx_engine #(
  parameter int unsigned   NUM_PORTS     = 4,
  parameter int unsigned   PORT_ID       = 0,
  parameter logic [47:0]   PORT_MAC      = '0,
  parameter int unsigned   MIN_FRAME_LEN = 64,
  parameter int unsigned   MAX_FRAME_LEN = 1518,
  parameter int unsigned   SLOTS         = 2,
  parameter int unsigned   SLOT_BYTES    = 2048,
  parameter int unsigned   DESC_DEPTH    = 8
) (
  input  var logic clk_i,
  input  var logic rst_ni,

  // ---- 8-bit byte stream from the MAC adapter ---------------------------
  input  var logic       b_valid_i,
  output      logic      b_ready_o,
  input  var logic [7:0] b_data_i,
  input  var logic       b_sof_i,
  input  var logic       b_eof_i,
  input  var logic       b_err_i,

  // ---- descriptor read port (FWFT, driven by the CAM stage) -------------
  output      logic                dvalid_o,
  input  var logic                 drd_i,
  output      logic [sw_pl_desc_w(NUM_PORTS)-1:0] dout_o,

  // ---- byte read port (FWFT, driven by the TX writer) -------------------
  input  var logic                 brd_i,
  output      logic [7:0]          bout_o,
  output      logic                bempty_o
);

  localparam int unsigned PW          = sw_port_w(NUM_PORTS);
  localparam int unsigned DESC_W      = sw_pl_desc_w(NUM_PORTS);
  localparam int unsigned OCTW        = SW_LEN_W + 1;
  localparam int unsigned BYTE_CNT_W  = sw_pl_fifo_cnt_w(SLOTS*SLOT_BYTES);

  // --------------------------------------------------------------------------
  // Slice interconnect
  // --------------------------------------------------------------------------
  logic [47:0] own_mac;

  logic            wr_en;         // ctrl -> frame_buf byte write
  logic            wfull;         // frame_buf -> ctrl / admission
  logic [BYTE_CNT_W-1:0] wfree;
  logic            undo, commit;  // ctrl -> frame_buf
  logic [OCTW-1:0] undo_cnt_wide; // ctrl -> engine (truncated below)
  logic [BYTE_CNT_W-1:0] undo_cnt;
  logic [DESC_W-1:0] commit_desc;
  logic            dfull;
  logic [sw_pl_fifo_cnt_w(DESC_DEPTH)-1:0] dfree;

  logic            admit;         // engine -> ctrl admission decision
  logic            byte_fire;     // ctrl -> parse per-byte strobe
  logic            hdr_clr;       // ctrl -> parse commit clear

  logic [SW_LEN_W:0] oct_cnt_q, oct_cnt_d;  // ctrl -> parse / check
  logic              err_d;                 // ctrl -> check
  logic              eof_bad;               // check -> ctrl verdict

  logic [47:0] dst_q, src_q;      // parse held fields -> descriptor
  logic [47:0] dst_d, src_d;      // parse next fields -> check
  logic [15:0] l2type_d;
  logic        vlan_d;

  // A zero PORT_MAC means "derive the usual locally administered address".
  // A continuous assignment, not a combinational process: every input is an
  // elaboration-time constant, and Icarus warns about a combinational process
  // with an empty sensitivity list (and may leave its output uninitialised).
  assign own_mac = (PORT_MAC == '0) ? sw_default_mac(PORT_ID) : PORT_MAC;

  assign admit = !wfull && !dfull &&
                 (wfree >= BYTE_CNT_W'(MAX_FRAME_LEN)) &&
                 (dfree != '0);

  // The descriptor is built from the final header registers on the commit
  // clock.  The len cast is safe: MAX_FRAME_LEN < 2**SW_LEN_W is checked below.
  assign commit_desc = {dst_q, src_q, SW_LEN_W'(oct_cnt_q), PW'(PORT_ID)};

  // Only oct_cnt_q bytes were written; the cast is a deliberate truncation
  // because MAX_FRAME_LEN < SLOTS*SLOT_BYTES is checked at elaboration.
  assign undo_cnt = BYTE_CNT_W'(undo_cnt_wide);

  // --------------------------------------------------------------------------
  // Control slice: FSM, admission, octet count, verdict latch
  // --------------------------------------------------------------------------
  es_switch_rx_ctrl #(
    .MAX_FRAME_LEN (MAX_FRAME_LEN)
  ) u_ctrl (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .b_valid_i   (b_valid_i),
    .b_sof_i     (b_sof_i),
    .b_eof_i     (b_eof_i),
    .b_err_i     (b_err_i),
    .b_ready_o   (b_ready_o),
    .admit_i     (admit),
    .wfull_i     (wfull),
    .eof_bad_i   (eof_bad),
    .byte_fire_o (byte_fire),
    .hdr_clr_o   (hdr_clr),
    .oct_cnt_o   (oct_cnt_q),
    .oct_cnt_d_o (oct_cnt_d),
    .err_d_o     (err_d),
    .wr_en_o     (wr_en),
    .undo_o      (undo),
    .undo_cnt_o  (undo_cnt_wide),
    .commit_o    (commit)
  );

  // --------------------------------------------------------------------------
  // Header slice: dst / src / length-type / VLAN latch
  // --------------------------------------------------------------------------
  es_switch_rx_parse u_parse (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .byte_fire_i (byte_fire),
    .oct_cnt_i   (oct_cnt_q),
    .b_data_i    (b_data_i),
    .clear_i     (hdr_clr),
    .dst_q_o     (dst_q),
    .src_q_o     (src_q),
    .dst_d_o     (dst_d),
    .src_d_o     (src_d),
    .l2type_d_o  (l2type_d),
    .vlan_d_o    (vlan_d)
  );

  // --------------------------------------------------------------------------
  // Combinational verdict: the eight malformed-frame checks
  // --------------------------------------------------------------------------
  es_switch_rx_check #(
    .MIN_FRAME_LEN (MIN_FRAME_LEN),
    .MAX_FRAME_LEN (MAX_FRAME_LEN)
  ) u_check (
    .oct_cnt_i (oct_cnt_d),
    .err_i     (err_d),
    .dst_i     (dst_d),
    .src_i     (src_d),
    .l2type_i  (l2type_d),
    .vlan_i    (vlan_d),
    .own_mac_i (own_mac),
    .bad_o     (eof_bad)
  );

`ifndef SYNTHESIS
  initial begin
    if (PORT_ID >= NUM_PORTS)
      $error("es_switch_rx_engine: PORT_ID out of range");
    if (MAX_FRAME_LEN >= (1 << SW_LEN_W))
      $error("es_switch_rx_engine: MAX_FRAME_LEN does not fit SW_LEN_W");
    if (MIN_FRAME_LEN < SW_HDR_LEN)
      $error("es_switch_rx_engine: MIN_FRAME_LEN below the header size");
  end
`endif

  // --------------------------------------------------------------------------
  // Frame buffer: byte FIFO + descriptor FIFO, both FWFT.
  // --------------------------------------------------------------------------
  es_switch_frame_buf #(
    .SLOTS      (SLOTS),
    .SLOT_BYTES (SLOT_BYTES),
    .DESC_DEPTH (DESC_DEPTH),
    .DESC_W     (DESC_W)
  ) u_buf (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .wr_en_i       (wr_en),
    .wr_data_i     (b_data_i),
    .wfull_o       (wfull),
    .wfree_o       (wfree),
    .undo_i        (undo),
    .undo_cnt_i    (undo_cnt),
    .commit_i      (commit),
    .commit_desc_i (commit_desc),
    .dfull_o       (dfull),
    .dfree_o       (dfree),
    .dvalid_o      (dvalid_o),
    .drd_i         (drd_i),
    .dout_o        (dout_o),
    .brd_i         (brd_i),
    .bout_o        (bout_o),
    .bempty_o      (bempty_o)
  );

endmodule : es_switch_rx_engine

`default_nettype wire

`endif  // ES_SWITCH_RX_ENGINE_SV
