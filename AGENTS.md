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
rtl/           the design.  One file per block, sw_<block>.sv / module sw_<block>
tb/            self-checking testbenches.  Never synthesised, never linted by CI
ci/            the CI toolchain contract (check-toolchain.sh)
librelane/     the physical implementation flow (config.json + README.md)
Makefile       every gate; the target list is documented in its own header
```

`rtl/sw_defs.sv` holds **every** shared constant, type and helper function, at
compilation-unit scope. It is included by every other RTL file and by the
testbenches. If you are about to add a constant, put it there.

## 2. The tool flow, and what each tool rejects

| Gate | Tool | What it catches that the others do not |
|---|---|---|
| `ci/check-toolchain.sh` | shell | a linter, simulator or synthesis frontend that has crossed a major version since the gates were written |
| `make lint` | Verilator `--lint-only -Wall` | width mismatches, unused signals, latches, incomplete case coverage, implicit sensitivity issues. **Any warning fails the build.** |
| `make rtl` | Icarus `-g2012`, RTL only | anything that only elaborates because a testbench happens to declare a missing signal |
| `make unit` / `sim` / `param` | Icarus + `vvp` | behaviour |
| `make synth` | yosys `read_verilog -sv` | everything the simulators happily accept and silicon will not |
| CI job `gds` | LibreLane 3.0.14, sky130A | timing, hold, DRC, LVS against the standard cells |

The runner image is pinned to `ubuntu-24.04` and the EDA packages come from its
archive rather than from a pinned artefact - distribution builds carry security
updates, and a third-party APT repository in the supply path of the job that
gates every commit is not worth a newer linter. The pin is what makes that
choice predictable, and `ci/check-toolchain.sh` is what makes the pin real.

### 2.1 The three hard yosys restrictions

These are not opinions. They are parse errors, and all three are invisible to
Icarus and Verilator, so a change that violates one passes every test you can
run locally and then fails in the flow. `rtl/sw_defs.sv` documents them in
full; the short form:

1. **No `package`, and no `import` in any form.** A package item is not a
   *constant range* to the frontend, so a width taken from a package is rejected
   in a port declaration before the body is even parsed. Neither
   `module X import pkg::*; (...)` nor `import pkg::*;` in a body is accepted.
   **Shared declarations therefore live at compilation-unit scope in
   `rtl/sw_defs.sv`, where they are visible everywhere, including in parameter
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
  `PINCONNECTEMPTY`) or the two blanket waivers in `sw_defs.sv` that cover a
  declaration-only file.
- `-Wno-DECLFILENAME` is passed on the command line because the module name is
  the file name; that is deliberate, not a suppressed defect.
- The lint result is **version sensitive**. CI installs the distribution's
  Verilator from the pinned `ubuntu-24.04` image, which is 5.020, and 5.020
  reports `WIDTHEXPAND` for `3'(8 - beat_left)`. Verilator 5.032 and 5.046
  report nothing at all for the same line, so a newer tool lints *cleaner* than
  the one CI runs. Three consequences: the width discipline in §3.2 has to be
  self-imposed — do not rely on the linter to tell you that an operand was
  silently extended; a warning you only see on an older Verilator must be fixed
  by making the operand widths match, not by wrapping the expression in a wider
  cast; and `ci/check-toolchain.sh` exists so that a major bump fails the job
  loudly instead of quietly removing findings.

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

## 3. RTL style rules

### 3.1 Declarations

- `` `default_nettype none `` **immediately after the include guard** of every
  file in `rtl/`, and `` `default_nettype wire `` immediately before the closing
  `` `endif ``. A typo in a port connection then becomes an elaboration error
  instead of a one-bit net that quietly carries X through the whole design. The
  restore is not optional: a file that leaves it `none` changes the meaning of
  every name compiled after it, in a file that has nothing to do with the change
  that caused the breakage.
- `logic` for nets, **never `wire` or `reg`**. Declare and then `assign`; do not
  use the `wire x = expr;` inline form, so that every derived signal in the
  design is declared and driven the same way.
- One driver per signal. A signal is written by exactly one `always_ff`, one
  `always_comb`, or one `assign` — never by two blocks, never by a block and an
  `assign`.
- `localparam` (not `parameter`) for anything derived inside a module. Module
  parameters are the module's configuration surface and must stay a short,
  documented list.
- Shared constants are `SW_`-prefixed and live in `sw_defs.sv`; module-local
  derived widths are UPPER_SNAKE (`TAGW`, `PW`, `BPW`, `FF_W`, `TAG_SRC`);
  per-port or per-instance quantities are lower case (`rx_stat`, `tx_free`).
- Parameterise with `int unsigned` for numbers and `logic [N-1:0]` for vectors.
  Any width a module computes from a parameter goes through a `localparam`, so
  the width is stated exactly once.
- A **packed** vector for anything indexed at run time; an unpacked array only
  for a memory or a register file indexed by a constant, elaboration-time
  index. Icarus does not resolve an unpacked array that is indexed with a
  run-time value — the read comes back stale, and the failure surfaces far away
  from the cause (see the `f_dst` comment in `sw_arbiter.sv`). Unpacked arrays
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
  and will build the full array. Write the shift-add, or narrow the operand, as
  `octets_x_copies` in `sw_arbiter.sv` does.
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
  has no sensitivity list at all. `count_copies` and `octets_x_copies` in
  `sw_arbiter.sv` are the reference examples.
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
  generate loop**, not a loop inside one process (see `g_mem_wr` in
  `sw_mac_table.sv`). A loop-indexed store is dropped silently by Icarus and
  the per-entry form is also what a vendor tool wants to see to infer the
  storage.
- Reset is **synchronous, active low, named `rst_ni`, and is the first branch of
  every `always_ff` that has state.** No asynchronous reset anywhere: the
  design is single-clock-domain by construction, and a synchronous reset is
  portable to every target. Reset memories and register files deliberately or
  not at all, and say which in a comment.

### 3.4 What must never appear in `rtl/`

Delays (`#`), `fork`/`join`, `wait`, `disable`, `real`, `$display`/`$finish`,
dynamic arrays, queues, classes, `assert`/`assume`/`cover` in the datapath, and
`import`. All of them are simulation-only or unsupported by the flow.

