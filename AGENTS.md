# AGENTS.md

Instructions for any agent (human or machine) changing this repository.

This is a **parameterised, store-and-forward Ethernet Layer-2 switch core** in
synthesizable SystemVerilog, with a self-checking regression and a LibreLane
(OpenLane 2) flow down to GDSII. Every rule below exists because this design is
read by four very different tools, and the strictest of them is the synthesis
frontend — not the simulator.

Read this file before you write a line of RTL. The rules are not stylistic
preferences; several of them exist because the alternative has already broken
this design in a way a testbench could not see.

---

## 1. Repository map

```
rtl/           the design. common/, mac/, mems/, perips/, switch/;
               es_<domain>_<block>.sv / matching module
tb/            self-checking testbenches. Never synthesised, never linted by CI
board/         per-board FPGA shells. de2_115/quartus_ii/ is a Quartus II
               project (board top, pins, constraints, build.bat) with its own
               self-checking TB; vivado/ is the eight-port MII template, also
               with its own TB. Both tops join the same five-top gates.
ci/            the CI toolchain contract (check-toolchain.sh)
librelane/     the physical implementation flow (config.json + README.md)
Makefile       every gate; the target list is documented in its own header
```

`rtl/es_defs.sv` holds common interface declarations and includes the guarded
`common/es_common_defs.sv`, `mac/es_mac_defs.sv`, `perips/es_perips_defs.sv`,
`switch/es_switch_pl_defs.sv` and `switch/es_switch_defs.sv` libraries in
dependency order. Put new constants in the owning library, keeping
cross-domain widths common; pipeline stage identifiers and descriptor field
offsets belong in `es_switch_pl_defs.sv`. All libraries remain at
compilation-unit scope; the umbrella include preserves standalone-module
compilation and the existing declaration-only lint policy. The pipeline
library is included *before* `es_switch_defs.sv`, because that file closes the
two declaration-only waivers at its end. There is no statistics register map,
no console library and no panel library.

**The datapath has one boundary that matters, and it is an 8-bit byte stream
with valid/ready.** `rtl/mac/` owns everything the line interface implies -
PHY pins, preamble and SFD (detected by the adapter, not pre-stripped by the
PHY), FCS generation and checking, inter-frame gap, symbol serialisation and
the clock-enable rate model. `rtl/switch/` owns the switching function as
staged levels: receive bytes into a per-port frame buffer, look up the
destination and learn the source in the same clock, decide the egress mask,
copy the frame into the egress queues. `es_switch_fabric` therefore holds no
clock-enable, line-rate or symbol-order knowledge at all, and compiling it
against a different MAC - including a future optical one - changes nothing
below the boundary. See "Pipeline architecture" at the end of this file.

The interface in use is chosen by which wrapper is elaborated: `es_switch_gmii`
(default GMII), `es_switch_mii` and `es_switch_rmii` each instantiate one
`es_mac_*_adapt` per port plus the same `es_switch_fabric`. `make lint`,
`make rtl` and `make synth` each run **all five** top modules - the three
`es_switch_*` wrappers plus board tops `es_switch_de2_115_top` and
`es_switch_vivado_top` - so changing a wrapper means making it green in all
five; a top that is never compiled silently rots.


## 2. The tool flow, and what each tool rejects

| Gate | Tool | What it catches that the others do not |
|---|---|---|
| `ci/check-toolchain.sh` | shell | a linter, simulator or synthesis frontend that has crossed a major version since the gates were written |
| `make lint` | Verilator `--lint-only -Wall` | width mismatches, unused signals, latches, incomplete case coverage, implicit sensitivity issues. **Any warning fails the build.** |
| `make rtl` | Icarus `-g2012`, RTL only | anything that only elaborates because a testbench happens to declare a missing signal |
| `make unit` / `sim` / `param` | Icarus + `vvp` | behaviour |
| `make synth` | yosys `read_verilog -sv` | everything the simulators happily accept and silicon will not |
| CI job `gds` | LibreLane 3.0.14, sky130A | timing, hold, DRC, LVS against the standard cells |

CI runs on a **self-hosted** runner, and the split of responsibilities is worth
knowing before you change anything there. The host provides Docker and nothing
else; the EDA toolchain comes from a container image declared per job with
`container:`, and that image is the pin that the runner label used to be.
Distribution builds carry security updates, and a third-party APT repository in
the supply path of the job that gates every commit is not worth a newer linter.
`ci/check-toolchain.sh` is what makes the pin real: CI runs it with
`ASSERT_OS=1`, so a toolchain image whose base distribution moved fails by name
rather than quietly changing what `make lint` reports. A local run leaves the
assertion off, which is why `bash wsl.sh "make lint"` works on a WSL
distribution that is not the CI one.

