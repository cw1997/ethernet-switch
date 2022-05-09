module fifo #(
    WIDTH, DEPTH
) (
    output logic [WIDTH-1:0]       read_data,
    input  logic                   read_enable,
    input  logic [WIDTH-1:0]       write_data,
    input  logic                   write_enable,
    output logic                   is_empty,
    output logic                   is_full,
    input  logic                   clock, reset
);

localparam OFFSET_WIDTH = $clog2(DEPTH);

logic [OFFSET_WIDTH:0] read_offset, write_offset;

wire read_offset_top_bit = read_offset[OFFSET_WIDTH];
wire write_offset_top_bit = write_offset[OFFSET_WIDTH];
wire [OFFSET_WIDTH-1:0] read_address = read_offset[OFFSET_WIDTH-1:0];
wire [OFFSET_WIDTH-1:0] write_address = write_offset[OFFSET_WIDTH-1:0];

assign is_empty = (read_offset_top_bit == write_offset_top_bit) & (read_address >= write_address);
assign is_full  = (read_offset_top_bit != write_offset_top_bit) & (read_address <= write_address);

wire read_vaild = ~is_empty & read_enable;
wire write_vaild = ~is_full & write_enable;

always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
        read_offset <= 0;
    end else begin
        if (read_vaild) begin
            read_offset <= read_offset + 1;
        end else begin
            read_offset <= read_offset;
        end
    end

    if (reset) begin
        write_offset <= 0;
    end else begin
        if (write_vaild) begin
            write_offset <= write_offset + 1;
        end else begin
            write_offset <= write_offset;
        end
    end
end

ram #(
    .WIDTH ( WIDTH ),
    .DEPTH ( DEPTH )
) fifo_ram (
    .read_vaild ( read_vaild ),
    .read_address ( read_address ),
    .read_data ( read_data ),
    .write_vaild ( write_vaild ),
    .write_address ( write_address ),
    .write_data ( write_data ),
    .clock ( clock ),
    .reset ( reset )
);

endmodule
