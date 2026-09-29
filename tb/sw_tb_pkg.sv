// ============================================================================
//  File        : sw_tb_pkg.sv
//  Description : Verification support package for the Layer-2 switch testbench.
//
//                The package deliberately contains *independent* implementations
//                of everything the testbench needs in order to predict, so that
//                the reference model can never share a bug with the RTL:
//
//                  * `tb_crc32` - bit-serial CRC-32 reference.  The RTL uses a
//                    byte-wide lookup table, so the two only agree if both are
//                    correct.
//                  * `tb_crc32_selftest` - known-answer test for the reference
//                    itself, so a failure of the reference is never mistaken
//                    for a failure of the design.
//                  * `tb_build_frame` - assembles a complete, wire-legal
//                    Ethernet frame into a flat octet vector.
//                  * `tb_rec_t` - the record the scoreboard compares, again a
//                    flat vector.
//
//                Flat packed vectors are used throughout instead of unpacked
//                arrays and structs.  Icarus Verilog - the simulator this
//                repository is regression-tested with - cannot pass an unpacked
//                array through a task or function argument, cannot put a struct
//                into a queue, and cannot index a queue element, so a vector
//                plus accessor functions is the portable formulation.  Verilator
//                accepts it just as happily.
//
//                Keeping the reference model bit-serial is what makes the
//                comparison meaningful: a shared table bug would cancel out.
// ============================================================================
`ifndef SW_TB_PKG_SV
`define SW_TB_PKG_SV

