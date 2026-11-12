#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build/lcd-fast
iverilog -g2012 -s tb -o build/lcd-fast/test \
    rtl/board/sdp_ram.sv rtl/upp/upp_fifo.sv rtl/upp/upp_dma.sv \
    rtl/upp/upp_lcdif.sv tests/lcd_fast/tb.v
vvp build/lcd-fast/test
