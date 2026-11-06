# Only the 50 MHz core clock is active.
create_clock -name sys_clk -period 20.000 [get_ports clk_i]

# PHY adaptation/CDC is required before enabling these 100 Mbit/s examples.
# Replace every <...> using PHY launch/capture edges, tCO, setup/hold and PCB skew.
# Each RX_CLK and TX_CLK below is an independent PHY output.

# Port 0: data bits [3:0].
# create_clock -name phy0_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[0]}]
# create_clock -name phy0_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[0]}]
# set_input_delay -clock phy0_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[0] mii_rxd_i[1] mii_rxd_i[2] mii_rxd_i[3] mii_rx_dv_i[0] mii_rx_er_i[0]}]
# set_output_delay -clock phy0_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[0] mii_txd_o[1] mii_txd_o[2] mii_txd_o[3] mii_tx_en_o[0] mii_tx_er_o[0]}]
# set_input_delay -clock phy0_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[0] mii_rxd_i[1] mii_rxd_i[2] mii_rxd_i[3] mii_rx_dv_i[0] mii_rx_er_i[0]}]
# set_output_delay -clock phy0_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[0] mii_txd_o[1] mii_txd_o[2] mii_txd_o[3] mii_tx_en_o[0] mii_tx_er_o[0]}]

# Port 1: data bits [7:4].
# create_clock -name phy1_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[1]}]
# create_clock -name phy1_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[1]}]
# set_input_delay -clock phy1_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[4] mii_rxd_i[5] mii_rxd_i[6] mii_rxd_i[7] mii_rx_dv_i[1] mii_rx_er_i[1]}]
# set_output_delay -clock phy1_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[4] mii_txd_o[5] mii_txd_o[6] mii_txd_o[7] mii_tx_en_o[1] mii_tx_er_o[1]}]
# set_input_delay -clock phy1_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[4] mii_rxd_i[5] mii_rxd_i[6] mii_rxd_i[7] mii_rx_dv_i[1] mii_rx_er_i[1]}]
# set_output_delay -clock phy1_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[4] mii_txd_o[5] mii_txd_o[6] mii_txd_o[7] mii_tx_en_o[1] mii_tx_er_o[1]}]

# Port 2: data bits [11:8].
# create_clock -name phy2_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[2]}]
# create_clock -name phy2_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[2]}]
# set_input_delay -clock phy2_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[8] mii_rxd_i[9] mii_rxd_i[10] mii_rxd_i[11] mii_rx_dv_i[2] mii_rx_er_i[2]}]
# set_output_delay -clock phy2_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[8] mii_txd_o[9] mii_txd_o[10] mii_txd_o[11] mii_tx_en_o[2] mii_tx_er_o[2]}]
# set_input_delay -clock phy2_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[8] mii_rxd_i[9] mii_rxd_i[10] mii_rxd_i[11] mii_rx_dv_i[2] mii_rx_er_i[2]}]
# set_output_delay -clock phy2_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[8] mii_txd_o[9] mii_txd_o[10] mii_txd_o[11] mii_tx_en_o[2] mii_tx_er_o[2]}]

# Port 3: data bits [15:12].
# create_clock -name phy3_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[3]}]
# create_clock -name phy3_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[3]}]
# set_input_delay -clock phy3_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[12] mii_rxd_i[13] mii_rxd_i[14] mii_rxd_i[15] mii_rx_dv_i[3] mii_rx_er_i[3]}]
# set_output_delay -clock phy3_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[12] mii_txd_o[13] mii_txd_o[14] mii_txd_o[15] mii_tx_en_o[3] mii_tx_er_o[3]}]
# set_input_delay -clock phy3_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[12] mii_rxd_i[13] mii_rxd_i[14] mii_rxd_i[15] mii_rx_dv_i[3] mii_rx_er_i[3]}]
# set_output_delay -clock phy3_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[12] mii_txd_o[13] mii_txd_o[14] mii_txd_o[15] mii_tx_en_o[3] mii_tx_er_o[3]}]

