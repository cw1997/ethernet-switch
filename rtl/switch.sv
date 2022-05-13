module switch #(
    // parameters
    // parameter
    // WIDTH = 32,
    // DEPTH = 8
    PORT_NUMBER = 4,
    ADDRESS_LOOKUP_ENTITY_NUMBER = PORT_NUMBER * PORT_NUMBER
) (
    // ports
//    input  logic        deliver_out_enable,
//    input  logic [47:0] deliver_out_mac_address,
//    input  logic [ 7:0] deliver_out_data [0:1535],
    input  logic        mii_tx_clock      [PORT_NUMBER],
    output logic        mii_tx_enable     [PORT_NUMBER],
    output logic        mii_tx_error      [PORT_NUMBER],
    output logic [ 3:0] mii_tx_data       [PORT_NUMBER],
    input  logic        mii_rx_clock      [PORT_NUMBER],
    input  logic        mii_rx_data_valid [PORT_NUMBER],
    input  logic        mii_rx_error      [PORT_NUMBER],
    input  logic [ 3:0] mii_rx_data       [PORT_NUMBER],
    input  logic        clock, reset
);

// logic        mii_tx_clock              [PORT_NUMBER];
// logic        mii_tx_enable             [PORT_NUMBER];
// logic        mii_tx_error              [PORT_NUMBER];
// logic [ 3:0] mii_tx_data               [PORT_NUMBER];
// logic        mii_rx_clock              [PORT_NUMBER];
// logic        mii_rx_data_valid         [PORT_NUMBER];
// logic        mii_rx_error              [PORT_NUMBER];
// logic        mii_rx_data               [PORT_NUMBER];
logic        switch_ready              [PORT_NUMBER];
logic        switch_vaild              [PORT_NUMBER];
logic [15:0] switch_length             [PORT_NUMBER];
logic [47:0] switch_source_mac_address [PORT_NUMBER];
logic [47:0] switch_destin_mac_address [PORT_NUMBER];
logic        switch_mii_tx_clock       [PORT_NUMBER];
logic        switch_mii_tx_enable      [PORT_NUMBER];
logic        switch_mii_tx_error       [PORT_NUMBER];
logic [ 3:0] switch_mii_tx_data        [PORT_NUMBER];

genvar port_index;
generate
for (port_index=0; port_index<PORT_NUMBER; ++port_index) begin: gen_transceiver
    transceiver switch_transceiver[port_index] (
        .mii_tx_clock ( mii_tx_clock[port_index] ),
        .mii_tx_enable ( mii_tx_enable[port_index] ),
        .mii_tx_error ( mii_tx_error[port_index] ),
        .mii_tx_data ( mii_tx_data[port_index] ),
        .mii_rx_clock ( mii_rx_clock[port_index] ),
        .mii_rx_data_valid ( mii_rx_data_valid[port_index] ),
        .mii_rx_error ( mii_rx_error[port_index] ),
        .mii_rx_data ( mii_rx_data[port_index] ),
        .switch_ready ( switch_ready[port_index] ),
        .switch_vaild ( switch_vaild[port_index] ),
        .switch_length ( switch_length[port_index] ),
        .switch_source_mac_address ( switch_source_mac_address[port_index] ),
        .switch_destin_mac_address ( switch_destin_mac_address[port_index] ),
        .switch_mii_tx_clock ( switch_mii_tx_clock[port_index] ),
        .switch_mii_tx_enable ( switch_mii_tx_enable[port_index] ),
        .switch_mii_tx_error ( switch_mii_tx_error[port_index] ),
        .switch_mii_tx_data ( switch_mii_tx_data[port_index] ),
        .clock ( clock ),
        .reset ( reset ),
    );
end
endgenerate


typedef struct packed {
    logic [47:0] mac_address;
    logic [ 1:0] port_index;
} address_lookup_table_t;
address_lookup_table_t address_lookup_table [ADDRESS_LOOKUP_ENTITY_NUMBER];

// logic match_table [PORT_NUMBER][ADDRESS_LOOKUP_ENTITY_NUMBER];
// logic match_port_index [ADDRESS_LOOKUP_ENTITY_NUMBER];

always_ff @(posedge clock or posedge reset) begin
    for (int port_index=0; port_index<PORT_NUMBER; ++port_index) begin
        for (int address_lookup_index=0; address_lookup_index<ADDRESS_LOOKUP_ENTITY_NUMBER; ++address_lookup_index) begin
            // match_table[port_index][address_lookup_index] = switch_destin_mac_address[port_index] == address_lookup_table[address_lookup_index].mac_address;
            // match_port_index[address_lookup_index] = address_lookup_table[address_lookup_index].port_index;
            // if (switch_destin_mac_address[port_index] == address_lookup_table[address_lookup_index].mac_address) begin
                // switch_mii_tx_clock[(address_lookup_table[address_lookup_index].port_index)] <= mii_tx_clock[port_index];
                // mii_tx_enable[port_index] <= switch_mii_tx_enable[(address_lookup_table[address_lookup_index].port_index)];
                // mii_tx_error[port_index] <= switch_mii_tx_error[(address_lookup_table[address_lookup_index].port_index)];
                // mii_tx_data[port_index] <= switch_mii_tx_data[(address_lookup_table[address_lookup_index].port_index)];
            // end
        end
    end
end

// always_ff @(posedge clock or posedge reset) begin
//         for (int port_index=0; port_index<PORT_NUMBER; ++port_index) begin
//             for (int address_lookup_index=0; address_lookup_index<ADDRESS_LOOKUP_ENTITY_NUMBER; ++address_lookup_index) begin
//                 match_table[port_index][address_lookup_index]: begin
//                     mii_tx_clock[port_index] <= switch_mii_tx_clock[(address_lookup_table[address_lookup_index].port_index)];
//                     mii_tx_enable[port_index] <= switch_mii_tx_enable[(address_lookup_table[address_lookup_index].port_index)];
//                     mii_tx_error[port_index] <= switch_mii_tx_error[(address_lookup_table[address_lookup_index].port_index)];
//                     mii_tx_data[port_index] <= switch_mii_tx_data[(address_lookup_table[address_lookup_index].port_index)];
//                 end
//             end
//         end
// end

// logic [47:0] mac_address_map [0:3];
// wire [0:3] match = {
//     deliver_out_mac_address == [0],
//     deliver_out_mac_address == [1],
//     deliver_out_mac_address == [2],
//     deliver_out_mac_address == [3]
// }

// always_comb begin
//     unique case (1'b1)
//         match[0]: ;
//         match[1]: ;
//         match[2]: ;
//         match[3]: ;
//     endcase
// end


endmodule
