module gray_code_decode #(
    parameter WIDTH
) (
    input  logic [WIDTH-1:0] gray_code,
    output logic [WIDTH-1:0] binary_code
);

always_comb begin
    binary_code[WIDTH-1] = gray_code[WIDTH-1];
    for (int i=WIDTH-1; i>=0; --i) begin
        binary_code[i-1] = binary_code[i] ^ gray_code[i-1];
    end
end

endmodule
