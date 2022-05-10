module signal_detect (
    // ports
    input  logic        signal,
    output logic        edge_positive,
    output logic        edge_negative,
    output logic        level_high,
    output logic        level_low,
    input  logic        clock,
    input  logic        reset
);

logic signal_prev;

always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
        edge_positive  <= 0;
        edge_negative  <= 0;
        level_high     <=  signal;
        level_low      <= ~signal;
        signal_prev    <= 0;
    end else begin
        edge_positive  <= ~signal_prev &  signal;
        edge_negative  <=  signal_prev & ~signal;
        level_high     <=  signal_prev &  signal;
        level_low      <= ~signal_prev & ~signal;
        signal_prev    <=  signal;
    end
end

endmodule