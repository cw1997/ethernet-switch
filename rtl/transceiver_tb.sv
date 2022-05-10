`timescale 1ns/1ns
module transceiver_tb #(
    // parameters
    clock_period = 2
) (
    // ports
);

localparam WIDTH = 4, DEPTH = 4;

logic clock, reset;
always #(clock_period/2) clock = ~clock;

logic        mii_tx_clock;
logic        mii_tx_enable;
logic        mii_tx_error;
logic [ 3:0] mii_tx_data;
logic        mii_rx_clock;
logic        mii_rx_data_valid;
logic        mii_rx_error;
logic [ 3:0] mii_rx_data;

localparam MAC_PACKET_LENGTH = 8 + 6 * 2 + 2 + 2 + 4;

bit [7:0] mac_packet [MAC_PACKET_LENGTH];

initial begin
    mac_packet = {
        8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h5D, // Preamble + SFD
        8'h11, 8'h22, 8'h33, 8'h44, 8'h55, 8'h66, // destin mac 11-22-33-44-55-66
        8'hAA, 8'hBB, 8'hCC, 8'hDD, 8'hEE, 8'hFF, // source mac AA-BB-CC-DD-EE-FF
        8'h08, 8'h00, // IP packet type
        8'h12, 8'h34, // payload
        8'hAB, 8'hCD, 8'hEF, 8'h01 // checksum CRC32 4-bytes
    };

    $monitor("%t : mii_rx_data_valid = %b, mii_rx_data = 0x%h (%bb)", $time, mii_rx_data_valid, mii_rx_data, mii_rx_data);
    // $monitor("%t : mii_tx_enable = %b, mii_tx_data = 0x%h (%bb)", $time, mii_tx_enable, mii_tx_data, mii_tx_data);

    mii_rx_error = 0;
    mii_rx_data_valid = 0;
    mii_rx_data = 4'd0;
    mii_rx_clock = 0;

    clock = 1;
    reset = 1;
    #4;
    reset = 0;

    mii_rx_data_valid = 1;

    for (int i=0; i<MAC_PACKET_LENGTH; ++i) begin
        mii_rx_data = mac_packet[i][7:4];
        #(clock_period);
        mii_rx_clock = 1;
        #(clock_period);
        mii_rx_clock = 0;

        mii_rx_data = mac_packet[i][3:0];
        #(clock_period);
        mii_rx_clock = 1;
        #(clock_period);
        mii_rx_clock = 0;
    end

    mii_rx_data_valid = 0;

    #(clock_period * 4);

    $stop();
end

transceiver #(
) tb_transceiver (
    .mii_tx_clock ( mii_tx_clock ),
    .mii_tx_enable ( mii_tx_enable ),
    .mii_tx_error ( mii_tx_error ),
    .mii_tx_data ( mii_tx_data ),
    .mii_rx_clock ( mii_rx_clock ),
    .mii_rx_data_valid ( mii_rx_data_valid ),
    .mii_rx_error ( mii_rx_error ),
    .mii_rx_data ( mii_rx_data ),
    .clock ( clock ),
    .reset ( reset )
);

endmodule