### 2.1 The three hard yosys restrictions

These are not opinions. They are parse errors, and all three are invisible to
Icarus and Verilator, so a change that violates one passes every test you can
run locally and then fails in the flow. `rtl/es_defs.sv` documents them in
full; the short form:

1. **No `package`, and no `import` in any form.** A package item is not a
   *constant range* to the frontend, so a width taken from a package is rejected
   in a port declaration before the body is even parsed. Neither
   `module X import pkg::*; (...)` nor `import pkg::*;` in a body is accepted.
   **Shared declarations therefore live at compilation-unit scope in
   `rtl/es_defs.sv`, where they are visible everywhere, including in parameter
   defaults and port ranges.**
2. **No `return` in any function**, in compilation-unit or module scope, with or
   without an enclosing `case`/`begin`. Assign to the function name instead;
   IEEE 1800-2017 13.3 defines it as equivalent. This applies to testbench
   functions too if they are ever moved into the synthesis set.
3. **`-sv` is mandatory** on `read_verilog`. The `.sv` extension does not imply
   it, and without it the parse dies on the first declaration with a message
   that looks like a package problem and is not one.

The synthesis command also runs with **`-noautowire`**, so an implicit net is
already an error there. Rule 3.1 below extends that protection to the linter
and the simulators. That is not a coincidence: LibreLane reads the design with
exactly the command in the `synth` target -

    read_verilog -defer -noautowire -sv -I<dir>... -D<define>... <file>

one file at a time - so `make synth` is a faithful stand-in for the flow's
frontend rather than an approximation of it.

### 2.2 Verilator's policy in this repository

- `-Wall` with the default error policy. **Do not add a waiver to silence a
  finding; fix the code.** Every `/* verilator lint_off */` in the tree is
  either a narrow, commented exception (a genuinely unconnected output pin,
  `PINCONNECTEMPTY`) or the two blanket waivers in `es_defs.sv` that cover a
  declaration-only file.
- `-Wno-DECLFILENAME` is passed on the command line because the module name is
  the file name; that is deliberate, not a suppressed defect.
- The lint result is **version sensitive**. CI's toolchain image carries the
  distribution's Verilator, which was 5.020 when this was written, and 5.020
  reports `WIDTHEXPAND` for `3'(8 - beat_left)`. Verilator 5.032 and 5.046
  report nothing at all for the same line, so a newer tool lints *cleaner* than
  the one CI runs. Three consequences: the width discipline in §3.2 has to be
  self-imposed — do not rely on the linter to tell you that an operand was
  silently extended; a warning you only see on an older Verilator must be fixed
  by making the operand widths match, not by wrapping the expression in a wider
  cast; and `ci/check-toolchain.sh` exists so that a major bump fails the job
  loudly instead of quietly removing findings. Note that a self-hosted runner
  makes this *more* likely, not less: the toolchain image is rebuilt on the
  host rather than re-pulled from a dated runner image, so "the tag is the same"
  no longer implies "the tools are the same". The assertion in §2 is the only
  thing standing between a rebuilt base image and a silently weaker lint gate.

### 2.3 The flow configuration is strict too

`librelane/config.json` is not a place for comments. LibreLane's config loader
validates every key against the variables the flow declares, and an unrecognised
key is a **hard error** - `Unknown key '<name>' provided` - raised while the
configuration is read, before the first synthesis step. (Keys beginning with `#`
or containing `_OPT` are silently skipped, but that is an implementation detail
rather than a documented convention, so do not build on it.)

This is worth knowing because the failure is expensive: it costs a multi-GB
image pull and a PDK download before telling you that one key is spelled wrong.
The two files that decide what is valid are in the pinned image's source tree:

    librelane/config/removals.py   variables that existed and were removed
    Changelog.md                   the per-step notes, under the version heading

and a key can be checked against the declarations with
`grep -rn '"VARIABLE_NAME"' librelane/`. If you rename anything in
`config.json`, record it in `librelane/README.md` in the same commit - the
migration table there is the only record of which name went where.

### 2.4 The Quartus parser has three holes of its own

`board/de2_115/quartus_ii/` is compiled by Quartus II, whose Verilog frontend
is a fourth strictness point - it accepts forms the other three tools reject
*and* rejects forms the other three accept. All three of the following have
already broken a real compile of this repository, and none of them is visible
to Verilator, Icarus or yosys:

