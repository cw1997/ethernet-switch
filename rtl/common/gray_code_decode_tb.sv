`timescale 1ns/1ns
module gray_code_decode_tb #(
    // parameters
    clock_period = 2
) (
    // ports
);

localparam WIDTH = 4;

// logic clock, reset;
// always #(clock_period/2) clock = ~clock;

logic [WIDTH-1:0] gray_code;
logic [WIDTH-1:0] binary_code;

bit [WIDTH-1:0] gray_codes [2**WIDTH];

// $monitor("%t\tbinary_code = %x, gray_code = %x", $time, binary_code, gray_code);

initial begin
    gray_codes[ 0] = 4'b0000;
    gray_codes[ 1] = 4'b0001;
    gray_codes[ 2] = 4'b0011;
    gray_codes[ 3] = 4'b0010;
    gray_codes[ 4] = 4'b0110;
    gray_codes[ 5] = 4'b0111;
    gray_codes[ 6] = 4'b0101;
    gray_codes[ 7] = 4'b0100;
    gray_codes[ 8] = 4'b1100;
    gray_codes[ 9] = 4'b1101;
    gray_codes[10] = 4'b1111;
    gray_codes[11] = 4'b1110;
    gray_codes[12] = 4'b1010;
    gray_codes[13] = 4'b1011;
    gray_codes[14] = 4'b1001;
    gray_codes[15] = 4'b1000;

    $monitor("%t : binary_code = 0x%h (%bb) , gray_code = 0x%h (%bb)", $time, binary_code, binary_code, gray_code, gray_code);

    for (int i=0; i<2**WIDTH; ++i) begin
        gray_code <= gray_codes[i];
        #2;
    end

    $stop();
end

gray_code_decode #(
    .WIDTH ( WIDTH )
) tb_gray_code_decode (
    .gray_code ( gray_code ),
    .binary_code ( binary_code )
);

endmodule
