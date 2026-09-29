# ethernet-switch

A parameterised, store-and-forward Ethernet Layer-2 switch core in
SystemVerilog, with a self-checking regression and a LibreLane (OpenLane 2)
implementation flow down to GDSII.

```
rtl/     the design
tb/      the testbenches
librelane/  the physical implementation flow
```

## The design

One clock domain, no clock-domain crossings. Each port runs at 10, 100 or
1000 Mbit/s and the line rate is handled with *clock enables* - the octet
strobes that a GMII PHY interface is naturally built from - rather than with
multiple clocks. One 64-bit beat is eight octets, so a 1000BASE-T port at a
125 MHz core is one beat per clock.

| Block | File | What it does |
|---|---|---|
| CRC-32 | `sw_crc32.sv` | byte-serial IEEE 802.3 FCS generation and checking, from one shared lookup table |
| Elastic buffer | `sw_sync_fifo.sv` | first-word-fall-through FIFO with a frame-granular rewind, so a rejected frame leaves the buffer in one pointer move |
| GMII receive | `sw_gmii_rx.sv` | octet stream to 64-bit beats, plus the FCS check |
| Ingress | `sw_rx_port.sv` | header parse, CAM lookup, ingress filter, buffering, descriptor generation |
| CAM | `sw_mac_table.sv` | shared set-associative forwarding table, `NUM_SETS` buckets x `NUM_WAYS` ways, one combinational read per port and a serialising learn queue |
| Fabric | `sw_arbiter.sv` | round-robin scheduling, whole-frame admission, one-to-many beat copy |
| GMII transmit | `sw_gmii_tx.sv` | beats to a wire-legal frame, FCS generated one octet ahead of the wire |
| Egress | `sw_tx_port.sv` | egress beat buffer and per-frame length descriptors |
| Top level | `sw_switch.sv` | port instances, CAM, fabric, statistics aggregation |
| Declarations | `sw_defs.sv` | every shared constant, type and helper, at compilation-unit scope |

Features: 802.1Q / 802.1ad tag aware forwarding, source address learning with
set-associative replacement and optional ageing, a configurable
unknown-unicast / group flooding policy, full FCS generation and checking, and
runt / oversize / ingress-overflow / CRC-error detection behind a 14-counter
statistics bus.

## The PHY interface

`gmii_rx_*` and `gmii_tx_*` are GMII-style 8-bit interfaces qualified by a
clock enable and synchronous to `clk_i`:

* one octet every `BYTE_PERIOD` clocks,
* the enable is asserted for the whole octet time and the data is stable for
  the same window,
* the enable is de-asserted during the inter-frame gap.

The preamble and the start-of-frame delimiter are removed on receive and
re-inserted on transmit, exactly as a real GMII MAC does. A PHY on its own
clock needs asynchronous FIFOs around the core; nothing inside changes.

## Building and testing

Requires Icarus Verilog (12+) and Verilator (5.x). `make synth` additionally
needs yosys.

    make lint      # Verilator -Wall; any warning fails
    make rtl       # Icarus elaboration of the RTL alone, no testbench
    make unit      # CRC-32, FIFO and CAM block-level testbenches (milliseconds)
    make sim       # the four-port mixed-speed switch testbench (slow)
    make param     # the three-port, 50 MHz parameterisation testbench
    make synth     # yosys read + elaborate + synthesise (needs yosys)

`make all` runs lint, unit, sim and param.

The main testbench is the slow one on purpose: it drives a 10 Mbit/s port on a
125 MHz core, so a single frame needs about 10 000 clocks and every test waits
for the slowest port to finish before it looks at the result. It runs four
ports at 10 / 100 / 1000 / 1000 Mbit/s simultaneously from one clock, which is
the configuration most likely to expose a clock-enable bug, and it checks every
frame that appears on the wire - destination, source, length, preamble and FCS -
against a reference model the testbench maintains itself.

## Physical implementation

`librelane/` holds the flow configuration and the timing constraints, and runs
under the pinned LibreLane container. See
[`librelane/README.md`](librelane/README.md) for how to run it, for the
configuration choices, and for **why the shared declarations live at
compilation-unit scope instead of in a package** - which is the single most
important portability constraint in this repository, because the synthesis
frontend rejects a package in three separate places and neither simulator
notices.

## Working on the design

[`AGENTS.md`](AGENTS.md) is the style and portability contract for this
repository: the tool flow and what each gate catches, the three restrictions the
synthesis frontend imposes, the RTL conventions (width discipline in
particular, since a silent operand extension is the defect the linter catches
least reliably), the testbench rules, and the order to run the gates in. Read it
before changing anything under `rtl/`.
