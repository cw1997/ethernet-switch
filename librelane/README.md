# LibreLane build

Physical implementation of `es_switch_gmii` (the GMII top) down to GDSII, with
LibreLane **3.0.14** and the `sky130A` / `sky130_fd_sc_hd` PDK. CI runs the same
flow in the `gds` job of `.github/workflows/ci.yml`.

```
librelane/
  config.json              the flow configuration
  constraints/io.sdc       timing constraints
  runs/                    per-run working directory (generated)
```

## Running it

```sh
mkdir -p "$HOME/.cache/librelane" librelane/runs
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/pdks \
  -v "$PWD:/work" -v "$HOME/.cache/librelane:/pdks" -w /work \
  ghcr.io/librelane/librelane:3.0.14 \
  librelane --pdk sky130A -s sky130_fd_sc_hd librelane/config.json
```

The image is a Nix closure, so **pin the tag**: the RTL is elaborated against its yosys and a floating `latest` makes a GDSII irreproducible. `--user` keeps run outputs owned by the invoking user.
`HOME` holds the PDK download (over a gigabyte); on the self-hosted runner it is bind-mounted from the host (`$HOME/.cache/librelane`), not the checkout, because `actions/checkout` runs `git clean -ffdx` and would delete a PDK inside the workspace. Delete that host directory by hand to force a re-fetch.

## 1. `config.json`

| Key | Value / purpose |
|---|---|
| `DESIGN_NAME` | `es_switch_gmii` — netlist and GDS are named after it |
| `VERILOG_FILES` | staged RTL in dependency order: `es_defs.sv`, `common/`, `mems/`, `mac/` byte-stream framers + adapters, `switch/` pipeline levels (the receive level is split into `es_switch_rx_ctrl` / `es_switch_rx_parse` / `es_switch_rx_check` slices plus the `es_switch_rx_engine` wrapper), `es_switch_fabric.sv`, three wrappers. Stops at the GMII top; board shells and PHY-management peripherals are outside the ASIC build. |
| `VERILOG_INCLUDE_DIRS` | `["rtl"]` |
| `VERILOG_DEFINES` | `["SYNTHESIS"]` — keeps elaboration-time `$error`/`$warning` checks out of the netlist, since yosys has no implementation for them |
| `CLOCK_PORT` / `CLOCK_PERIOD` | `clk_i` / `10` (100 MHz). The RTL default is 125 MHz; 10 ns is a defensible target on this PDK. |
| `FALLBACK_SDC` | `librelane/constraints/io.sdc` |
| Sizing / routing | `FP_SIZING=relative`, `FP_CORE_UTIL=40`, `PL_MAX_DISPLACEMENT_*`, `CTS_CLK_BUFFERS`, `CTS_DISTANCE_BETWEEN_BUFFERS`, `RT_MIN_LAYER=met1`, `RT_MAX_LAYER=met5`, `DRT_THREADS=8`, `DRT_ANTENNA_REPAIR_*`, `RUN_ANTENNA_REPAIR`, `RUN_LVS` |

**Unknown JSON keys are a hard error.** The loader validates every key against the flow's variables (`Unknown key '<name>' provided`) while reading the config, *before* synthesis — after a multi-GB image pull and PDK download. There are no comments in `config.json` (keys starting with `#` or containing `_OPT` are skipped silently, but that is an implementation detail, not a convention).
To check a key against the pinned tag: `librelane/config/removals.py` lists removed variables, `Changelog.md` holds the per-step notes, and `grep -rn '"VARIABLE_NAME"' librelane/` finds the declarations. Any rename in `config.json` must be recorded here in the same commit.

## 2. `SYNTH_PARAMETERS` — this build's change record

The flow elaborates a **reduced** instance so it completes on this PDK. The full RTL defaults (`MAX_FRAME_LEN=1518`, `SLOTS=2`, `SLOT_BYTES=2048`, `TX_QUEUE_DEPTH=256`, `CAM_SETS=128`, `CAM_WAYS=4`) are what `make sim` and `make param-scan` exercise; the flow uses the smaller set below. `VERILOG_DEFINES: ["SYNTHESIS"]` also selects the same reduced geometry directly from `es_switch_pl_defs.sv`, so `make synth` (which defines the same macro) elaborates the identical instance — the `SYNTH_PARAMETERS` below restate it explicitly rather than being the only mechanism.

| Key | This build | Status in this rewrite |
|---|---|---|
| `MAX_FRAME_LEN` | 256 | unchanged |
| `MIN_FRAME_LEN` | 64 | **new** |
| `SLOTS` | 1 | **new** (replaces the old frame-buffer sizing) |
| `SLOT_BYTES` | 512 | **new**; `SLOTS*SLOT_BYTES = 512` is a power of two |
| `DESC_DEPTH` | 8 | **new** |
| `TX_QUEUE_DEPTH` | 64 | **new** |
| `CAM_SETS` | 16 | unchanged |
| `CAM_WAYS` | 2 | unchanged |

