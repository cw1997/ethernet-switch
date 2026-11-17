// ============================================================================
//  File        : es_mixed_gmii_check.sv
//  Description : Auxiliary mixed-frame checker reused by the GMII system
//                regression.  Verifies per-port frame classification against
//                an independent expectation without sharing the DUT's logic.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "es_tb_pkg.sv"

module es_mixed_gmii_check
  import es_tb_pkg::*;
(
  input var logic clk_i, rst_ni,
  output logic done_o = 0
);
  localparam int unsigned CLIENT = 128;
  localparam int unsigned N = 3;
  logic [N-1:0] rx_en = '0, tx_en;
  logic [N*8-1:0] rx_d = '0, tx_d;
  time fast_second_done = 0, slow_first_done = 0;

  // Unpacked-array adapter for the GMII top's pad ports; genvar indices keep
  // every element access constant and Icarus-safe.
  logic       link_up_a[N];
  logic       rx_en_a[N];
  logic [7:0] rx_d_a[N];
  wire        tx_en_a[N];
  wire  [7:0] tx_d_a[N];

  genvar ga;
  generate
    for (ga = 0; ga < N; ga++) begin : g_port_adapt
      assign link_up_a[ga]     = 1'b1;
      assign rx_en_a[ga]       = rx_en[ga];
      assign rx_d_a[ga]        = rx_d[ga*8 +: 8];
      assign tx_en[ga]         = tx_en_a[ga];
      assign tx_d[ga*8 +: 8]   = tx_d_a[ga];
    end
  endgenerate

  es_gmii_top #(
    .NUM_PORTS      (N),
    .PORT_SPEED     ({2'd1, 2'd2, 2'd2}),
    .MAX_FRAME_LEN  (CLIENT),
    .SLOT_BYTES     (256),
    .TX_QUEUE_DEPTH (2),
    .CAM_SETS       (16),
    .CAM_WAYS       (2)
  ) dut (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .link_up_i      (link_up_a),
    .gmii_rx_en_i   (rx_en_a),
    .gmii_rx_data_i (rx_d_a),
    .gmii_tx_en_o   (tx_en_a),
    .gmii_tx_data_o (tx_d_a)
  );

  function automatic tb_frame_buf_t wire_image(input int unsigned seq);
    return tb_build_frame(48'hffff_ffff_ffff, 48'h0211_2233_4400 | 48'(seq),
                          TB_ET_IPV4, CLIENT, 0, 0);
  endfunction

  task automatic check_lane(input int unsigned port_id, input int unsigned period);
    tb_frame_buf_t expected;
    bit exact;
    for (int unsigned seq = 0; seq < 3; seq++) begin
      expected = wire_image(seq);
      do @(negedge clk_i); while (!tx_en[port_id]);
      exact = 1;
      for (int unsigned octet = 0; octet < tb_frame_octets(CLIENT, 0); octet++)
        for (int unsigned beat = 0; beat < period; beat++) begin
          if (octet != 0 || beat != 0) @(negedge clk_i);
          exact &= tx_en[port_id] && tx_d[port_id*8 +: 8] == tb_get_octet(expected, octet);
        end
      if (port_id == 1 && seq == 1) fast_second_done = $time;
      if (port_id == 2 && seq == 0) slow_first_done = $time;
      @(negedge clk_i);
      if (exact !== 1'b1 || tx_en[port_id] !== 1'b0)
        $fatal(1, "FAIL mixed-speed GMII port %0d frame %0d", port_id, seq);
      $display("PASS mixed-speed GMII port %0d frame %0d", port_id, seq);
    end
  endtask

  initial begin
    wait (rst_ni);
    fork
      begin : drive
        tb_frame_buf_t frame;
        for (int unsigned seq = 0; seq < 3; seq++) begin
          frame = wire_image(seq);
          for (int unsigned octet = 0; octet < tb_frame_octets(CLIENT, 0); octet++) begin
            @(negedge clk_i);
            rx_en[0] = 1;
            rx_d[7:0] = tb_get_octet(frame, octet);
          end
          @(negedge clk_i); rx_en[0] = 0;
          repeat (12) @(negedge clk_i);
        end
      end
      check_lane(1, 1);
      check_lane(2, 10);
    join
    if (fast_second_done >= slow_first_done)
      $fatal(1, "FAIL fast GMII egress waited for slow line transmission");
    $display("PASS fast GMII egress progresses independently");
    done_o = 1;
  end
endmodule
