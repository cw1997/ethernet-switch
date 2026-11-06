// ============================================================================
//  File        : sw_uart_tb.sv
//  Description : Simulation support and self-checking regression for sw_uart_tb.
//                Uses the test clock/reset and explicit stimulus below. Wire
//                models and scoreboards check behavior, not board CDC timing.
// ============================================================================
`timescale 1ns/1ps
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "monitor/es_monitor_defs.sv"
`include "console/es_console_defs.sv"
module sw_uart_case #(parameter int BITS=8,PAR=0,STOPS=1,FLOW=0,
                     HZ=1_600_000,BAUD=100_000)(output logic finished=0);
  logic clk=0,rst=0,rx=1,cts=0,tx,rts;
  always #5 clk=~clk;
  logic send=0,ready,got,parerr,frerr,overflow;
  logic [7:0] txdata=8'ha5,rxdata;
  logic accept=1;
  int errors=0, received=0;
  localparam int PERIOD=(HZ+BAUD/2)/BAUD;
  localparam logic [7:0] MASK=8'(255 >> (8-BITS));
  es_console_uart #(.CLK_FREQ_HZ(HZ),.BAUD_RATE(BAUD),.DATA_BITS(BITS),.PARITY(PAR),.STOP_BITS(STOPS),.FLOW_CONTROL(FLOW)) dut(
    .clk_i(clk),.rst_ni(rst),.rx_i(rx),.cts_ni(cts),.tx_o(tx),.rts_no(rts),
    .tx_valid_i(send),.tx_data_i(txdata),.tx_ready_o(ready),.rx_valid_o(got),.rx_data_o(rxdata),
    .rx_ready_i(accept),.parity_error_o(parerr),.frame_error_o(frerr),.overflow_o(overflow));
  task check(input bit ok,input string label);
    if(!ok)begin errors++;$display("FAIL UART %0d/%0d/%0d/%0d %s",BITS,PAR,STOPS,FLOW,label);end
    else $display("PASS UART %0d/%0d/%0d/%0d %s",BITS,PAR,STOPS,FLOW,label);
  endtask
  task wirebit(input bit b);rx=b;repeat(PERIOD)@(negedge clk);endtask
  task receive_frame(input logic[7:0] value,input bit badpar,input bit badstop);
    bit parity;parity=0;
    wirebit(0);
    for(int b=0;b<BITS;b++)begin wirebit(value[b]);parity^=value[b];end
    if(PAR!=0)wirebit(parity^(PAR==1)^badpar);
    repeat(STOPS)wirebit(!badstop);
    wirebit(1);wirebit(1);
  endtask
  bit seenpar=0,seenframe=0,seenover=0;
  always @(negedge clk)begin
    if(got)begin received++;check(rxdata==(8'h53&MASK),"RX wire value");end
    if(parerr)seenpar=1;if(frerr)seenframe=1;if(overflow)seenover=1;
  end
  task decode_tx;
    bit parity;parity=0;
    @(negedge tx);repeat(PERIOD/2)@(negedge clk);check(tx==0,"TX start");
    for(int b=0;b<BITS;b++)begin repeat(PERIOD)@(negedge clk);check(tx==txdata[b],"TX data bit");parity^=txdata[b];end
    if(PAR!=0)begin repeat(PERIOD)@(negedge clk);check(tx==(parity^(PAR==1)),"TX parity");end
    repeat(STOPS)begin repeat(PERIOD)@(negedge clk);check(tx==1,"TX stop");end
  endtask
  initial begin
    repeat(4)@(negedge clk);rst=1;repeat(4)@(negedge clk);
    fork
      decode_tx();
      begin send=1;@(negedge clk);send=0;repeat(5)@(negedge clk);cts=1;end
    join
    repeat(PERIOD*3)@(negedge clk);
    if(FLOW)check(!ready&&tx,"CTS stops between characters without truncation");
    else check(ready,"None ignores CTS");
    cts=0;repeat(4)@(negedge clk);
    receive_frame(8'h53,0,0);check(received==1,"one valid frame delivered");
    if(PAR!=0)begin receive_frame(8'h53,1,0);check(seenpar&&received==1,"bad parity rejected");end
    receive_frame(8'h53,0,1);check(seenframe,"bad stop diagnosed");
    accept=0;repeat(3)@(negedge clk);check(rts==(FLOW!=0),"RTS reflects receive capacity");
    receive_frame(8'h53,0,0);check(seenover,"receive overflow diagnosed");
    if(errors)$fatal(1,"UART case failed %0d errors",errors);
    $display("UART case done, 0 errors");finished=1;
  end
endmodule
module sw_uart_tb;
  logic [5:0] finished;
  sw_uart_case #(.HZ(50_000_000),.BAUD(115200)) c0(finished[0]);
  sw_uart_case #(.BITS(7),.PAR(2),.STOPS(2),.FLOW(1)) c1(finished[1]);
  sw_uart_case #(.BITS(5),.PAR(1),.STOPS(1),.FLOW(1)) c2(finished[2]);
  sw_uart_case #(.BITS(6),.PAR(0),.STOPS(2)) c3(finished[3]);
  sw_uart_case #(.BITS(8),.PAR(1),.STOPS(2)) c4(finished[4]);
  sw_uart_case #(.BITS(8),.PAR(2),.STOPS(1),.FLOW(1)) c5(finished[5]);
  initial begin wait(&finished);$display("sw_uart_tb: PASS, 6 modes, 0 errors");$finish;end
  initial begin #1_000_000;$fatal(1,"UART timeout");end
endmodule
