# DLAU: Deep Learning Accelerator Unit

A scalable, parameterized Verilog implementation of a deep learning accelerator unit for FPGA, based on *"DLAU: A Scalable Deep Learning Accelerator Unit on FPGA"*.

## Pipeline

```
Input Stream → TMMU → PSAU → AFAU → Output
```

| Module | File | Description |
|--------|------|-------------|
| `fifo` | `rtl/fifo.v` | First-word-fall-through circular buffer |
| `row_mac` | `rtl/row_mac.v` | Two-stage pipelined multiply-accumulate for one output row |
| `tmmu` | `rtl/tmmu.v` | Tiled Matrix Multiplication Unit: loads weights and inputs, computes partial sums |
| `psau` | `rtl/psau.v` | Part Sum Accumulation Unit: accumulates tile partial sums and adds bias |
| `afau` | `rtl/afau.v` | Activation Function Acceleration Unit: ReLU or piecewise-linear sigmoid, shift and saturate |
| `dlau` | `rtl/dlau_top.v` | Top level wiring TMMU → PSAU → AFAU |

## Input stream format

Per tile, the TMMU consumes bytes in this order: `ROWS*COLS` weights, then `COLS` inputs.

## Parameters

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `ROWS` | 4 | Output neurons computed in parallel |
| `COLS` | 4 | Tile width (inputs per tile) |
| `DATA_WIDTH` | 8 | Quantized input/output precision |
| `COUNT_WIDTH` | 12 | Width of the tile counter / accumulator headroom |
| `FIFO_DEPTH` | 64 | Depth of each inter-stage FIFO |

## Build order

```
rtl/fifo.v rtl/row_mac.v rtl/tmmu.v rtl/psau.v rtl/afau.v rtl/dlau_top.v
```

Example with Icarus Verilog:

```
iverilog -g2012 -o dlau.vvp rtl/fifo.v rtl/row_mac.v rtl/tmmu.v rtl/psau.v rtl/afau.v rtl/dlau_top.v
```

Top module: `dlau`.
