# ============================================================================
#  File        : librelane/constraints/io.sdc
#  Description : Timing constraints for the switch core.
#
#                The design has a single clock.  Every other port is a synchronous
#                data or control signal relative to it:
#
#                  * `clk_i`   - the only clock.  The RTL defaults to 125 MHz
#                                 (8 ns), but this flow runs it at 10 ns / 100 MHz
#                                 to match `CLOCK_PERIOD`; see the README.
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
# `period` is authoritative and comes from the [clock] section of config.json;
# this create_clock only has to name the port and agree with it.
create_clock -name core_clk -period 10.000 [get_ports {clk_i}]

# The design is fully synchronous and has no generated or divided clocks, so
# there are no other clock definitions and nothing to pre-CTS model.

# ---------------------------------------------------------------------------
# Port collections
# ---------------------------------------------------------------------------
# The data ports are named explicitly rather than derived as "all inputs minus
# the clock".
#
# The usual shorthand is
#
#     set data_inputs [remove_from_collection [all_inputs] [get_ports {clk_i}]]
#
# and `remove_from_collection` is a PrimeTime extension that OpenSTA - the timer
# this flow actually uses - does not have.  When it is used, OpenSTA aborts while
# *reading* the constraints, before a single path is analysed, and the timing
# sign-off step fails with a parse error that has nothing to do with timing.  The
# first run of this flow died exactly there, after 664k cells had already
# synthesised and mapped.
#
# Naming the ports is portable across every timer, states exactly what is
# constrained instead of what is not, and fails loudly if a port is renamed -
# which a wildcard would not.
set data_inputs [get_ports {rst_ni learning_en_i cfg_ovr_i cam_flush_i \
                            link_up_i[*] flood_mode_i[*] \
                            gmii_rx_en_i[*] gmii_rx_data_i[*]}]
set data_outputs [get_ports {gmii_tx_en_o[*] gmii_tx_data_o[*] stat_o[*]}]

# ---------------------------------------------------------------------------
# Input timing
# ---------------------------------------------------------------------------
# `rst_ni` is synchronous and active low.  It is therefore an ordinary input: it
# is given an input delay like every other input and is sampled on the clock
# edge.  Keeping it out of set_false_path is deliberate - a reset that is not
# properly constrained shows up as an unconstrained endpoint and makes the
# timing report meaningless.
#
# 0.5 ns of input delay is a twentieth of the 10 ns period, a conventional figure
# for an on-chip or short off-chip source.  It is a real constraint, not a
# placeholder, so changing it changes the design the tool tries to build.
set_input_delay -clock core_clk -max 0.5 $data_inputs
set_input_delay -clock core_clk -min 0.0 $data_inputs

# ---------------------------------------------------------------------------
# Output timing
# ---------------------------------------------------------------------------
# The same 0.5 ns on the way out: of the 10 ns period, 0.5 ns is spent satisfying
# the PHY's setup requirement at the far end of the interface.
set_output_delay -clock core_clk -max 0.5 $data_outputs
set_output_delay -clock core_clk -min 0.0 $data_outputs

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
# A modest load on every output.  The GMII data buses are consumed by a PHY over
# a short PCB trace.  Capacitive numbers in SDC are in the timer's capacitance
# unit, which for this library is the picofarad, so 0.010 here is 10 fF - a
# lumped figure for the receiver's input capacitance and the trace, not 10 pF.
set_load -pin_load 0.010 $data_outputs

# Drive the inputs with a small, fast buffer so the input net has a real slew
# rather than an ideal one.  The cell is named from the standard cell library
# this flow is run against (`sky130_fd_sc_hd`), because a liberty constraint
# that names a cell the library does not contain is not a constraint: the timer
# reports an unmatched cell and the paths through it are left unconstrained.
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_1 -pin X $data_inputs

# ---------------------------------------------------------------------------
# Design rule limit
# ---------------------------------------------------------------------------
# A transition limit is a real constraint and every timer understands it.  Area
# and fanout limits are not SDC: the area target is `FP_CORE_UTIL` in
# config.json, which the floorplanner uses to size the core.
#
# OpenSTA, unlike PrimeTime, does not accept the one-argument
# `set_max_transition 1.0` shorthand that means "every port"; it reports
# "set_max_transition requires two positional arguments" and stops.  It also has
# no `all_ports` command.  The port list is therefore spelled out, and it is the
# wildcard `[get_ports *]` rather than the input and output collections above
# because slew matters on the clock and on the outputs too.
set_max_transition 1.0 [get_ports *]
