`timescale 1ns/1ps
`include "sw_defs.sv"
module sw_tx_completion_case #(parameter int BP=1)(output logic finished=0);
  logic clk=0,rst=0,start=0;always #5 clk=~clk;
  logic busy,done,en,rd;logic[7:0] data;
  logic [SW_LEN_W-1:0] length=SW_LEN_W'(64),done_len;
  int octet_clocks=0,completions=0,expected_octets=76,expected_length=64;
  sw_gmii_tx #(.BYTE_PERIOD(BP)) dut(.clk_i(clk),.rst_ni(rst),.fr_start_i(start),.fr_len_i(length),
    .done_o(done),.done_len_o(done_len),.tx_busy_o(busy),.beat_valid_i(1'b1),
    .beat_data_i(64'd0),.beat_rd_o(rd),.oct_en_o(en),.oct_d_o(data));
  always @(posedge clk)if(rst)begin
    if(en)octet_clocks++;
    if(done)begin
      if(!en||octet_clocks!=expected_octets*BP||int'(done_len)!=expected_length)
        $fatal(1,"completion wrong BP=%0d clocks=%0d len=%0d",BP,octet_clocks,done_len);
      completions++;octet_clocks=0;
      $display("PASS TX completion BP=%0d after all %0d wire octets len=%0d",BP,expected_octets,done_len);
    end
  end
  initial begin
    repeat(4)@(negedge clk);rst=1;repeat(3)@(negedge clk);
    start=1;@(negedge clk);start=0;
    wait(completions==1);wait(!busy);@(negedge clk);
    length=SW_LEN_W'(100);expected_length=100;expected_octets=112;
    start=1;@(negedge clk);start=0;wait(completions==2);
    repeat(3)@(negedge clk);
    if(en||done)$fatal(1,"completion must be a one-cycle pulse before IFG");finished=1;
  end
endmodule
module sw_tx_completion_tb;
  logic[2:0] finished;
  sw_tx_completion_case #(.BP(1)) c1(finished[0]);
  sw_tx_completion_case #(.BP(4)) c4(finished[1]);
  sw_tx_completion_case #(.BP(40)) c40(finished[2]);
  initial begin wait(&finished);$display("sw_tx_completion_tb: PASS, 6 frames, 0 errors");$finish;end
  initial begin #1_000_000;$fatal(1,"TX completion timeout");end
endmodule
