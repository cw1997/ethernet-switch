module ram #(
    // parameters
    parameter
    WIDTH = 32,
    DEPTH = 8
) (
    // ports
    input  logic        read_vaild,
    output logic        read_ready,
    input  logic [$clog2(DEPTH)-1:0] read_address,
    output logic [WIDTH-1:0] read_data,
    input  logic        write_vaild,
    output logic        write_ready,
    input  logic [$clog2(DEPTH)-1:0] write_address,
    input  logic [WIDTH-1:0] write_data,
    input  logic        clock, reset
);

logic [WIDTH-1:0] ram [0:DEPTH-1];

initial begin
	// $readmemb("D:\\GitHub\\openx86\\w80386dx\\rtl\\common\\rom.bin", ram);
    // for(int n=0; n<32; n=n+1)
        // $display("ram[0x%h] = %h", n, ram[n]);
end

// assign ready signal from vaild signal directly
// because write and read is one-cycle operation on the RAM register
assign read_ready = read_vaild;
assign write_ready = write_vaild;

// assign read_data = read_vaild ? ram[read_address] : '{default:'z};
// dont use comb logic because we need to output the read_data synchronize
always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
        read_data <= '{default:'z};
    end begin
        if (read_vaild) begin
            read_data <= ram[read_address];
        end else begin
            read_data <= '{default:'z};
        end
    end
end

always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
        for (int i=0; i<DEPTH; ++i) begin
            ram[i] <= 0; //(DEPTH-1)'b0;
        end
    end else begin
        if (write_vaild) begin
            for (int i=0; i<DEPTH; ++i) begin
                if (i == write_address) begin
                    ram[i] <= write_data;
                end else begin
                    ram[i] <= ram[i];
                end
            end
        end
    end
end

endmodule
