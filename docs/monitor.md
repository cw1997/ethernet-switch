# Switch telemetry ABI v1

The core and GMII/MII/RMII wrappers expose `phy_status_i`, `mon_req_i`,
`mon_addr_i`, `mon_ready_o`, `mon_valid_o`, and `mon_data_o`. These ports use
`clk_i` and synchronous active-low `rst_ni`. Existing `stat_o` retains its
original 32-bit scheduler-admission semantics. Named constants are in
`rtl/sw_defs.sv`. Integrations must connect all new inputs, using zero PHY
metadata when a PHY manager is absent and zero requests when unused.

## Sampling and meaning

`NUM_PORTS`, `CLK_FREQ_HZ`, and `REFRESH_INTERVAL_MS` configure telemetry;
refresh defaults to 500 ms and must be positive. The window is
`ceil(CLK_FREQ_HZ * REFRESH_INTERVAL_MS / 1000)` clocks. A single serial
multiplier/divider computes rates and publishes the entire snapshot together.
Publication follows capture by approximately `(6*NUM_PORTS+1)*196` clocks.
If an interval shorter than computation time is requested, the next capture
waits for the calculator; the exported actual window always governs rates.
No request, display, UART, or management handshake can stall forwarding.

RX counts accepted frames and their MAC-client bytes. TX counts frame completion
at the end of the last FCS octet window, with transmitted padding included in
MAC-client byte count; administratively disabled egress completions are excluded.
Neither includes preamble, FCS, or IFG bytes. A completed frame means that the MAC
finished serializing it, not that the remote peer acknowledged receipt. A frame
interrupted by physical link loss is not guaranteed to arrive. Per-port ingress
stall drops are attributed to the source port. Other error counters retain the
events and priority of the existing parser; error categories should not be
summed as an independent all-wire packet counter.

Each 32-bit source counter is extended into 64 bits every clock, preserving
wraps even during long sampling windows. All displayed rates are floor-rounded
per-second values: frames * clock_hz / window_clocks and bytes * 8 * clock_hz /
window_clocks. Load is effective frame bit/s divided by link capacity, in per
mille, separately for full-duplex RX/TX. Unknown/down PHY status has unavailable
capacity and reports zero load; consult the validity/link bits before interpreting
zero. Queue occupancy/peaks are 64-bit payload beats, not packet counts; they do
not include the currently serialized beat or descriptor slots. Fabric busy is
the fraction of clocks admitting or transferring a frame. Uptime is 64-bit seconds.

## CSR protocol

Addresses are byte addresses, little-word-first for 64-bit values. Assert a
request with an address and accept it on a rising edge with `mon_ready_o=1`.
A response is identified by `mon_valid_o=1`; data is meaningful only then.
The read-only interface is ordered; simple clients issue one outstanding read.
Ordinary reads respond in one clock. MAC reads can take additional clocks;
requests must respect ready. Unmapped/misaligned reads return zero.

Read system word 49 (sequence), then desired fields, then sequence again.
Retry if the sequence changed. System word 50 remains zero until a full window
and its calculations are complete. The board scanner checks the sequence before
and after its entire read and only then replaces the display cache. Console
commands copy that cache so slow UART or CTS pauses cannot mix windows.
MAC reads release the bus between entries and during UART output, so a paused
console does not freeze the display cache.

The system record begins at 0. Per-port record p begins at
`SW_MON_PORT_BASE + p*256` (`SW_MON_PORT_BASE=0x10000000`). Records contain 64
32-bit words. Below, numbers are word indices, multiplied by four for addresses.

- Port 0: PHY status byte. Bits 0 valid, 1 link, 2 full duplex, 4:3 speed
  (0=10M, 1=100M, 2=1000M, 3=reserved), 5 management error; 7:6 reserved zero.
  System 0 is ready; system 1 is number of ports.
- Port 1/2: current RX/TX payload queue occupancy; 3/4: RX/TX window peaks.
- Port 5/6: RX/TX load per mille. System words 2..7 are reserved.
- Words 8..35: fourteen 64-bit counter pairs in original `SW_STAT_*` order.
  In this ABI the TX frame/octet pairs are completions, not admission counts.
  Pairs 10..13 (CAM IDs) are reserved zero; use the existing global `stat_o` for
  legacy CAM hit/miss/learn, and system 51/53 for occupancy and cumulative flush.
- Words 36/38/40/42: 64-bit RX pps, TX pps, RX bit/s, TX bit/s.
- System 44/45: uptime seconds; 46/47: actual sample window clocks;
  48: configured refresh ms; 49: snapshot sequence; 50: sample valid;
  51: live CAM entries at capture; 52: CAM capacity;
  53: cumulative flush requests; 54: fabric busy per mille;
  55: CAM ageing enabled; 56/57: capture clock timestamp; 58: ABI version.
