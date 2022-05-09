`timescale 1ns/1ns
module fifo_tb #(
    // parameters
    clock_period = 2
) (
    // ports
);

localparam WIDTH = 4, DEPTH = 4;

logic clock, reset;
always #(clock_period/2) clock = ~clock;

logic [WIDTH-1:0] read_data;
logic             read_enable;
logic [WIDTH-1:0] write_data;
logic             write_enable;
logic             is_empty;
logic             is_full;

initial begin
    $monitor("%t : read_enable = %b, read_data = 0x%h (%bb) , is_empty = %b, is_full = %b", $time, read_enable, read_data, read_data, is_empty, is_full);
    $monitor("%t : write_enable = %b, write_data = 0x%h (%bb) , is_empty = %b, is_full = %b", $time, write_enable, write_data, write_data, is_empty, is_full);

    read_enable = 0;
    write_data = 4'd0;
    write_enable = 0;

    clock = 1;
    reset = 1;
    #4;
    reset = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); write_enable = 1; write_data = 4'd1;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd2;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd3;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); write_enable = 1; write_data = 4'd4;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd5;
    // #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd6;
    // #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd7;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); write_enable = 1; write_data = 4'd8;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd9;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd10;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); read_enable = 1;
    // #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    // #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); write_enable = 1; write_data = 4'd11;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); write_enable = 1; write_data = 4'd12;
    #(clock_period); write_enable = 0; write_data = '{default:'z};

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    #(clock_period); read_enable = 1;
    #(clock_period); read_enable = 0;

    $stop();
end

fifo #(
    .WIDTH ( WIDTH ),
    .DEPTH ( DEPTH )
) tb_fifo (
    .read_data ( read_data ),
    .read_enable ( read_enable ),
    .write_data ( write_data ),
    .write_enable ( write_enable ),
    .is_empty ( is_empty ),
    .is_full ( is_full ),
    .clock ( clock ),
    .reset ( reset )
);

endmodule
