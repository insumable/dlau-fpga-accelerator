`timescale 1ns/1ps

//  AFAU  -  Activation Function Acceleration Unit
//
//  Applies per-row activation to PSAU output:
//    act_type=0 → ReLU:    max(0, x)
//    act_type=1 → Sigmoid: piecewise linear, 8 segments, ×256 fixed point
//  Arithmetic right-shifts result by shift_amount, saturates to signed
//  DATA_WIDTH output precision.
//
//  Sigmoid coefficients (×256 fixed point, verified):
//    seg  a    b(=σ(seg)×256)
//     0   59   128    (σ(0)=0.500)
//     1   38   187    (σ(1)=0.731)
//     2   19   225    (σ(2)=0.880)
//     3    7   244    (σ(3)=0.953)
//     4    3   251    (σ(4)=0.982)
//     5    1   254    (σ(5)=0.993)
//     6    0   255    (σ(6)=0.998)
//     7    1   255    (σ(7)=0.999)
//  Symmetry: σ(-x) = 1 - σ(x)  →  256 - f(|x|)
//
//  FSM:  IDLE (capture + activate) → OUTPUT → IDLE
//
//  Depends on: fifo.v

module afau #(
    parameter ROWS        = 4,
    parameter COLS        = 4,
    parameter DATA_WIDTH  = 8,
    parameter COUNT_WIDTH = 16,
    parameter PSUM_W      = (2 * DATA_WIDTH) + ((COLS > 1) ? $clog2(COLS) : 0),
    parameter ACC_W       = PSUM_W + COUNT_WIDTH,
    parameter SHIFT_WIDTH = (ACC_W > 1) ? $clog2(ACC_W) : 1,
    parameter FIFO_DEPTH  = 64
)(
    input  wire                        clk, rst,
    input  wire                        act_type,
    input  wire [SHIFT_WIDTH-1:0]      shift_amount,
    input  wire signed [(ROWS*ACC_W)-1:0] psau_data,
    input  wire                        psau_empty,
    output wire                        psau_rd_en,
    input  wire                        out_rd_en,
    output wire [(ROWS*DATA_WIDTH)-1:0] out_dout,
    output wire                        out_empty, out_full,
    output wire                        done, ready
);
    localparam S_IDLE = 2'd0;
    localparam S_ACT  = 2'd1;
    localparam S_OUT  = 2'd2;
    localparam OUT_W  = ROWS * DATA_WIDTH;
    localparam signed [ACC_W-1:0] QUANT_MAX =
        {{(ACC_W-DATA_WIDTH){1'b0}}, {1'b0, {(DATA_WIDTH-1){1'b1}}}};
    localparam signed [ACC_W-1:0] QUANT_MIN =
        {{(ACC_W-DATA_WIDTH){1'b1}}, {1'b1, {(DATA_WIDTH-1){1'b0}}}};

    reg [1:0] state;
    reg done_flag;
    reg act_type_r;
    reg [SHIFT_WIDTH-1:0] shift_amount_r;
    reg signed [(ROWS*ACC_W)-1:0] psau_data_r;

    assign done       = done_flag;
    assign ready      = (state == S_IDLE);
    assign psau_rd_en = (state == S_IDLE) && !psau_empty;

    wire signed [ACC_W-1:0] drow [0:ROWS-1];
    genvar gr;
    generate
        for (gr = 0; gr < ROWS; gr = gr+1) begin : unpack_psau
            assign drow[gr] = psau_data_r[gr*ACC_W +: ACC_W];
        end
    endgenerate

    // Piecewise linear sigmoid (×256 fixed point)
    function automatic signed [ACC_W-1:0] sigmoid_pwl;
        input signed [ACC_W-1:0] x;
        reg signed [ACC_W-1:0] ax, a, b, fpos;
        reg [2:0] seg;
        begin
            ax  = x[ACC_W-1] ? -x : x;
            seg = (ax >= 8) ? 3'd7 : ax[2:0];
            case (seg)
                3'd0: begin a = 59;  b = 128; end
                3'd1: begin a = 38;  b = 187; end
                3'd2: begin a = 19;  b = 225; end
                3'd3: begin a = 7;   b = 244; end
                3'd4: begin a = 3;   b = 251; end
                3'd5: begin a = 1;   b = 254; end
                3'd6: begin a = 0;   b = 255; end
                3'd7: begin a = 1;   b = 255; end
                default: begin a = 0; b = 128; end
            endcase
            fpos = a * (ax - seg) + b;
            if      (x <= -8) sigmoid_pwl = 0;
            else if (x >=  8) sigmoid_pwl = 256;
            else if (!x[ACC_W-1])  sigmoid_pwl = fpos;
            else                   sigmoid_pwl = 256 - fpos;
        end
    endfunction

    wire signed [ACC_W-1:0] act_val [0:ROWS-1];
    wire signed [ACC_W-1:0] shifted [0:ROWS-1];
    wire signed [DATA_WIDTH-1:0] quant [0:ROWS-1];

    genvar a;
    generate
        for (a = 0; a < ROWS; a = a+1) begin : act_gen
            assign act_val[a] = (act_type_r == 1'b0)
                ? (drow[a][ACC_W-1] ? {ACC_W{1'b0}} : drow[a])
                : sigmoid_pwl(drow[a]);
            assign shifted[a] = act_val[a] >>> shift_amount_r;
            assign quant[a]   = (shifted[a] >  QUANT_MAX) ? QUANT_MAX[DATA_WIDTH-1:0] :
                                 (shifted[a] < QUANT_MIN) ? QUANT_MIN[DATA_WIDTH-1:0] :
                                  shifted[a][DATA_WIDTH-1:0];
        end
    endgenerate

    reg [OUT_W-1:0] result_r;
    reg             out_wr_en;

    fifo #(.DATA_WIDTH(OUT_W), .DEPTH(FIFO_DEPTH)) u_out_fifo (
        .clk(clk),
        .rst(rst),
        .wr_en(out_wr_en),
        .din(result_r),
        .rd_en(out_rd_en),
        .dout(out_dout),
        .full(out_full),
        .empty(out_empty)
    );

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            done_flag      <= 0;
            out_wr_en      <= 0;
            result_r       <= 0;
            act_type_r     <= 0;
            shift_amount_r <= 0;
            psau_data_r    <= 0;
        end else begin
            done_flag <= 0;
            out_wr_en <= 0;
            case (state)
                S_IDLE: begin
                    if (!psau_empty) begin
                        psau_data_r    <= psau_data;
                        act_type_r     <= act_type;
                        shift_amount_r <= shift_amount;
                        state <= S_ACT;
                    end
                end

                S_ACT: begin
                    for (i = 0; i < ROWS; i = i+1)
                        result_r[i*DATA_WIDTH +: DATA_WIDTH] <= quant[i];
                    state <= S_OUT;
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
