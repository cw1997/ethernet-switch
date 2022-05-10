`timescale 1ns/1ns
module signal_detect_tb #(
    // parameters
    clock_period = 2
) (
    // ports
);

logic clock, reset;
logic signal;

always #(clock_period/2) clock = ~clock;

initial begin
    clock <= 0;
    reset <= 1;
    signal <= 0;

    #3;
    reset <= 0;

    #1;
    signal <= 0;

    #2;
    signal <= 1;

    #1;
    signal <= 1;

    #3;
    signal <= 0;

    #4;

    $stop();
end

logic edge_positive, edge_negative, level_high, level_low;
signal_detect signal_detect_inst (
    .signal ( signal ),
    .edge_positive ( edge_positive ),
    .edge_negative ( edge_negative ),
    .level_high ( level_high ),
    .level_low ( level_low ),
    .clock ( clock ),
    .reset ( reset )
);

endmodule