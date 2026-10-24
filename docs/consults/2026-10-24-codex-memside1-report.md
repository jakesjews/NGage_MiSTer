# Shared memory, first measurement step — 2026-10-24

Base: master `92cd47f`, including deferred D-cache eviction (`a69e840`). Work
branch: `codex/memside`. The parked `codex/timing2` branch remains at `c188fe5`.
This task adds instruction-side measurements and I-cache critical-word-first;
it does not change the CPU pipeline schedule or add a merger write-back buffer.

## 1. Instruction-side instrumentation

The old `code` counter is **FIFO full OR fetch request without ACK**. It is not
an I-cache miss-stall counter. The two supplied speed consults correctly identify
that ambiguity; their inferred gameplay percentages are not measurements of
these new taps. The old counter remains at index 9, now labelled `code-combined`
in `tools/mister_dbg.py`.

Eight counters append to the existing 25. These are clocks/events per second,
not percentages of instructions. Percentages in the decoder use 104 MHz.

| Counter | Overlay word | `arm925t.dbg_icache` source | Meaning |
|---:|---:|---:|---|
| 25 | 37 | 0 | FIFO full clocks |
| 26 | 38 | 1 | Fetch CYC and STB without ACK |
| 27 | 39 | 2 | Demand-owned I-cache burst terminal beats |
| 28 | 40 | 3 | Fetch without ACK **and FIFO not full** |
| 29 | 41 | 4 | Pending demand-fill bus request while the merger owns DATA |
| 30 | 42 | 5, qualified in NGage | Pending demand-fill request selected through the I wrapper and CODE merger owner, while the DMA/self-test owns the external path |
| 31 | 43 | 6 | Completed I-TLB page-table walk beats |
| 32 | 44 | 7 | Completed D-TLB page-table walk beats |

Bit 5 is a qualification tap, **not** the final external-arbitration counter:
NGage combines it with `ngage_mem.dbg_dma_owner` or `test_sel`. The DMA grant is
an observation of the existing registered `wb_arb2` owner. The merger similarly
exports its existing DATA owner. No grant/control behavior changes.

The I-cache FSM exports demand completion and pending-bus-wait taps through
`zap_cache`; both cache wrappers count actual granted TLB responses, not held
requests. ACK or ERR terminates a beat and counts it. Demand completions include
failed bursts, but exclude uncached instruction accesses, maintenance, and
prefetch-only bursts. Prefetch is off by default. An in-flight prefetch adopted
before its terminal beat becomes a demand-owned completion; a completed buffer
hit is not another bus fill.

Counter 28 includes uncached fetch and translation/recovery delay; it is the
requested fetch-wait-without-backpressure measure, not proof of backend-ready
lost execution. Counter 29 includes both data reads and deferred write-backs.
Counter 30 excludes clocks already attributed to DATA ownership. Neither is
the target memory's service latency. The old code count equals FIFO-full plus
counter 28; overlap of raw fetch wait and FIFO-full is counter 26 minus 28.
The wait counters overlap the existing bus-target counters and must not be
added to them as disjoint CPI categories.

The overlay counter index is widened from five to six bits for counter 32.
Existing fixed words 0–11 and counters 0–24 retain their positions. Loader
status/history move to words 45/46, rows 188–190/192–194. The Python decoder and
actual-video top bench use the new positions; old screenshots require the old
decoder. All eight accumulators, snapshot registers and overlay selection stay
under `NGAGE_DEBUG`. Outside debug these combinational observation ports are
sunk in the existing unused-debug expression and prune away. No extra state or
control is added to the stripped core in this piece.

Baseline and instrumentation-only verification: 228/228 CPU runs pass at
0:0 / 0:3 / 2:9, with **every cycle and instruction count identical** (21,087,834
cycles in total). QEMU: **57 agree, 0 differ**. The bench checks the old combined
stall against the two new raw taps every clock and checks counter 28's predicate.
Both lint configurations pass; generation and `cpu-gen-check` pass; generated
`input reg` count remains 10. `make -C sim top` passes all checks in
150,622,764 clocks, including the loader words read through actual video pixels;
the Python decoder also reads the resulting image correctly.

## 2. I-cache critical-word-first

Implementation and measured results follow in the second change.