The previous physical build sized the datapath with four separate FIFO-depth knobs. All four were removed with the staged-pipeline rewrite and no longer exist as parameters; five keys are new (`MIN_FRAME_LEN`, `SLOTS`, `SLOT_BYTES`, `DESC_DEPTH`, `TX_QUEUE_DEPTH`), while `MAX_FRAME_LEN`, `CAM_SETS` and `CAM_WAYS` keep their old values.
The instance stays self-consistent: `MAX_FRAME_LEN=256` fits `SLOT_BYTES=512`, and `SLOTS*SLOT_BYTES` is 2⁹, which the frame buffer's elaboration check requires. These reduced figures are not a claim that the full-size configuration was placed and routed.

## 3. `constraints/io.sdc`

Only `clk_i`, `rst_ni`, `link_up_i[*]`, `gmii_rx_en_i[*]`, `gmii_rx_data_i[*]`, `gmii_tx_en_o[*]` and `gmii_tx_data_o[*]` are constrained. There is a single clock (`create_clock -name core_clk -period 10.000`); every other port is an ordinary synchronous signal. `rst_ni` is an **active-low synchronous** reset, so it gets a normal input delay and is deliberately *not* in `set_false_path`. Input/output delay is 0.5 ns max / 0.0 ns min, load 0.010 (10 fF); the area target is `FP_CORE_UTIL`, not `set_max_area`.
The file is read by OpenSTA, not PrimeTime. Three PrimeTime-isms abort OpenSTA *while reading the file*, surfacing as a bogus STA failure:

| Construct | OpenSTA says |
|---|---|
| `remove_from_collection` | `invalid command name "remove_from_collection"` |
| `set_max_transition 1.0` (one-arg shorthand) | requires two positional arguments |
| `set_max_transition 1.0 [all_ports]` | `invalid command name "all_ports"` |

So ports are named explicitly, the driving cell is one the library has (`sky130_fd_sc_hd__buf_1`, pin `X`), and the transition limit uses `set_max_transition 1.0 [get_ports *]`. A renamed or resurrected status port would fail loudly here rather than silently escaping timing.

## 4. LibreLane 2.4 → 3.0 migration (config keys)

The 3.0 major release removed or renamed ten variables this configuration used; an unknown key is a hard error, so the migration is not optional. This table is the only record of which name went where.

| 2.x | 3.0 | Why |
|---|---|---|
| `SDC_FILE` | `FALLBACK_SDC` | deprecated name; `PNR_SDC_FILE` / `SIGNOFF_SDC_FILE` still exist |
| `CTS_BUF_CELL` | `CTS_CLK_BUFFERS` | one cell became a wildcard list (`sky130_fd_sc_hd__buf_*`) |
| `CTS_BUF_DISTANCE` | `CTS_DISTANCE_BETWEEN_BUFFERS` | renamed, same meaning; 60 um kept |
| `CTS_CLUSTER_SIZE` | `CTS_SINK_CLUSTERING_SIZE` | renamed, now optional |
| `CTS_CLUSTER_MAX_LEAVES` | `CTS_SINK_CLUSTERING_MAX_DIAMETER` | **not a rename** (leaves → diameter in um); no faithful conversion, so both left unset |
| `GRT_ADAPTIVE_ITERATIONS` | — | removed; `GRT_OVERFLOW_ITERS` is a different optimisation |
| `RT_THREADS` | — | removed; `DRT_THREADS` is what the detailed router reads |
| `RT_ANTENNA_ITERS` | `DRT_ANTENNA_REPAIR_ITERS` | antenna repair given its own `DRT_` prefix |
| `RT_ANTENNA_MARGIN` | `DRT_ANTENNA_REPAIR_MARGIN` | same |
| `RUN_DRC` | — | DRC no longer optional (`RUN_MAGIC_DRC` / `RUN_KLAYOUT_DRC` default true) |

`FP_SIZING`, `FP_CORE_UTIL`, `PL_MAX_DISPLACEMENT_*`, `RT_MIN_LAYER`, `RT_MAX_LAYER`, `DRT_THREADS`, `RUN_ANTENNA_REPAIR`, `RUN_LVS` are unchanged. Two non-rename changes can turn a green run red: hold violations are now fatal on any corner (`HOLD_VIOLATION_CORNERS=['*']`), and `Checker.KLayoutDensity` / `KLayoutAntenna` / `MaxSlewViolations` / `MaxCapViolations` / `OpenROAD.DumpRCValues` are new steps. A finding there is real and belongs in the design or constraints.

## 5. Synthesis portability and the CI `gds` approval gate

The flow reads the design with `read_verilog -defer -noautowire -sv -I<dir>... -D<define>... <file>`, one file at a time, then `chparam -set` for each `SYNTH_PARAMETERS` entry. That is why the RTL obeys the three yosys bans (no `package`/`import`, no `return` in a function, `-sv` mandatory) and why `make synth` is a faithful stand-in for the frontend. `make synth` uses the locally installed yosys, which need not be the version inside the image, so cell/area numbers differ.
The CI `gds` job is **gated behind a manual approval**: it declares `environment: production`, which must exist in repository settings with "Required reviewers" enabled, or no gate is enforced. It `needs: [lint, test]`, runs on the self-hosted runner, has a 180-minute budget, pins `ghcr.io/librelane/librelane:3.0.14`, and globs for `es_switch_gmii.gds` in `librelane/runs`. A job waiting for approval is not dispatched and blocks nothing; an approved, started job holds the single runner. This document does not claim a GDSII has been produced or taped out on this revision.
