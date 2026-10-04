`timescale 1ns/1ps

//  TMMU  -  Tiled Matrix Multiplication Unit
//
//  Receives a stream of bytes:  [ROWS*COLS weights] then [COLS inputs]
//  Computes: psum[r] = Σ weight[r][c] * input[c]  for all rows in parallel
//  Outputs ROWS × PSUM_W partial sums per tile into output FIFO
//
//  FSM:  IDLE → LOAD_WEIGHTS → LOAD_INPUTS → START_MAC → WAIT_MAC → WRITE → IDLE
//  The row MAC path is pipelined so the multiplier and adder stages do not
//  sit on the same clock boundary.
//
//  Depends on: fifo.v, row_mac.v

module tmmu #(
    parameter ROWS       = 4,
    parameter COLS       = 4,
    parameter DATA_WIDTH = 8,
    parameter PSUM_W     = (2 * DATA_WIDTH) + ((COLS > 1) ? $clog2(COLS) : 0),
    parameter FIFO_DEPTH = 64
)(
    input  wire clk,
    input  wire rst,
    input  wire in_wr_en,
    input  wire [DATA_WIDTH-1:0] in_din,
    input  wire out_rd_en,
    output wire [(ROWS*PSUM_W)-1:0] out_dout,
    output wire out_empty,
    output wire out_full,
    output wire in_full,
    output wire in_empty,
    output wire compute_done
);
    localparam WCNT  = ROWS * COLS;
    localparam PBITS = ROWS * PSUM_W;
    localparam MAX_COUNT = (WCNT > COLS) ? WCNT : COLS;
    localparam CNT_W = (MAX_COUNT > 1) ? $clog2(MAX_COUNT) : 1;

    localparam S_IDLE     = 3'd0;
    localparam S_LOADW    = 3'd1;
    localparam S_LOADI    = 3'd2;
    localparam S_STARTMAC = 3'd3;
    localparam S_WAITMAC  = 3'd4;
    localparam S_WRITE    = 3'd5;

    reg [2:0] state;
    reg [CNT_W-1:0] cnt;
    reg mac_in_valid;
    reg done_flag;
    reg out_wr_en;

    wire [DATA_WIDTH-1:0] in_dout;
    wire in_rd_en;
    assign in_rd_en = ((state == S_LOADW) || (state == S_LOADI)) && !in_empty;
    assign compute_done = done_flag;

    fifo #(.DATA_WIDTH(DATA_WIDTH), .DEPTH(FIFO_DEPTH)) u_in_fifo (
        .clk(clk),
        .rst(rst),
        .wr_en(in_wr_en),
        .din(in_din),
        .rd_en(in_rd_en),
        .dout(in_dout),
        .full(in_full),
        .empty(in_empty)
    );

    reg signed [DATA_WIDTH-1:0] weights [0:WCNT-1];
    reg signed [DATA_WIDTH-1:0] inp [0:COLS-1];
    reg signed [PSUM_W-1:0] psum [0:ROWS-1];

    wire signed [PSUM_W-1:0] row_sum [0:ROWS-1];
    wire row_valid [0:ROWS-1];
    wire mac_out_valid;
    wire signed [(COLS*DATA_WIDTH)-1:0] input_flat;

    genvar input_idx;
    generate
        for (input_idx = 0; input_idx < COLS; input_idx = input_idx + 1) begin : pack_inputs
            assign input_flat[input_idx*DATA_WIDTH +: DATA_WIDTH] = inp[input_idx];
        end
    endgenerate

    genvar row_idx, weight_idx;
    generate
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin : mac_rows
            wire signed [(COLS*DATA_WIDTH)-1:0] weight_row_flat;

            for (weight_idx = 0; weight_idx < COLS; weight_idx = weight_idx + 1) begin : pack_weights
                assign weight_row_flat[weight_idx*DATA_WIDTH +: DATA_WIDTH] =
                    weights[row_idx*COLS + weight_idx];
            end

            row_mac #(.COLS(COLS), .DATA_WIDTH(DATA_WIDTH), .PSUM_W(PSUM_W)) u_row_mac (
                .clk(clk),
                .rst(rst),
                .in_valid(mac_in_valid),
                .weight_flat(weight_row_flat),
                .input_flat(input_flat),
                .out_valid(row_valid[row_idx]),
                .y(row_sum[row_idx])
            );
        end
    endgenerate

    assign mac_out_valid = row_valid[0];

    wire [PBITS-1:0] out_din_w;
    genvar pout;
    generate
        for (pout = 0; pout < ROWS; pout = pout + 1) begin : pack_psum
            assign out_din_w[pout*PSUM_W +: PSUM_W] = psum[pout];
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
            state        <= S_IDLE;
            cnt          <= 0;
            mac_in_valid <= 0;
            done_flag    <= 0;
            out_wr_en    <= 0;
            for (i = 0; i < WCNT; i = i + 1) weights[i] <= 0;
            for (i = 0; i < COLS; i = i + 1) inp[i] <= 0;
            for (i = 0; i < ROWS; i = i + 1) psum[i] <= 0;
        end else begin
            mac_in_valid <= 0;
            done_flag <= 0;
            out_wr_en <= 0;

            case (state)
                S_IDLE: begin
                    cnt <= 0;
                    if (!in_empty)
                        state <= S_LOADW;
                end

                S_LOADW: begin
                    if (!in_empty) begin
                        weights[cnt] <= $signed(in_dout);
                        cnt <= cnt + 1;
                        if (cnt == WCNT - 1) begin
                            cnt <= 0;
                            state <= S_LOADI;
                        end
                    end
                end

                S_LOADI: begin
                    if (!in_empty) begin
                        inp[cnt] <= $signed(in_dout);
                        cnt <= cnt + 1;
                        if (cnt == COLS - 1) begin
                            cnt <= 0;
                            state <= S_STARTMAC;
                        end
                    end
                end

                S_STARTMAC: begin
                    mac_in_valid <= 1;
                    state <= S_WAITMAC;
                end

                S_WAITMAC: begin
                    if (mac_out_valid) begin
                        for (i = 0; i < ROWS; i = i + 1)
                            psum[i] <= row_sum[i];
                        state <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    if (!out_full) begin
                        out_wr_en <= 1;
                        done_flag <= 1;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