1. **No inline genvar declaration.** `for (genvar gp = 0; ...)` is a syntax
   error. Declare `genvar gp;` separately and write `for (gp = 0; ...)`.
   A genvar may be reused by sequential (sibling) loops; loops that are
   concurrently nested must use distinct names.
2. **No implicit generate.** A bare module-level `for` - the implicit generate
   block of IEEE 1800 - is rejected outright (`syntax error ... expecting
   "endmodule"`). Every module-level loop is wrapped in an explicit
   `generate ... endgenerate`. Procedural `for` loops inside
   `always_*`/`function`/`initial` bodies are unaffected.
3. **`//` comments are scanned for pragmas.** A comment line whose first word
   after `//` is `synthesis` (or `pragma`, `synopsys`, ...) is read as a tool
   directive: prose like "the synthesis flow" produces
   `Unrecognized synthesis attribute "flow"` - a warning, but a confusing one.
   Never let a comment line start with one of those words.
4. **`initial`-initialised memories are pathologically slow.** A lookup table
   built by an `initial` block is a constant ROM to every other tool, but
   Quartus's constant evaluator burned 27 CPU-minutes per instance without
   completing on a 256x32 table (Quartus Prime 25.1std), against 35 seconds
   for the same value computed by a function. Compute elaboration-time tables
   in `function`s, not `initial` blocks.

## 3. RTL style rules

### 3.1 Declarations

- `` `default_nettype none `` **immediately after the include guard** of every
  file in `rtl/`, and `` `default_nettype wire `` immediately before the closing
  `` `endif ``. A typo in a port connection then becomes an elaboration error
  instead of a one-bit net that quietly carries X through the whole design. The
  restore is not optional: a file that leaves it `none` changes the meaning of
  every name compiled after it, in a file that has nothing to do with the change
  that caused the breakage.
- Module inputs use `input var logic`: Vivado rejects the implicit net kind of
  `input logic` under `default_nettype none`. The board MDIO ports use
  explicit `tri logic` nets for bidirectional high impedance.
- `logic` for nets, **never `wire` or `reg`**. Declare and then `assign`; do not
  use the `wire x = expr;` inline form, so that every derived signal in the
  design is declared and driven the same way.
- One driver per signal. A signal is written by exactly one `always_ff`, one
  `always_comb`, or one `assign` — never by two blocks, never by a block and an
  `assign`.
- `localparam` (not `parameter`) for anything derived inside a module. Module
  parameters are the module's configuration surface and must stay a short,
  documented list.
- Shared constants are `SW_`-prefixed and live in the owning `es_*_defs.sv`
  library (cross-domain interfaces in `es_defs.sv`); module-local
  derived widths are UPPER_SNAKE (`TAGW`, `PW`, `BPW`, `FF_W`, `TAG_SRC`);
  per-port or per-instance quantities are lower case (`rx_stat`, `tx_free`).
- Parameterise with `int unsigned` for numbers and `logic [N-1:0]` for vectors.
  Any width a module computes from a parameter goes through a `localparam`, so
  the width is stated exactly once.
- A **packed** vector for anything indexed at run time; an unpacked array only
  for a memory or a register file indexed by a constant, elaboration-time
  index. Icarus does not resolve an unpacked array that is indexed with a
  run-time value — the read comes back stale, and the failure surfaces far away
  from the cause (see the packed-vector comments in `es_switch_cam_table.sv`). Unpacked arrays
  also cannot be passed to a subroutine; pack them first.

### 3.2 Width discipline — the rule this repository exists to enforce

**Every operand of an arithmetic or bitwise operator must have the same width,
and that width must be the one you mean.**

- Never mix a sized vector with an unsized literal. `a + 1` is a **32-bit**
  operation: the literal makes the expression 32 bits, `a` is zero-extended to
  32, the result is computed there, and the bits above your target are then
  thrown away. Write `a + W'(1)`, or declare a sized `localparam` for the
  constant and use that. Same for `-`, `*`, `>>`, `&`, `|`.
- `W'(x)` is a **conversion**, not a way to silence the linter. Before writing
  one, decide what the correct width is and make the expression produce it. If
  the conversion genuinely truncates, that is a design decision and it gets a
  comment saying so — including the case where the truncated value is a
  don't-care, so the next reader does not "fix" it into a real wraparound.
- Where a value must wrap, write the wrap out
  (`cond ? '0 : cur + W'(1)`). A counter that wraps by overflowing is only
  correct when the count is a power of two, and a silent wrong answer on a
  three-port fabric is the worst kind of bug to find.
