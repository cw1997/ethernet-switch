# LibreLane / OpenLane 2 build

Physical implementation of `sw_switch` down to a GDSII.

## Layout

    librelane/
      config.json              the flow configuration
      constraints/io.sdc       timing constraints
      runs/                    per-run working directory (generated, not committed)

## Running it

    mkdir -p .cache/librelane
    docker run --rm \
      --user "$(id -u):$(id -g)" \
      -e HOME=/work/.cache/librelane \
      -v "$PWD:/work" -w /work \
      ghcr.io/librelane/librelane:2.4.2 \
      librelane --pdk sky130A -s sky130_fd_sc_hd librelane/config.json

The image is a Nix closure, so the toolchain is exactly the one the flow was
released with.  The `--user` flag keeps the run's outputs owned by the invoking
user rather than by root; without it the run directory comes out root-owned and
the next local run cannot overwrite it.

`HOME` points at a directory inside the workspace rather than at `/tmp`,
because that is where the flow keeps its PDK download.  The PDK is over a
gigabyte and takes a few minutes, and a run that has to fetch it from scratch is
a run that fails when the network hiccups - which is exactly what happened the
first time this flow was run here.  With a persistent `HOME` the PDK is fetched
once and every later run reuses it.

CI does the same thing in the `gds` job of `../.github/workflows/ci.yml`, behind
a manual approval, and caches `.cache/librelane` between runs.

## Configuration notes

**`CLOCK_PERIOD = 10`** (100 MHz).  The RTL default is `CLK_FREQ_HZ =
125_000_000`, i.e. 8 ns, and the design does not close at 8 ns on the free
open-source PDK: the forwarding table is a 128x4 set-associative CAM with a
single-clock read port, and the ingress buffer chains a FIFO read, a parser state
machine and a 64-bit write.  10 ns is a defensible target for this core and keeps
CI meaningful.  It is the knob to relax or tighten - a period that is too small
shows up as a routing failure, never as a wrong GDSII.

**`VERILOG_DEFINES = ["SYNTHESIS"]`**.  The RTL tests for it: the
elaboration-time `$error` / `$warning` checks in `sw_switch` are simulation only,
because yosys has no implementation for those system tasks and aborts on a
design containing them.

**`RT_MIN_LAYER` / `RT_MAX_LAYER` are `met1` / `met5`.**  These name *tech LEF
routing layers*, and sky130's routing layers are `li1`, `met1` … `met5` - there
is no `M9`.  The consequence of getting it wrong is indirect and expensive:
`scripts/openroad/common/set_rc.tcl` walks the routing layers and switches
"collecting" on at the layer whose name equals `RT_MIN_LAYER` and off at
`RT_MAX_LAYER`.  A name that matches nothing leaves that list empty, the script
falls into its single-layer branch and calls

    set_wire_rc -signal -layer ""

which OpenROAD rejects with `[RSZ-0015] layer NULL not found`.  The flow dies
there, at step 23 of 78, *after* global placement has already run.  A setting
whose failure mode is an empty list several steps downstream of the mistake is
worth pinning down in `config.json` rather than leaving to a default.

### `SYNTH_PARAMETERS`: why this run is smaller than the regression

The physical run elaborates a **reduced** instance of the core.  This is
deliberate, it is the difference between a flow that finishes and one that does
not, and it is worth being precise about which is which.

| | module defaults (what the regression exercises) | `SYNTH_PARAMETERS` (this run) |
|---|---|---|
| `MAX_FRAME_LEN` | 1518 | 256 |
| `RX_FIFO_DEPTH` / `TX_FIFO_DEPTH` | 256 beats | 64 beats |
| `TAG_FIFO_DEPTH` | 16 | 8 |
| `WF_DEPTH` | 16 | 8 |
| `CAM_SETS` x `CAM_WAYS` | 128 x 4 | 16 x 2 |
| synthesised cells | 663 923 | 132 678 |
| flip-flops | 168 593 | 42 748 |
| cell area (sky130) | 3.59 mm^2 | 1.911 mm^2 |

