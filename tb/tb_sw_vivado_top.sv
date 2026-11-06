// ============================================================================
//  File        : tb_sw_vivado_top.sv
//  Description : Eight-port Vivado board-shell regression using the existing
//                synchronous MII wire models at 50 MHz / 100 Mbit/s.
//
//                Each ingress floods once to seven egresses, then learned
//                stations exchange a ring of directed frames, including 7->0.
//                The models reconstruct TX nibbles and independently check
//                preamble/SFD and FCS; header/length checks catch wrong-port
//                forwarding as well as damaged or missing frames.
//
//                Reset is driven between clock edges to expose an accidental
//                asynchronous path or a missing synchronizer stage. A second
//                reset proves that the highest-numbered port can recover and
//                that learned state is cleared before forwarding resumes.
//
//                Scope: this exercises the sw_mii synchronous frame contract.
//                Reserved PHY clocks are deliberately not phase locked to the
//                core, but no data is sampled using them; this is not a CDC,
//                PHY initialization or physical MII timing test.
// ============================================================================
`timescale 1ns/1ps
module tb_sw_vivado_top;
  import sw_tb_pkg::*;

  // ---- model configuration and clocks --------------------------------------
  // Match the fixed board shell rather than the rtl/ wrapper's four-port
  // default. A BYTE_PERIOD of four gives two core clocks per MII nibble.
  localparam int unsigned NUM_PORTS = 8;
  localparam int unsigned CLK_HZ = 50_000_000;
  localparam int unsigned BP = sw_byte_period(CLK_HZ, SW_SPEED_100M);
  localparam logic [NUM_PORTS-1:0] ALL_PORTS = {NUM_PORTS{1'b1}};
  // Never used as a source, so this address must remain an unknown unicast
  // throughout the first phase even while the station addresses are learned.
  localparam sw_mac_t UNKNOWN_DST = 48'h02_EE_00_00_00_FF;
  logic clk = 1'b0;
  logic rst_button_n = 1'b0;
  logic rx_clk = 1'b0;
  logic tx_clk = 1'b0;
  always #10 clk = ~clk;
  always #20 rx_clk = ~rx_clk;
  always #19 tx_clk = ~tx_clk;

  // ---- board pins and DUT ---------------------------------------------------
  // No pull-ups are modeled on MDIO: observing Z directly detects an FPGA
  // driver left enabled, which an idle-high board pull-up could conceal.
  logic [NUM_PORTS-1:0] rx_dv, rx_er, tx_en, tx_er, phy_reset_n, mdc;
  logic [NUM_PORTS*4-1:0] rxd, txd;
  tri [NUM_PORTS-1:0] mdio;
  sw_vivado_top u_dut (
    .clk_i(clk), .rst_button_ni(rst_button_n),
    .mii_rx_clk_i({NUM_PORTS{rx_clk}}), .mii_tx_clk_i({NUM_PORTS{tx_clk}}),
    .mii_rx_dv_i(rx_dv), .mii_rx_er_i(rx_er), .mii_rxd_i(rxd),
    .mii_tx_en_o(tx_en), .mii_tx_er_o(tx_er), .mii_txd_o(txd),
    .phy_reset_no(phy_reset_n), .phy_mdc_o(mdc), .phy_mdio_io(mdio)
  );

  // ---- one independent wire monitor per port -------------------------------
  // Each model follows its own PHY reset output, so a missing upper reset
  // bit cannot be hidden by resetting every model from the testbench button.
  // Data slicing is constant within each generated instance, matching the
  // board pin convention p -> [4*p +: 4].
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_phy
      sw_mii_if #(.PORT_ID(g), .BYTE_PERIOD(BP)) u_if (
        .clk_i(clk), .rst_ni(phy_reset_n[g]), .enable_i(1'b1),
        .mii_rx_dv(rx_dv[g]), .mii_rx_er(rx_er[g]), .mii_rxd(rxd[g*4 +: 4]),
        .mii_tx_en(tx_en[g]), .mii_txd(txd[g*4 +: 4])
      );
    end
  endgenerate

  // ---- self-checking helpers ------------------------------------------------
  int unsigned errors = 0;
  int unsigned checks = 0;
  // Case inequality intentionally treats an X/Z predicate as a failure;
  // accepting an unknown condition could turn an uninitialized DUT into PASS.
  task automatic check(input logic ok, input string label_text);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("[%0t] FAIL %s", $time, label_text);
    end else $display("[%0t] PASS %s", $time, label_text);
  endtask
  // Locally administered station MACs differ from the switch's own default
  // port MACs. Reusing a port MAC would trigger the ingress reflection filter
  // and make a good forwarding path look broken. p is limited to 0..7.
  function automatic sw_mac_t station(input int unsigned p);
    return 48'h02_AA_00_00_00_00 + 48'(p);
  endfunction
  // ---- constant hierarchical dispatch --------------------------------------
  // Icarus requires constant hierarchical indices for model task calls; a
  // runtime g_phy[p].u_if reference cannot select an elaborated instance.
  // Keep these cases in step with the fixed eight-port DUT and model bank.
  // The send length is destination-MAC through payload, excluding preamble
  // and FCS. The model supplies FCS on RX and consumes the complete TX stream.
  task automatic send_frame(input int unsigned p, input sw_mac_t dst);
    case (p)
      0: g_phy[0].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      1: g_phy[1].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      2: g_phy[2].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      3: g_phy[3].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      4: g_phy[4].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      5: g_phy[5].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      6: g_phy[6].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      7: g_phy[7].u_if.send(dst, station(p), TB_ET_IPV4, 100);
      default: $fatal(1, "invalid sending port %0d", p);
    endcase
  endtask
  // A bounded receive converts a missing frame into a zero-length record,
  // which check_frame rejects instead of leaving the simulation waiting.
  // The 10,000-core-clock limit is 200 us at 50 MHz, allowing store-and-forward
  // latency for these serial 100-byte stimuli without an unbounded queue wait.
  task automatic receive_frame(input int unsigned p, output tb_rec_t rec);
    case (p)
      0: g_phy[0].u_if.pop_frame(rec, 10000);
      1: g_phy[1].u_if.pop_frame(rec, 10000);
      2: g_phy[2].u_if.pop_frame(rec, 10000);
      3: g_phy[3].u_if.pop_frame(rec, 10000);
      4: g_phy[4].u_if.pop_frame(rec, 10000);
      5: g_phy[5].u_if.pop_frame(rec, 10000);
      6: g_phy[6].u_if.pop_frame(rec, 10000);
      7: g_phy[7].u_if.pop_frame(rec, 10000);
      default: $fatal(1, "invalid receiving port %0d", p);
    endcase
  endtask
  // The query helpers use a nonzero invalid-index sentinel: check_queues
  // expects zero, so a dispatch mistake cannot masquerade as an empty queue.
  function automatic int unsigned pending(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.pending();
      1: return g_phy[1].u_if.pending();
      2: return g_phy[2].u_if.pending();
      3: return g_phy[3].u_if.pending();
      4: return g_phy[4].u_if.pending();
      5: return g_phy[5].u_if.pending();
      6: return g_phy[6].u_if.pending();
      7: return g_phy[7].u_if.pending();
      default: return 32'hffff_ffff;
    endcase
  endfunction
  function automatic int unsigned dropped(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.dropped();
      1: return g_phy[1].u_if.dropped();
      2: return g_phy[2].u_if.dropped();
      3: return g_phy[3].u_if.dropped();
      4: return g_phy[4].u_if.dropped();
      5: return g_phy[5].u_if.dropped();
      6: return g_phy[6].u_if.dropped();
      7: return g_phy[7].u_if.dropped();
      default: return 32'hffff_ffff;
    endcase
  endfunction
  function automatic int unsigned short_frames(input int unsigned p);
    case (p)
      0: return g_phy[0].u_if.short_frames();
      1: return g_phy[1].u_if.short_frames();
      2: return g_phy[2].u_if.short_frames();
      3: return g_phy[3].u_if.short_frames();
      4: return g_phy[4].u_if.short_frames();
      5: return g_phy[5].u_if.short_frames();
      6: return g_phy[6].u_if.short_frames();
      7: return g_phy[7].u_if.short_frames();
      default: return 32'hffff_ffff;
    endcase
  endfunction
  // ---- wire verdicts and management defaults -------------------------------
  // CRC and preamble verdicts come from the MII monitor, not DUT statistics.
  // The length below excludes the wire preamble/SFD and FCS; comparing those
  // bytes as part of the length would falsely report every legal frame long.
  task automatic check_frame(input tb_rec_t rec, input sw_mac_t dst,
                             input sw_mac_t src, input int unsigned p);
    check(tb_rec_len(rec) == 100, $sformatf("port %0d frame length", p));
    check(tb_rec_dst(rec) == dst, $sformatf("port %0d destination", p));
    check(tb_rec_src(rec) == src, $sformatf("port %0d source", p));
    check(tb_rec_l2(rec) == TB_ET_IPV4, $sformatf("port %0d EtherType", p));
    check(tb_rec_fcs_ok(rec), $sformatf("port %0d independent FCS", p));
    check(tb_rec_pre_ok(rec), $sformatf("port %0d preamble/SFD", p));
  endtask
  // Whole-vector case equality catches undriven/unknown upper-port bits that
  // checking only a representative low port would miss.
  task automatic check_management;
    check(mdc === '0, "all eight MDC pins idle low");
    check(mdio === {NUM_PORTS{1'bz}}, "all eight MDIO pins high impedance");
  endtask
  // Missing expected frames are caught by receive_frame/check_frame. Queue
  // emptiness additionally catches ingress reflection, duplicate flooding or
  // an unwanted unicast copy; overflow/short counters make monitor loss fatal.
  task automatic check_queues;
    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      check(pending(p) == 0, $sformatf("port %0d no extra/reflected frame", p));
      check(dropped(p) == 0, $sformatf("port %0d no monitor overflow", p));
      check(short_frames(p) == 0, $sformatf("port %0d no short frames", p));
    end
  endtask

  // ---- stimulus and final verdict ------------------------------------------
  tb_rec_t rec;
  int unsigned dst_port;
  initial begin
    // Keep the physical button asserted through synchronizer startup. Sampling
    // after the edge (#1) observes NBA updates without racing the DUT flops.
    repeat (4) @(negedge clk);
    check(phy_reset_n === '0, "all eight PHYs held in reset");
    check_management();
    #3 rst_button_n = 1'b1;
    #1 check(phy_reset_n === '0, "release remains synchronous");
    @(posedge clk); #1;
    check(phy_reset_n === '0, "first release sample remains reset");
    @(posedge clk); #1;
    check(phy_reset_n === ALL_PORTS, "second release sample releases all PHYs");
    repeat (4) @(negedge clk);
    // ---- 1. all-ingress unknown-unicast flooding ---------------------------
    // Every ingress sends once; all seven eligible egresses must receive.
    // This also learns all station addresses for the next phase. Drain each
    // fan-out before the next send so no copy can satisfy a later frame check.
    for (int unsigned src = 0; src < NUM_PORTS; src++) begin
      send_frame(src, UNKNOWN_DST);
      for (int unsigned dst = 0; dst < NUM_PORTS; dst++) begin
        if (dst != src) begin
          receive_frame(dst, rec);
          check_frame(rec, UNKNOWN_DST, station(src), dst);
        end
      end
      check_queues();
    end
    // ---- 2. learned unicast over every port boundary -----------------------
    // Known unicast must reach only the next port, including port 7 -> 0.
    // The explicit last-port branch exercises wraparound without relying on
    // overflow of an index that might later have a different width.
    for (int unsigned src = 0; src < NUM_PORTS; src++) begin
      dst_port = (src == NUM_PORTS - 1) ? 0 : src + 32'(1);
      send_frame(src, station(dst_port));
      receive_frame(dst_port, rec);
      check_frame(rec, station(dst_port), station(src), dst_port);
      check_queues();
    end
    // This one internal observation confirms CAM hits; received-frame
    // correctness remains based on wire records. No statistics pins are added
    // to the physical top merely to make the regression observable.
    check(u_dut.stat[32*SW_STAT_CAM_HIT +: 32] == NUM_PORTS,
          "all eight directed frames hit learned entries");
    check(tx_er === '0, "all eight TX error outputs inactive");
    // ---- 3. reset during an established forwarding configuration ----------
    // Reset after traffic and prove the highest ingress still works afterward.
    // The destination was learned earlier; after reset it must flood to all
    // seven other ports, exposing a stale CAM as well as broken upper wiring.
    @(negedge clk); #3 rst_button_n = 1'b0;
    #1 check(phy_reset_n === ALL_PORTS, "press remains synchronous");
    @(posedge clk); #1;
    check(phy_reset_n === ALL_PORTS, "first press sample remains released");
    @(posedge clk); #1;
    check(phy_reset_n === '0, "second press sample resets all PHYs");
    repeat (4) @(negedge clk);
    check(tx_en === '0, "all eight TX enables inactive in reset");
    rst_button_n = 1'b1;
    repeat (4) @(negedge clk);
    send_frame(NUM_PORTS - 1, station(0));
    for (int unsigned dst = 0; dst < NUM_PORTS - 1; dst++) begin
      receive_frame(dst, rec);
      check_frame(rec, station(0), station(NUM_PORTS - 1), dst);
    end
    check_queues();
    check_management();
    // Keep both a printed error count and a nonzero process exit on failure:
    // make/CI must fail even when nobody reads the waveform or full log.
    $display("tb_sw_vivado_top: checks=%0d errors=%0d", checks, errors);
    if (errors != 0) $fatal(1, "tb_sw_vivado_top FAILED");
    $display("tb_sw_vivado_top PASSED");
    $finish;
  end
  // Independent watchdog catches a stopped clock or a blocking model task;
  // per-receive timeouts alone cannot protect a task stuck before reception.
  // The 1 ns time unit makes this a 20 ms limit, beyond normal test duration.
  initial begin
    #20_000_000;
    $fatal(1, "tb_sw_vivado_top timeout");
  end
endmodule