- Where a feature is disabled by a parameter, disable it **explicitly**
  (`if (PARAM != 0) ...`), never by letting a threshold underflow to a value
  the counter happens never to reach.
- Do not use `*` between two 32-bit vectors to express "count × count". A
  synthesis tool cannot see that the multiplier only ever reaches `NUM_PORTS`
  and will build the full array. Narrow the operand and write the wrap
  explicitly instead - `cam_rr_add` in `es_switch_cam_table.sv` advances a
  `WAYW`-bit pointer with `r + WAYW'(1)` rather than a 32-bit multiply.
- An array/loop index in a comparison against a parameter is a sized cast of the
  parameter (`PW'(NUM_PORTS - 1)`), not a bare literal.

### 3.3 Processes

- `always_ff @(posedge clk_i)` for state, `always_comb` for combinational logic.
  Never `always @*` and never a bare `always`.
- Non-blocking `<=` in `always_ff`, blocking `=` in `always_comb` and in
  functions. No exceptions; a blocking assignment to a register is a race.
- **Every `always_comb` assigns every output before anything else and has a
  `default` in every `case`.** A combinational block that reads a variable it
  writes (a "found yet?" accumulator, a running sum) puts that variable in the
  block's own implicit sensitivity list: the block re-triggers on its own output
  forever and the simulation hangs with time standing still, which looks like a
  dead clock and nothing else. Put accumulators in a **function** — a function
  has no sensitivity list at all. `cam_grant` and `cam_pick` in
  `es_switch_cam_table.sv` are the reference examples.
- **Never index a memory with a run-time value inside `always_comb`.** Stage the
  read into a flat vector with continuous assignments (in a generate loop, so
  the offset is a constant) and let the process read the vector. The generated
  hardware is identical; the sensitivity list is not.
- Prefer continuous assignments and generate loops for per-element decodes and
  part selects. A constant part select inside an `always_*` block makes Icarus
  over-approximate the sensitivity list; a variable-offset one on the
  right-hand side of a non-blocking assign into an unpacked array makes the
  store silently never land. Both are documented at the site in the code.
- **Writes into an unpacked array go through per-entry `always_ff` blocks in a
  generate loop**, not a loop inside one process (see `g_entry` in
  `es_switch_cam_table.sv`). A loop-indexed store is dropped silently by Icarus and
  the per-entry form is also what a vendor tool wants to see to infer the
  storage.
- Reset is **synchronous, active low, named `rst_ni`, and is the first branch of
  every `always_ff` that has state.** No asynchronous reset anywhere: the
  design is single-clock-domain by construction, and a synchronous reset is
  portable to every target. Reset memories and register files deliberately or
  not at all, and say which in a comment.

#### 3.3.1 The switch domain: assign-only modules, `es_mems_reg_bank` state

`rtl/switch/` follows the E200 (`e200_opensource`) discipline instead: a
module there contains only `logic` declarations, `assign` statements, pure
functions and generate loops - **no `always` block of any kind**. Every
sequential element is an `es_mems_reg_bank` instance, one per register
(`DEPTH=1`) or one per array (`DEPTH=N`; the CAM entry array and the per-set
round-robin pointers in `es_switch_cam_table.sv`). The greppable invariant is
that no line in the domain *begins a statement* with `always` -
`grep -rn '^\s*always' rtl/switch` comes back empty - so ordinary prose in
comments may still use the word. The remaining procedural blocks live in the
other domains and inside `es_mems_reg_bank.sv` itself.

- Control signals follow the E200 lifecycle: `*_set` / `*_clr` / `*_ena`
  compute the write enable, `*_d` is the combinational next value, `*_q` the
  held value. Next-state logic is a chain of ternary `assign`s, ordered so the
  later overrides of the single-process form they were derived from still win.
- FSMs are binary-encoded `localparam logic [W-1:0]` constants, with the
  reset state first and equal to zero so the bank's all-zero `RESET_VALUE` is
  the reset encoding. There is **no `typedef enum` in the switch domain**
  (see the yosys enum-cast hazard under "Shared RTL domains").
