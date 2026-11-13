// ============================================================================
//  File        : es_switch_pl_defs.sv
//  Description : Compilation-unit declarations for the staged switch pipeline.
//
//                Why a separate library
//                ----------------------
//                The pipeline levels exchange a descriptor, not a struct:
//                yosys rejects package items in port ranges and has no
//                implementation for `import` (AGENTS.md 2.1).  Field offsets
//                are therefore functions over `NUM_PORTS`, evaluated into a
//                `localparam` at each module, exactly as the legacy
//                `sw_tag_*_lsb()` helpers did.  A caller writes
//
//                    localparam int unsigned DESC_DST =
//                        sw_pl_desc_dstm_lsb(NUM_PORTS);
//                    ... desc[DESC_DST +: 48] ...
//
//                This file is included BEFORE switch/es_switch_defs.sv, inside
//                the two declaration-only Verilator waivers opened by
//                es_defs.sv.  A declaration that a given top does not read yet
//                is normal for a shared library and must not fail `make lint`;
//                es_switch_defs.sv closes the waivers at its end.  The library
//                only depends on `SW_LEN_W` (es_defs.sv) and `sw_port_w()`
//                (common/es_common_defs.sv), both visible at this point.
//
//                No function here uses `return`: yosys rejects it in any
//                scope.  Assign to the function name instead (AGENTS.md 2.1).
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_PL_DEFS_SV
`define ES_SWITCH_PL_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  Byte-stream contract between a MAC adapter and the switch core
// ============================================================================
// One octet per handshake.  Sideband travels in the same packed word so a
// pipe_stage can carry the whole boundary with one instance.  The switch core
// sees MAC client data only: no preamble, no SFD, no FCS.
localparam int unsigned SW_PL_BYTE_W = 8;
localparam int unsigned SW_PL_BS_W   = SW_PL_BYTE_W + 3;  // {err, eof, sof, data}

localparam int unsigned SW_PL_BS_DATA_LSB = 0;
localparam int unsigned SW_PL_BS_SOF_LSB  = SW_PL_BYTE_W;
localparam int unsigned SW_PL_BS_EOF_LSB  = SW_PL_BYTE_W + 1;
localparam int unsigned SW_PL_BS_ERR_LSB  = SW_PL_BYTE_W + 2;

/// Preamble octet and start-of-frame delimiter.  The MAC adapter hunts for
/// seven of the former followed by the latter; a broken run produces no bytes
/// at all rather than a partial frame (see es_mac_frame_rx.sv).
localparam logic [7:0] SW_PL_PREAMBLE_OCTET = 8'h55;
localparam logic [7:0] SW_PL_SFD_OCTET      = 8'hD5;

// ============================================================================
// 2.  Pipeline level identifiers (documentation and test labels)
// ============================================================================
localparam int unsigned SW_PL_STAGE_RX     = 0;  ///< S0/S1 receive + frame buffer
localparam int unsigned SW_PL_STAGE_CAM    = 2;  ///< S2 lookup + learn
localparam int unsigned SW_PL_STAGE_DECIDE = 3;  ///< S3 egress mask
localparam int unsigned SW_PL_STAGE_WRITE  = 4;  ///< S4 frame copy engines
localparam int unsigned SW_PL_STAGE_TX     = 5;  ///< S5 per-port TX queue

/// Default inter-stage register depth, overridable per level.
localparam int unsigned SW_PL_DEFAULT_DP = 1;

// ============================================================================
// 3.  Frame descriptor layout
// ============================================================================
// Width of the occupancy/free counter of an es_mems_sync_fifo with the given
// DEPTH.  It has to be callable directly in a port range, exactly like
// sw_port_w(): a module's own localparam is declared too late for that.
function automatic int unsigned sw_pl_fifo_cnt_w(input int unsigned depth);
  sw_pl_fifo_cnt_w = ((depth <= 2) ? 1 : $clog2(depth)) + 1;
endfunction

// Descriptor = {dst_mac, src_mac, len, src_port}, LSB-first order as listed
// below.  `len` counts MAC client octets (preamble and FCS excluded).  The
// frame bytes themselves live in a per-port FIFO, so no slot id is needed:
// descriptors and frames are consumed in the same order (AGENTS.md: a
// run-time-indexed unpacked array would silently return stale data in Icarus).
function automatic int unsigned sw_pl_desc_w(input int unsigned nports);
  sw_pl_desc_w = 48 + 48 + SW_LEN_W + sw_port_w(nports);
endfunction

function automatic int unsigned sw_pl_desc_len_lsb(input int unsigned nports);
  sw_pl_desc_len_lsb = sw_port_w(nports);
endfunction

function automatic int unsigned sw_pl_desc_srcm_lsb(input int unsigned nports);
  sw_pl_desc_srcm_lsb = sw_port_w(nports) + SW_LEN_W;
endfunction

function automatic int unsigned sw_pl_desc_dstm_lsb(input int unsigned nports);
  sw_pl_desc_dstm_lsb = sw_port_w(nports) + SW_LEN_W + 48;
endfunction

// ============================================================================
// 4.  CAM-level and decide-level packages
// ============================================================================
/// CAM level appends {hit, port_onehot} to the descriptor.
function automatic int unsigned sw_pl_cam_w(input int unsigned nports);
  sw_pl_cam_w = sw_pl_desc_w(nports) + 1 + nports;
endfunction

function automatic int unsigned sw_pl_cam_hit_lsb(input int unsigned nports);
  sw_pl_cam_hit_lsb = sw_pl_desc_w(nports);
endfunction

function automatic int unsigned sw_pl_cam_port_lsb(input int unsigned nports);
  sw_pl_cam_port_lsb = sw_pl_desc_w(nports) + 1;
endfunction

/// Decide level appends the egress mask to the descriptor.
function automatic int unsigned sw_pl_dec_w(input int unsigned nports);
  sw_pl_dec_w = sw_pl_desc_w(nports) + nports;
endfunction

function automatic int unsigned sw_pl_dec_mask_lsb(input int unsigned nports);
  sw_pl_dec_mask_lsb = sw_pl_desc_w(nports);
endfunction

// ============================================================================
// 5.  Default geometry for the synthesis front end
// ============================================================================
// `make synth` and LibreLane both define SYNTHESIS.  A full-size frame buffer
// (4 ports x 2048 bytes x 8 = 131072 flops) makes yosys' `synth -flatten`
// take tens of minutes, far beyond a CI lint job; the gate only has to prove
// that the frontend can read and elaborate the design.  It therefore uses the
// same reduced geometry as librelane/config.json.  Simulations (SYNTHESIS
// undefined) keep the full defaults, so no behavioural test is weakened.
`ifdef SYNTHESIS
localparam int unsigned SW_PL_DEF_MIN_FRAME_LEN   = 64;
localparam int unsigned SW_PL_DEF_MAX_FRAME_LEN   = 256;
localparam int unsigned SW_PL_DEF_SLOTS          = 1;
localparam int unsigned SW_PL_DEF_SLOT_BYTES     = 512;
localparam int unsigned SW_PL_DEF_DESC_DEPTH     = 8;
localparam int unsigned SW_PL_DEF_TX_QUEUE_DEPTH = 64;
localparam int unsigned SW_PL_DEF_CAM_SETS       = 16;
localparam int unsigned SW_PL_DEF_CAM_WAYS       = 2;
`else
localparam int unsigned SW_PL_DEF_MIN_FRAME_LEN   = 64;
localparam int unsigned SW_PL_DEF_MAX_FRAME_LEN   = 1518;
localparam int unsigned SW_PL_DEF_SLOTS          = 2;
localparam int unsigned SW_PL_DEF_SLOT_BYTES     = 2048;
localparam int unsigned SW_PL_DEF_DESC_DEPTH     = 8;
localparam int unsigned SW_PL_DEF_TX_QUEUE_DEPTH = 256;
localparam int unsigned SW_PL_DEF_CAM_SETS       = 128;
localparam int unsigned SW_PL_DEF_CAM_WAYS       = 4;
`endif

`default_nettype wire

`endif  // ES_SWITCH_PL_DEFS_SV
