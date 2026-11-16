// ============================================================================
//  File        : sw_fabric_tb.sv
//  Description : End-to-end regression for the staged switch fabric (S1 through S5).
//
//                Drives the 8-bit byte-stream contract directly, without the
//                MAC pin adapters, so a failure can only come from the
//                pipeline itself.  Each egress has an independent wire model
//                that reconstructs frame length, a byte checksum and the two
//                MAC addresses - enough to catch a dropped, duplicated,
//                misrouted or corrupted frame without any unpacked-array or
//                run-time-indexed storage in the testbench.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"

module sw_fabric_mon (
  input  var logic        clk_i,
  input  var logic        rst_ni,
  input  var logic        valid_i,
  input  var logic        ready_i,
  input  var logic        sof_i,
  input  var logic        eof_i,
  input  var logic [7:0]  data_i,
  input  var logic        clear_i,
  output logic     [11:0] len_o,
  output logic     [7:0]  sum_o,
  output logic     [47:0] dst_o,
  output logic     [47:0] src_o,
  output logic     [3:0]  cnt_o
);
  logic [11:0] idx;
  logic [11:0] len_r;
  logic [7:0]  sum_r;
  logic [47:0] dst_r;
  logic [47:0] src_r;
  logic [3:0]  cnt_r;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      idx   <= '0;
      len_r <= '0;
      sum_r <= '0;
      dst_r <= '0;
      src_r <= '0;
      cnt_r <= '0;
    end else if (valid_i && ready_i) begin
      if (sof_i) begin
        idx   <= '0;
        sum_r <= '0;
        dst_r <= '0;
        src_r <= '0;
      end
      sum_r <= sum_r + data_i;
      if (idx < 12'd6)      dst_r <= {dst_r[39:0], data_i};
      else if (idx < 12'd12) src_r <= {src_r[39:0], data_i};
      idx <= idx + 12'd1;
      if (eof_i) begin
        len_r <= idx + 12'd1;
        cnt_r <= cnt_r + 4'd1;
      end
    end
  end

  assign len_o = len_r;
  assign sum_o = sum_r;
  assign dst_o = dst_r;
  assign src_o = src_r;
  assign cnt_o = cnt_r;
endmodule : sw_fabric_mon

module sw_fabric_tb;

  localparam int unsigned NUM_PORTS = 4;
  localparam int unsigned MAXF      = 1518;
  localparam int unsigned NW        = NUM_PORTS*8;

  logic clk;
  logic rst_n;
  logic clear;

  logic [NUM_PORTS-1:0]   rx_valid;
  logic [NUM_PORTS-1:0]   rx_ready;
  logic [NUM_PORTS*8-1:0] rx_data;
  logic [NUM_PORTS-1:0]   rx_sof;
  logic [NUM_PORTS-1:0]   rx_eof;
  logic [NUM_PORTS-1:0]   rx_err;
  logic [NUM_PORTS-1:0]   link_up;
  logic [NUM_PORTS*32-1:0] rx_fcs;

  logic [NUM_PORTS-1:0]   tx_valid;
  logic [NUM_PORTS-1:0]   tx_ready;
  logic [NUM_PORTS*8-1:0] tx_data;
  logic [NUM_PORTS-1:0]   tx_sof;
  logic [NUM_PORTS-1:0]   tx_eof;

  logic [NUM_PORTS*12-1:0] mon_len;
  logic [NUM_PORTS*8-1:0]  mon_sum;
  logic [NUM_PORTS*48-1:0] mon_dst;
  logic [NUM_PORTS*48-1:0] mon_src;
  logic [NUM_PORTS*4-1:0]  mon_cnt;

  initial begin : clk_gen
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  es_switch_fabric #(
    .NUM_PORTS      (NUM_PORTS),
    .MIN_FRAME_LEN  (60),
    .MAX_FRAME_LEN  (1518),
    .SLOTS          (2),
    .SLOT_BYTES     (2048),
    .DESC_DEPTH     (8),
    .TX_QUEUE_DEPTH (256),
    .CAM_SETS       (16),
    .CAM_WAYS       (2),
    .LEARNING_EN    (1),
    .FLOOD_MODE     (2'd1)
  ) u_dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .link_up_i  (link_up),
    .rx_valid_i (rx_valid),
    .rx_ready_o (rx_ready),
    .rx_data_i  (rx_data),
    .rx_sof_i   (rx_sof),
    .rx_eof_i   (rx_eof),
    .rx_err_i   (rx_err),
    .rx_fcs_i   (rx_fcs),
    .tx_valid_o (tx_valid),
    .tx_ready_i (tx_ready),
    .tx_data_o  (tx_data),
    .tx_sof_o   (tx_sof),
    .tx_eof_o   (tx_eof)
  );

  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_mon
      sw_fabric_mon u_mon (
        .clk_i   (clk),
        .rst_ni  (rst_n),
        .valid_i (tx_valid[g]),
        .ready_i (tx_ready[g]),
        .sof_i   (tx_sof[g]),
        .eof_i   (tx_eof[g]),
        .data_i  (tx_data[g*8 +: 8]),
        .clear_i (clear),
        .len_o   (mon_len[g*12 +: 12]),
        .sum_o   (mon_sum[g*8 +: 8]),
        .dst_o   (mon_dst[g*48 +: 48]),
        .src_o   (mon_src[g*48 +: 48]),
        .cnt_o   (mon_cnt[g*4 +: 4])
      );
    end
  endgenerate

  int unsigned checks;
  int unsigned errors;

  task automatic check(input bit ok, input string label);
    checks = checks + 1;
    $display("[%0t] %s %s", $time, ok ? "PASS" : "FAIL", label);
    if (!ok) errors = errors + 1;
  endtask

  function automatic logic [MAXF*8-1:0] mk_frame(
      input logic [47:0] dst, input logic [47:0] src,
      input int unsigned len);
    logic [MAXF*8-1:0] img;
    int unsigned i;
    img = '0;
    for (i = 0; i < 6; i++) img[i*8 +: 8] = dst[47-8*i -: 8];
    for (i = 0; i < 6; i++) img[(6+i)*8 +: 8] = src[47-8*i -: 8];
    img[12*8 +: 8] = 8'h08;
    img[13*8 +: 8] = 8'h00;
    for (i = 14; i < len; i++) img[i*8 +: 8] = 8'(i);
    mk_frame = img;
  endfunction

  function automatic logic [7:0] frame_sum(input logic [MAXF*8-1:0] img,
                                           input int unsigned len);
    logic [7:0] s;
    int unsigned i;
    s = 8'd0;
    for (i = 0; i < len; i++) s = s + img[i*8 +: 8];
    frame_sum = s;
  endfunction

  // Independent reflected CRC from the testbench wire model.
  function automatic logic [31:0] frame_fcs(input logic [MAXF*8-1:0] img,
                                             input int unsigned len);
    logic [31:0] crc;
    crc = '1;
    for (int unsigned i = 0; i < len; i++)
      crc = sw_tb_pkg::tb_crc32_octet(crc, img[i*8 +: 8]);
    return ~crc;
  endfunction

  // The two source lanes may drive simultaneously. The CRC sideband is
  // computed from each frame independently, including any pad bytes.
  task automatic drive_frames(
      input int unsigned port, input logic [MAXF*8-1:0] first_image,
      input int unsigned len, input bit error_last, input bit bad_fcs,
      input bit paired, input logic [MAXF*8-1:0] second_image);
    logic [NUM_PORTS-1:0] active_ports;
    active_ports = NUM_PORTS'(1) << port;
    if (paired) active_ports[1] = 1'b1;
    rx_fcs = (NUM_PORTS*32)'(frame_fcs(first_image, len) ^ 32'(bad_fcs)) << (port*32);
    if (paired) rx_fcs[32 +: 32] = frame_fcs(second_image, len);
    for (int unsigned i = 0; i < len; i++) begin
      @(negedge clk);
      if (i == 0) check((rx_ready & active_ports) == active_ports, "SOF reservation");
      rx_valid = active_ports;
      rx_data  = NW'(first_image[i*8 +: 8]) << (port*8);
      if (paired) rx_data[8 +: 8] = second_image[i*8 +: 8];
      rx_sof = (i == 0) ? active_ports : '0;
      rx_eof = (i == len-1) ? active_ports : '0;
      rx_err = (error_last && (i == len-1)) ? active_ports : '0;
    end
    @(posedge clk); #1;
    rx_valid = '0; rx_sof = '0; rx_eof = '0; rx_err = '0; rx_data = '0;
  endtask

  task automatic send_frame(input int unsigned port,
                            input logic [47:0] dst, input logic [47:0] src,
                            input int unsigned len, input bit err_last);
    drive_frames(port, mk_frame(dst, src, len), len, err_last, 0, 0, '0);
  endtask

  // Observe each beat after the first SOF. A bubble, interleaved frame, or
  // missing byte fails at its position even if the final byte sum matches.
  task automatic expect_stream(
      input int unsigned port, input logic [MAXF*8-1:0] first_image,
      input logic [MAXF*8-1:0] second_image, input int unsigned len,
      output bit chose_first, output time started);
    logic [MAXF*8-1:0] got;
    bit exact;
    do @(posedge clk); while (!tx_valid[port] || !tx_ready[port]);
    started = $time;
    exact = 1;
    got = '0;
    for (int unsigned i = 0; i < len; i++) begin
      if (i != 0) @(posedge clk);
      exact &= tx_valid[port] && tx_ready[port] &&
               (tx_sof[port] == (i == 0)) && (tx_eof[port] == (i == len-1));
      got[i*8 +: 8] = tx_data[port*8 +: 8];
    end
    chose_first = (got === first_image);
    check(exact && (chose_first || (got === second_image)),
          $sformatf("port %0d contiguous byte-exact frame", port));
  endtask

  task automatic idle(input int unsigned n);
    int unsigned i;
    rx_valid = '0; rx_sof = '0; rx_eof = '0; rx_err = '0; rx_data = '0;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  task automatic clear_monitors();
    clear = 1'b1;
    @(posedge clk);
    #1;
    clear = 1'b0;
  endtask

  task automatic expect_on(input int unsigned port, input int unsigned cnt,
                           input logic [47:0] dst, input logic [47:0] src,
                           input int unsigned len, input string label);
    logic [7:0] want_sum;
    want_sum = frame_sum(mk_frame(dst, src, len), len);
    check(mon_cnt[port*4 +: 4] == 4'(cnt), {label, ": frame count"});
    if (cnt != 0) begin
      check(mon_len[port*12 +: 12] == 12'(len), {label, ": length"});
      check(mon_sum[port*8 +: 8] == want_sum,  {label, ": payload"});
      check(mon_dst[port*48 +: 48] == dst,     {label, ": dst MAC"});
      check(mon_src[port*48 +: 48] == src,     {label, ": src MAC"});
    end
  endtask

  logic [47:0] host_a;
  logic [47:0] host_b;
  logic [47:0] host_c;
  logic [47:0] bcast;

  initial begin : main_proc
    checks = 0;
    errors = 0;
    host_a = 48'h02_aa_00_00_00_01;
    host_b = 48'h02_bb_00_00_00_02;
    host_c = 48'h02_cc_00_00_00_03;
    bcast  = SW_MAC_BROADCAST;

    rst_n    = 1'b0;
    clear    = 1'b0;
    link_up  = '1;
    tx_ready = '1;
    rx_valid = '0; rx_data = '0; rx_sof = '0; rx_eof = '0; rx_err = '0;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    idle(4);
    clear_monitors();

    // ---- 1. broadcast floods to every other port, never the source -------
    send_frame(0, bcast, host_a, 64, 0);
    idle(160);
    expect_on(0, 0, bcast, host_a, 64, "bcast src port 0");
    expect_on(1, 1, bcast, host_a, 64, "bcast port 1");
    expect_on(2, 1, bcast, host_a, 64, "bcast port 2");
    expect_on(3, 1, bcast, host_a, 64, "bcast port 3");
    clear_monitors();

    // ---- 2. learning: HOST_B on port 2, then a known unicast ------------
    send_frame(2, bcast, host_b, 64, 0);
    idle(160);
    clear_monitors();
    send_frame(0, host_b, host_a, 64, 0);
    idle(160);
    expect_on(0, 0, host_b, host_a, 64, "known unicast filtered at src");
    expect_on(1, 0, host_b, host_a, 64, "known unicast not on port 1");
    expect_on(2, 1, host_b, host_a, 64, "known unicast reaches port 2");
    expect_on(3, 0, host_b, host_a, 64, "known unicast not on port 3");
    clear_monitors();

    // ---- 3. unknown unicast floods ---------------------------------------
    send_frame(1, host_c, host_a, 64, 0);
    idle(160);
    expect_on(0, 1, host_c, host_a, 64, "unknown unicast port 0");
    expect_on(1, 0, host_c, host_a, 64, "unknown unicast src port 1");
    expect_on(2, 1, host_c, host_a, 64, "unknown unicast port 2");
    expect_on(3, 1, host_c, host_a, 64, "unknown unicast port 3");
    clear_monitors();

    // ---- 4. a corrupt frame is dropped everywhere ------------------------
    send_frame(0, bcast, host_a, 64, 1);
    idle(160);
    expect_on(0, 0, bcast, host_a, 64, "bad FCS src");
    expect_on(1, 0, bcast, host_a, 64, "bad FCS port 1");
    expect_on(2, 0, bcast, host_a, 64, "bad FCS port 2");
    expect_on(3, 0, bcast, host_a, 64, "bad FCS port 3");
    clear_monitors();

    // ---- 5. MAC relocation -----------------------------------------------
    // Test 3 re-learned HOST_A on port 1 (every legal frame learns its source),
    // so a frame addressed to HOST_A must now go to port 1, not port 0.
    send_frame(0, host_a, host_b, 64, 0);
    idle(160);
    expect_on(0, 0, host_a, host_b, 64, "moved unicast filtered at src");
    expect_on(1, 1, host_a, host_b, 64, "moved unicast reaches new port 1");
    expect_on(2, 0, host_a, host_b, 64, "moved unicast not on port 2");
    expect_on(3, 0, host_a, host_b, 64, "moved unicast not on port 3");
    clear_monitors();

    // ---- 6. source-port filter: destination learned on the ingress port ---
    send_frame(3, bcast, host_c, 64, 0);
    idle(160);
    clear_monitors();
    send_frame(3, host_c, host_a, 64, 0);
    idle(160);
    expect_on(0, 0, host_c, host_a, 64, "self-dest filtered port 0");
    expect_on(1, 0, host_c, host_a, 64, "self-dest filtered port 1");
    expect_on(2, 0, host_c, host_a, 64, "self-dest filtered port 2");
    expect_on(3, 0, host_c, host_a, 64, "self-dest filtered at src");

    // 7. Header rejection and CRC are independent. A later probe to the
    // rejected source must flood, proving that neither failure learned it.
    for (int rule = 0; rule < 10; rule++) begin
      logic [MAXF*8-1:0] image;
      logic [47:0] rejected_src;
      int unsigned len;
      rejected_src = 48'h02_77_12_34_56_00 | 48'(rule);
      if (rule == 7) rejected_src = 48'h01_77_12_34_56_00;
      if (rule == 8) rejected_src = 48'h02_00_00_00_00_00;
      len = (rule == 0) ? 59 : 60;
      image = mk_frame(bcast, rejected_src, len);
      case (rule)
        1: image = mk_frame(rejected_src, rejected_src, len);
        2: image = mk_frame('0, rejected_src, len);
        3: image = mk_frame(bcast, '0, len);
        4: image[12*8 +: 16] = 16'hdd05; // 1501 in wire order
        5: image[12*8 +: 16] = 16'h2f00; // 47 data octets need 61 bytes
        9: image = mk_frame(48'h02_00_00_00_00_00, rejected_src, len);
        default: ;
      endcase
      clear_monitors();
      drive_frames(0, image, len, 0, rule == 6, 0, '0);
      idle(160);
      check(mon_cnt == '0, $sformatf("invalid frame rule %0d is dropped", rule));
      if ((rule != 3) && (rule != 7)) begin
        send_frame(1, rejected_src, host_b, 64, 0);
        idle(160);
        expect_on(2, 1, rejected_src, host_b, 64, "invalid source was never learned");
      end
    end

    begin : frame_formats
      logic [MAXF*8-1:0] padded, exact_length;
      bit match_first;
      time started;
      padded = mk_frame(bcast, host_a, 60);
      padded[12*8 +: 16] = 16'h1400; // 20 octets followed by pad
      exact_length = mk_frame(bcast, host_a, 61);
      exact_length[12*8 +: 16] = 16'h2f00;
      fork
        drive_frames(0, padded, 60, 0, 0, 0, '0);
        expect_stream(1, padded, padded, 60, match_first, started);
      join
      idle(10);
      fork
        drive_frames(0, exact_length, 61, 0, 0, 0, '0);
        expect_stream(1, exact_length, exact_length, 61, match_first, started);
      join
    end

    // Both senders target the same learned port for several rounds. Each
    // round must complete one frame per source, even if frame order rotates.
    begin : same_destination
      logic [47:0] receiver;
      logic [MAXF*8-1:0] image_a, image_b;
      bit first, second;
      time started;
      receiver = 48'h02_88_44_55_66_77;
      idle(10);
      send_frame(3, bcast, receiver, 64, 0);
      idle(180);
      image_a = mk_frame(receiver, host_a, 64);
      image_b = mk_frame(receiver, host_b, 64);
      repeat (4) begin
        fork
          drive_frames(0, image_a, 64, 0, 0, 1, image_b);
          begin
            expect_stream(3, image_a, image_b, 64, first, started);
            expect_stream(3, image_a, image_b, 64, second, started);
            check(first != second, "contending lanes each forward one whole frame");
          end
        join
      end
    end

    // Keep the first winner's lane backlogged while the other lane
    // waits. A lowest-port-priority frame arbiter would send a short
    // frame ahead of the second long one.
    begin : round_robin_priority
      logic [47:0] receiver;
      logic [MAXF*8-1:0] long_a, long_b, short_a, short_b;
      bit first, second;
      time started;
      receiver = 48'h02_88_44_55_66_77;
      long_a = mk_frame(receiver, host_a, 256);
      long_b = mk_frame(receiver, host_b, 256);
      short_a = mk_frame(receiver, host_a, 64);
      short_b = mk_frame(receiver, host_b, 64);
      fork
        begin
          drive_frames(0, long_a, 256, 0, 0, 1, long_b);
          repeat (2) drive_frames(0, short_a, 64, 0, 0, 1, short_b);
        end
        begin
          expect_stream(3, long_a, long_b, 256, first, started);
          expect_stream(3, long_a, long_b, 256, second, started);
          check(first != second, "round robin serves the competing long frame before queued short frames");
          repeat (2) begin
            expect_stream(3, short_a, short_b, 64, first, started);
            expect_stream(3, short_a, short_b, 64, second, started);
            check(first != second, "backlogged lanes alternate whole-frame grants");
          end
        end
      join
    end

    begin : disjoint_destinations
      logic [47:0] receiver;
      logic [MAXF*8-1:0] image_a, image_b;
      bit first, second;
      time started_a, started_b;
      receiver = 48'h02_99_44_55_66_77;
      send_frame(2, bcast, receiver, 64, 0);
      idle(180);
      image_a = mk_frame(receiver, host_a, 64);
      image_b = mk_frame(48'h02_88_44_55_66_77, host_b, 64);
      fork
        drive_frames(0, image_a, 64, 0, 0, 1, image_b);
        expect_stream(2, image_a, image_a, 64, first, started_a);
        expect_stream(3, image_b, image_b, 64, second, started_b);
      join
      check(started_a == started_b, "disjoint destinations forward in parallel");
    end

    // A paused egress fills its two-frame capacity. Two broadcasts can
    // already transmit anywhere else, and the third resumes when credit
    // returns. None may stall between its own SOF and EOF.
    begin : slow_destination
      logic [MAXF*8-1:0] image;
      bit matched;
      time started;
      image = mk_frame(bcast, host_a, MAXF);
      @(negedge clk); tx_ready[2] = 0;
      fork
        begin
          repeat (3) begin
            drive_frames(0, image, MAXF, 0, 0, 0, '0);
            idle(16);
          end
        end
        begin
          repeat (2) expect_stream(1, image, image, MAXF, matched, started);
          repeat (64) @(negedge clk);
          check(!tx_valid[1], "third broadcast waits for paused destination credit");
          @(negedge clk); tx_ready[2] = 1;
          expect_stream(1, image, image, MAXF, matched, started);
        end
      join
      idle(2*MAXF);
    end

    if (errors == 0) $display("sw_fabric_tb: PASSED (%0d checks)", checks);
    else             $display("sw_fabric_tb: FAILED (%0d of %0d checks)", errors, checks);
    if (errors != 0) $fatal(1, "sw_fabric_tb: FAILED");
    $finish;
  end

  initial begin : watchdog
    #2000000;
    $fatal(1, "sw_fabric_tb: timeout");
  end

endmodule : sw_fabric_tb
