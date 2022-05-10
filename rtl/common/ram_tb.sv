// project: w80386dx
// author: Chang Wei<changwei1006@gmail.com>
// repo: https://github.com/openx86/w80386dx
// module: common_ram_tb
// create at: 2021-12-18 01:47:34
// description: test common_ram module

`timescale 1ns/1ns
module ram_tb #(
    // parameters
) (
    // ports
);

localparam
WIDTH = 8, DEPTH = 8;

logic        read_vaild;
logic        read_ready;
logic [$clog2(DEPTH)-1:0] read_address;
logic [WIDTH-1:0] read_data;
logic        write_vaild;
logic        write_ready;
logic [$clog2(DEPTH)-1:0] write_address;
logic [WIDTH-1:0] write_data;
logic        clock, reset;

ram #(
    .WIDTH ( WIDTH ),
    .DEPTH ( DEPTH )
) tb_ram (
    .read_vaild ( read_vaild ),
    .read_ready ( read_ready ),
    .read_address ( read_address ),
    .read_data ( read_data ),
    .write_vaild ( write_vaild ),
    .write_ready ( write_ready ),
    .write_address ( write_address ),
    .write_data ( write_data ),
    .clock ( clock ),
    .reset ( reset )
);

always #1 clock = ~clock;

initial begin
    // $monitor("%t: read_ready=0x%h, read_data=0x%h", $time, read_ready, read_data);
    $monitor("%t: write_ready=0x%h, write_address=0x%h, write_data=0x%h", $time, write_ready, write_address, write_data);
    read_vaild = 0;
    read_address = 0;
    write_vaild = 0;
    write_address = 0;
    write_data = 0;
    clock = 0;
    reset = 1;
    #2;
    reset = 0;

    read_vaild = 1;
    read_address = 0;
    $display("%t: read: address=0x%h", $time, read_address);

    #8;

    write_vaild = 1;
    write_address = 0;
    write_data = 1;
    $display("%t: write: address=0x%h", $time, write_address);

    #8;

    read_vaild = 1;
    read_address = 0;
    $display("%t: read: address=0x%h", $time, read_address);

    #64;

    $stop();
end

endmodule
