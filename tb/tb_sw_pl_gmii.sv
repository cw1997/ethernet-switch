// ============================================================================
//  File        : tb_sw_pl_gmii.sv
//  Description : Self-checking system regression for the GMII staged-switch
//                top.  Drives COMPLETE wire frames (preamble/SFD/client/FCS)
//                directly onto the packed GMII pins and independently
//                reconstructs every transmitted frame at the wire boundary.
//
//                NUM_PORTS, CAM_SETS and CAM_WAYS are parameters, so one
//                testbench elaborates for 4/8/16/32/48 ports and for arbitrary
//                set/way geometries via `iverilog -P`.  The wire model uses
//                only packed vectors and the functional tb_put_octet/update
//                idiom from sw_tb_pkg: Icarus cannot be trusted with a
//                run-time-indexed unpacked array.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "sw_tb_pkg.sv"

module sw_pl_gmii_mon
  import sw_tb_pkg::*;
#(
  parameter int unsigned PORT_ID = 0
) (
  input  var logic        clk_i,
  input  var logic        rst_ni,
  input  var logic        clear_i,
  input  var logic        tx_en_i,
  input  var logic [7:0]  tx_d_i,

  output      logic [15:0] cnt_o,
  output      logic [11:0] len_o,
  output      logic [47:0] dst_o,
  output      logic [47:0] src_o,
  output      logic        ok_o
);

  tb_frame_buf_t     buf_r;
  int unsigned       idx;
  logic [15:0]       cnt_r;
  logic [11:0]       len_r;
  logic [47:0]       dst_r;
  logic [47:0]       src_r;
  logic              ok_r;
  logic              pre_ok;
  logic              fcs_ok;
  logic [31:0]       want_fcs;
  logic [31:0]       got_fcs;
  int unsigned       client_len;
  int unsigned       k;

  assign cnt_o = cnt_r;
  assign len_o = len_r;
  assign dst_o = dst_r;
  assign src_o = src_r;
  assign ok_o  = ok_r;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      buf_r  <= '0;
      idx    <= 0;
      cnt_r  <= '0;
      len_r  <= '0;
      dst_r  <= '0;
      src_r  <= '0;
      ok_r   <= 1'b1;
    end else if (tx_en_i) begin
      buf_r <= tb_put_octet(buf_r, idx, tx_d_i);
      idx   <= idx + 1;
    end else if (idx != 0) begin
      // One complete frame just ended.  idx counts wire octets:
      // 8 preamble/SFD + client_len client octets + 4 FCS.
      client_len = idx - 12;
      cnt_r <= cnt_r + 16'd1;
      len_r <= 12'(client_len);
      dst_r <= {tb_get_octet(buf_r, 8),  tb_get_octet(buf_r, 9),
                tb_get_octet(buf_r, 10), tb_get_octet(buf_r, 11),
                tb_get_octet(buf_r, 12), tb_get_octet(buf_r, 13)};
      src_r <= {tb_get_octet(buf_r, 14), tb_get_octet(buf_r, 15),
                tb_get_octet(buf_r, 16), tb_get_octet(buf_r, 17),
                tb_get_octet(buf_r, 18), tb_get_octet(buf_r, 19)};

      pre_ok = 1'b1;
      for (k = 0; k < 7; k++) begin
        if (tb_get_octet(buf_r, k) != 8'h55) pre_ok = 1'b0;
      end
      if (tb_get_octet(buf_r, 7) != 8'hD5) pre_ok = 1'b0;

      want_fcs = tb_crc32(buf_r, client_len, 8);
      got_fcs  = {tb_get_octet(buf_r, idx-1), tb_get_octet(buf_r, idx-2),
                  tb_get_octet(buf_r, idx-3), tb_get_octet(buf_r, idx-4)};
      fcs_ok   = (want_fcs == got_fcs);
      ok_r     = ok_r && pre_ok && fcs_ok;
      idx      <= 0;
    end
  end
endmodule : sw_pl_gmii_mon

module tb_sw_pl_gmii
  import sw_tb_pkg::*;
#(
  parameter int unsigned NUM_PORTS = 4,
  parameter int unsigned CAM_SETS  = 16,
  parameter int unsigned CAM_WAYS  = 2
) ();

  localparam int unsigned NW = NUM_PORTS*8;

  logic clk;
  logic rst_n;
  logic clear;

  logic [NUM_PORTS-1:0]   rx_en;
  logic [NUM_PORTS*8-1:0] rx_d;
  logic [NUM_PORTS-1:0]   tx_en;
  logic [NUM_PORTS*8-1:0] tx_d;
  logic [NUM_PORTS-1:0]   link_up;

  logic [NUM_PORTS*16-1:0] mon_cnt;
  logic [NUM_PORTS*12-1:0] mon_len;
  logic [NUM_PORTS*48-1:0] mon_dst;
  logic [NUM_PORTS*48-1:0] mon_src;
  logic [NUM_PORTS-1:0]    mon_ok;

  initial begin : clk_gen
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  es_switch_gmii #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (125_000_000),
    .PORT_SPEED  ({NUM_PORTS{2'd2}}),
    .CAM_SETS    (CAM_SETS),
    .CAM_WAYS    (CAM_WAYS)
  ) u_dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .link_up_i      (link_up),
    .gmii_rx_en_i   (rx_en),
    .gmii_rx_data_i (rx_d),
    .gmii_tx_en_o   (tx_en),
    .gmii_tx_data_o (tx_d)
  );

  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_mon
      sw_pl_gmii_mon #(.PORT_ID(g)) u_mon (
        .clk_i  (clk),        .rst_ni (rst_n),
        .clear_i(clear),
        .tx_en_i(tx_en[g]),   .tx_d_i (tx_d[g*8 +: 8]),
        .cnt_o  (mon_cnt[g*16 +: 16]), .len_o(mon_len[g*12 +: 12]),
        .dst_o  (mon_dst[g*48 +: 48]), .src_o(mon_src[g*48 +: 48]),
        .ok_o   (mon_ok[g])
      );
    end
  endgenerate

  int unsigned checks;
  int unsigned errors;

  task automatic check(input bit ok, input string label);
    checks = checks + 1;
    if (!ok) begin
      errors = errors + 1;
      $display("[%0t] FAIL %s", $time, label);
    end
  endtask

  // Present a complete wire frame on one port, then a legal inter-frame gap.
  task automatic send_frame(input int unsigned port, input sw_mac_t dst,
                            input sw_mac_t src, input int unsigned client_len,
                            input bit vlan_en, input bit corrupt_fcs);
    tb_frame_buf_t f;
    int unsigned n;
    int unsigned i;
    logic [7:0] o;
    f = tb_build_frame(dst, src, TB_ET_IPV4, client_len, vlan_en, corrupt_fcs);
    n = tb_frame_octets(client_len, vlan_en);
    for (i = 0; i < n; i++) begin
      @(posedge clk);
      o    = tb_get_octet(f, i);
      rx_en = NUM_PORTS'(1) << port;
      rx_d  = NW'(o) << (port*8);
    end
    @(posedge clk);
    rx_en = '0;
    rx_d  = '0;
    for (i = 0; i < 14; i++) @(posedge clk);
  endtask

  task automatic idle(input int unsigned n);
    int unsigned i;
    rx_en = '0;
    rx_d  = '0;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  task automatic clear_monitors();
    clear = 1'b1;
    @(posedge clk);
    #1;
    clear = 1'b0;
  endtask

  task automatic expect_on(input int unsigned port, input int unsigned cnt,
                           input sw_mac_t dst, input sw_mac_t src,
                           input int unsigned client_len, input string label);
    check(mon_cnt[port*16 +: 16] == 16'(cnt), {label, ": frame count"});
    if (cnt != 0) begin
      check(mon_len[port*12 +: 12] == 12'(client_len), {label, ": length"});
      check(mon_dst[port*48 +: 48] == dst,             {label, ": dst MAC"});
      check(mon_src[port*48 +: 48] == src,             {label, ": src MAC"});
      check(mon_ok[port] == 1'b1,                     {label, ": preamble/FCS"});
    end
  endtask

  sw_mac_t host_a;
  sw_mac_t host_b;
  sw_mac_t host_c;
  sw_mac_t bcast;
  int unsigned last_port;
  int unsigned p;

  initial begin : main_proc
    checks    = 0;
    errors    = 0;
    host_a    = 48'h02_aa_00_00_00_01;
    host_b    = 48'h02_bb_00_00_00_02;
    host_c    = 48'h02_cc_00_00_00_03;
    bcast     = SW_MAC_BROADCAST;
    last_port = NUM_PORTS - 1;

    rst_n   = 1'b0;
    clear   = 1'b0;
    link_up = '1;
    rx_en   = '0;
    rx_d    = '0;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    idle(20);
    clear_monitors();

    $display("tb_sw_pl_gmii: NUM_PORTS=%0d CAM=%0dx%0d", NUM_PORTS, CAM_SETS, CAM_WAYS);

    // ---- 1. reset and idle ------------------------------------------------
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_a, 64, "idle");

    // ---- 2. broadcast floods, never back to the source -------------------
    send_frame(0, bcast, host_a, 64, 0, 0);
    idle(240);
    expect_on(0, 0, bcast, host_a, 64, "bcast src");
    for (p = 1; p < NUM_PORTS; p++)
      expect_on(p, 1, bcast, host_a, 64, "bcast flood");
    clear_monitors();

    // ---- 3. learning + known unicast -------------------------------------
    send_frame(last_port, bcast, host_b, 64, 0, 0);
    idle(240);
    clear_monitors();
    send_frame(0, host_b, host_a, 64, 0, 0);
    idle(240);
    expect_on(0, 0, host_b, host_a, 64, "known unicast src");
    for (p = 1; p < last_port; p++)
      expect_on(p, 0, host_b, host_a, 64, "known unicast others");
    expect_on(last_port, 1, host_b, host_a, 64, "known unicast dest");
    clear_monitors();

    // ---- 4. unknown unicast floods ---------------------------------------
    send_frame(1, host_c, host_a, 64, 0, 0);
    idle(240);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (p != 1) expect_on(p, 1, host_c, host_a, 64, "unknown unicast");
      else        expect_on(p, 0, host_c, host_a, 64, "unknown unicast src");
    end
    clear_monitors();

    // ---- 5. corrupt FCS is dropped everywhere ----------------------------
    send_frame(0, bcast, host_a, 64, 0, 1);
    idle(240);
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_a, 64, "bad FCS");
    clear_monitors();

    // ---- 6. 802.1Q tagged frame ------------------------------------------
    send_frame(0, bcast, host_a, 100, 1, 0);
    idle(260);
    expect_on(0, 0, bcast, host_a, 100, "vlan src");
    for (p = 1; p < NUM_PORTS; p++)
      expect_on(p, 1, bcast, host_a, 100, "vlan flood");
    clear_monitors();

    // ---- 7. exactly MTU is legal, one over MTU is dropped ----------------
    send_frame(0, bcast, host_a, 1518, 0, 0);
    idle(1800);
    for (p = 1; p < NUM_PORTS; p++)
      expect_on(p, 1, bcast, host_a, 1518, "max MTU");
    clear_monitors();
    send_frame(0, bcast, host_a, 1519, 0, 0);
    idle(1800);
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, bcast, host_a, 1519, "over MTU");
    clear_monitors();

    // ---- 8. source-port filter, then an explicit MAC relocation ----------
    // The VLAN / MTU broadcasts re-learned HOST_A on port 0, so a frame
    // addressed to it arriving on port 0 is filtered everywhere.
    send_frame(0, host_a, host_b, 64, 0, 0);
    idle(240);
    for (p = 0; p < NUM_PORTS; p++)
      expect_on(p, 0, host_a, host_b, 64, "self-dest filtered");
    clear_monitors();

    // A frame sourced by HOST_A on port 2 moves the station there; the next
    // unicast to HOST_A must go to port 2 only.
    send_frame(2, bcast, host_a, 64, 0, 0);
    idle(240);
    clear_monitors();
    send_frame(0, host_a, host_b, 64, 0, 0);
    idle(240);
    for (p = 0; p < NUM_PORTS; p++) begin
      if (p == 2) expect_on(p, 1, host_a, host_b, 64, "moved unicast");
      else        expect_on(p, 0, host_a, host_b, 64, "moved unicast others");
    end

    if (errors == 0)
      $display("tb_sw_pl_gmii: PASSED (%0d checks, %0d ports, CAM %0dx%0d)",
               checks, NUM_PORTS, CAM_SETS, CAM_WAYS);
    else
      $display("tb_sw_pl_gmii: FAILED (%0d of %0d checks)", errors, checks);
    if (errors != 0) $fatal(1, "tb_sw_pl_gmii: FAILED");
    $finish;
  end

  initial begin : watchdog
    #20000000;
    $fatal(1, "tb_sw_pl_gmii: timeout");
  end

endmodule : tb_sw_pl_gmii