The reduced-instance figures are what LibreLane's own yosys reports at step 6:
`Number of cells: 132678`, of which `sky130_fd_sc_hd__dfxtp_2` 42 748, and
`Chip area for module '\sw_switch': 1911082.88` um^2.  The full-size figures
come from the same tool with the module defaults.  (`make synth`, which uses the
locally installed yosys rather than the container's, reports 137 413 cells for
the same instance; the 3.5% difference is ABC mapping between yosys versions,
not a different design.)

What was measured, not estimated: the full-size instance reaches technology
mapping and hands ABC a 694 687-gate netlist with 168 639 inputs and 168 805
outputs.  ABC's area-recovery pass is single-threaded at that size, and it had
not finished after two and a half hours.  The reduced instance is 5x smaller
and is what the flow below actually completes.

The instance stays self-consistent: `sw_beats_of(MAX_FRAME_LEN)` is 32 beats
and the buffers are 64, so the design's own elaboration-time sanity checks stay
quiet and the core still accepts every frame up to 256 octets.  The parameters
are exactly the ones that set the storage: the eight 256x64 ingress and egress
buffers and the 128x4 forwarding table are almost all of the flip-flops, and the
first-word-fall-through read multiplexer of each of those eight buffers is a
large fraction of the combinational area - `sky130_fd_sc_hd` has no SRAM macro,
so there is no memory to infer and every bit is a register behind a mux tree.

**What this run is not.**  It is not a claim that the full configuration has been
placed and routed.  It proves that the design reads, elaborates, synthesises and
routes through the whole flow on the open-source PDK, at a size the flow can
finish.  The full-size cell and area figures above are real, and are what a
full-size implementation would start from; they need a commercial-grade flow, a
much longer run, and a memory compiler to be practical.

The regression is unaffected.  `tb_sw_switch` exercises the full-size
parameters in simulation (1518 octet frames, 256 beat buffers, a 128x4 CAM) and
`sw_flood_tb` covers a third port count and two clock rates.  Reducing the
physical run makes room for the flow; it does not replace any of that.

## Synthesis portability

The design is written to survive the frontend that OpenLane / LibreLane drive
(`yosys`, via `read_verilog -sv`).  That frontend is far more restricted than a
simulator, and it fails in three separate places, so the RTL avoids all three.
The reasoning is recorded in `rtl/sw_defs.sv`; this is the summary.

**1. No `package`.**  The shared declarations - protocol constants, the link
speed model, the tag layout, the statistics map - used to live in
`sw_switch_pkg`.  They now sit at *compilation-unit* scope in `rtl/sw_defs.sv`,
which every RTL file `` `include``s, and no module needs an import clause.  A
package is unusable here for three reasons:

* A package item is not a *constant range*, so a width taken from the package is
  rejected in a port declaration - `Non-constant range in declaration of
  \fr_len_i`.  Promoting it to a module parameter does not help: a package
  localparam in a parameter default, and a package function call, fail the same
  way.  Twelve port declarations across six files were affected.
* A call to a package function must be explicitly scoped.  An unscoped call is
  not resolved at all: `Can't resolve function name '\sw_is_broadcast'`.
* No form of the import is accepted - not `module X import pkg::*; (...)`, not
  the in-body `import pkg::*;`, not the file-scope form.  The parse dies on the
  `import` token with a message that points at the module keyword.

Compilation-unit scope has none of these restrictions: the frontend makes those
names visible in parameter lists, port ranges, bodies and subroutine argument
lists alike.  It is also a single definition, so there is still exactly one copy
of every constant.  Icarus Verilog and Verilator accept the form unchanged, and
the testbenches see the same names because they are compiled into the same
compilation unit as the RTL.

**2. No `return` in any function.**  The same frontend rejects `return` in *any*
function, in package scope and in module scope alike, and with or without an
enclosing `case` or `begin` - `sw_rx_port.sv:171: ERROR: syntax error, unexpected
TOK_ID`.  Every function in the RTL therefore assigns to the function name, which
IEEE 1800-2017 13.3 defines as equivalent.  The simulators accept `return`, so
this failure only appears once the design is handed to the flow, and the message
points at the `return` token rather than at anything semantically wrong.

**3. No `$error` / `$warning` in the netlist.**  Already handled by the
`SYNTHESIS` guard in `sw_switch`.

### Checking it without a 7 GB container

