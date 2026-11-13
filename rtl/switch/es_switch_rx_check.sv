// ============================================================================
//  File        : es_switch_rx_check.sv
//  Description : The eight malformed-frame checks of the S0/S1 receive level,
//                as one purely combinational verdict - no state, no registers.
//
//                es_switch_rx_ctrl consults `bad_o` on the eof clock, when
//                oct_cnt_i / err_i / dst_i / src_i / l2type_i / vlan_i carry
//                the NEXT values that the single-process form this was split
//                from checked (`oct_cnt_n`, `err_n` and the just-latched
//                header).  A frame is bad if ANY check fails; the ctrl slice
//                turns that into the sticky verdict which rewinds the byte
//                FIFO and suppresses the descriptor.
//
//                The eight rejection classes are: 1. bad FCS / RX_ER /
//                truncation (`err_i`), 2. runt, 3. over MTU, 4. 802.3
//                length-field mismatch, 5. truncated VLAN tag, 6. group
//                (multicast / broadcast) source address, and 7/8. either
//                address matching this port's own MAC.  FCS itself is checked
//                once, in the MAC adapter; this module only consumes the
//                verdict, so the CRC LFSR is never instantiated twice on the
//                same bytes.
//
//                MIN_FRAME_LEN / MAX_FRAME_LEN count MAC client octets
//                (preamble/SFD and FCS excluded), matching tb_build_frame's
//                `total_len`.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_RX_CHECK_SV
`define ES_SWITCH_RX_CHECK_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_rx_check #(
  /// Smallest accepted MAC client frame in octets (the runt check).
  parameter int unsigned MIN_FRAME_LEN = 64,
  /// Largest accepted MAC client frame in octets (the over-MTU check).
  parameter int unsigned MAX_FRAME_LEN = 1518
) (
  input  var logic [SW_LEN_W:0] oct_cnt_i,  ///< next octet count (valid at eof)
  input  var logic              err_i,      ///< next error accumulator
  input  var logic [47:0]       dst_i,      ///< next latched destination MAC
  input  var logic [47:0]       src_i,      ///< next latched source MAC
  input  var logic [15:0]       l2type_i,   ///< next latched length/type field
  input  var logic              vlan_i,     ///< next VLAN flag
  input  var logic [47:0]       own_mac_i,  ///< this port's own address
  output      logic             bad_o       ///< asserted when any check fails
);

  localparam int unsigned OCTW = SW_LEN_W + 1;

  assign bad_o =
      // 1. FCS / RX_ER / truncation verdict from the MAC adapter.
      err_i ||
      // 2. runt.
      (oct_cnt_i < OCTW'(MIN_FRAME_LEN)) ||
      // 3. oversize (also caught by ctrl's over-MTU drain mid-frame, but a
      //    one-byte-over frame ends here).
      (oct_cnt_i > OCTW'(MAX_FRAME_LEN)) ||
      // 4. 802.3 length field disagrees with the measured client length.
      //    The cast of l2type_i is a deliberate truncation: the field only
      //    matters here when sw_is_8023_length() is true, and a length field
      //    is at most 1500, far below 2**SW_LEN_W.
      (!vlan_i && sw_is_8023_length(l2type_i) &&
       (oct_cnt_i != (OCTW'(SW_HDR_LEN) + OCTW'(l2type_i)))) ||
      // 5. VLAN tag truncated before the inner EtherType.
      (vlan_i && (oct_cnt_i < OCTW'(SW_HDR_LEN_VLAN))) ||
      // 6. group (multicast / broadcast) source address.
      !sw_is_unicast(src_i) ||
      // 7/8. either address belongs to this port itself.
      (src_i == own_mac_i) || (dst_i == own_mac_i);

endmodule : es_switch_rx_check

`default_nettype wire

`endif  // ES_SWITCH_RX_CHECK_SV
