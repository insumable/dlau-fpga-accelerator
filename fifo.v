`timescale 1ns/1ps

//  FIFO  -  First-Word-Fall-Through (FWFT) circular buffer
//  dout is always the head element (no extra rd_en pulse needed to see data)
module fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 64
)(
    input  wire                  clk, rst, wr_en, rd_en,
    input  wire [DATA_WIDTH-1:0] din,
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  full, empty
);
    localparam AW = $clog2(DEPTH); // address width for indexing the FIFO depth
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1]; // memory array for FIFO storage
    reg [AW:0] wr_ptr, rd_ptr, cnt; // write pointer, read pointer, and count of elements in FIFO

    assign full  = (cnt == DEPTH);
    assign empty = (cnt == 0);
    assign dout  = empty ? {DATA_WIDTH{1'b0}} : mem[rd_ptr[AW-1:0]];

    // Write logic: wr_ptr advances when wr_en is asserted and FIFO is not full
    always @(posedge clk) begin
        if (rst) wr_ptr <= 0;
        else if (wr_en && !full) begin
            mem[wr_ptr[AW-1:0]] <= din; // Write data to FIFO at the current write pointer location
            wr_ptr <= wr_ptr + 1;
        end
    end

    // Read logic: rd_ptr advances when rd_en is asserted and FIFO is not empty
    always @(posedge clk) begin
        if (rst) rd_ptr <= 0;
        else if (rd_en && !empty) rd_ptr <= rd_ptr + 1; // Advance read pointer when reading from FIFO
    end

    // Count logic to track the number of elements in the FIFO, used for full/empty status
    always @(posedge clk) begin
        if (rst) cnt <= 0; 
        else case ({wr_en && !full, rd_en && !empty})
            2'b10:   cnt <= cnt + 1;
            2'b01:   cnt <= cnt - 1;
            default: cnt <= cnt;
        endcase
    end
endmodule