- A register that deliberately holds no reset - the stage-register data
  payloads, meaningless while their valid bit is low, which is the E203
  `dffl` convention - ties the bank's `rst_ni` to `1'b1` and says so in a
  comment.
- Every bank instance is named `u_<role>_q`, so after `synth -flatten` the
  netlist register names still read as
  `<hierarchy>.u_<role>_q.g_entry[n].value_q` and the data flow stays
  traceable through the combinational clouds.
- New files keep every §2.4 rule: explicit `generate`, no inline `genvar`, no
  comment line starting with a pragma word, tables computed in functions.

### 3.4 What must never appear in `rtl/`

Delays (`#`), `fork`/`join`, `wait`, `disable`, `real`, `$display`/`$finish`,
dynamic arrays, queues, classes, `assert`/`assume`/`cover` in the datapath, and
`import`. All of them are simulation-only or unsupported by the flow. That now
includes `initial`: there is none left in `rtl/`.

Two narrow, documented exceptions exist:

- `es_common_crc32.sv` computes its byte-wise CRC lookup in a function rather than an
  `initial`-initialised table. The table form was the one sanctioned `initial`
  block until it met Quartus, whose constant evaluator needs tens of
  CPU-minutes *per instance* on an initial-block-initialised memory (§2.4);
  the function computes the identical value everywhere. Never reintroduce an
  `initial` block, and never let one produce a value that a write path depends
  on — see the power-of-two frame-buffer check in
  `es_switch_frame_buf.sv`.