package sw_tb_pkg;

  // The RTL's shared declarations (`sw_mac_t`, `SW_PREAMBLE_LEN`, `SW_FCS_LEN`)
  // live at compilation-unit scope in `rtl/sw_defs.sv`, which every RTL file
  // includes, so they are already in scope inside this package and need no
  // import.  This is deliberate rather than accidental: see sw_defs.sv for why
  // the RTL cannot use a package, and a package cannot reference
  // compilation-unit-scope names on the synthesis frontend either, so keeping
  // this one *out* of a package dependency is what lets the whole testbench and
  // the whole design share one declaration set.
  // ==========================================================================
  // Octet vector convention
  // ==========================================================================
  // A frame image is a flat packed vector of 8*MAX_OCTETS bits.  Octet 0 - the
  // first octet on the wire - lives in the most significant octet lane:
  //
  //   octet i  <->  fbuf[(MAX_OCTETS-1-i)*8 +: 8]
  //
  // Octet access always goes through `tb_get_octet` / `tb_put_octet` so the
  // convention is stated exactly once.
  localparam int unsigned TB_MAX_OCTETS = 2048;

  typedef logic [TB_MAX_OCTETS*8-1:0] tb_frame_buf_t;

  /// Read octet `i` of a frame image.
  function automatic logic [7:0] tb_get_octet(
      input tb_frame_buf_t b,
      input int unsigned   i);
    tb_get_octet = b[(TB_MAX_OCTETS-1-i)*8 +: 8];
  endfunction

  /// Write octet `i` of a frame image.
  function automatic tb_frame_buf_t tb_put_octet(
      input tb_frame_buf_t b,
      input int unsigned   i,
      input logic [7:0]    d);
    tb_put_octet = b & ~(tb_frame_buf_t'(8'hFF) << ((TB_MAX_OCTETS-1-i)*8));
    tb_put_octet = tb_put_octet | (tb_frame_buf_t'(d) << ((TB_MAX_OCTETS-1-i)*8));
  endfunction

  // ==========================================================================
  // CRC-32 reference - bit serial, IEEE 802.3
  // ==========================================================================
  localparam logic [31:0] TB_POLY = 32'hEDB8_8320;  // reflected 0x04C11DB7

  /// One step of the bit-serial LFSR: absorb the eight bits of `d`, least
  /// significant first, starting from register value `init`.
  function automatic logic [31:0] tb_crc32_octet(
      input logic [31:0] init,
      input logic [7:0]  d);
    logic [31:0] c;
    logic        fb;
    c = init;
    for (int unsigned i = 0; i < 8; i++) begin
      fb = c[0] ^ d[i];
      c  = fb ? ((c >> 1) ^ TB_POLY) : (c >> 1);
    end
    return c;
  endfunction

  /// CRC-32 of the `n` octets starting at `off` in a frame image, as the FCS is
  /// computed over them: seed all ones, finish with a complement.
  function automatic logic [31:0] tb_crc32(
      input tb_frame_buf_t b,
      input int unsigned   n,
      input int unsigned   off = 0);
    logic [31:0] c;
    c = 32'hFFFF_FFFF;
    for (int unsigned i = 0; i < n; i++) c = tb_crc32_octet(c, tb_get_octet(b, off + i));
    return c ^ 32'hFFFF_FFFF;
  endfunction

  /// Known-answer test for the reference above: the CRC-32 of the ASCII string
  /// "123456789" is 0xCBF43926.  The testbench calls this before anything else
  /// so that a broken reference is reported as such.
  function automatic logic tb_crc32_selftest();
    tb_frame_buf_t b;
    int            i;
    b = '0;
    for (i = 0; i < 9; i++) b = tb_put_octet(b, i, 8'h30 + 8'(i + 1));
    return (tb_crc32(b, 9) == 32'hCBF4_3926);
  endfunction

  // ==========================================================================
  // Protocol constants used by the tests
  // ==========================================================================
  localparam logic [15:0] TB_ET_IPV4 = 16'h0800;
  localparam logic [15:0] TB_ET_ARP  = 16'h0806;
  localparam logic [15:0] TB_ET_IPV6 = 16'h86DD;

  // ==========================================================================
  // Frame construction
  // ==========================================================================
  /// Number of octets a complete frame occupies on the wire: the eight preamble
  /// and SFD octets, the MAC client data, and the four FCS octets.
  function automatic int unsigned tb_frame_octets(
      input int unsigned total_len,
      input bit          vlan_en = 1'b0);
    tb_frame_octets = SW_PREAMBLE_LEN + total_len + SW_FCS_LEN;
  endfunction

  /// Build one complete Ethernet frame image: preamble, start-of-frame
  /// delimiter, MAC client data and FCS.
  ///
  /// This is a *function* returning the image, not a task writing through an
  /// output argument.  IEEE 1800 allows only inputs in a function argument list,
  /// and an unpacked array argument is not portable at all - Icarus Verilog
  /// rejects both.  The frame length is a separate function, `tb_frame_octets`,
  /// so the caller never has to know the layout.
  ///
  /// Layout of the MAC client data: destination MAC, source MAC, the
  /// length/EtherType field, an optional 802.1Q tag, then a payload filled with
  /// a counting pattern.  The counting pattern is deliberate: it makes any octet
  /// reordering or beat-masking error in the datapath immediately visible in the
  /// FCS check, instead of silently corrupting real payload data.
  ///
  /// `total_len` is the MAC client data length and must be at least 64.  The
  /// frame on the wire is therefore 8 + total_len + 4 octets.
  ///
  /// `corrupt_fcs` flips one bit of the first FCS octet, which is how the
  /// testbench injects a frame the receiver has to reject.
  function automatic tb_frame_buf_t tb_build_frame(
      input sw_mac_t     dst,
      input sw_mac_t     src,
      input logic [15:0] l2type,
      input int unsigned total_len,
      input bit          vlan_en     = 1'b0,
      input bit          corrupt_fcs = 1'b0);
    tb_frame_buf_t frame;
    int unsigned   n;
    int unsigned   p;
    int unsigned   i;
    logic [31:0]   fcs;

    frame = '0;
    n = 0;

    // ---- preamble and start-of-frame delimiter -----------------------------
    for (i = 0; i < 7; i++) begin
      frame = tb_put_octet(frame, n, 8'h55);
      n++;
    end
    frame = tb_put_octet(frame, n, 8'hD5);
    n++;

    // ---- destination and source MAC ----------------------------------------
    // A 48 bit address is sliced most significant octet first, which is already
    // the order the octets appear in the frame, so no reversal is needed.
    for (i = 0; i < 6; i++) begin
      frame = tb_put_octet(frame, n, dst[47-8*i -: 8]);
      n++;
    end
    for (i = 0; i < 6; i++) begin
      frame = tb_put_octet(frame, n, src[47-8*i -: 8]);
      n++;
    end

    // ---- length / EtherType ------------------------------------------------
    frame = tb_put_octet(frame, n, l2type[15:8]);  n++;
    frame = tb_put_octet(frame, n, l2type[7:0]);   n++;

    // ---- optional 802.1Q tag ----------------------------------------------
    // Two octets of tag control information, then the real EtherType.  The
    // switch has to parse through it and forward it untouched.
    if (vlan_en) begin
      frame = tb_put_octet(frame, n, 8'h00);             n++;  // priority, VID hi
      frame = tb_put_octet(frame, n, 8'h01);             n++;  // VID lo
      frame = tb_put_octet(frame, n, TB_ET_IPV4[15:8]);  n++;
      frame = tb_put_octet(frame, n, TB_ET_IPV4[7:0]);   n++;
    end

    // ---- payload -----------------------------------------------------------
    // `n` indexes the frame image, which starts with the eight preamble octets,
    // while `total_len` counts only the MAC client data, so the payload runs to
    // SW_PREAMBLE_LEN + total_len.
    p = n;
    for (i = 0; p < SW_PREAMBLE_LEN + total_len; i++) begin
      frame = tb_put_octet(frame, p, 8'(i));
      p++;
    end
    n = SW_PREAMBLE_LEN + total_len;

    // ---- FCS ---------------------------------------------------------------
    // The FCS covers the MAC client data only: it starts after the eight
    // preamble and SFD octets and runs to the end of the client data, which is
    // exactly what a real MAC transmits and what a real receiver verifies.
    fcs = tb_crc32(frame, total_len, SW_PREAMBLE_LEN);
    if (corrupt_fcs) fcs[0] = ~fcs[0];
    frame = tb_put_octet(frame, n, fcs[7:0]);    n++;
    frame = tb_put_octet(frame, n, fcs[15:8]);   n++;
    frame = tb_put_octet(frame, n, fcs[23:16]);  n++;
    frame = tb_put_octet(frame, n, fcs[31:24]);  n++;

    return frame;
  endfunction

  // ==========================================================================
  // Formatting
  // ==========================================================================
  /// Printable "xx:xx:xx:xx:xx:xx" form of a MAC address, for test log lines.
  function automatic string tb_mac_str(input sw_mac_t m);
    return $sformatf("%02x:%02x:%02x:%02x:%02x:%02x",
                     m[47:40], m[39:32], m[31:24], m[23:16], m[15:8], m[7:0]);
  endfunction

  // ==========================================================================
  // Scoreboard record
  // ==========================================================================
  // What the scoreboard compares for one frame.  The fields are packed
  // destination-first and the offsets are *derived* from the field widths below,
  // so `tb_rec_pack` and the accessors cannot drift apart:
  //
  //   [REC_W-1        :REC_W-48]  destination MAC
  //   [               :REC_W-96]  source MAC
  //   [               :REC_W-112] length/EtherType field as seen on the wire
  //   [               :REC_W-144] MAC client data length, FCS excluded
  //   [REC_W-145]                  FCS correct
  //   [REC_W-146]                  preamble and SFD correct
  localparam int unsigned REC_W = 146;

  typedef logic [REC_W-1:0] tb_rec_t;

  localparam int REC_LEN_LSB = 0;                            // length field
  localparam int REC_L2_LSB  = REC_LEN_LSB + 32;             // l2type field
  localparam int REC_SRC_LSB = REC_L2_LSB  + 16;             // source MAC
  localparam int REC_DST_LSB = REC_SRC_LSB + 48;             // destination MAC
  localparam int REC_FCS_LSB = REC_DST_LSB + 48;             // FCS verdict
  localparam int REC_PRE_LSB = REC_FCS_LSB + 1;              // preamble verdict

  function automatic tb_rec_t tb_rec_pack(
      input sw_mac_t     dst,
      input sw_mac_t     src,
      input logic [15:0] l2type,
      input int unsigned len,
      input bit          fcs_ok      = 1'b0,
      input bit          preamble_ok = 1'b0);
    tb_rec_pack = '0;
    tb_rec_pack[REC_DST_LSB +: 48] = dst;
    tb_rec_pack[REC_SRC_LSB +: 48] = src;
    tb_rec_pack[REC_L2_LSB  +: 16] = l2type;
    tb_rec_pack[REC_LEN_LSB +: 32] = 32'(len);
    tb_rec_pack[REC_FCS_LSB]        = fcs_ok;
    tb_rec_pack[REC_PRE_LSB]        = preamble_ok;
  endfunction

  function automatic sw_mac_t      tb_rec_dst(input tb_rec_t r);
    tb_rec_dst = r[REC_DST_LSB +: 48];
  endfunction

  function automatic sw_mac_t      tb_rec_src(input tb_rec_t r);
    tb_rec_src = r[REC_SRC_LSB +: 48];
  endfunction

  function automatic logic [15:0] tb_rec_l2(input tb_rec_t r);
    tb_rec_l2 = r[REC_L2_LSB +: 16];
  endfunction

  function automatic int unsigned tb_rec_len(input tb_rec_t r);
    tb_rec_len = int'(r[REC_LEN_LSB +: 32]);
  endfunction

  function automatic bit tb_rec_fcs_ok(input tb_rec_t r);
    tb_rec_fcs_ok = r[REC_FCS_LSB];
  endfunction

  function automatic bit tb_rec_pre_ok(input tb_rec_t r);
    tb_rec_pre_ok = r[REC_PRE_LSB];
  endfunction

  /// Build a scoreboard record from a received frame image.
  ///
  /// `n` is the total number of octets captured on the wire (preamble
  /// included).  The header starts at octet 8 and the FCS occupies the last
  /// four octets.
  function automatic tb_rec_t tb_rec_from_wire(
      input tb_frame_buf_t b,
      input int unsigned   n,
      input bit            fcs_ok,
      input bit            preamble_ok);
    sw_mac_t d;
    sw_mac_t s;
    int unsigned i;
    d = 48'd0;
    s = 48'd0;
    for (i = 0; i < 6; i++) d = {d[40:0], tb_get_octet(b, 8 + i)};
    for (i = 6; i < 12; i++) s = {s[40:0], tb_get_octet(b, 8 + i)};
    return tb_rec_pack(d, s,
                       {tb_get_octet(b, 20), tb_get_octet(b, 21)},
                       n - 12, fcs_ok, preamble_ok);
  endfunction

endpackage : sw_tb_pkg

`endif // SW_TB_PKG_SV
