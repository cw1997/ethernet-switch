# ethernet-switch

A parameterised Ethernet Layer-2 switch in synthesizable SystemVerilog, built as a **five-level, frame-concurrent pipeline** over an 8-bit byte-stream boundary, with a self-checking regression and a LibreLane 3.0 (OpenLane 2) flow down to GDSII.

**English** | [简体中文](README.zh-Hans.md)

The generic RTL defaults to **four ports** (parameter-overridable). The DE2-115 board shell has **two** and the Vivado template **eight**. The design is grouped under `rtl/common/`, `rtl/mac/`, `rtl/mems/`, `rtl/perips/`, `rtl/switch/`, with `rtl/es_defs.sv` as the umbrella header pulling the declaration libraries together in dependency order. There is no monitoring, statistics, command or indicator path anywhere in the design.

---

## Contents

[1 Boundary](#1-the-one-boundary-that-matters) · [2 Pipeline](#2-pipeline-architecture) · [3 Drop rules](#3-frame-admission-and-the-eight-drop-rules) · [4 CAM](#4-cam-behaviour) · [5 Tops](#5-five-top-level-modules) · [6 Parameters](#6-parameters) · [7 Ports](#7-ports-and-the-rate-model) · [8 Map](#8-repository-map) · [9 Gates](#9-build-gates-and-verification) · [10 Constraints](#10-rtl-hard-constraints) · [11 Boards](#11-board-shells-and-the-physical-flow) · [12 Migration](#12-migration-from-the-previous-architecture) · [13 Limits](#13-known-limitations)

---

## 1. The one boundary that matters

`rtl/mac/` and `rtl/switch/` meet at one deliberately narrow contract: an **8-bit byte stream** with `valid/ready` handshakes and `sof/eof/err` sideband. The switch core sees **MAC client data only** — no preamble, SFD, FCS or inter-frame gap. Everything the line implies lives in `rtl/mac/`:

* the RX framer hunts for **7 × 0x55 + 0xD5** itself (the PHY is not assumed to have stripped the preamble) and checks the CRC-32 FCS;
* the TX framer generates preamble/SFD, pads short client data, recomputes the FCS and inserts the inter-frame gap;
* MII/RMII adapters reuse nibble/dibit serialisers to reconstruct the octet stream, and the clock-enable rate model lives here too.

`es_switch_fabric` therefore holds no clock-enable, line-rate or symbol-order knowledge; compiling it against a different MAC changes nothing below the boundary. `link_up_i` is a **data gate**, not an observability surface.

## 2. Pipeline architecture

The single-frame global arbiter is gone. One frame can sit in each level at once, and all `NUM_PORTS` receive engines run in parallel. Levels are joined by `es_common_pipe_stage` instances (valid/ready registers with `DP` and `CUT_READY`).

| Level | Module | Responsibility |
|---|---|---|
| S0/S1 | `es_switch_rx_engine` (=`es_switch_rx_ctrl` + `es_switch_rx_parse` + `es_switch_rx_check`) + `es_switch_frame_buf` | one byte per clock, header latch, all eight drop checks (combinational), per-port byte FIFO + descriptor FIFO, legal-frame descriptor |
| S2 | `es_switch_cam_stage` + `es_switch_cam_table` | `NUM_PORTS` destination lookups and `NUM_PORTS` source learns in the **same clock** |
| S3 | `es_switch_decide` | broadcast / group / unknown-unicast policy, source-port filter, egress mask |
| S4 | `es_switch_tx_writer` | one copy engine per source port reading its own frame slot; target write port uses lowest-number-wins arbitration |
| S5 | `es_switch_tx_engine` | per-port TX FIFO; the MAC adapter then regenerates preamble, pad, FCS and IFG |

Invariants that keep every level lossless and synthesisable:

* A frame becomes visible downstream **only** after it has arrived in full and passed every check. A bad or over-MTU frame is removed by a **single `undo` pulse** rewinding the byte-FIFO write pointer; it produces no descriptor.
* **`SLOTS * SLOT_BYTES` must be a power of two.** The rewind is `wr_ptr - undo_cnt` on an `ADDR_W`-wide pointer while `next_slot` skips the unused encodings of a non-power-of-two depth; mixing the two lands on an illegal encoding. The frame buffer checks this at elaboration.
* Inter-level payloads are **packed** `{}` vectors with `localparam` widths and field-offset functions from `es_switch_pl_defs.sv` — no struct, interface or package. A transfer happens only on a handshake, so backpressure never drops a byte.
* A frame whose egress mask is zero is **not** dropped at S3: the TX writer still drains its bytes so the next descriptor starts at the right offset.

## 3. Frame admission and the eight drop rules

`MIN_FRAME_LEN` / `MAX_FRAME_LEN` bound the MAC client byte count (preamble/SFD and FCS excluded). A frame is admitted only when the byte FIFO can hold a whole maximum-length frame and the descriptor FIFO has a slot; once admitted, `b_ready_o` stays high for the entire frame. Eight rejection classes:

| # | Class | Detected at |
|---|---|---|
| 1 | bad FCS / RX_ER / truncation (`b_err_i` verdict) | MAC adapter verdict, consumed by RX engine |
| 2 | runt (below `MIN_FRAME_LEN`) | RX engine |
| 3 | over MTU (above `MAX_FRAME_LEN`) | RX engine (drains the rest of the wire frame) |
| 4 | 802.3 length field disagrees with measured client length | RX engine |
| 5 | VLAN tag truncated before the inner EtherType | RX engine |
| 6 | group (multicast/broadcast) source address | RX engine |
| 7 | source address equals this port's own MAC | RX engine |
| 8 | destination address equals this port's own MAC | RX engine |

FCS is checked **once**, in the MAC adapter; the RX engine only consumes the verdict, so the CRC LFSR is never instantiated twice on the same bytes.

## 4. CAM behaviour

* `NUM_PORTS` combinational lookups and `NUM_PORTS` learns run in the **same clock**. Lookup is **read-first**: a learn on the same edge is not visible to that clock's lookups.
* `CAM_SETS × CAM_WAYS` entries, a pure XOR-fold bucket hash (no multiplier, divider or wide adder chain) with a constant-index priority mux for bucket selection, set-associative with a round-robin victim pointer. Exact-tag matches relocate in place and do not advance the pointer.
* If more learns than `NUM_WAYS` land in one bucket in one clock, `learn_ready_o` backpressures the excess for one clock; `cam_stage` keeps `valid` asserted until the learn is granted. **Silently dropping a learn is forbidden.**
* Parallelism is fixed by `NUM_PORTS`: one CAM lookup and one learn lane per port, and one copy engine per source port (each reading its own ingress byte FIFO). There are no separate lane-count knobs. Bucket selection is a constant-index priority mux and the hash is a pure XOR fold, so `synth -flatten` stays tractable.

## 5. Five top-level modules

The five top names are unchanged. `lint`, `rtl` and `synth` elaborate **all five**, so a wrapper that is never compiled cannot silently rot.

| Top | Interface | Instance | Notes |
|---|---|---|---|
| `es_switch_gmii` | GMII, 8-bit pins | ASIC / default | `DESIGN_NAME` for LibreLane |
| `es_switch_mii` | MII, 4-bit nibbles | DE2-115 shell | rejects a 1000 Mbit/s port at elaboration |
| `es_switch_rmii` | RMII, 2-bit dibits | — | rejects 1000 Mbit/s; needs a divisible `BYTE_PERIOD` |
| `es_switch_de2_115_top` | 2 × MII PHY pins | Quartus II board | 50 MHz, 100 Mbit/s, MDIO PHY management |
| `es_switch_vivado_top` | 8 × MII template | Vivado board | 50 MHz, 100 Mbit/s, `link_up_i` tied high |

## 6. Parameters

Every wrapper exposes the same configuration surface (board shells fix some of it as `localparam`):

| Parameter | Default | Meaning |
|---|---|---|
| `NUM_PORTS` | 4 | number of ports |
| `CLK_FREQ_HZ` | 125 MHz (GMII) / 50 MHz (MII, RMII) | core clock frequency |
| `PORT_SPEED` | `2'd2` GMII / `2'd1` MII,RMII | per-port `sw_speed_e`, packed `N*2` bits |
| `PORT_MAC` | `'0` | per-port MAC, packed `N*48`; zero derives a local address |
| `MIN_FRAME_LEN` | 64 | minimum accepted client bytes |
| `MAX_FRAME_LEN` | 1518 | maximum accepted client bytes |
| `SLOTS` | 2 | frame slots per ingress buffer |
| `SLOT_BYTES` | 2048 | bytes per slot; `SLOTS*SLOT_BYTES` must be 2ⁿ |
| `DESC_DEPTH` | 8 | descriptor FIFO depth |
| `TX_QUEUE_DEPTH` | 256 | per-port TX FIFO depth |
| `CAM_SETS` | 128 | CAM sets |
| `CAM_WAYS` | 4 | CAM ways per set |
| `LEARNING_EN` | 1 | enable source learning |
| `FLOOD_MODE` | `2'd1` | flooding policy (below) |
| `IFG_OCTETS` | 12 | inter-frame gap in octets |

**Simulation vs synthesis defaults.** The table above is the *simulation* default. When `SYNTHESIS` is defined — which both `make synth` and LibreLane do — `es_switch_pl_defs.sv` supplies a reduced geometry (`MAX_FRAME_LEN=256`, `SLOTS=1`, `SLOT_BYTES=512`, `TX_QUEUE_DEPTH=64`, `CAM_SETS=16`, `CAM_WAYS=2`). A full-size buffer is 4×2048×8 ≈ 131 000 flops, which yosys' `synth -flatten` takes tens of minutes to lower; the synthesis gate only has to prove the frontend can read and elaborate the design. Simulations keep the full defaults, so no behavioural check is weakened. LibreLane restates the same reduced values in `SYNTH_PARAMETERS`.

`FLOOD_MODE`: **0** = forward broadcast only; **1** = also flood unknown unicast (default); **2** = also flood unknown group/multicast. `LEARNING_EN` and `FLOOD_MODE` are pure elaboration parameters — there is no run-time control path.

## 7. Ports and the rate model

The handshake is `<src>_o_valid/<src>_o_ready` ↔ `<dst>_i_valid/<dst>_i_ready`; RX carries `sof/eof/err`, TX carries `sof/eof`. GMII top ports: `clk_i`, `rst_ni`, `link_up_i[N]`, `gmii_rx_en_i[N]`, `gmii_rx_data_i[N*8]`, `gmii_tx_en_o[N]`, `gmii_tx_data_o[N*8]`. MII/RMII tops replace the data buses with their nibble/dibit pins and RX_ER signals.

A port needs one elaboration-time constant, `BYTE_PERIOD = sw_byte_period(CLK_FREQ_HZ, PORT_SPEED[p])`: the number of `clk_i` cycles per octet. At 125 MHz that is 1 (1000BASE-T), 10 (100BASE-TX), 100 (10BASE-T); at 50 MHz a 100 Mbit/s port is 4. Line rate is expressed with **clock enables, not extra clock domains** — the whole design is single-clock and free of clock-domain crossings.

## 8. Repository map

```
rtl/common/     two-stage sampler, CRC-32, DFF/pipe-stage primitives
rtl/mac/        byte-stream framers, GMII/MII/RMII adapters, serialisers
rtl/mems/       FWFT FIFO, 1R1W RAM, parallel register banks
rtl/perips/     MDIO and 88E1111 PHY management
rtl/switch/     staged fabric: rx_engine (ctrl/parse/check slices),
                frame_buf, cam_stage/table, decide, tx_writer, tx_engine,
                fabric, three wrappers
tb/             self-checking regressions (never synthesised, never linted)
board/          DE2-115 (Quartus II) and Vivado 8-port MII shells, each with a TB
ci/             toolchain contract (check-toolchain.sh)
librelane/      config.json + constraints/io.sdc + flow README
Makefile        every gate; the target list is in its own header
AGENTS.md       authoritative rules for RTL, testbenches and the flow
```

## 9. Build, gates and verification

Run the gates in this order; they are ordered by how fast they fail.

```sh
ci/check-toolchain.sh   # the tools match the versions the gates assume
make lint               # Verilator -Wall; any warning is an error
make rtl                # Icarus elaboration of the five tops, RTL only
make unit               # block-level + staged-fabric regressions
make mii rmii vivado board-unit   # the four PHY/board front ends
make sim                # GMII system regression, complete wire frames
make param              # 3 ports, non-power-of-two CAM (96 × 3)
make param-scan         # 4/8/16/32/48 ports × CAM geometries
make synth              # yosys; needs yosys on PATH, NOT part of `make all`
make all                # everything above except `synth`
```

| Gate | Tool | What it catches that the others do not |
|---|---|---|
| `make lint` | Verilator `--lint-only -Wall` | width mismatches, unused signals, latches, incomplete case coverage; any warning fails |
| `make rtl` | Icarus `-g2012`, RTL only | anything that only elaborates because a TB declares a missing signal |
| `make unit` / `sim` / `param` | Icarus + `vvp` | behaviour |
| `make synth` | yosys `read_verilog -sv` | everything the simulators accept and the silicon flow will not |
| CI job `gds` | LibreLane 3.0.14, sky130A | timing, hold, DRC, LVS against standard cells |

`make param-scan` covers port counts **4/8/16/32/48** and CAM combinations `(16,2) (96,3) (64,1) (32,4) (128,4) (64,2) (48,5)`; all seven run the full scenario suite and pass. The scan samples *geometries*, not scenarios - a full cross-product of scenarios, port counts and every CAM set/way pair would exceed the CI time budget.

**`make all` does not include `make synth`** — run it separately before calling a change done; it is the only gate that enforces the synthesis restrictions. CI runs on a **self-hosted** Linux runner in four jobs — `images`, `lint`, `test`, `gds` — with LibreLane **3.0.14**; the `gds` job is gated behind a manual approval. On Windows the EDA tools live in WSL, so every command is wrapped:

```sh
bash wsl.sh "make lint"
bash wsl.sh "make synth"
```

CI uses Linux directly and never needs `wsl.sh`. Definition of done is in `AGENTS.md` §5: no new `verilator lint_off`, no new `initial` block, all gates green.

## 10. RTL hard constraints

Not style preferences — several exist because the alternative already broke this design in a way a testbench could not see.

* **Three yosys bans.** (1) no `package` and no `import` in any form — shared declarations live at compilation-unit scope in `es_defs.sv`; (2) no `return` in any function — assign to the function name instead (IEEE 1800-2017 13.3); (3) `read_verilog` **must** use `-sv`; the `.sv` extension does not imply it. All three are invisible to Icarus and Verilator.
* **Verilator `-Wall` with zero warnings, and no new `lint_off` waivers.** Fix the finding rather than silencing it. `-Wno-DECLFILENAME` is a command-line convention, not a suppressed defect.
* **Reset is synchronous, active low, named `rst_ni`, and is the first branch of every `always_ff` with state.** No asynchronous reset anywhere.
* **A packed vector for anything indexed at run time.** Icarus returns stale data for a run-time-indexed unpacked array; unpacked arrays are only for constant-indexed memories/register files.
* **Register files are written by per-entry `always_ff` blocks in a generate loop** with constant indices, never a loop-indexed store.
* Elaboration-time parameter checks use `$error` / `$warning` inside `` `ifndef SYNTHESIS ``, because yosys has no implementation for them.
* Every operand of an arithmetic/bitwise operator has the same, intended width; `always_comb` assigns every output first and carries a `default` in every `case`; Quartus needs explicit `generate`, separately declared genvars and function-computed elaboration-time tables. See `AGENTS.md` for the full rules.

## 11. Board shells and the physical flow

* **DE2-115** — `board/de2_115/quartus_ii/README.md`: dual-port 100 Mbit/s MII, 50 MHz, 88E1111 PHY management over MDIO, KEY0 reset, TX_CLK dividers. Its board TB `force`s `phy_enabled` to bypass MDIO management because no external MDIO PHY responder is modelled; it does **not** validate MDIO management.
* **Vivado** — `board/vivado/README.md`: eight-port MII template. `configure.tcl` reattaches RTL via `glob`, stale `.xpr` source nodes are cleared, and physical PHY clock capture / CDC remain unfinished board-integration work.
* **LibreLane** — `librelane/README.md`: `config.json`, the `SYNTH_PARAMETERS` change record, `io.sdc`, the 2.4 → 3.0 migration table and the CI `gds` approval gate.

## 12. Migration from the previous architecture

This release is a full datapath rewrite. The former wide-beat, single-frame global-arbiter design and all of its monitoring, status, command and indicator paths have been removed in favour of the byte-stream frame-concurrent pipeline above. Configuration is now purely elaboration-time (`FLOOD_MODE`, `LEARNING_EN`); `link_up_i` is only a data gate. The five top names are unchanged.

## 13. Known limitations

* The LibreLane build elaborates a **reduced** instance (`SYNTH_PARAMETERS`); it proves the flow reads, synthesises and routes the design at a size it can finish. It is not a claim that a full-size configuration was placed and routed, and this document does not claim a GDSII has been taped out.
* The Vivado shell's physical PHY clock capture, CDC and timing adaptation are explicitly **unfinished**; `make vivado` models the synchronous MII boundary only and does not test real PHY CDC or board timing.
* The DE2-115 board TB bypasses MDIO management (`phy_enabled` is forced); PHY management is not verified by that bench.
* `make synth` uses the locally installed yosys, which need not be the exact version inside the LibreLane image; cell/area figures therefore differ.