- `es_switch_frame_buf.sv`, `es_switch_rx_engine.sv` and the `es_switch_mii` /
  `es_switch_rmii` wrappers report elaboration-time parameter checks with
  `$error` / `$warning` inside `` `ifndef SYNTHESIS ``, because yosys has no
  implementation for them and aborts on a design that contains one. Keep any new
  parameter check in that same block.

### 3.5 Naming

| Form | Meaning | Example |
|---|---|---|
| `clk_i`, `rst_ni` | clock, active-low reset | |
| `<name>_i` / `<name>_o` | port direction | `rx_valid_i`, `gmii_tx_d_o` |
| `<name>_q` | registered value | `state_q`, `cnt_q` |
| `<name>_d`, `<name>_n` | combinational *next value* | `oct_cnt_n`, `dst_n` |
| `S_XXX` | FSM state: `typedef enum logic [n:0]` outside the switch domain; binary `localparam logic [W-1:0]` inside `rtl/switch/` (§3.3.1) | `S_HUNT`, `S_IDLE` |
| `es_<domain>_*` / `sw_*` | design module / shared declaration | `es_mems_sync_fifo`, `sw_is_unicast` |
| `unused_*` | a deliberate dummy consumer for a signal nothing reads | `unused_board`, `unused_phy` |

A `case` on an `enum` always carries a `default`, even when every encoding of
the enum is covered. That is what `-Wall`'s `CASEINCOMPLETE` expects, and it
means an encoding the RTL never writes cannot leave the block's outputs
undefined.

### 3.6 Comments

This codebase explains **why**, and specifically what the failure mode is. That
is the house style and it is worth keeping:

- Do not restate the code. "`state` is the current state" helps nobody.
- Do explain the invariant the code depends on, and the wrong value it produces
  if that invariant is broken.
- Where a construct is a workaround for a tool, name the tool and the symptom.
  Most of the counter-intuitive code here exists because the obvious form fails
  somewhere, and the next person needs to know whether the workaround is still
  load-bearing.

The same comment discipline applies to **all newly authored RTL, testbenches,
board shells, Tcl/XDC files and build-script additions**, not just `rtl/`:

- Follow the existing English house style: a separator-delimited file header
  with `File` and `Description`, then named sections for configuration, ports,
  reset/clocking, datapath/control and checking as appropriate. Document the
  parts that exist; do not add empty boilerplate sections or comment every line.
- Headers state the interface contract and limits: clock frequency/domain,
  reset polarity and startup requirements, frame boundaries, packed port/bit
  mapping and supported configurations where relevant. Keep widths/counts in
  comments synchronized with the HDL, constraints and regression.
- Document public ports/parameters and non-obvious internal state at their
  declarations. Explain units, validity windows, priorities and invariants;
  explain intentional truncation, wraparound, tie-offs and dummy consumers
  where they occur. Refer to the shared explanation for repeated declarations
  rather than duplicating it on every `input var logic` line.
- A board template must distinguish implemented logic from reserved signals
  and unfinished PHY/CDC/timing work. A synchronization attribute, unused clock
  input or placeholder constraint is not proof of safe clock-domain crossing.
  Say how reset release is sampled and whether power-on initialization,
  debounce and PHY reset hold time are provided or still required.
- Testbench comments describe the independent reference/wire model, stimulus
  phases, expected recipients and failure modes. Explain timeout/watchdog
  limits and simulator-specific dispatch. Do not claim payload comparison,
  hardware timing or CDC coverage that the checks do not actually provide.
- Tcl/build comments explain path anchoring, repeated-run behavior, hierarchy
  selection and effects on existing projects/run products. XDC comments state
  which commands are active, the source of physical pin/voltage/delay values,
  clock/edge assumptions and why an exception is needed. Keep placeholders
  inactive and preserve DRC severity until board-specific values are known.
- Tool workarounds name the affected frontend and actual symptom; distinguish
  a language rule, a documented restriction and a result measured on a tool
  version. Do not expand a local check into an unverified all-tool claim.
- Keep comments adjacent to the behavior they explain and update them with
  every implementation change. For comment-only edits, verify executable
  tokens/commands and inactive constraint examples remain unchanged; comments
  can still affect tool pragmas, so retain the restrictions in §2.4.
- Do not insert comments into strict JSON or hand-annotate generated Vivado
  project/run files. Put explanations in the authored Tcl/XDC source or README
  instead; preserve existing tool directives and include-guard semantics.

---

## 4. Testbench rules (`tb/`)

The testbenches are **not** synthesised, so §2.1 and §3.4 do not apply to them:
`return` in a function is fine, `sw_tb_pkg` is a real package and is imported
normally, and `$display`, delays and reference models are expected.

They are still held to:

- Self-checking, with a printed `PASS`/`FAIL` per check, an explicit error count
  at the end, and `$finish` — never a silent success. A failure must be
  diagnosable from the log alone, which is why CI uploads the logs even when the
  job fails.
- Model the wire, not the RTL. A testbench that shares an assumption with the
  design cannot fail; `tb/tb_sw_pl_gmii.sv` re-assembles complete wire frames
  and checks the preamble and FCS independently for exactly that reason. The
  MII/RMII and board TBs use their own independent wire models too.
- Cover the awkward configurations, not just the happy path: a port count that
  is not a power of two, non-power-of-two CAM set/way counts, and every common
  port count (`make param-scan` elaborates 4/8/16/32/48 ports).
- `NUM_PORTS`-derived widths and index arithmetic in a testbench follow §3.2 too.
  A testbench with a width bug fails in a way that looks like an RTL bug.

---

## 5. How to verify a change

Run these in order; they are ordered by how fast they fail.

```sh
ci/check-toolchain.sh  # ~0.1 s  - the tools match the versions the gates assume
make lint      # ~1 s    - Verilator -Wall, any warning is an error
make rtl       # ~1 s    - Icarus elaboration of the RTL alone
make unit      # ~25 s   - block-level and staged-fabric regressions
make mii rmii vivado board-unit  # the four PHY/board front ends
make sim       # ~1 min  - GMII system regression, complete wire frames
make param     # ~1 min  - 3 ports, non-power-of-two CAM (96 sets x 3 ways)
make param-scan# ~5 min  - 4/8/16/32/48 ports x CAM geometries
make synth     # yosys; needs yosys on PATH, not part of `make all`
```

On Windows the toolchain lives in WSL; `bash wsl.sh "make lint"` runs a command
there. (CI uses Linux directly and never needs it.) A local
`ci/check-toolchain.sh` reports the base distribution rather than asserting it —
only CI passes `ASSERT_OS=1` — so a WSL distribution newer than the CI toolchain
image is not an error locally.

**Run `make synth` before you call a change done.** `make all` does not include
it (it is slow and needs yosys, and `all` is what you want while iterating), but
the CI lint job does. The simulators are far more permissive than the synthesis
frontend, and a design can pass every testbench and still be unreadable by the
flow. It is the only gate that catches §2.1.

A green local run is not a green CI run any more, for one reason: CI grades the
RTL with the Verilator inside the toolchain image, and your WSL one need not be
the same major version. If a lint warning appears locally that CI does not
report, that is the version difference from §2.2 and not a spurious finding —
but the *reverse* is the dangerous direction, and it is the one the toolchain
contract in §2 exists to catch.

Definition of done:

- [ ] `ci/check-toolchain.sh`, `make lint`, `make rtl`, `make unit`, `make sim`,
      `make param`, `make param-scan`, `make mii`, `make rmii`, `make vivado`,
      `make board-unit` all pass.
- [ ] `make synth` elaborates and synthesises all five top modules
      (`es_switch_gmii`, `es_switch_mii`, `es_switch_rmii`,
      `es_switch_de2_115_top`, `es_switch_vivado_top`).
- [ ] `rtl/switch/` still contains no procedural block (`grep -rn '^\s*always'
      rtl/switch` comes back empty); new sequential state there is an
      `es_mems_reg_bank` instance (§3.3.1).
- [ ] A behavioural change has a test that fails without it.
- [ ] No new `verilator lint_off`, and no new `initial` block.
- [ ] New shared constants are in the appropriate `es_*_defs.sv` library; new module parameters are
      `localparam`-derived and documented in the port list.
- [ ] A change to `librelane/config.json` is recorded in
      `librelane/README.md`, and every key in it is a variable the pinned
      LibreLane declares.
- [ ] A change to the toolchain contract — the expected tool versions in
      `ci/check-toolchain.sh`, or `EXPECTED_OS` in the workflow — is made in
      this file's §2 terms: say which tool moved and what the regression said
      about it. Do not widen the contract to make the job green.
- [ ] The file header still describes what the module is for.

## 6. Things that will bite you

Each of these is a real trap in this design; the code says so at the site, and
this is the short list.

| Trap | What happens | Rule |
|---|---|---|
| Unsized literal in arithmetic | operand silently extended, width decided by the literal | §3.2 |
| Size cast used to silence it | works on 5.032, still flagged on 5.020, still wrong | §3.2, §2.2 |
| `for (genvar g = 0; ...)` inline form | Quartus parse error; invisible to every other tool | §2.4 |
| Bare module-level `for` (implicit generate) | Quartus parse error, "expecting endmodule"; needs explicit `generate` | §2.4 |
| Comment line starting with "synthesis" | Quartus reads it as a pragma, warns about a phantom attribute | §2.4 |
| Unpacked array indexed at run time | stale read in Icarus, looks like a datapath fault | §3.1 |
| Accumulator in `always_comb` | self-retriggering sensitivity, simulation hangs | §3.3 |
| Memory read in `always_comb` | same hang, less obviously | §3.3 |
| Loop-indexed store into an array | store silently dropped, learned entry never appears | §3.3 |
| `undo` with a non-power-of-two FIFO DEPTH | write pointer lands on an illegal encoding | Pipeline architecture |
| More concurrent CAM learns than ways in one set | silently dropped learn unless `learn_ready_o` backpressures | Pipeline architecture |
| `package` / `import` / `return` | passes every simulator, fails in the flow | §2.1 |
| A comment key in `config.json` | hard error, after a multi-GB image pull | §2.3 |
| A renamed flow variable | hard error, same cost; `removals.py` is the list | §2.3 |
| Counter left to wrap by overflow | only correct when the count is 2**n | §3.2 |
| `32 * 32` for two counts | a real multiplier array in the netlist | §3.2 |
| Comment that contradicts the code | worse than no comment — see `tx_octets_inc` | §3.6 |
| Assuming a non-2**n octet period works | 1000BASE-T on a 50 MHz core runs at 400 Mbit/s | `sw_byte_period` |


## Shared RTL domains

`rtl/mac/` owns the line interface: preamble and SFD detection, FCS,
inter-frame gap, symbol serialisation and clock-enable rate adaptation. It is
the only domain that knows a clock enable or a symbol order exists.
`rtl/switch/` owns the staged switching function: parse, learn, decide,
buffer, copy into egress queues.
`rtl/perips/` owns MDIO and 88E1111 PHY management.
`rtl/mems/` owns FWFT FIFO, asynchronous-read/synchronous-write RAM and
parallel register banks. `rtl/common/` owns the two-stage sampler, CRC-32 and
the pipeline register primitives (`es_common_dffs`, `es_common_pipe_stage`).
Source lists use these paths; no ROM initialization is introduced -
elaboration-time tables remain functions. There is no panel, console,
statistics or monitoring domain.

**Two synthesis hazards that only appear here.** Casting a *variable* to an enum
type - `sw_console_cmd_e'(some_var)` - is rejected by yosys with "Static cast
with non constant expression"; compare the plain encoding against the enum's
constants instead. And an enum-typed function argument has the same problem, so
the console's table functions take `logic [3:0]` and compare against the
`sw_console_*_e` members.

