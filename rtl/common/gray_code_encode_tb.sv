`timescale 1ns/1ns
module gray_code_encode_tb #(
    // parameters
    clock_period = 2
) (
    // ports
);

localparam WIDTH = 8;

// logic clock, reset;
// always #(clock_period/2) clock = ~clock;

logic [WIDTH-1:0] binary_code;
logic [WIDTH-1:0] gray_code;

initial begin
    $monitor("%t : binary_code = 0x%h (%bb) , gray_code = 0x%h (%bb)", $time, binary_code, binary_code, gray_code, gray_code);

    for (int i=0; i<2**WIDTH; ++i) begin
        binary_code <= i;
        #2;
    end

    $stop();
end

gray_code_encode #(
    .WIDTH ( WIDTH )
) tb_gray_code_encode (
    .binary_code ( binary_code ),
    .gray_code ( gray_code )
);

endmodule
