module transceiver #(
    mac_address = 48'h11_22_33_44_55_66
) (
    input  logic        mii_tx_clock,
    output logic        mii_tx_enable,
    output logic        mii_tx_error,
    output logic [ 3:0] mii_tx_data,
    input  logic        mii_rx_clock,
    input  logic        mii_rx_data_valid,
    input  logic        mii_rx_error,
    input  logic [ 3:0] mii_rx_data,
    input  logic        clock, reset
);

localparam
WIDTH = 8, DEPTH = 32;

logic [WIDTH-1:0] read_data;
logic             read_enable;
logic [WIDTH-1:0] write_data;
logic             write_enable;
logic             is_empty;
logic             is_full;

fifo #(
    .WIDTH ( WIDTH ),
    .DEPTH ( DEPTH )
) transceiver_fifo (
    .read_data ( read_data ),
    .read_enable ( read_enable ),
    .write_data ( write_data ),
    .write_enable ( write_enable ),
    .is_empty ( is_empty ),
    .is_full ( is_full ),
    .clock ( clock ),
    .reset ( reset )
);

logic rxdv_edge_positive, rxdv_edge_negative, rxdv_level_high, rxdv_level_low;
signal_detect signal_detect_rxdv (
    .signal ( mii_rx_data_valid ),
    .edge_positive ( rxdv_edge_positive ),
    .edge_negative ( rxdv_edge_negative ),
    .level_high ( rxdv_level_high ),
    .level_low ( rxdv_level_low ),
    .clock ( clock ),
    .reset ( reset )
);

logic rxc_edge_positive, rxc_edge_negative, rxc_level_high, rxc_level_low;
signal_detect signal_detect_mii_rx_clock (
    .signal ( mii_rx_clock ),
    .edge_positive ( rxc_edge_positive ),
    .edge_negative ( rxc_edge_negative ),
    .level_high ( rxc_level_high ),
    .level_low ( rxc_level_low ),
    .clock ( clock ),
    .reset ( reset )
);

enum logic [1:0] {
    STATE_TRANSMIT_7_4 = 2'h1,
    STATE_TRANSMIT_3_0 = 2'h2
} state_send, state_recv;

always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
        write_data <= 0;
        write_enable <= 0;
        state_recv <= STATE_TRANSMIT_7_4;
    end else begin
        unique case (state_recv)
            STATE_TRANSMIT_7_4: begin
                write_enable <= 0;
                if (rxdv_edge_positive | (rxdv_level_high & rxc_edge_positive)) begin
                    state_recv <= STATE_TRANSMIT_3_0;
                    write_data[7:4] <= mii_rx_data;
                end else begin
                    state_recv <= STATE_TRANSMIT_7_4;
                end
            end
            STATE_TRANSMIT_3_0: begin
                if (rxdv_level_high & rxc_edge_positive) begin
                    write_data[3:0] <= mii_rx_data;
                    write_enable <= 1;
                    state_recv <= STATE_TRANSMIT_7_4;
                end else begin
                    write_enable <= 0;
                    state_recv <= STATE_TRANSMIT_3_0;
                end
            end
            default: state_send <= STATE_TRANSMIT_7_4;
        endcase
    end
end

endmodule