- System counter/rate pairs are sums across ports. Traffic crossing ingress and
  egress is counted separately in those directions, not deduplicated.
- System byte address 0xf0 is a **live** timestamp-low read which also captures
  timestamp-high and flush generation. Read 0xf4 and 0xf8 afterward to retrieve
  that same timestamp's high word and flush generation. These three words are
  independent of the periodic snapshot and are excluded from its atomicity claim.

## MAC enumeration

Read entry i at `SW_MON_MAC_BASE+i*16` (`SW_MON_MAC_BASE=0x20000000`), in word
order 0,1,2,3. Word 0 is MAC[31:0], word 1 is zero-extended MAC[47:32], word 2 is
port index, word 3 is valid (0/1). Word 0 captures the entire entry; the remaining
words retain that captured value even if learning replaces or flushes it.
Out-of-range entries are invalid. Entries are exposed by a separate reader;
learning, ageing and packet lookup have no read arbitration with management.

A traversal is a live view, not an atomic table dump. MACs may move or expire
during traversal. The console reports live start/end clock timestamps and flush
generations; unequal flush generations mean the table was cleared during the
scan. MACs are learned addresses still in the table, not an online-device list.
Ageing remains disabled by default; enabling it uses the existing CAM parameters.

## Console

The board shell and `sw_console` accept compile-time parameters:
`UART_BAUD_RATE=115200`, `UART_DATA_BITS=8`, `UART_PARITY=SW_UART_PARITY_NONE`,
`UART_STOP_BITS=1`, `UART_FLOW_CONTROL=SW_UART_FLOW_NONE`.

`sw_uart` supports 5..8 bits, None/Odd/Even parity, 1/2 stop bits, and None or
RTS/CTS. The ASCII console requires 7/8 bits. Unsupported values fail elaboration;
the rounded integer baud period must be at least four clocks and within 2 percent
of the requested rate. RTS/CTS are active-low permissions. CTS is checked between
characters, never within a character; RTS is deasserted during command processing.
None ignores CTS and holds RTS asserted. No XON/XOFF is implemented.

Commands are lowercase ASCII terminated with CR, LF, or CRLF:

```text
help
status
port 0
mac all
mac 0
```

`status` includes aggregate and all ports. The `page_0_all_else_port+1` header
identifies records: 0=aggregate, 1=port0, and so on. `port n` uses a zero-based
decimal port number. Values are named, **hexadecimal** unsigned integers with
`0x` prefixes; `_pps`, `_bit_per_second`, `_permille`, and `_octets` specify units.
Parity/framing/overflow, busy-input and long-line diagnostics are separately
counted. At most one command is processed at a time. Lines longer than 32 bytes
are drained to their terminator and rejected. Busy input is discarded with a
subsequent error response. Hardware-flow-control peers must respect RTS.

## Verification

`make monitor` tests sampling arithmetic, 32-bit wrap extension, reset, MAC word
coherence, non-integral windows, UART framing/error/flow modes, page wrap for
1/2/3/5 ports, HEX scaling, and a wire-level LCD and 88E1111 model. It also tests
the real UART console, CSR cache arbitration, MAC filtering and busy/invalid input.
`make unit` includes this target. Flood regressions compare every output clock
between active-query and quiet-query instances, including a congested slow port.
Run all repository gates and FPGA placement/timing before asserting physical
clock closure. Simulation equivalence alone does not establish FPGA Fmax.

Local validation on 2026-11-05 used Icarus 12.0, Verilator 5.032 and Yosys 0.52.
The toolchain contract, lint, RTL elaboration, unit, parameter, MII, RMII and main
regressions passed. All four top modules completed full flattened Yosys synthesis
and its final structural check reported zero problems. After the board-only
changes, its final flow was rerun with `make synth-board`; `make synth` still
selects all four complete flows, without success caches or relaxed checks.

The 158-check main regression has the same fifteen timestamped phase boundaries
and finish time as the archived HEAD baseline. Additional coverage includes
14 rejected parameter configurations, a six-entry CAM geometry, six UART modes
(including actual 50 MHz / 115200 / 8N1), 17 end-to-end console checks, and CTS
pauses during which the display cache continues to refresh.

Default-parameter generic Yosys cell counts, before/after this change:

- GMII: 664,422 / 793,320 (+19.4%).
- MII: 664,591 / 793,511 (+19.4%).
- RMII: 664,652 / 793,575 (+19.4%).
- DE2-115: 367,135 / 596,310 (+62.4%), including the new board peripherals.

These are generic logic cells, not FPGA LUTs or measured frequency. The board
flow retains Yosys's two expected warnings about native MDIO tri-state pins.
Quartus II 13.1 rejected the local Remote Desktop license before synthesis
(error 292032). FPGA fitting, resource utilization and timing, actual peripheral
IO timing, GDS timing and board operation remain unverified for this revision.
