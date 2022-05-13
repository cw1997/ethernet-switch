module ethernet_switch_top #(
    PORT_NUMBER = 4
) (
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

logic        switch_mii_tx_clock      [PORT_NUMBER];
logic        switch_mii_tx_enable     [PORT_NUMBER];
logic        switch_mii_tx_error      [PORT_NUMBER];
logic [ 3:0] switch_mii_tx_data       [PORT_NUMBER];
logic        switch_mii_rx_clock      [PORT_NUMBER];
logic        switch_mii_rx_data_valid [PORT_NUMBER];
logic        switch_mii_rx_error      [PORT_NUMBER];
logic [ 3:0] switch_mii_rx_data       [PORT_NUMBER];

assign switch_mii_tx_clock[0] = mii_tx_clk;
assign mii_tx_en = switch_mii_tx_enable[0];
assign mii_tx_er = switch_mii_tx_error[0];
assign mii_tx_data = switch_mii_tx_data[0];
assign switch_mii_rx_clock[0] = mii_rx_clk;
assign switch_mii_rx_data_valid[0] = mii_rx_dv;
assign switch_mii_rx_error[0] = mii_rx_er;
assign switch_mii_rx_data[0] = mii_rx_data;

switch #(
    .PORT_NUMBER ( PORT_NUMBER )
) top_switch (
    .mii_tx_clock      ( switch_mii_tx_clock ),
    .mii_tx_enable     ( switch_mii_tx_enable ),
    .mii_tx_error      ( switch_mii_tx_error ),
    .mii_tx_data       ( switch_mii_tx_data ),
    .mii_rx_clock      ( switch_mii_rx_clock ),
    .mii_rx_data_valid ( switch_mii_rx_data_valid ),
    .mii_rx_error      ( switch_mii_rx_error ),
    .mii_rx_data       ( switch_mii_rx_data ),
    .clock ( clock ),
    .reset ( ~rst_n ),
);

endmodule
