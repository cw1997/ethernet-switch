# ============================================================================
# File        : pins.xdc
# Description : Physical pin/electrical TEMPLATE for es_switch_vivado_top, eight MII
#               ports plus a 50 MHz clock and an active-low reset button.
#               All assignments below are intentionally commented: the FPGA
#               package identifies legal pins, not the board's actual wiring.
#
#               Replace <PIN>/<STANDARD> using the board schematic, bank VCCO
#               and PHY I/O voltage before enabling each assignment. There are
#               2 + 8*17 = 138 port bits; the pure-switching design exports no
#               statistics, console or panel bus, so every pin is a PHY, clock
#               or reset signal. Port p uses data [4*p +: 4] and bit p of each
#               per-port control bus.
#               Keep this inventory in step with the HDL and timing templates.
#
#               Preserve UCIO-1/NSTD-1 severity: an incomplete template must
#               fail bitstream checks rather than choose arbitrary board pins.
# ============================================================================

# ---- board clock and mechanical reset ---------------------------------------
# clk_i needs a clock-capable pin. A differential board oscillator requires
# an HDL input-buffer adaptation as well as a different physical pin mapping.

# set_property PACKAGE_PIN <PIN> [get_ports {clk_i}]
# set_property IOSTANDARD <STANDARD> [get_ports {clk_i}]

# set_property PACKAGE_PIN <PIN> [get_ports {rst_button_ni}]
# set_property IOSTANDARD <STANDARD> [get_ports {rst_button_ni}]

# ---- PHY-supplied receive clocks (currently reserved in the HDL) -------------
# These signals are inputs even though their timing templates use create_clock.
# Assigning pins does not implement the missing per-port capture/CDC logic.
# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_clk_i[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_clk_i[7]}]

# ---- PHY-supplied transmit clocks -------------------------------------------
# Standard MII TX_CLK is driven by the PHY; do not wire it as an FPGA output.
# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_clk_i[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_clk_i[7]}]

# ---- receive valid/error status ---------------------------------------------
# Each status bit belongs to the same port as its four-bit RX data slice.
# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_dv_i[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_dv_i[7]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rx_er_i[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rx_er_i[7]}]

# ---- receive data, four pins per port ---------------------------------------
# Consecutive groups are port 0 [3:0] through port 7 [31:28]; match the PHY's
# RXD bit numbering within each group rather than reversing nibble wire order.
# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[7]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[8]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[8]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[9]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[9]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[10]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[10]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[11]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[11]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[12]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[12]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[13]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[13]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[14]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[14]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[15]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[15]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[16]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[16]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[17]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[17]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[18]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[18]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[19]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[19]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[20]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[20]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[21]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[21]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[22]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[22]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[23]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[23]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[24]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[24]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[25]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[25]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[26]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[26]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[27]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[27]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[28]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[28]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[29]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[29]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[30]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[30]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_rxd_i[31]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_rxd_i[31]}]

# ---- transmit enable/error status -------------------------------------------
# Keep each TX_EN/TX_ER bit with its own port's TXD and PHY TX_CLK pins.
# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_en_o[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_en_o[7]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_tx_er_o[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_tx_er_o[7]}]

# ---- transmit data, four pins per port --------------------------------------
# Bus packing is the same as RX; nibble serialization is performed in es_switch_mii.
# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[7]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[8]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[8]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[9]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[9]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[10]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[10]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[11]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[11]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[12]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[12]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[13]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[13]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[14]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[14]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[15]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[15]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[16]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[16]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[17]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[17]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[18]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[18]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[19]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[19]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[20]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[20]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[21]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[21]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[22]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[22]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[23]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[23]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[24]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[24]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[25]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[25]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[26]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[26]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[27]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[27]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[28]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[28]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[29]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[29]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[30]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[30]}]

# set_property PACKAGE_PIN <PIN> [get_ports {mii_txd_o[31]}]
# set_property IOSTANDARD <STANDARD> [get_ports {mii_txd_o[31]}]

# ---- PHY reset and idle management pins -------------------------------------
# Reset is active low but has no PHY-specific hold/stabilization timer. MDC is
# held low, MDIO is released; external pull-ups and valid PHY straps are still
# required. Do not infer an FPGA I/O voltage from the RJ45 line-side voltage.
# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_reset_no[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_reset_no[7]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdc_o[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdc_o[7]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[0]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[0]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[1]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[1]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[2]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[2]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[3]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[3]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[4]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[4]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[5]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[5]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[6]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[6]}]

# set_property PACKAGE_PIN <PIN> [get_ports {phy_mdio_io[7]}]
# set_property IOSTANDARD <STANDARD> [get_ports {phy_mdio_io[7]}]

