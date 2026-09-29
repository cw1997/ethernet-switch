# ============================================================================
#  File        : librelane/constraints/io.sdc
#  Description : Timing constraints for the switch core.
#
#                The design has a single clock.  Every other port is a synchronous
#                data or control signal relative to it:
#
#                  * `clk_i`   - the only clock, 125 MHz nominal in the RTL
#                  * `rst_ni`  - an *active-low synchronous* reset, so it is an
#                                 ordinary input and is constrained as one.  A
#                                 design with an asynchronous reset would need a
#                                 `set_false_path` to the reset pins instead.
#                  * the GMII pins - clock-enable qualified, i.e. they change
#                                 only in the cycles in which a GMII octet time
#                                 runs, and are stable for the rest.  They are
#                                 ordinary synchronous I/O.
#
#                The GMII rate is a consequence of the clock, not a separate
#                clock: one octet per BYTE_PERIOD core clocks, where BYTE_PERIOD
#                is 1 at 1000BASE-T, 10 at 100BASE-TX and 100 at 10BASE-T on a
#                125 MHz core.  That is the whole reason the core has a single
#                clock domain and the ports are clock-enable driven.
# ============================================================================

# ---------------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------------
# `period` is authoritative and comes from the [clock] section of config.toml;
# this create_clock only has to name the port and agree with it.
create_clock -name core_clk -period 10.000 [get_ports {clk_i}]

# The design is fully synchronous and has no generated or divided clocks, so
# there are no other clock definitions and nothing to pre-CTS model.

# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------
# `rst_ni` is synchronous and active low.  It is therefore an ordinary input:
# it is given an input delay like every other input and is sampled on the clock
# edge.  Keeping it out of set_false_path is deliberate - a reset that is not
# properly constrained will show up as an unconstrained endpoint and make the
# timing report meaningless.
set_input_delay -clock core_clk -max 0.5 [get_ports {rst_ni}]
set_input_delay -clock core_clk -min 0.0 [get_ports {rst_ni}]

# ---------------------------------------------------------------------------
# I/O timing
# ---------------------------------------------------------------------------
# Exclude the clock itself; everything else that is an input is a synchronous
# data or control input.
set data_inputs [remove_from_collection [all_inputs] [get_ports {clk_i}]]
set data_outputs [all_outputs]

# 0.5 ns of input delay: a fifth of the period, a conventional figure for an
# on-chip or short off-chip source.  It is a real constraint, not a placeholder,
# so changing it changes the design the tool tries to build.
set_input_delay -clock core_clk -max 0.5 $data_inputs
set_input_delay -clock core_clk -min 0.0 $data_inputs

set_output_delay -clock core_clk -max 0.5 $data_outputs
set_output_delay -clock core_clk -min 0.0 $data_outputs

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
# A modest load on every output.  The GMII data buses are consumed by a PHY over
# a short PCB trace, and 10 pF is a reasonable lumped figure for that plus the
# receiver's input capacitance.
set_load -pin_load 0.010 $data_outputs

# Drive the inputs with a small, fast buffer so the input net has a real slew
# rather than an ideal one.
set_driving_cell -lib_cell BUFFD1BWP30P140 \
  -pin GB $data_inputs

# ---------------------------------------------------------------------------
# Design rule and area limits
# ---------------------------------------------------------------------------
# The design is a switch, not a datapath, so it is fairly small; these are
# generous ceilings that exist to catch a runaway synthesis rather than to
# constrain the result.
set_max_area 0
set_max_fanout 24
set_max_transition 1.0