The frontend is the whole of the problem, and it is a single fast command.  To
confirm the RTL is flow-readable without downloading the image:

    yosys -p 'read_verilog -sv -DSYNTHESIS -I rtl \
              rtl/sw_defs.sv rtl/sw_crc32.sv rtl/sw_sync_fifo.sv \
              rtl/sw_gmii_rx.sv rtl/sw_rx_port.sv rtl/sw_arbiter.sv \
              rtl/sw_mac_table.sv rtl/sw_gmii_tx.sv rtl/sw_tx_port.sv \
              rtl/sw_switch.sv; \
            hierarchy -check -top sw_switch; \
            synth -top sw_switch -flatten; stat'

Note the `-sv`.  `read_verilog` does **not** infer SystemVerilog from a `.sv`
extension, so without it the parse dies on the very first declaration with
`syntax error, unexpected TOK_ID` - which looks like a package problem and is not
one.  LibreLane passes `-sv` itself; the command above only has to match.

The frontend reports about two dozen `Replacing memory ... with list of
registers` warnings.  Those are expected and benign: the forwarding table is a
register file by design (see the note at the top of `sw_mac_table.sv`), and the
rest are small unpacked vectors that flatten to registers for free.

## The timer is not PrimeTime

`constraints/io.sdc` is read by OpenSTA, which implements a useful subset of
SDC and nothing more.  Three constructs that are unremarkable in a PrimeTime
script abort OpenSTA *while reading the file*, before a single path is analysed
- so the failure surfaces as `12-openroad-staprepnr` reporting `Failed STA for
the ... corner`, which reads like a timing violation and is a parse error:

| Construct | OpenSTA says |
|---|---|
| `remove_from_collection` (a PrimeTime extension) | `invalid command name "remove_from_collection"` |
| `set_driving_cell ... BUFFD1BWP30P140` (a cell that is not in the `hd` library) | matched, paths left unconstrained |
| `set_max_transition 1.0` (one-argument shorthand) | `set_max_transition requires two positional arguments` |
| `set_max_transition 1.0 [all_ports]` (`all_ports` is PrimeTime) | `invalid command name "all_ports"` |

The file therefore names its ports explicitly, names a driving cell from the
library actually in use (`sky130_fd_sc_hd__buf_1`, pin `X`), and spells out the
object list for the transition limit.  It also drops `set_max_area`, which is
not SDC - the area target in this flow is `FP_CORE_UTIL`, which is what sizes
the core.

### Checking the SDC without a full flow run

A flow run takes hours to reach a GDS; reading one SDC takes seconds.  The
harness reads the *real* synthesised netlist out of the most recent run, links
it against a timing corner's liberty, and applies the candidate file:

    sta -no_init -exit <<'EOF'
    read_liberty sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
    read_verilog librelane/runs/*/06-yosys-synthesis/sw_switch.nl.v
    link_design sw_switch
    read_sdc librelane/constraints/io.sdc
    puts "SDC-OK [get_clocks *]"
    EOF

Both the liberty and the netlist have to come from the container, since that is
where the PDK and yosys live.  It exercises the netlist and the constraints
together, which a synthetic placeholder module does not - the first version of
this harness used one, and OpenSTA could not even parse it.

## The netlist this produces

The reduced instance is 132 678 cells, 42 748 of them `dfxtp_2` flip-flops, and
1.911 mm^2 of `sky130_fd_sc_hd` cell area.  At `FP_CORE_UTIL = 40` LibreLane sizes
the floorplan to a 2196.8 x 2207.6 um die, and global placement reports 40.8%
utilisation of the 4.773 mm^2 core - which is what that utilisation number is
measured against.  The full-size figures are in the `SYNTH_PARAMETERS` section
above; both were measured with the flow itself, not estimated.

One number in the timing report is worth not misreading.  Worst pre-place slack
is around -195 ns, and every bit of it is on `rst_ni`: the synthesis netlist
drives that net **unbuffered into 3286 loads**, so the single inverter at the
port sees about 7.9 pF and arrives with a ~90 ns slew.  That is a property of a
mapped-but-not-placed netlist, not of the design - OpenROAD's `repair_design`
builds the buffer tree during place and route - and it is why the figure to
quote is the post-CTS one, not this.
