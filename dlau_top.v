`timescale 1ns/1ps

//  dlau_top.v  -  DLAU: Deep Learning Accelerator Unit  (top level)
//  Pipeline : Input Stream → TMMU → PSAU → AFAU → Output
//  Scalable via parameters: ROWS, COLS, DATA_WIDTH, FIFO_DEPTH
//  Based on: "DLAU: A Scalable Deep Learning Accelerator Unit on FPGA"
//
//  Depends on: tmmu.v, psau.v, afau.v (and transitively fifo.v, row_mac.v)
//
//  Wires TMMU → PSAU → AFAU into a streaming pipeline.
//
//  Scalability:
//    ROWS  = number of output neurons computed per cycle
//    COLS  = tile width / number of inputs per tile
//    DATA_WIDTH = input/output quantized precision
//    Increase for higher throughput at the cost of FPGA resources.

module dlau #(
    parameter ROWS       = 4,
    parameter COLS       = 4,
    parameter DATA_WIDTH = 8,
    parameter COUNT_WIDTH = 12,
    parameter PSUM_W     = (2 * DATA_WIDTH) + ((COLS > 1) ? $clog2(COLS) : 0),
    parameter ACC_W      = PSUM_W + COUNT_WIDTH,
    parameter SHIFT_WIDTH = (ACC_W > 1) ? $clog2(ACC_W) : 1,
    parameter FIFO_DEPTH = 64
)(
    input  wire                        clk, rst,
    input  wire [COUNT_WIDTH-1:0]      num_tiles,
    input  wire signed [(ROWS*ACC_W)-1:0] bias_flat,
    input  wire                        act_type,
    input  wire [SHIFT_WIDTH-1:0]      shift_amount,
    input  wire                        in_wr_en,
    input  wire [DATA_WIDTH-1:0]       in_din,
    output wire                        in_full,
    input  wire                        out_rd_en,
    output wire [(ROWS*DATA_WIDTH)-1:0] out_dout,
    output wire                        out_empty,
    output wire                        tmmu_done,
    output wire                        psau_done,
    output wire                        afau_done
);
    wire [(ROWS*PSUM_W)-1:0] tmmu_to_psau;
    wire                 tmmu_out_empty, tmmu_out_full;
    wire                 psau_tmmu_rd;

    wire [(ROWS*ACC_W)-1:0] psau_to_afau;
    wire                 psau_out_empty, psau_out_full;
    wire                 afau_psau_rd;

    wire tmmu_in_empty, psau_ready, afau_ready, afau_out_full;

    tmmu #(
        .ROWS(ROWS), 
        .COLS(COLS),
        .PSUM_W(PSUM_W),
        .DATA_WIDTH(DATA_WIDTH), 
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_tmmu (
        .clk(clk),          
        .rst(rst),
        .in_wr_en(in_wr_en),
        .in_din(in_din),
        .out_rd_en(psau_tmmu_rd),
        .out_dout(tmmu_to_psau),
        .out_empty(tmmu_out_empty), 
        .out_full(tmmu_out_full),
        .in_full(in_full),          
        .in_empty(tmmu_in_empty),
        .compute_done(tmmu_done)
    );

    psau #(
        .ROWS(ROWS), 
        .COLS(COLS),
        .DATA_WIDTH(DATA_WIDTH), 
        .COUNT_WIDTH(COUNT_WIDTH),
        .PSUM_W(PSUM_W), 
        .ACC_W(ACC_W), 
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_psau (
        .clk(clk),            
        .rst(rst),
        .num_tiles(num_tiles), 
        .bias_flat(bias_flat),
        .tmmu_data(tmmu_to_psau), 
        .tmmu_empty(tmmu_out_empty),
        .tmmu_rd_en(psau_tmmu_rd),
        .out_rd_en(afau_psau_rd),
        .out_dout(psau_to_afau),
        .out_empty(psau_out_empty), 
        .out_full(psau_out_full),
        .done(psau_done), 
        .ready(psau_ready)
    );

    afau #(
        .ROWS(ROWS), 
        .COLS(COLS), 
        .DATA_WIDTH(DATA_WIDTH),
        .COUNT_WIDTH(COUNT_WIDTH), 
        .PSUM_W(PSUM_W),
        .ACC_W(ACC_W), 
        .SHIFT_WIDTH(SHIFT_WIDTH), 
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_afau (
        .clk(clk),             
        .rst(rst),
        .act_type(act_type),   
        .shift_amount(shift_amount),
        .psau_data(psau_to_afau), 
        .psau_empty(psau_out_empty),
        .psau_rd_en(afau_psau_rd),
        .out_rd_en(out_rd_en),
        .out_dout(out_dout),
        .out_empty(out_empty), 
        .out_full(afau_out_full),
        .done(afau_done), 
        .ready(afau_ready)
    );
endmodule
