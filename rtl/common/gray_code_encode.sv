module gray_code_encode #(
    WIDTH
) (
    input  logic [WIDTH-1:0] binary_code,
    output logic [WIDTH-1:0] gray_code
);

assign gray_code = (binary_code >> 1) ^ binary_code;

endmodule
