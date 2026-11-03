# ============================================================================
#  de2_115.sdc - TimeQuest constraints for the DE2-115 board shell
#
#  The core runs directly on the 50 MHz board oscillator; there is no PLL and
#  therefore no derived clock tree.  The only clocks that exist are clk_50 and
#  the two divide-by-two MII transmit clocks this shell exports.
# ============================================================================

# The whole switch is synchronous to this clock (rtl/ is single-clock by
# construction).
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

# Per-port MII transmit clocks.  The TX_CLK toggle registers clock on the
# *negedge* of clk_50, so their rising edges land on the source's falling
# edges: source edge numbering is 1 = rise @ 0 ns, 2 = fall @ 10 ns,
# 3 = rise @ 20 ns, ..., so a rise/fall/rise output pattern is edges 2, 4, 6.
create_generated_clock -name tx_clk0 -source [get_ports {CLOCK_50}] \
    -edges {2 4 6} [get_ports {ENET0_TX_CLK}]
create_generated_clock -name tx_clk1 -source [get_ports {CLOCK_50}] \
    -edges {2 4 6} [get_ports {ENET1_TX_CLK}]

derive_clock_uncertainty

# ---- asynchronous inputs ------------------------------------------------------
# The PHYs drive their RX pins from their own RX_CLK, which is asynchronous to
# clk_50 by construction (the link partner's clock).  The shell samples them
# in the clk_50 domain - the documented single-clock limitation of the board
# shell, see the header of hdl/sw_de2_115_top.sv - so declaring the crossing
# false is the honest constraint: there is no closure to be had here, and
# TimeQuest should not pretend otherwise.  MDIO and INT_N are unused inputs.
set_false_path -from [get_ports {ENET0_RX_DV ENET0_RX_ER ENET0_RX_DATA[*] \
                                 ENET1_RX_DV ENET1_RX_ER ENET1_RX_DATA[*] \
                                 ENET0_MDIO ENET1_MDIO \
                                 ENET0_INT_N ENET1_INT_N \
                                 KEY[*]}]

# The PHY reset outputs and the LEDs have no meaningful clocked relationship
# with clk_50 from the outside.
set_false_path -to [get_ports {ENET0_RESET_N ENET1_RESET_N \
                               LEDR[*] LEDG[*]}]

# ---- MII transmit outputs -------------------------------------------------------
# The PHY latches TXD/TX_EN/TX_ER on rising TX_CLK.  Data changes on clk_50
# posedges and TX_CLK rises on clk_50 negedges, so every nibble sits 10 ns
# before one rising edge and 10 ns after the previous one - phase
# independently (see hdl/sw_de2_115_top.sv).  IEEE 802.3 Clause 22 asks a MAC
# for 15 ns of setup; this structure guarantees 10 ns of raw offset, and the
# constraint below spends it as ">= 5 ns of setup at the PHY, <= 5 ns of
# routing skew between the data and clock output paths", which is what
# TimeQuest can actually enforce.  Tighten the 5.000 after a board
# measurement, not before.
set_output_delay -clock tx_clk0 -max 5.000 [get_ports {ENET0_TX_DATA[*] ENET0_TX_EN ENET0_TX_ER}]
set_output_delay -clock tx_clk0 -min 0.000 [get_ports {ENET0_TX_DATA[*] ENET0_TX_EN ENET0_TX_ER}]
set_output_delay -clock tx_clk1 -max 5.000 [get_ports {ENET1_TX_DATA[*] ENET1_TX_EN ENET1_TX_ER}]
set_output_delay -clock tx_clk1 -min 0.000 [get_ports {ENET1_TX_DATA[*] ENET1_TX_EN ENET1_TX_ER}]

# MDC idles low forever; no timing to check.
set_false_path -to [get_ports {ENET0_MDC ENET1_MDC}]