## Pipeline architecture

The switch is a **frame-level concurrent pipeline**: the legacy global arbiter
moved one frame at a time for the entire fabric; the staged design lets one
frame sit in each level at once, with all `NUM_PORTS` receive engines running
in parallel. Each level owns its own valid/ready stage register (in the E203
pipe-stage template, held in `es_mems_reg_bank` instances, §3.3.1), so no
`es_common_pipe_stage` sits between the levels today; that primitive stays in
the tree, regression-tested by `sw_pipe_stage_tb`, for timing repair if a
level ever needs a deeper ready cut (`DP` register depth, 0 = bypass;
`CUT_READY`).

| Level | Module | Responsibility |
|---|---|---|
| S0/S1 | `es_switch_rx_engine` (=`es_switch_rx_ctrl` + `es_switch_rx_parse` + `es_switch_rx_check`) + `es_switch_frame_buf` | one byte per clock, header latch, eight malformed-frame checks (combinational), per-port byte FIFO + descriptor FIFO, legal-frame descriptor |
| S2 | `es_switch_cam_stage` + `es_switch_cam_table` | `NUM_PORTS` destination lookups and `NUM_PORTS` source learns in the **same clock** |
| S3 | `es_switch_decide` | broadcast / group / unknown-unicast policy, source-port filter, egress mask |
| S4 | `es_switch_tx_writer` | several copy engines read their own frame slot and feed the egress queues |
| S5 | `es_switch_tx_engine` | per-port TX FIFO, then the MAC adapter re-generates preamble, pad, FCS and IFG |

