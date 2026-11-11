#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
out=${DMA_COUNT_OUT:-sim/build/dma-count}
mkdir -p "$out"
python3 - "$out/dma_run.inc" <<'PY'
from pathlib import Path
import sys
source = Path('model/hw/ngage_dma.c').read_text()
start = source.index('static hwaddr dma_phys(')
end = source.index('static uint64_t dma_read(', start)
Path(sys.argv[1]).write_text(source[start:end])
PY
${CC:-cc} -std=c11 -Wall -Wextra -Werror -I"$out" sim/dma-count/model_test.c -o "$out/model_test"
iverilog -g2012 -s tb -o "$out/rtl_test" rtl/board/sdp_ram.sv rtl/upp/upp_dma.sv sim/dma-count/tb.v
if ! "$out/model_test" "${DMA_COUNT_CASE:-0}" > "$out/model.log" 2>&1; then
    cat "$out/model.log"
    exit 1
fi
if ! vvp "$out/rtl_test" +case="${DMA_COUNT_CASE:-0}" > "$out/rtl.log" 2>&1; then
    cat "$out/rtl.log"
    exit 1
fi
cat "$out/model.log" "$out/rtl.log"
