# ethernet-switch

A parameterised, store-and-forward Ethernet Layer-2 switch core in
synthesizable SystemVerilog, with a self-checking regression and a LibreLane
implementation flow down to GDSII.

**English** | [简体中文](README.zh-Hans.md)

## Repository map

| Path | What is in it |
|---|---|
| `rtl/` | the design. One file per block, `sw_<block>.sv` / module `sw_<block>` |
| `tb/` | the self-checking testbenches; never synthesised, never linted by CI |
| `ci/` | the CI toolchain contract (`check-toolchain.sh`) and the toolchain image definition (`toolchain/Dockerfile`) |
| `librelane/` | the physical implementation flow (`config.json`, constraints, and its own README) |
| `Makefile` | every gate; the target list is documented in its own header |
| `AGENTS.md` | the style and portability contract - read it before changing anything under `rtl/` |

## Contents

* [What this is, and what it is not](#what-this-is-and-what-it-is-not)
* [The datapath, end to end](#the-datapath-end-to-end)
  - [The shape of the datapath](#the-shape-of-the-datapath)
  - [One clock, and clock enables instead of clocks](#one-clock-and-clock-enables-instead-of-clocks)
  - [Receive: octets to a buffered, described frame](#receive-octets-to-a-buffered-described-frame)
  - [The forwarding database](#the-forwarding-database)
  - [The fabric](#the-fabric)
  - [Transmit: beats back to a wire-legal frame](#transmit-beats-back-to-a-wire-legal-frame)
* [The life of one frame](#the-life-of-one-frame)
* [The blocks](#the-blocks)
* [The frame descriptor](#the-frame-descriptor)
* [Statistics](#statistics)
* [Parameters](#parameters)
* [The PHY interface](#the-phy-interface)
* [Building and testing](#building-and-testing)
* [Physical implementation](#physical-implementation)
* [Working on the design](#working-on-the-design)

## What this is, and what it is not

It is a **switching core**, not a network interface card. It sits between GMII
PHY interfaces and does the Layer-2 work: it terminates the MAC framing on each
port, parses the header, resolves the destination against a learned forwarding
database, buffers the frame, and re-serialises it onto the destination port(s)
with a freshly computed FCS.

It deliberately does **not** contain: a PCS or PMA, autonegotiation, link
monitoring, flow control (802.3x pause frames), spanning tree, VLAN filtering or
tag rewriting, priority/QoS scheduling, or any statistics *access* mechanism -
the counters are exported on a read-only bus and it is up to the integrator to
read them. What it does contain is the part that is hard to get right and that
every switch needs to be correct: frame-boundary handling, store-and-forward
buffering with no descriptor/payload skew, source-address learning that cannot
lose an entry under simultaneous access, and a fabric that cannot interleave two
frames into one egress buffer.

It is written to be **synthesizable and portable** rather than merely
simulatable. The three restrictions that costs imposes are in
[AGENTS.md](AGENTS.md#21-the-three-hard-yosys-restrictions) and
[`librelane/README.md`](librelane/README.md#synthesis-portability); the short
version is that the shared declarations live at compilation-unit scope instead
of in a `package`, because the synthesis frontend rejects a package in three
separate places and neither simulator notices.

## The datapath, end to end

### The shape of the datapath

The pipeline one frame travels through, drawn for one port. Everything in the
diagram except the CAM and the fabric exists once per port; `sw_mac_table` and
`sw_arbiter` are single shared instances that serve every port in the same
clock:

```
            GMII RX octets (clock-enable qualified)
                 |
                 v
          +-------------+   octets -> 64-bit beats; the FCS is checked at
          | sw_gmii_rx  |   the octet rate, with one clock of hold margin
          +-------------+
                 |
                 v  beats
          +-------------+     lookup (answer one clock later)
          |             | <----------------------------> +-------------+
          | sw_rx_port  |     learn, queued and drained    | sw_mac_table|
          |  (ingress)  |     one per clock                | (shared CAM)|
          +-------------+                                  +-------------+
                 |
                 v  payload beats + one tag descriptor per frame
          +-------------+   pops the descriptor, checks that every egress in
          | sw_arbiter  |   the mask can take the whole frame, then copies
          |  (fabric)   |   each beat to every port in the mask in the same
          +-------------+   clock
                 |
                 v  payload beats + one length descriptor per frame
          +-------------+   egress beat buffer; the per-frame length is
          | sw_tx_port  |   popped in step with the first beat
          +-------------+
                 |
                 v  beats
          +-------------+   beats -> wire-legal frame: preamble, SFD,
          | sw_gmii_tx  |   zero-padded client data, a fresh FCS and a
          +-------------+   12-octet inter-frame gap
                 |
                 v
            GMII TX octets
```

The ingress side of every port produces two streams that must never drift
apart: **payload beats** in a `sw_sync_fifo` of `RX_FIFO_DEPTH` entries, and
**frame descriptors** (the tag word below) in a second FIFO. The fabric
(`sw_arbiter`) reads the descriptor first, checks that every destination egress
can take the whole frame, then copies the payload beats into the egress
buffers - one beat to every port in the destination mask in the same clock.
Egress buffers the beats the same way, described by a per-frame length
descriptor, and `sw_gmii_tx` re-serialises the result.

### One clock, and clock enables instead of clocks

Every port shares a single `clk_i`. There are **no clock-domain crossings
anywhere** in the design, which is a deliberate choice with two consequences
worth stating plainly:

* A port's line rate is set by a **clock enable**, not by a clock. The only
  elaboration-time constant a port needs is `BYTE_PERIOD`, the number of
  `clk_i` cycles that make up one GMII octet time, and it is derived from the
  core clock and the configured speed by `sw_byte_period()`:

  | core clock | 10 Mbit/s | 100 Mbit/s | 1000 Mbit/s |
  |---|---|---|---|
  | 125 MHz | 100 | 10 | 1 |
  | 50 MHz | 40 | 4 | 1 &dagger; |
  | 200 MHz | 160 | 16 | 2 &dagger; |

  A slower core clock does not change the datapath at all; it stretches the
  enable period. Two things follow from that:

  - **The core clock sets the per-port ceiling.** At 125 MHz, `BYTE_PERIOD = 1`
    is already 125 Mbaud, so no port can exceed 1 Gbit/s however it is
    configured.
  - &dagger; **An octet period has to be a whole number of clocks, so a core
    clock that does not divide the octet time cannot be represented.**
    1000BASE-T needs an 8 ns octet time, which is 2.5 clocks at 50 MHz and 1.6
    at 200 MHz; the function rounds and then clamps to 1, so those ports are
    driven *faster* than the configured line rate - 400 Mbit/s at 50 MHz, 800
    Mbit/s at 200 MHz. The lower rates are exact at all three clocks above,
    because 8 ns divides into 40 ns and 160 ns. `make param` is 50 MHz and
    deliberately runs 100/100/10 Mbit/s, so it does not hit this. **A core clock
    and a port speed that are not commensurate will not give you the line rate
    you asked for** - the honest fix is a fractional or DDS clock enable, which
    this design does not have.

* The internal datapath is 64 bits wide - one **beat** is eight octets, octet 0
  in `[63:56]`. A 1 Gbit/s port therefore delivers one beat every eight core
  clocks, not one beat per clock, and the beat bus runs at 12.5% of its width at
  line rate. That is headroom, not a bottleneck: the fabric is the shared
  resource, and it is sized for the aggregate.

### Receive: octets to a buffered, described frame

```
GMII octets -> sw_gmii_rx -> elastic FIFO -> sw_rx_port -> payload FIFO + tag FIFO
```

**`sw_gmii_rx`** converts the octet stream into beats and checks the FCS in the
same module, so the CRC always advances at the octet rate. It re-synchronises
onto a free-running phase counter and samples on the *last* cycle of each octet
time, which gives a full clock of hold margin without a FIFO or a CDC. A full
beat is deliberately held until the next octet (the frame continues) or until the
link goes idle (the frame ends), because a PHY may hold `gmii_en_i` high for the
rest of the final octet time and an eager emit would lose the end-of-frame
marker.

**`sw_rx_port`** parses the header, asks the CAM, applies the ingress policy, and
then buffers. The parser is a small state machine over the elastic FIFO. The
14-octet MAC header does not line up with the 8-octet beat boundary, so it is
stitched from two beats - destination address from beat 0, source address and
the length/EtherType field straddling the 8-octet boundary - and an 802.1Q /
802.1ad tag adds a third beat. The exact split is written out at the site in the
code, because getting it wrong shifts every header field by two octets and
produces a switch that looks like it works.

**Frame size** is resolved from the header only when the header can say so. A
legacy 802.3 *length* field (<= 1500) gives an exact size and is held to. Every
modern EtherType frame is measured on the wire instead: octets received minus the
four FCS octets. Frames whose length field contradicts what arrived are rejected
as runts or oversize, which is what a real bridge does.

**The verdict is frozen when the frame is complete**, not before: store and
forward, so a frame is never emitted into an egress buffer and then retracted.

**A rejected frame costs one pointer move.** The parser appends payload to the
payload FIFO as it goes, so a frame that turns out to be bad is rewound out of
the buffer with a write-pointer rollback rather than being read back. The tag
descriptor is written only for a frame that passed, so payload and descriptor
cannot lose frame synchronisation whatever the receive conditions are. This is
what the `undo_*` port of `sw_sync_fifo` exists for.

**The ingress policy** decides a destination bitmask, and it is where a bridge's
behaviour actually lives:

| condition | result |
|---|---|
| source MAC is this port's own address | dropped - a reflected frame |
| destination is this port's own address, arriving on this port | dropped - it is *for* this port, and flooding it would leak a unicast onto every other segment |
| destination is `ff:ff:ff:ff:ff:ff` | flooded to every port except the ingress |
| destination is a group (multicast) address | flooded only if the policy allows it |
| destination is a unicast address known to the CAM | sent to that one port, minus the ingress port; dropped if that port *is* the ingress port |
| destination is an unknown unicast | flooded or dropped, per policy |

The policy is a module parameter with a run-time override, so the same RTL serves
a hub and a learning switch.

### The forwarding database

`sw_mac_table` is one **shared** CAM serving every port: `NUM_SETS` buckets of
`NUM_WAYS` entries, indexed by an FNV-1a hash of the 48-bit address truncated to
the bucket index. Neither needs to be a power of two - the hash takes a real
modulo and the replacement pointer is bounded explicitly.

Two properties are worth calling out because they are what make it a forwarding
*database* rather than a lookup table:

* **Every port reads in parallel, in one clock.** A read touches only the single
  bucket the address hashes to, so the cost per port is `NUM_WAYS` 48-bit
  comparators and all `NUM_PORTS` lookups resolve together. The receive path
  never arbitrates for a lookup, which is why there is no lookup latency to hide
  in the parser.
* **Learning cannot lose an entry.** A CAM has one write port, but every port can
  finish a frame in the same clock. Requests are collected into an internal
  queue and drained one per clock, so two ports learning simultaneously both get
  recorded, the second one a clock later. Insertion first searches the bucket for
  an exact match and *relocates* the station if it is there, so a station that
  moves to another port does not leave a stale duplicate behind; only a genuine
  insertion advances the round-robin replacement pointer.

Optional ageing sweeps the table and expires entries that have not been refreshed.
Refreshing is implicit - the source address is re-learned on every accepted
frame - and the per-entry countdown means `AGE_LIMIT = 0` degenerates to "expire
on the first sweep after the last refresh" with no special case.

### The fabric

`sw_arbiter` is where the failures live, so it is worth being explicit about what
it guarantees.

* **One frame in flight.** A grant is only issued while no transfer is in
  progress. Allowing a new grant in the same clock as the last beat of the
  in-flight frame would put two frames' beats in the same egress FIFO in the same
  cycle; the beats interleave, the frame boundaries are lost, and the transmit
  path then starts frames on descriptors that no longer match the data behind
  them. That failure looks like transmit-path corruption and is not.
* **Whole-frame admission, checked up front.** Before starting, the arbiter
  checks that *every* destination egress can take the complete frame - payload
  room for all of its beats, **and** a free length descriptor. Checking only the
  first is what strands a frame in a buffer with nothing to serialise it: the
  beat FIFO holds `TX_FIFO_DEPTH / 8` minimum-length frames while only
  `LEN_FIFO_DEPTH` descriptors exist, and a frame whose descriptor write is
  dropped can never be transmitted. Because the check is made once, up front, and
  only one frame is ever in flight, a transfer can never stall mid-frame and can
  never drop beats.
* **One-to-many by construction.** A grant produces a destination *mask*, and one
  beat is written to every port in that mask in the same clock. Flooding is
  therefore not a special case that has to be kept correct; it is what the fabric
  does.
* **The first beat is flagged.** That is what lets an egress queue exactly one
  length descriptor per frame while receiving all of its beats.
* **Head-of-line protection is opt-in.** `STALL_LIMIT` bounds how long a blocked
  head-of-line frame may wait before it is discarded, which bounds the latency a
  congested egress can impose on the other ports. The default is 0, meaning stall
  forever and never drop.

### Transmit: beats back to a wire-legal frame

```
payload FIFO + descriptor FIFO -> sw_gmii_tx -> GMII octets
```

`sw_tx_port` buffers the beats in one FIFO and the per-frame lengths in a
smaller one. A frame starts when a descriptor is available *and* the serialiser
has finished the previous inter-frame gap, and the descriptor is popped at the
same moment, so the two streams cannot drift apart. It reports two separate
capacity numbers to the fabric - free beats, and whether one more whole frame
fits - because they are two separate buffers and reporting only the first is what
lets the fabric wedge.

`sw_gmii_tx` generates the preamble, the SFD, the MAC client data (zero-padded to
the 802.3 minimum, with the padding covered by the FCS) and the FCS, and
enforces a 12-octet inter-frame gap. The FCS generator runs **one octet ahead of
the wire** - it absorbs exactly the octet being registered onto `gmii_d_o` at the
same clock edge - so when the last client octet leaves the MAC the LFSR already
holds the final result and the first FCS octet follows with no bubble and no
extra pipeline register. A request is latched rather than acted on immediately,
so every octet window of a frame is exactly `BYTE_PERIOD` clocks long even when
the request arrives mid-window.

## The life of one frame

The sections above describe each block; this walks one unicast frame from
port 0 to port 3 and names the guarantee that is exercised at each step.

1. **Octets arrive.** `sw_gmii_rx` samples the GMII octet stream on a
   free-running phase counter, checks the FCS as the octets stream by, and
   assembles 64-bit beats. The last beat is deliberately held until the next
   octet or the link idle, so the end-of-frame marker cannot be lost.
2. **The header is parsed.** `sw_rx_port`'s state machine stitches the
   destination and source addresses out of the first one or two beats (a third
   if the frame is 802.1Q tagged) and resolves the frame size - from the
   legacy length field when the header carries one, otherwise measured on the
   wire.
3. **The CAM is asked.** The lookup is issued while the payload is still
   streaming into the buffer, and the answer arrives one clock later - which
   is why there is no lookup latency to hide in the parser.
4. **The verdict is frozen.** The frame is fully received *before* the
   forwarding decision is committed: store and forward. A frame that fails the
   FCS, length or ingress-policy checks is rewound out of the payload FIFO with
   a single write-pointer rollback - one pointer move, no data read back - and
   no descriptor is ever written for it.
5. **The source address is learned.** The (now validated) source address is
   handed to the CAM's learn queue; if another port learned in the same clock,
   this request waits one cycle in the queue and neither is lost. An address
   already present is *relocated*, not duplicated, so a station that moves
   ports leaves no stale entry behind.
6. **The fabric grants the whole frame.** `sw_arbiter` pops the descriptor,
   verifies that every egress port in the mask has payload room for all of the
   frame's beats *and* a free length descriptor, and only then starts the
   transfer. One frame is in flight at a time; a new grant cannot race the
   last beat of the previous frame. The transfer therefore cannot stall
   mid-frame and cannot drop beats.
7. **Beats fan out.** Each payload beat is written to every port in the mask
   in the same clock - flooding is not a special case, it is what the fabric
   does. The first beat is flagged so the egress knows which descriptor the
   beats belong to.
8. **The frame is re-serialised.** `sw_tx_port` waits until a descriptor is
   available *and* the inter-frame gap has elapsed, pops the descriptor at the
   same moment the beats start, and `sw_gmii_tx` emits preamble, SFD, the
   client data (zero-padded to the 802.3 minimum, padding covered by the FCS)
   and a freshly computed FCS. The FCS LFSR runs one octet ahead of the wire,
   so the last client octet is followed by the first FCS octet with no bubble.

A broadcast is the same walk with a multi-bit mask at step 6, and the fabric
counts it as N copies - one per port that received it - on the first beat of
each copy.

## The blocks

| Block | File | What it does |
|---|---|---|
| CRC-32 | `sw_crc32.sv` | octet-serial IEEE 802.3 FCS generation and checking from one shared table |
| Elastic buffer | `sw_sync_fifo.sv` | first-word-fall-through FIFO with a frame-granular rewind and a hard flush |
| GMII receive | `sw_gmii_rx.sv` | octet stream to 64-bit beats, plus the FCS check |
| Ingress | `sw_rx_port.sv` | header parse, CAM lookup, ingress policy, buffering, descriptor generation |
| CAM | `sw_mac_table.sv` | the shared forwarding database: `NUM_SETS` x `NUM_WAYS`, one parallel read per port, a serialising learn queue |
| Fabric | `sw_arbiter.sv` | round-robin scheduling, whole-frame admission, one-to-many beat copy |
| GMII transmit | `sw_gmii_tx.sv` | beats to a wire-legal frame, FCS generated one octet ahead of the wire |
| Egress | `sw_tx_port.sv` | egress beat buffer, per-frame length descriptors, transmit statistics |
| Top level | `sw_switch.sv` | port instances, CAM, fabric, statistics aggregation, elaboration-time checks |
| Declarations | `sw_defs.sv` | every shared constant, type and helper, at compilation-unit scope |

## The frame descriptor

Every buffered frame is described by one **tag** word in a per-port descriptor
FIFO, travelling alongside the payload. The field offsets are defined once in
`sw_defs.sv` as `sw_tag_*_lsb()` helpers and read by both ends, so the two
cannot drift apart; the total width is `sw_tag_width(NUM_PORTS)`.

| field | width | offset helper | meaning |
|---|---|---|---|
| `dst_mask` | `NUM_PORTS` | `sw_tag_dstm_lsb` | the egress bitmask the ingress filter decided, already frozen |
| `src` | `sw_port_w(NUM_PORTS)` | `sw_tag_src_lsb` | ingress port index, for observability |
| `len` | `SW_LEN_W` (11) | `sw_tag_len_lsb` | MAC client data length, FCS excluded |
| `flood` | 1 | `sw_tag_flood_lsb` | set when `dst_mask` came from a flooding decision |
| `drop` | 1 | `sw_tag_drop_lsb` | defensive: the descriptor describes a frame the fabric should discard |

`drop` is always zero in the current design. The ingress filter rejects a frame
*before* buffering it - that is what the rewind in `sw_sync_fifo` is for - so a
descriptor is only ever written for a frame that passed. The fabric retains the
ability to discard such a descriptor, and the field is kept because a design
that buffered first and filtered later would need it; the field extraction is
live in the fabric, not dead code left behind by accident.

## Statistics

A 14-counter read-only bus, summed across ports at the top level, 32 bits per
counter. Counters are named for the *event* they record, not for the block that
happens to own them:

| | |
|---|---|
| `RX_FRAMES` `RX_OCTETS` | frames and octets accepted by the ingress filter and forwarded into the fabric |
| `RX_FILTERED` | frames dropped by the ingress policy |
| `RX_CRC_ERR` `RX_RUNT` `RX_OVERSIZE` | frames failing the FCS, shorter than the minimum, longer than the configured maximum |
| `RX_OVERFLOW` | frames dropped because an ingress buffer was exhausted - reported separately from an oversize frame, because it points at a buffer that is too small rather than at a bad frame |
| `TX_FRAMES` `TX_OCTETS` | frame copies injected into transmit ports, counted on the *first beat* of each copy and reduced with a population count - a broadcast to three ports is three copies, and counting grants would report it as one |
| `TX_STALLED` | frames discarded by the head-of-line protection |
| `CAM_HIT` `CAM_MISS` | lookups that resolved to a port, and that fell through to flooding; both ports hitting in the same clock are both counted |
| `CAM_LEARN` | insertions written into the table |
| `CAM_FLUSH` | reported straight from the flush request line rather than counted - it is a one-shot software action, not an event the table can observe |

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `NUM_PORTS` | 4 | number of ports; any value >= 1, not necessarily a power of two |
| `CLK_FREQ_HZ` | 125 000 000 | core clock; sets every port's octet period |
| `PORT_MAC` | `'0` | 48 bits per port, port *p* at `[48*p +: 48]`; an all-zero port gets `02:00:00:00:00:<p>` |
| `PORT_SPEED` | all 1000BASE-T | 2 bits per port, port *p* at `[2*p +: 2]`: 0 = 10, 1 = 100, 2 = 1000 Mbit/s, 3 = down |
| `MAX_FRAME_LEN` | 1518 | largest frame accepted, FCS excluded |
| `RX_FIFO_DEPTH` | 256 | payload beats per ingress port; must be >= `ceil(MAX_FRAME_LEN/8)` |
| `TX_FIFO_DEPTH` | 256 | payload beats per egress port; same rule |
| `TAG_FIFO_DEPTH` | 16 | descriptors buffered per ingress port |
| `WF_DEPTH` | 16 | elastic beat FIFO between the GMII adapter and the parser |
| `FLOOD_MODE` | 1 | 0 = block unknown unicast, 1 = flood it, 2 = flood unknown group too |
| `LEARNING_EN` | 1 | source-address learning default |
| `STALL_LIMIT` | 0 | cycles a head-of-line frame may wait before being dropped; 0 never drops |
| `CAM_SETS` `CAM_WAYS` | 128, 4 | forwarding table geometry; ageing is off by default |

Per-port parameters are **flat packed vectors** rather than unpacked array
parameters, because unpacked array parameters are not universally supported and
the cost of the packed form is zero. A mis-sized buffer is reported at
elaboration time (in simulation, where a mis-parameterised instance is actually
built) rather than as a mysterious frame loss later.

## The PHY interface

The original `sw_switch` module exposes `gmii_rx_*` and `gmii_tx_*` as GMII-style
8-bit interfaces. `sw_switch_phy` adds a selectable PHY-facing wrapper: each
port chooses `SW_PHY_GMII`, `SW_PHY_MII`, `SW_PHY_RMII`, or `SW_PHY_RGMII` through
`PORT_PHY_IF` (3 bits per port, port p at bits `[3*p +: 3]`). All four
representations are synchronous to the existing `clk_i`; this wrapper
deliberately does not consume raw PHY clocks or infer DDR I/O cells.

* GMII presents one 8-bit sample per octet time.
* MII presents the low nibble, then the high nibble, over two equal windows.
* RMII presents bit pairs `[1:0]`, `[3:2]`, `[5:4]`, then `[7:6]`.
* RGMII is represented by a captured rise/fall nibble pair and a synchronous
  `*_rx_ce_i` / `*_tx_ce_o` event. RX CE marks an active captured byte and need
  not be asserted during idle; RX_CTL low still terminates the frame. The outer
  I/O shell performs the physical DDR capture and launch.

MII and RMII symbol boundaries must be phase-aligned by the synchronous outer
shell to the adapter's derived byte period. The wrapper does not consume an
independent PHY clock or perform CDC.

The encoding is deliberately wider than the four assigned values: `sw_phy_if_e`
is 3 bits, values `4` through `7` are reserved, and an adapter instantiated with
one of them holds every output idle even when its pins are driven. A future MAC
interface (SGMII, XGMII, ...) is therefore added by giving it the next enum
value in `sw_defs.sv` and adding its case arms in `sw_phy_adapter` — no
renumbering of the existing modes and no port-width change anywhere else. The
reserved-encoding idle behaviour is covered by `make phy`.

`PHY_RX_PREAMBLE` selects whether an adapter expects the physical receive stream
as `55 x 7, D5, frame` (1) or the normal MAC-style `frame` stream (0). A PHY
coding error suppresses the damaged frame rather than creating a false boundary.

`gmii_rx_*` and `gmii_tx_*` are GMII-style 8-bit interfaces qualified by a clock
enable and synchronous to `clk_i`:

* one octet every `BYTE_PERIOD` clocks;
* the enable is asserted for the whole octet time and the data is stable for the
  same window;
* the enable is de-asserted for at least one clock during the inter-frame gap.

The preamble and the start-of-frame delimiter are removed by the PHY on receive
and re-inserted on transmit, exactly as a real GMII MAC does. A PHY running on
its own clock needs asynchronous FIFOs around the core; nothing inside changes.

## Building and testing

Requires Icarus Verilog 12+ and Verilator 5.x; `make synth` additionally needs
yosys.

    make lint      # Verilator -Wall; any warning fails the build
    make rtl       # Icarus elaboration of the RTL alone, no testbench
    make unit      # block-level testbenches and the fabric regression (~25 s)
    make param     # the three-port, 50 MHz parameterisation testbench (~4 s)
    make phy       # the synchronous PHY adapter and wrapper tests
    make sim       # the four-port mixed-speed switch testbench (~6 min)
    make synth     # yosys read + elaborate + synthesise (~3 min)

`make all` runs lint, unit, sim, param and phy. The gates are ordered by how fast
they fail, and each one catches something the others do not - see
[AGENTS.md](AGENTS.md#2-the-tool-flow-and-what-each-tool-rejects) for what each
is actually good for.

The regression is deliberately awkward to pass:

* `make sim` runs **four ports at 10 / 100 / 1000 / 1000 Mbit/s from one clock**,
  which is the configuration most likely to expose a clock-enable bug. The 10
  Mbit/s port needs about 10 000 clocks per frame, so every test waits for the
  slowest port. It checks every frame that appears on the wire - destination,
  source, length, preamble and FCS - against a reference model the testbench
  maintains itself, and a 64-bit beat is re-assembled from the octet stream by an
  independent PHY model.
* `make param` re-instantiates the *same* RTL at **3 ports (not a power of two)**
  on a **50 MHz** core, so the derived port widths are 2 bits and the octet
  periods are 40 and 4 clocks - a geometry the main testbench never uses.
* `make unit` runs the fabric regression twice, once with every port at line rate
  and once with one port at 10 Mbit/s. The slow one is the interesting one: it is
  the only configuration in the suite in which an egress buffer has to hold a
  queue while the fabric keeps pushing into it.

## Physical implementation

`librelane/` holds the flow configuration and the timing constraints, and runs
under a pinned LibreLane container against the open-source `sky130A` PDK. See
[`librelane/README.md`](librelane/README.md) for how to run it, what each
configuration value is doing, and the 2.4-to-3.0 migration table.

Two things about it are worth knowing before reading the numbers there. The
physical run elaborates a **reduced** instance of the core, deliberately: the
full-size parameters need a commercial-grade flow and a memory compiler to be
practical, and the reduced instance is what proves the design reads, elaborates,
synthesises and routes end to end on the open-source PDK. And the flow is gated
behind a manual approval in CI, because it is the only job that produces an
artefact someone might act on.

## Working on the design

[`AGENTS.md`](AGENTS.md) is the style and portability contract for this
repository: the tool flow and what each gate catches, the three restrictions the
synthesis frontend imposes, the RTL conventions - width discipline has its own
section, because a silently extended operand is the defect the linter catches
*least* reliably across Verilator versions - the testbench rules, and the order
to run the gates in. Read it before changing anything under `rtl/`.