Two narrow, documented exceptions exist:

- `sw_crc32.sv` builds its constant CRC table in an `initial` block. This is an
  elaboration-time constant ROM, needs no reset and no run-time
  initialisation, and synthesises to a constant table. Do not add a second
  `initial` block anywhere, and never let one produce a value that a write path
  depends on — see the `WAY_LAST` comment in `sw_mac_table.sv` for a design that
  got that wrong.
- `sw_switch.sv` reports elaboration-time parameter checks with `$error` /
  `$warning` inside `` `ifndef SYNTHESIS ``, because yosys has no implementation
  for them and aborts on a design that contains one. Keep any new parameter
  check in that same block.

### 3.5 Naming

| Form | Meaning | Example |
|---|---|---|
| `clk_i`, `rst_ni` | clock, active-low reset | |
| `<name>_i` / `<name>_o` | port direction | `beat_valid_i`, `gmii_d_o` |
| `<name>_q` | registered value | `len_q`, `cam_hit_q` |
| `<name>_d`, `<name>_n` | combinational *next value* | `count_d`, `crc_en_n` |
| `S_XXX` | FSM state, in a `typedef enum logic [n:0]` | `S_PRE`, `S_TAIL` |
| `sw_*` | module or shared declaration | `sw_sync_fifo`, `sw_is_unicast` |
| `cnt_*`, `stat_o` | statistics | `cnt_tx_octets` |
| `unused_*` | a deliberate dummy consumer for a signal nothing reads | `unused_crc_ok` |

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
  design cannot fail; `tb/sw_gmii_if.sv` re-assembles the octet stream and
  checks the FCS independently for exactly that reason.
- Cover the awkward configurations, not just the happy path: a port count that
  is not a power of two, a core clock that is not 125 MHz, a slow port
  (`make unit` runs the fabric regression at 10 Mbit/s for this reason).
- `NUM_PORTS`-derived widths and index arithmetic in a testbench follow §3.2 too.
  A testbench with a width bug fails in a way that looks like an RTL bug.

---

## 5. How to verify a change

Run these in order; they are ordered by how fast they fail.

```sh
ci/check-toolchain.sh  # ~0.1 s  - the tools match the versions the gates assume
make lint      # ~1 s    - Verilator -Wall, any warning is an error
make rtl       # ~1 s    - Icarus elaboration of the RTL alone
make unit      # ~25 s   - CRC-32, FIFO, CAM, and the fabric regression
make param     # ~4 s    - 3 ports, 50 MHz, a port count that is not 2**n
make sim       # ~6 min  - 4 ports at 10/100/1000/1000 Mbit/s, 158 checks
make synth     # ~3 min  - yosys; needs yosys on PATH, not part of `make all`
```

On Windows the toolchain lives in WSL; `bash wsl.sh "make lint"` runs a command
there. (CI uses Linux directly and never needs it.)

**Run `make synth` before you call a change done.** `make all` does not include
it (it is slow and needs yosys, and `all` is what you want while iterating), but
the CI lint job does. The simulators are far more permissive than the synthesis
frontend, and a design can pass every testbench and still be unreadable by the
flow. It is the only gate that catches §2.1.

Definition of done:

- [ ] `ci/check-toolchain.sh`, `make lint`, `make rtl`, `make unit`, `make sim`,
      `make param` all pass.
- [ ] `make synth` elaborates and synthesises `sw_switch`.
- [ ] A behavioural change has a test that fails without it.
- [ ] No new `verilator lint_off`, and no new `initial` block.
- [ ] New shared constants are in `sw_defs.sv`; new module parameters are
      `localparam`-derived and documented in the port list.
- [ ] A change to `librelane/config.json` is recorded in
      `librelane/README.md`, and every key in it is a variable the pinned
      LibreLane declares.
- [ ] The file header still describes what the module is for.

## 6. Things that will bite you

Each of these is a real trap in this design; the code says so at the site, and
this is the short list.

| Trap | What happens | Rule |
|---|---|---|
| Unsized literal in arithmetic | operand silently extended, width decided by the literal | §3.2 |
| Size cast used to silence it | works on 5.032, still flagged on 5.020, still wrong | §3.2, §2.2 |
| Unpacked array indexed at run time | stale read in Icarus, looks like a datapath fault | §3.1 |
| Accumulator in `always_comb` | self-retriggering sensitivity, simulation hangs | §3.3 |
| Memory read in `always_comb` | same hang, less obviously | §3.3 |
| Loop-indexed store into an array | store silently dropped, learned entry never appears | §3.3 |
| `package` / `import` / `return` | passes every simulator, fails in the flow | §2.1 |
| A comment key in `config.json` | hard error, after a multi-GB image pull | §2.3 |
| A renamed flow variable | hard error, same cost; `removals.py` is the list | §2.3 |
| Counter left to wrap by overflow | only correct when the count is 2**n | §3.2 |
| `32 * 32` for two counts | a real multiplier array in the netlist | §3.2 |
| Comment that contradicts the code | worse than no comment — see `tx_octets_inc` | §3.6 |
| Assuming a non-2**n octet period works | 1000BASE-T on a 50 MHz core runs at 400 Mbit/s | `sw_byte_period` |
