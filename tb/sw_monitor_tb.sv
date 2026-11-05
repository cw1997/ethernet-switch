// Telemetry arithmetic and atomicity tests use independently calculated rates.
`timescale 1ns/1ps
`include "sw_defs.sv"
module sw_monitor_tb;
  localparam int N=3;
  logic clk=0, rst=0;
  always #5 clk=~clk;
  logic [N*32*SW_STAT_COUNT-1:0] stat='0;
  logic [N-1:0] done='0;
  logic [N*SW_LEN_W-1:0] len='0;
  logic [N*32-1:0] rx_used='0,tx_used='0;
  logic [N*8-1:0] phy={N{8'h0f}};
  logic req=0, ready, valid,cam_req,cam_valid=0;
  logic [31:0] addr=0,data,cam_index;
  logic [127:0] cam_entry=0;
  int errors=0,checks=0;
  sw_monitor #(.NUM_PORTS(N),.CLK_FREQ_HZ(1_000_001),.REFRESH_INTERVAL_MS(10),.CAM_CAPACITY(7)) dut (
    .clk_i(clk),.rst_ni(rst),.port_stat_i(stat),.tx_done_i(done),.tx_len_i(len),
    .phy_status_i(phy),.rx_used_i(rx_used),.tx_used_i(tx_used),.busy_i(1'b1),
    .flush_i(1'b0),.cam_entries_i(32'd2),.req_i(req),.addr_i(addr),.ready_o(ready),
    .valid_o(valid),.data_o(data),.cam_req_o(cam_req),.cam_index_o(cam_index),
    .cam_valid_i(cam_valid),.cam_entry_i(cam_entry));
  // Independent one-cycle CAM responder; payload intentionally changes after capture.
  always @(posedge clk) begin
    cam_valid<=cam_req;
    if(cam_req) cam_entry<={32'd1,32'd2,16'd0,48'h021122334455};
  end
  task check(input bit ok,input string label);
    checks++; if(ok) $display("PASS %s",label); else begin errors++; $display("FAIL %s",label); end
  endtask
  task read32(input logic [31:0] a,output logic [31:0] v);
    @(negedge clk); while(!ready) @(negedge clk); addr=a;req=1;
    @(negedge clk);req=0;
    while(!valid) @(negedge clk);v=data;
  endtask
  logic [31:0] v,lo,hi,seq;
  initial begin
    repeat(4) @(negedge clk);rst=1;
    read32(32'd200,v);check(v==0,"sample unavailable before full window");
    @(negedge clk);
    stat[(0*SW_STAT_COUNT+int'(SW_STAT_RX_FRAMES))*32+:32]=32'd10;
    stat[(0*SW_STAT_COUNT+int'(SW_STAT_RX_OCTETS))*32+:32]=32'd1000;
    stat[(0*SW_STAT_COUNT+int'(SW_STAT_RX_CRC_ERR))*32+:32]=32'd2;
    rx_used[0+:32]=32'd17;tx_used[0+:32]=32'd9;
    len[SW_LEN_W+:SW_LEN_W]=SW_LEN_W'(60);
    repeat(5) begin done[1]=1;@(negedge clk);end
    done=0; repeat(3) @(negedge clk); rx_used='0;tx_used='0;
    do read32(32'd196,seq); while(seq==0);
    read32(32'd200,v);check(v==1,"first atomic publication becomes valid");
    read32(32'd184,lo);read32(32'd188,hi);check({hi,lo}==64'd10001,"non-integral ms rounded up to 10001 clocks");
    read32(SW_MON_PORT_BASE+32'(SW_MON_RATE*4),v);
    check(v==32'd999,"10 frames in 10.001ms normalized to pps");
    read32(SW_MON_PORT_BASE+32'((SW_MON_RATE+4)*4),v);
    check(v==32'd799920,"RX bit/s excludes FCS, exact clock normalization");
    read32(SW_MON_PORT_BASE+32'd256+32'((SW_MON_RATE+2)*4),v);
    check(v==32'd499,"TX completion pps independently attributed");
    read32(SW_MON_PORT_BASE+32'd256+32'((SW_MON_COUNTER+14)*4),v);check(v==5,"TX counts completed frames");
    read32(SW_MON_PORT_BASE+32'd256+32'((SW_MON_COUNTER+16)*4),v);check(v==300,"TX completed MAC client bytes");
    read32(SW_MON_PORT_BASE+32'd12,v);check(v==17,"RX queue window peak retained");
    read32(SW_MON_PORT_BASE+32'd16,v);check(v==9,"TX queue window peak retained");
    read32(32'((SW_MON_COUNTER+14)*4),v);check(v==5,"aggregate counts each egress copy");
    read32(32'd216,v);check(v==1000,"fabric busy duty cycle");
    read32(SW_MON_MAC_BASE,v);check(v==32'h22334455,"MAC read word zero");
    cam_entry='0;
    read32(SW_MON_MAC_BASE+32'd4,v);check(v==32'h00000211,"MAC high word from same captured entry");
    read32(SW_MON_MAC_BASE+32'd8,v);check(v==2,"MAC port word");
    read32(SW_MON_MAC_BASE+32'd12,v);check(v==1,"MAC validity word");
    read32(32'h30000000,v);check(v==0,"unmapped CSR reads zero");
    do read32(32'd196,v);while(v==seq);
    read32(SW_MON_PORT_BASE+32'(SW_MON_RATE*4),v);check(v==0,"idle next window reports zero rate");
    // A modulo-32 wrap must not lose 2**32 events even across a long sample.
    @(negedge clk);stat[0+:32]=32'hfffffffe;
    repeat(3) @(negedge clk);stat[0+:32]=32'd1;
    read32(32'd196,seq);do read32(32'd196,v);while(v==seq);
    read32(SW_MON_PORT_BASE+32'(SW_MON_COUNTER*4),lo);
    read32(SW_MON_PORT_BASE+32'((SW_MON_COUNTER+1)*4),hi);
    check({hi,lo}==64'h0000000100000001,"32-bit source wrap extended to cumulative 64 bits");
    @(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;
    read32(32'd200,v);check(v==0,"reset invalidates snapshot");
    $display("sw_monitor_tb: %0d checks, %0d errors",checks,errors);
    if(errors) $fatal(1,"FAIL telemetry");$finish;
  end
  initial begin #2_000_000;$fatal(1,"monitor timeout");end
endmodule