Rules that keep this buildable by all four tools:

- Handshakes are `<src>_o_valid/<src>_o_ready` ↔ `<dst>_i_valid/<dst>_i_ready`;
  a local `<name>_hsked = valid & ready` is **declared `logic`** and assigned,
  never `wire x = expr`. A transfer happens only on a handshake, so backpressure
  can never drop a byte.
- Inter-level payloads are **packed** `{}` vectors with `localparam` widths and
  field-offset functions from `es_switch_pl_defs.sv`. No struct, interface or
  package. `es_common_pipe_stage` resets its valid bit but deliberately not its
  data register.
- A frame becomes visible downstream **only** after it has been received in
  full and passed every check; a bad or over-MTU frame is rewound out of the
  byte FIFO and never produces a descriptor. Frame buffering is one byte FIFO
  plus one descriptor FIFO per ingress port. **`SLOTS*SLOT_BYTES` must be a
  power of two**: the rewind is `wr_ptr - undo_cnt` on an ADDR_W-wide pointer
  while `next_slot` skips the unused encodings of a non-power-of-two DEPTH,
  and mixing the two lands on an illegal encoding. `es_switch_frame_buf`
  checks this at elaboration.
- The CAM has `NUM_PORTS` read ports (combinational bucket read; `cam_stage`
  registers the verdict together with its descriptor) and `NUM_PORTS` write
  ports. The entry array and the round-robin pointers live in
  `es_mems_reg_bank` instances whose per-entry write enables are decoded with
  constant indices - the same constant-index form as a per-entry generate
  `always_ff`, never a loop-indexed store.
  Lookup is **read-first**. If more learns than `NUM_WAYS` land in one bucket in
  one clock, `learn_ready_o` backpressures the excess for one clock; silently
  dropping a learn is forbidden.
- Parallelism is fixed by `NUM_PORTS`: the CAM has one lookup and one learn
  lane per port, and `es_switch_tx_writer` has one copy engine per source port,
  each reading its own ingress byte FIFO. There are no separate lane-count
  parameters. Bucket selection uses a constant-index priority mux (never a
  wide variable part-select), and the hash is a pure XOR fold with no
  multiplier, divider or wide adder - both are there to keep `synth -flatten`
  tractable.
- **Simulation vs synthesis geometry.** `es_switch_pl_defs.sv` supplies two
  sets of parameter defaults. With `SYNTHESIS` defined (`make synth` and
  LibreLane) the frame buffer is `SLOTS=1 / SLOT_BYTES=512`, the CAM is 16x2
  and `MAX_FRAME_LEN=256`; without it (all simulations) it is `2 / 2048`,
  128x4 and 1518. A full-size buffer is about 131 000 flops and takes tens of
  minutes to flatten. Never weaken a behavioural test to make a gate faster:
  the simulations keep the full geometry.
- There is **no status, statistics, panel, console, LED or DIP path** in the
  new design. `FLOOD_MODE` and `LEARNING_EN` are pure parameters.
- Regression is layered by geometry, not by scenario: `make param-scan`
  elaborates the full system scenario suite at 4/8/16/32/48 ports with seven
  CAM set/way combinations. `make param` adds a 3-port non-power-of-two case.
  A full cross-product of scenarios, port counts and CAM geometries would
  exceed the CI time budget, so the scan samples geometries rather than
  trimming scenarios.

