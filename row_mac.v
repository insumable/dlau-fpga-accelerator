`timescale 1ns/1ps

//  row_mac  -  Scalable MAC for one output row
//  Two-stage pipeline:
//    1. Register all per-column products
//    2. Register the sum of those products
module row_mac #(
    parameter COLS       = 4,
    parameter DATA_WIDTH = 8,
    parameter PSUM_W     = (2 * DATA_WIDTH) + ((COLS > 1) ? $clog2(COLS) : 0)
)(
    input  wire clk,
    input  wire rst,
    input  wire in_valid,
    input  wire signed [(COLS*DATA_WIDTH)-1:0] weight_flat,
    input  wire signed [(COLS*DATA_WIDTH)-1:0] input_flat,
    output wire out_valid,
    output reg  signed [PSUM_W-1:0] y
);
    localparam PROD_W = 2 * DATA_WIDTH;

    wire signed [PROD_W-1:0] products [0:COLS-1];
    wire signed [PSUM_W-1:0] products_ext [0:COLS-1];
    reg  signed [PSUM_W-1:0] prod_reg [0:COLS-1];
    reg                      valid_stage1;
    reg                      valid_stage2;
    reg  signed [PSUM_W-1:0] sum_comb;

    genvar col_idx;
    generate
        for (col_idx = 0; col_idx < COLS; col_idx = col_idx + 1) begin : gen_products
            assign products[col_idx] =
                $signed(weight_flat[col_idx*DATA_WIDTH +: DATA_WIDTH]) *
                $signed(input_flat[col_idx*DATA_WIDTH +: DATA_WIDTH]);
            assign products_ext[col_idx] =
                {{(PSUM_W-PROD_W){products[col_idx][PROD_W-1]}}, products[col_idx]};
        end
    endgenerate

    integer i;
    always @(*) begin
        sum_comb = {PSUM_W{1'b0}};
        for (i = 0; i < COLS; i = i + 1)
            sum_comb = sum_comb + prod_reg[i];
    end

    assign out_valid = valid_stage2;

    always @(posedge clk) begin
        if (rst) begin
            valid_stage1 <= 1'b0;
            valid_stage2 <= 1'b0;
            y <= {PSUM_W{1'b0}};
            for (i = 0; i < COLS; i = i + 1)
                prod_reg[i] <= {PSUM_W{1'b0}};
        end else begin
            valid_stage1 <= in_valid;
            valid_stage2 <= valid_stage1;
            if (in_valid)
                for (i = 0; i < COLS; i = i + 1)
                    prod_reg[i] <= products_ext[i];
            if (valid_stage1)
                y <= sum_comb;
        end
    end
endmodule