# Port 4: data bits [19:16].
# create_clock -name phy4_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[4]}]
# create_clock -name phy4_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[4]}]
# set_input_delay -clock phy4_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[16] mii_rxd_i[17] mii_rxd_i[18] mii_rxd_i[19] mii_rx_dv_i[4] mii_rx_er_i[4]}]
# set_output_delay -clock phy4_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[16] mii_txd_o[17] mii_txd_o[18] mii_txd_o[19] mii_tx_en_o[4] mii_tx_er_o[4]}]
# set_input_delay -clock phy4_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[16] mii_rxd_i[17] mii_rxd_i[18] mii_rxd_i[19] mii_rx_dv_i[4] mii_rx_er_i[4]}]
# set_output_delay -clock phy4_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[16] mii_txd_o[17] mii_txd_o[18] mii_txd_o[19] mii_tx_en_o[4] mii_tx_er_o[4]}]

# Port 5: data bits [23:20].
# create_clock -name phy5_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[5]}]
# create_clock -name phy5_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[5]}]
# set_input_delay -clock phy5_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[20] mii_rxd_i[21] mii_rxd_i[22] mii_rxd_i[23] mii_rx_dv_i[5] mii_rx_er_i[5]}]
# set_output_delay -clock phy5_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[20] mii_txd_o[21] mii_txd_o[22] mii_txd_o[23] mii_tx_en_o[5] mii_tx_er_o[5]}]
# set_input_delay -clock phy5_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[20] mii_rxd_i[21] mii_rxd_i[22] mii_rxd_i[23] mii_rx_dv_i[5] mii_rx_er_i[5]}]
# set_output_delay -clock phy5_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[20] mii_txd_o[21] mii_txd_o[22] mii_txd_o[23] mii_tx_en_o[5] mii_tx_er_o[5]}]

# Port 6: data bits [27:24].
# create_clock -name phy6_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[6]}]
# create_clock -name phy6_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[6]}]
# set_input_delay -clock phy6_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[24] mii_rxd_i[25] mii_rxd_i[26] mii_rxd_i[27] mii_rx_dv_i[6] mii_rx_er_i[6]}]
# set_output_delay -clock phy6_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[24] mii_txd_o[25] mii_txd_o[26] mii_txd_o[27] mii_tx_en_o[6] mii_tx_er_o[6]}]
# set_input_delay -clock phy6_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[24] mii_rxd_i[25] mii_rxd_i[26] mii_rxd_i[27] mii_rx_dv_i[6] mii_rx_er_i[6]}]
# set_output_delay -clock phy6_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[24] mii_txd_o[25] mii_txd_o[26] mii_txd_o[27] mii_tx_en_o[6] mii_tx_er_o[6]}]

# Port 7: data bits [31:28].
# create_clock -name phy7_rx_clk -period 40.000 [get_ports {mii_rx_clk_i[7]}]
# create_clock -name phy7_tx_clk -period 40.000 [get_ports {mii_tx_clk_i[7]}]
# set_input_delay -clock phy7_rx_clk -min <RX_MIN_NS> [get_ports {mii_rxd_i[28] mii_rxd_i[29] mii_rxd_i[30] mii_rxd_i[31] mii_rx_dv_i[7] mii_rx_er_i[7]}]
# set_output_delay -clock phy7_tx_clk -min <TX_MIN_NS> [get_ports {mii_txd_o[28] mii_txd_o[29] mii_txd_o[30] mii_txd_o[31] mii_tx_en_o[7] mii_tx_er_o[7]}]
# set_input_delay -clock phy7_rx_clk -max <RX_MAX_NS> [get_ports {mii_rxd_i[28] mii_rxd_i[29] mii_rxd_i[30] mii_rxd_i[31] mii_rx_dv_i[7] mii_rx_er_i[7]}]
# set_output_delay -clock phy7_tx_clk -max <TX_MAX_NS> [get_ports {mii_txd_o[28] mii_txd_o[29] mii_txd_o[30] mii_txd_o[31] mii_tx_en_o[7] mii_tx_er_o[7]}]

# Output -min commonly includes negative hold time.
# rst_button_ni feeds only the ASYNC_REG chain: add a board-specific exception
# to the first sampling flop only; never cut the inter-stage timing path.
# No global false paths/clock groups hide unfinished CDC.
# PHY reset/MDIO electrical and timing requirements also need board review.
