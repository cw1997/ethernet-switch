# LibreLane / OpenLane 2 build

Physical implementation of `sw_switch` down to a GDSII.

## Layout

    librelane/
      config.json              the flow configuration
      constraints/io.sdc       timing constraints
      runs/                    per-run working directory (generated, not committed)

## Running it

    docker run --rm \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp \
      -v "$PWD:/work" -w /work \
      ghcr.io/librelane/librelane:2.4.2 \
      librelane --pdk sky130A -s sky130_fd_sc_hd librelane/config.json

The image is a Nix closure, so the toolchain is exactly the one the flow was
released with.  The `--user` and `HOME` flags keep the run's caches and outputs
owned by the invoking user rather than by root; without them the run directory
comes out root-owned and the next local run cannot overwrite it.

CI does the same thing in the `gds` job of `../.github/workflows/ci.yml`, behind
a manual approval.

## Configuration notes

**`CLOCK_PERIOD = 10`** (100 MHz).  The RTL default is `CLK_FREQ_HZ =
125_000_000`, i.e. 8 ns, and the design does not close at 8 ns on the free
open-source PDK: the forwarding table is a 128x4 set-associative CAM with a
single-clock read port, and the ingress buffer chains a FIFO read, a parser state
machine and a 64-bit write.  10 ns is a defensible target for this core and keeps
CI meaningful.  It is the knob to relax or tighten - a period that is too small
shows up as a routing failure, never as a wrong GDSII.

**Parameters are left at their module defaults**: four ports at 1000 Mbit/s, 256
beat ingress and egress buffers, 128x4 forwarding table.  That is the
configuration the regression testbench exercises first.  Overriding them here
would change the netlist that CI proves.

**`VERILOG_DEFINES = ["SYNTHESIS"]`.**  The RTL tests for it: the
elaboration-time `$error` / `$warning` checks in `sw_switch` are simulation only,
because yosys has no implementation for those system tasks and aborts on a
design containing them.

## Status: synthesis does not yet complete

The flow currently stops at the first yosys step.  The package and the
`SYNTHESIS` guard are already fixed; what remains is one yosys limitation that
needs a refactor of the port declarations.

### What has been fixed

Two real portability problems were found by running the flow and are now fixed in
the RTL, with the reasoning recorded in the source:

1. **`$error` / `$warning` in an `initial` block** (`rtl/sw_switch.sv`).  yosys
   aborts on a design that contains them.  The checks are now wrapped in
   `` `ifndef SYNTHESIS `` so they still run in simulation - which is where a
   mis-parameterised instance is built - and are absent from the netlist.

2. **`return` inside a `case` in a package-scope function**
   (`rtl/sw_switch_pkg.sv`).  The yosys frontend rejects it:

       sw_switch_pkg.sv:70: ERROR: syntax error, unexpected TOK_CONSTVAL

   Every package function now assigns to the function name through a local
   instead.  The same `return` parses fine in a module body and in a package
   function with no `case`, and Icarus and Verilator both accept it, so the
   failure only appeared once the design was handed to the flow.

### What is still open

`module X import pkg::*; (...)` is not supported by yosys 0.46 at all - not in a
module header, not inside the body, not at file scope.  Each RTL module is now
written as

    `ifndef SYNTHESIS
    module X import sw_switch_pkg::*; #(
    `else
    module X #(
    `endif

which satisfies the simulators.  The remaining problem is narrower: yosys *does*
make the items of an **included** package visible, but it cannot use them in a
**port declaration's bit range**:

    rtl/sw_gmii_tx.sv:89: ERROR: Non-constant range in declaration of \fr_len_i

Twelve port declarations across six files take their width from a package item:

| File | Declarations |
|---|---|
| `sw_arbiter.sv`   | `src_tag_rd_data_i`, `dst_wr_len_o`, `dst_free_i`, `stat_o` |
| `sw_gmii_tx.sv`   | `fr_len_i` |
| `sw_rx_port.sv`   | `tag_rd_data_o`, `stat_o` |
| `sw_switch.sv`   | `stat_o` |
| `sw_tx_port.sv`   | `wr_len_i`, `free_o`, `stat_o` |

Promoting the width to a module *parameter* does not help - a package localparam
in a parameter default fails the same way, and so does a package function call.

The fix that is verified to work is to move the width constants and the width
helper functions out of the package and into a small **global-scope** include,
which yosys reads at file scope.  Both of these parse in yosys, Icarus and
Verilator alike:

    // global scope, not inside a package
    localparam int GW = 5;
    function automatic logic [31:0] tgw(input logic [31:0] n);
      tgw = 1 + 2*n;
    endfunction

    module s1 #(parameter int N = 3) (
      output logic [tgw(N)-1:0] a,   // package item: rejected
      output logic [GW-1:0]     b    // global item:  accepted
    );

So the change is: add e.g. `rtl/sw_widths.sv` holding `SW_LEN_W`, `SW_STAT_COUNT`,
`sw_tag_width` and `sw_tx_free_width` at global scope, include it from every RTL
file, and use those names in the twelve port declarations.  The package keeps
everything else.  This has **not** been applied - the flow has not been run to
completion, so no GDSII exists yet and the timings above are unmeasured.

### Consequence for CI

The `gds` job will fail at the first synthesis step until the port declarations
are changed.  It fails loudly rather than producing something misleading, which
is the right behaviour, but it does mean the third job is not green yet.
