module ethernet_switch_top (
    input  logic 		mii_tx_clk,
    output logic 		mii_tx_en,
    output logic 		mii_tx_er,
    output logic [ 3:0] mii_tx_data,
    input  logic		mii_rx_clk,
    input  logic		mii_rx_dv,
    input  logic		mii_rx_er,
    input  logic [ 3:0] mii_rx_data,
    output logic 		phy_rst_n,
    input  logic 		clock, rst_n
);

assign phy_rst_n = rst_n;

transceiver top_transceiver (
    .mii_tx_clock ( mii_tx_clk ),
    .mii_tx_enable ( mii_tx_en ),
    .mii_tx_data ( mii_tx_data ),
    .mii_rx_clock ( mii_rx_clk ),
    .mii_rx_data_valid ( mii_rx_dv ),
    .mii_rx_error ( mii_rx_er ),
    .mii_rx_data ( mii_rx_data ),
    .clock ( clock ),
    .reset ( ~rst_n ),
);

endmodule
