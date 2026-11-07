// ============================================================================
//  File        : es_mems_ram_1r1w.sv
//  Description : Synchronous write, asynchronous read RAM; contents are not reset.
//                Writes use clk_i; the read port is asynchronous.  The owner
//                must keep both addresses below DEPTH and qualify unread data.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MEMS_RAM_1R1W_SV
`define ES_MEMS_RAM_1R1W_SV

`default_nettype none

module es_mems_ram_1r1w #(
  /// Stored word width in bits.
  parameter int unsigned WIDTH = 64,
  /// Number of entries; addresses must remain below DEPTH.
  parameter int unsigned DEPTH = 16,
  /// Address width must represent every entry in DEPTH.
  parameter int unsigned ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
  /// Write clock and synchronous write enable.
  input var logic clk_i,
  input var logic wr_en_i,
  /// Both addresses must remain in [0, DEPTH); the read address is asynchronous.
  input var logic [ADDR_W-1:0] wr_addr_i, rd_addr_i,
  /// Data captured on clk_i when wr_en_i is asserted.
  input var logic [WIDTH-1:0] wr_data_i,
  /// Asynchronous read of the addressed word; contents are not reset.
  output    logic [WIDTH-1:0] rd_data_o
);

  // --------------------------------------------------------------------------
  // Storage
  //
  // No reset or initialization: the owner qualifies unread/empty data.  A
  // same-address write becomes visible after the clock's nonblocking update,
  // i.e. a read of the address being written returns the *old* word in the
  // same clock.
  // --------------------------------------------------------------------------
  logic [WIDTH-1:0] mem [0:DEPTH-1];

  always_ff @(posedge clk_i) begin
    if (wr_en_i) mem[wr_addr_i] <= wr_data_i;
  end

  assign rd_data_o = mem[rd_addr_i];

endmodule : es_mems_ram_1r1w

`default_nettype wire

`endif  // ES_MEMS_RAM_1R1W_SV
