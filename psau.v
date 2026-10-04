`timescale 1ns/1ps

//  PSAU  -  Part Sum Accumulation Unit
//
//  Reads num_tiles partial-sum vectors from TMMU output FIFO,
//  accumulates them in ACC_W registers,
//  adds bias, then writes final ACC_W-per-row result to output FIFO.
//
//  FSM:  IDLE → ACCUMULATE → OUTPUT → IDLE
//
//  Depends on: fifo.v

module psau #(
    parameter ROWS        = 4,
    parameter COLS        = 4,
    parameter DATA_WIDTH  = 8,
    parameter COUNT_WIDTH = 16, 
    parameter PSUM_W      = (2 * DATA_WIDTH) + ((COLS > 1) ? $clog2(COLS) : 0),
    parameter ACC_W       = PSUM_W + COUNT_WIDTH, 
    parameter FIFO_DEPTH  = 64
)(
    input  wire                            clk, rst,
    input  wire [COUNT_WIDTH-1:0]          num_tiles,
    input  wire signed [(ROWS*ACC_W)-1:0]  bias_flat,
    input  wire signed [(ROWS*PSUM_W)-1:0] tmmu_data,
    input  wire                            tmmu_empty,
    output wire                            tmmu_rd_en,
    input  wire                            out_rd_en,
    output wire signed [(ROWS*ACC_W)-1:0]  out_dout,
    output wire                            out_empty, out_full, done, ready
);
    localparam PBITS  = ROWS * ACC_W;
    localparam S_IDLE = 2'd0;
    localparam S_ACC  = 2'd1;
    localparam S_OUT  = 2'd2;

    reg [1:0]  state;
    reg [COUNT_WIDTH-1:0] tile_cnt, num_tiles_r; 

    reg signed [ACC_W-1:0] acc [0:ROWS-1];
    reg done_flag;
    assign done       = done_flag;
    assign ready      = (state == S_IDLE);
    assign tmmu_rd_en = (state == S_ACC) && !tmmu_empty;

    wire signed [PSUM_W-1:0] prow [0:ROWS-1];
    wire signed [ACC_W-1:0]  bias_row [0:ROWS-1];
    genvar gr;
    generate
        for (gr = 0; gr < ROWS; gr = gr+1) begin : unpack_tmmu
            assign prow[gr] = tmmu_data[gr*PSUM_W +: PSUM_W];
            assign bias_row[gr] = bias_flat[gr*ACC_W +: ACC_W];
        end
    endgenerate

    wire signed [ACC_W-1:0] final_acc [0:ROWS-1];
    reg               out_wr_en;
    wire [PBITS-1:0]  out_din_w;

    genvar be;
    generate
        for (be = 0; be < ROWS; be = be + 1) begin : extend_bias
            assign final_acc[be] = acc[be] + bias_row[be];
        end
    endgenerate

    genvar pout;
    generate
        for (pout = 0; pout < ROWS; pout = pout + 1) begin : pack_acc
            assign out_din_w[pout*ACC_W +: ACC_W] = final_acc[pout];
        end
    endgenerate

    fifo #(.DATA_WIDTH(PBITS), .DEPTH(FIFO_DEPTH)) u_out_fifo (
        .clk(clk), 
        .rst(rst),
        .wr_en(out_wr_en), 
        .din(out_din_w),
        .rd_en(out_rd_en), 
        .dout(out_dout),
        .full(out_full), 
        .empty(out_empty)
    );

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE; 
            tile_cnt    <= 0;
            num_tiles_r <= 0;     
            done_flag   <= 0;
            out_wr_en   <= 0;
            for (i = 0; i < ROWS; i = i+1) acc[i] <= 0;
        end else begin
            done_flag <= 0;
            out_wr_en <= 0;
            case (state)

                S_IDLE: begin
                    tile_cnt    <= 0;
                    num_tiles_r <= num_tiles;
                    for (i = 0; i < ROWS; i = i+1) acc[i] <= 0;
                    if (!tmmu_empty && num_tiles > 0) state <= S_ACC;
                end

                S_ACC: begin
                    if (!tmmu_empty) begin
                        for (i = 0; i < ROWS; i = i+1)
                            acc[i] <= acc[i] + {{(ACC_W-PSUM_W){prow[i][PSUM_W-1]}}, prow[i]};
                        tile_cnt <= tile_cnt + 1;
                        if (tile_cnt == num_tiles_r - 1) state <= S_OUT;
                    end
                end

                S_OUT: begin
                    if (!out_full) begin
                        out_wr_en <= 1;
                        done_flag <= 1;
                        state     <= S_IDLE;
                    end
                end

            endcase
        end
    end
endmodule
