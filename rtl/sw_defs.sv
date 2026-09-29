// ============================================================================
//  File        : sw_defs.sv
//  Description : Shared declarations for the parameterised Ethernet Layer-2
//                switch core: protocol constants, the link-speed model, the
//                frame-descriptor ("tag") bit layout and the statistics
//                register map.
//
//                Everything that must stay consistent between the receive path,
//                the switching fabric, the transmit path and the address table
//                lives here, so the modules can be elaborated independently of
//                each other.  Keeping a single copy of these definitions is what
//                makes the design portable across the whole tool flow.
//
//  ---------------------------------------------------------------------------
//  Why these declarations are at *compilation-unit* scope and not in a package
//  ---------------------------------------------------------------------------
//  This is the one structural decision in the design that is dictated by the
//  tools rather than by taste, so it is worth spelling out.
//
//  A SystemVerilog `package` is the natural home for shared declarations, and
//  this file used to be one (`sw_switch_pkg`).  It does not survive the
//  synthesis flow, because the frontend that OpenLane / LibreLane drive for
//  synthesis (yosys, through `read_verilog -sv`) is much more restricted than
//  the simulators, and it fails in three separate places:
//
//    1. Port declarations.  A package item is not a *constant range* as far as
//       the frontend is concerned, so a width taken from the package is
//       rejected before the body is even looked at:
//
//           rtl/sw_gmii_tx.sv:89: ERROR: Non-constant range in declaration of
//           \fr_len_i
//
//       Promoting the width to a module *parameter* does not help: a package
//       localparam in a parameter default fails the same way, and so does a
//       package function call.
//
//    2. Function calls.  A call to a package function has to be explicitly
//       scoped (`pkg::f(x)`).  An unscoped call is not resolved at all:
//
//           ERROR: Can't resolve function name `\sw_is_broadcast'
//
//       Scoping every call would work, but it puts a `sw_switch_pkg::` prefix
//       on roughly forty call sites and makes the package mandatory again.
//
//    3. Package imports.  Neither the module-header form
//       (`module X import pkg::*; (...)`) nor the in-body form
//       (`import pkg::*;`) nor the file-scope form is accepted; the parse dies
//       on the `import` token with a message that points at the module keyword
//       rather than at the import.
//
//  Declarations at compilation-unit scope have none of these restrictions: the
//  frontend makes them visible to every module, in parameter lists, in port
//  ranges, in bodies and in task/function argument lists alike.  That is why
//  this file is *not* wrapped in a `package`, why every RTL file `` `include``s
//  it, and why no RTL file needs an import at all.
//
//  Icarus Verilog and Verilator accept this form unchanged, and the regression
//  testbenches see the same names because they are compiled into the same
//  compilation unit as the RTL.
//
//  ---------------------------------------------------------------------------
//  Why there is no `return` in any function
//  ---------------------------------------------------------------------------
//  The same frontend rejects `return` in *any* function, in package scope and
//  in module scope alike, and with or without an enclosing `case` or `begin`:
//
//      sw_rx_port.sv:171: ERROR: syntax error, unexpected TOK_ID
//
//  Icarus and Verilator both accept it, so the failure only appears once the
//  design is handed to the flow - at the very first step, with a message that
//  points at the `return` token rather than at anything semantically wrong.
//  Every function below therefore assigns to the function name, which IEEE
//  1800-2017 13.3 defines as equivalent and which every tool in the flow
//  accepts.
//
//  Language    : SystemVerilog (IEEE 1800-2017)
//  Tooling     : Lint/simulate with Verilator 5.x and Icarus Verilog 12+
//                (`-g2012`).  Synthesise with any IEEE 1800 capable tool.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_DEFS_SV
`define SW_DEFS_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

// This is a shared declaration library, not a module: no constant or helper
// below is referenced by every file that includes it.  Waive the two warnings
// that report exactly that situation so that every other check can stay
// enabled.
`ifdef VERILATOR
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
`endif

// ============================================================================
// 1.  Link speed model
// ============================================================================
// The switch core is fully synchronous to a single `clk_i`.  The three
// Ethernet line rates are therefore handled with *clock enables* (octet
// strobes) instead of with multiple clock domains, which keeps the whole
// design free of clock-domain crossings.
//
// A port only needs one elaboration-time constant: BYTE_PERIOD, the number of
// `clk_i` cycles that make up one GMII octet time.
//
//                  octet rate   BYTE_PERIOD @125 MHz
//     10 Mbit/s      2.5 MHz          100
//    100 Mbit/s     25   MHz           10
//   1000 Mbit/s    125   MHz            1
typedef enum logic [1:0] {
  SW_SPEED_10M   = 2'd0,  ///< 10 Mbit/s    (10BASE-T)
  SW_SPEED_100M  = 2'd1,  ///< 100 Mbit/s   (100BASE-TX)
  SW_SPEED_1000M = 2'd2,  ///< 1000 Mbit/s  (1000BASE-T / GMII)
  SW_SPEED_NONE  = 2'd3   ///< port administratively down
} sw_speed_e;

/// Nominal line rate in bit/s for a link speed.  Used by the byte-period
/// helper below; a down port reports 1 so that the division never degenerates.
function automatic int unsigned sw_speed_baud(input sw_speed_e speed);
  int unsigned baud;
  begin
    baud = 1;
    case (speed)
      SW_SPEED_10M  : baud = 10000000;
      SW_SPEED_100M : baud = 100000000;
      SW_SPEED_1000M: baud = 1000000000;
      default       : baud = 1;
    endcase
    sw_speed_baud = baud;
  end
endfunction

/// Number of `clk_i` cycles that make up one GMII octet time.
///
///   period = clk_freq_hz * 8 / baud        (rounded to nearest, min 1)
///
/// For the canonical 125 MHz core clock this yields 1 (1000BASE-T, full line
/// rate), 10 (100BASE-TX) and 100 (10BASE-T).  A slower core clock simply
/// stretches the period - the datapath itself never changes, because it is
/// driven exclusively by the resulting clock enable.
function automatic int unsigned sw_byte_period(
    input int unsigned clk_freq_hz,
    input sw_speed_e  speed);
  int unsigned baud;
  int unsigned period;
  begin
    baud    = sw_speed_baud(speed);
    period  = (clk_freq_hz * 8 + (baud / 2)) / baud;
    // A down port (baud == 1) and a very slow clock both have to yield a
    // usable, non-zero period; the octet enable is then simply very slow.
    sw_byte_period = (period == 0) ? 1 : period;
  end
endfunction

// ============================================================================
// 2.  Frame geometry (octets; the FCS is excluded unless stated otherwise)
// ============================================================================
localparam int unsigned SW_HDR_LEN        = 14;   ///< dst MAC + src MAC + EtherType
localparam int unsigned SW_HDR_LEN_VLAN   = 18;   ///< 802.1Q tagged header
localparam int unsigned SW_FCS_LEN        = 4;    ///< Ethernet FCS (CRC-32)
localparam int unsigned SW_MIN_FRAME_LEN  = 64;   ///< 802.3 minimum frame size
localparam int unsigned SW_MAX_FRAME_LEN  = 1518; ///< 802.3 maximum frame size
localparam int unsigned SW_MIN_PAYLOAD    = 46;   ///< minimum MAC client data
localparam int unsigned SW_MAX_ETHERTYPE  = 1500; ///< largest legal 802.3 length
localparam int unsigned SW_PREAMBLE_LEN   = 8;    ///< 7 x 0x55 + 1 x 0xD5
localparam int unsigned SW_IFG_OCTETS     = 12;   ///< minimum inter-frame gap

/// Number of octets carried by one 64-bit beat of the switching datapath.
localparam int unsigned SW_BEAT_BYTES = 8;

/// Bit width of a frame length field: 11 bits covers 2047 octets, i.e. any
/// frame up to MAX_FRAME_LEN = 1518 plus headroom.
localparam int unsigned SW_LEN_W = 11;

// ============================================================================
// 3.  EtherType values recognised by the receive parser
// ============================================================================
localparam logic [15:0] SW_ETHERTYPE_IPV4  = 16'h0800;
localparam logic [15:0] SW_ETHERTYPE_ARP   = 16'h0806;
localparam logic [15:0] SW_ETHERTYPE_VLAN  = 16'h8100; ///< 802.1Q customer tag
localparam logic [15:0] SW_ETHERTYPE_QINQ  = 16'h88A8; ///< 802.1ad service tag
localparam logic [15:0] SW_ETHERTYPE_IPV6  = 16'h86DD;

/// True when the length/EtherType field carries an 802.1Q / 802.1ad tag, which
/// pushes the real EtherType four octets further into the header.
function automatic logic sw_is_vlan_type(input logic [15:0] l2type);
  sw_is_vlan_type = (l2type == SW_ETHERTYPE_VLAN) ||
                    (l2type == SW_ETHERTYPE_QINQ);
endfunction

/// True when the second header word carries an 802.3 *length* rather than an
/// EtherType.  A length field is the only case in which the frame size is
/// known before the frame has been received; every EtherType frame has to be
/// measured on the wire instead.
function automatic logic sw_is_8023_length(input logic [15:0] l2type);
  sw_is_8023_length = (l2type <= SW_MAX_ETHERTYPE[15:0]);
endfunction

// ============================================================================
// 4.  Ethernet CRC-32 (IEEE 802.3 clause 4.1)
// ============================================================================
//  * `SW_CRC32_POLY` is the *reflected* form of the generator 0x04C11DB7, which
//    is what the byte-at-a-time implementation in sw_crc32 uses.
//  * The transmitter seeds the LFSR with all ones and applies a final XOR
//    before appending the resulting value as the FCS, least significant
//    octet first.
//  * The receiver runs the identical LFSR over the received octets
//    *including* the received FCS and compares the leftover value with
//    `SW_CRC32_RESIDUE`.  That residue is a property of the polynomial, so one
//    comparison validates the whole frame.
//
//  Residue: the textbook "magic residue" 0xC704DD1B belongs to the MSB-first
//  (non-reflected) formulation of the polynomial.  This design uses the
//  reflected LFSR, whose registers carry the bit-reversed residue
//  reverse32(0xC704DD1B) = 0xDEBB20E3.  Using the non-reflected constant with
//  a reflected LFSR would reject every valid frame, which is exactly the kind
//  of mismatch `sw_crc32_tb` is there to catch.
localparam logic [31:0] SW_CRC32_POLY    = 32'hEDB8_8320;
localparam logic [31:0] SW_CRC32_INIT    = 32'hFFFF_FFFF;
localparam logic [31:0] SW_CRC32_XOROUT  = 32'hFFFF_FFFF;
/// Residue of a valid frame in the *reflected* domain (see the note above).
localparam logic [31:0] SW_CRC32_RESIDUE = 32'hDEBB_20E3;

/// One reflected bit step of the CRC-32 LFSR, as the receiver and transmitter
/// both use it.  Provided so the residue above can be re-derived and checked
/// rather than taken on trust.
function automatic logic [31:0] sw_crc32_bit(
    input logic [31:0] c,
    input logic        b);
  sw_crc32_bit = (c[0] ^ b) ? ((c >> 1) ^ SW_CRC32_POLY) : (c >> 1);
endfunction

/// Absorb one octet into the LFSR, least significant bit first.
function automatic logic [31:0] sw_crc32_absorb_octet(
    input logic [31:0] c,
    input logic [7:0]  d);
  logic [31:0] x;
  x = c;
  for (int unsigned i = 0; i < 8; i++) x = sw_crc32_bit(x, d[i]);
  sw_crc32_absorb_octet = x;
endfunction

/// Compute the residue of a valid frame from the polynomial: seed with all
/// ones, absorb a message, append its complemented value as the FCS, and
/// report what is left.  Provided so that `SW_CRC32_RESIDUE` can be
/// re-derived and checked rather than taken on trust.
function automatic logic [31:0] sw_crc32_residue();
  logic [31:0] c;
  logic [31:0] fcs;
  logic [31:0] x;
  c   = sw_crc32_absorb_octet(SW_CRC32_INIT, 8'h00);
  fcs = c ^ SW_CRC32_XOROUT;
  x   = sw_crc32_absorb_octet(c, fcs[7:0]);
  x   = sw_crc32_absorb_octet(x, fcs[15:8]);
  x   = sw_crc32_absorb_octet(x, fcs[23:16]);
  x   = sw_crc32_absorb_octet(x, fcs[31:24]);
  sw_crc32_residue = x;
endfunction

// ============================================================================
// 5.  Address helpers
// ============================================================================
//  An address is held with the first transmitted octet in the most significant
//  byte, so `mac[47:40]` is the first octet on the wire.
//
//  The individual/group (I/G) bit is the *least significant* bit of that first
//  octet, i.e. bit 40 of the 48-bit value: 0 = individual (unicast) address,
//  1 = group (multicast / broadcast) address.  Getting this bit wrong makes
//  every unicast address look like a group address, which silently disables
//  source-address learning and turns the switch into a flooding hub.
typedef logic [47:0] sw_mac_t;

/// Position of the I/G bit within `sw_mac_t`.
localparam int SW_MAC_IG_BIT = 40;

localparam sw_mac_t SW_MAC_BROADCAST = 48'hFF_FF_FF_FF_FF_FF;
localparam sw_mac_t SW_MAC_NULL      = 48'h00_00_00_00_00_00;

/// True for the reserved all-ones broadcast address.
function automatic logic sw_is_broadcast(input sw_mac_t mac);
  sw_is_broadcast = (mac == SW_MAC_BROADCAST);
endfunction

/// True for a group (multicast) address.  The all-zero address is excluded
/// because it is neither a valid source nor a valid destination.
function automatic logic sw_is_group(input sw_mac_t mac);
  sw_is_group = (mac[SW_MAC_IG_BIT] == 1'b1) && (mac != SW_MAC_NULL);
endfunction

/// True for an individually addressed (unicast) address.
function automatic logic sw_is_unicast(input sw_mac_t mac);
  sw_is_unicast = (mac[SW_MAC_IG_BIT] == 1'b0);
endfunction

/// Locally administered (02:...) unicast address derived from a port index.
/// Used as the default address of a port that was left unassigned.
function automatic sw_mac_t sw_default_mac(input int unsigned idx);
  sw_default_mac = 48'h02_00_00_00_00_00 | 48'(idx);
endfunction

// ============================================================================
// 6.  Unknown-unicast / group-address flooding policy
// ============================================================================
typedef enum logic [1:0] {
  SW_FLOOD_BCAST_ONLY = 2'd0, ///< forward only dst == ff:ff:ff:ff:ff:ff
  SW_FLOOD_BCAST_UKN  = 2'd1,  ///< also flood unicast addresses that miss
  SW_FLOOD_ALL        = 2'd2   ///< also flood unknown group addresses
} sw_flood_mode_e;

// ============================================================================
// 7.  Frame-descriptor ("tag") field layout
// ============================================================================
// Every buffered frame is described by one tag word that travels alongside the
// payload in a per-port descriptor FIFO.  The field offsets below keep the
// producer (sw_rx_port) and the consumer (sw_arbiter) in lock-step.
//
//   +-------------------------------+  bit TAGW-1
//   |  dst_mask  |  NUM_PORTS bits  |
//   +------------+------------------+
//   |     len    |  11 bits         |
//   +------------+------------------+
//   |     src    |  PW bits         |
//   +------------+------------------+
//   |    flood   |  1 bit           |
//   +------------+------------------+
//   |    drop    |  1 bit           |  bit 0
//   +-------------------------------+
//
// `dst_mask` is the ingress filter's forwarding decision, already frozen when
// the frame was buffered.  It is one-hot for a unicast hit and all-ones
// (minus the ingress port) for a flooded frame.

/// Bits needed to encode a port index in [0, NUM_PORTS).
function automatic int sw_port_w(input int unsigned n);
  sw_port_w = (n > 2) ? $clog2(n) : 1;
endfunction

function automatic int sw_tag_dstm_lsb(input int unsigned n);
  sw_tag_dstm_lsb = 0;
endfunction

function automatic int sw_tag_src_lsb(input int unsigned n);
  sw_tag_src_lsb = n;
endfunction

function automatic int sw_tag_len_lsb(input int unsigned n);
  sw_tag_len_lsb = n + sw_port_w(n);
endfunction

function automatic int sw_tag_flood_lsb(input int unsigned n);
  sw_tag_flood_lsb = sw_tag_len_lsb(n) + SW_LEN_W;
endfunction

function automatic int sw_tag_drop_lsb(input int unsigned n);
  sw_tag_drop_lsb = sw_tag_flood_lsb(n) + 1;
endfunction

/// Total width of a frame descriptor in bits.
function automatic int sw_tag_width(input int unsigned n);
  sw_tag_width = sw_tag_drop_lsb(n) + 1;
endfunction

/// Width of the egress-FIFO free-space counter exposed to the fabric.
function automatic int sw_tx_free_width(input int unsigned depth);
  sw_tx_free_width = (depth <= 2) ? 1 : $clog2(depth);
endfunction

/// Number of 64-bit beats needed to hold a frame of `len` octets.
function automatic int unsigned sw_beats_of(input int unsigned len);
  sw_beats_of = (len + (SW_BEAT_BYTES - 1)) / SW_BEAT_BYTES;
endfunction

// ============================================================================
// 8.  Statistics register map exported on the read-only `stat_o` bus
// ============================================================================
typedef enum int unsigned {
  SW_STAT_RX_FRAMES   = 0,  ///< frames accepted by the receive filter
  SW_STAT_RX_OCTETS   = 1,  ///< octets forwarded into the switching fabric
  SW_STAT_RX_FILTERED = 2,  ///< frames dropped by the ingress filter
  SW_STAT_RX_CRC_ERR  = 3,  ///< frames failing the FCS check
  SW_STAT_RX_RUNT     = 4,  ///< frames shorter than 64 octets
  SW_STAT_RX_OVERSIZE = 5,  ///< frames longer than the configured maximum
  SW_STAT_RX_OVERFLOW = 6,  ///< frames dropped: ingress buffer exhausted
  SW_STAT_TX_FRAMES   = 7,  ///< frame copies injected into a transmit port
  SW_STAT_TX_OCTETS   = 8,  ///< octets injected into a transmit port
  SW_STAT_TX_STALLED  = 9,  ///< frames discarded because egress was blocked
  SW_STAT_CAM_HIT     = 10, ///< CAM lookups that resolved to a port
  SW_STAT_CAM_MISS    = 11, ///< CAM lookups that fell through to flooding
  SW_STAT_CAM_LEARN   = 12, ///< address insertions written into the CAM
  SW_STAT_CAM_FLUSH   = 13  ///< CAM flush operations performed
} sw_stat_id_e;

/// Number of statistics registers.
localparam int unsigned SW_STAT_COUNT = 14;

`ifdef VERILATOR
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
`endif

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif // SW_DEFS_SV
