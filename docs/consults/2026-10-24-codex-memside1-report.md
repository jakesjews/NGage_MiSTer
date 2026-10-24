# Shared memory, first measurement step — 2026-10-24

Base: master `92cd47f`, including deferred D-cache eviction (`a69e840`). Work
branch: `codex/memside`. The parked `codex/timing2` branch remains at `c188fe5`.
This task adds instruction-side measurements and I-cache critical-word-first;
it does not change the CPU pipeline schedule or add a merger write-back buffer.

## 1. Instruction-side instrumentation (`50cbff0`)

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

On this base revision the I-cache did **not** yet output BTE at all: it fetched
linearly from word zero. The D-cache already carried BTE through the shared
merger. Merely changing the merger's CODE constant would therefore not be enough.

At demand-miss acceptance, the FSM captures the missed physical word index and
a wrap flag. `FETCH_SINGLE` forms current/next addresses by concatenating the
registered line PA with a two-bit modulo-four sum and `00`. ACK still selects
between these two candidates; there is no carry into the line address and no
new stage or handshake. The ordinal beat counter remains 0,1,2,3, and EOB is
still the fourth beat, irrespective of which word it is.

| Missed word | Before: word indices | After: word indices | Requested word advances by |
|---:|---|---|---:|
| +0 | 0,1,2,3 | 0,1,2,3 | 0 accepted beats |
| +4 | 0,1,2,3 | 1,2,3,0 | 1 accepted beat |
| +8 | 0,1,2,3 | 2,3,0,1 | 2 accepted beats |
| +12 | 0,1,2,3 | 3,0,1,2 | 3 accepted beats |

The returned data and valid bit are indexed by the **registered bus address**,
not the ordinal counter. The complete RAM line is consequently in ordinary
word order. The existing `buf_nxt` → registered `response_dat_ff` /
`fill_ready_ff` bypass sees the critical beat immediately at its receiving
edge. No live cache or bus-data bypass is added to the CPU pipeline.

`zap_cache` forwards the FSM's BTE only for the cache manager; TLB and tag
maintenance remain linear. `zap_top` wires that NXT sideband to the merger,
which registers the selected I-side BTE alongside address and CTI, just as for
DATA. The ONLY_CORE branch explicitly supplies linear BTE. Other cache-line
sizes retain the old linear order; critical-word-first is enabled for the
phone's 16-byte lines.

The prefetch option remains off by default and is not enabled by this work.
Prefetch bursts remain linear. A demand that adopts a partially returned
prefetch sets its starting index to zero and keeps BTE linear, preserving
both the already received words and the sideband of a stalled bus beat.
A completed prefetch-buffer hit still installs its existing line unchanged.

**Fault and redirect behavior is unchanged.** Early words may enter the FIFO,
but cannot execute until the whole fill succeeds. Errors on any beat remain
sticky, prohibit installation, and produce the existing precise prefetch
abort. Branch redirects and maintenance retain their existing handling.
This full-fill execution gate limits the benefit of critical-word-first; it
is not removed as part of shared-memory work.

### SDRAM and flash

No `upp_bus`, SDRAM, NOR, or DDR-flash behavior needed changing. The merger now
lets the I-cache use the same wrap-4 contract already used by data fills.
SDRAM begins at the requested word and wraps within the 16-byte line. UPP's
flash path initializes `fl_widx` from that word and keeps the buffered block
valid across word 3 → word 0 when `fl_wrap4` is set. Command/status reads use
the existing BTE-aware halfword path instead of the read-array line path.

DDR3's physical cache-miss burst remains aligned and linear; the bridge buffers
and selects its words in the requested Wishbone order. A DDR-cache hit can
return the critical 8-byte beat first; a cold DDR miss may still wait for that
beat in its aligned burst. Thus end-to-end Wishbone correctness does not imply
a reordered physical DDR3 burst or a guaranteed flash latency improvement.

### Verification and cycle measurements

The new RTL-only `icwf_rtl.S` calls a line at all four word offsets, checks four
distinct instruction effects, rewrites backing RAM with the D-cache off, and
checks every warm entry still executes the original installed words. An
invalidation then exposes the replacement words. The same binary passes on
the archived master model and the new model; both execute 13,510 instructions.
It is RTL-only because the test relies on stale instruction-cache contents.
No existing binary or QEMU reference was rebuilt/rerun.

The bench additionally checks every default-configuration demand fill:

- The first external address is the original missed physical word.
- Every subsequent accepted address wraps within that line, BTE is wrap-4,
  and EOB occurs on beat four; no word is repeated or missing.
- The four buffer words match the actual returned data in address order.
- When the lookup still requests the critical word, its first response appears
  in the registered early-restart bypass at the immediately following edge.

The existing `icache_restart` test covers ARM and Thumb offsets, invalidation,
redirects, errors on each beat, and retry after a failed fill. Its assertions
still prohibit any provisional instruction from executing before a late error.
The common bus monitor checks address/data/CTI/BTE stability while held.

Default suite: **231/231 pass**, comprising the existing 228 plus the new test
at 0:0 / 0:3 / 2:9. **Every instruction count is identical** to baseline at the
same latency. QEMU comparison: **57 agree, 0 differ**. Instrumentation alone
changed no cycles. Critical-word-first changes 101 runs across 34 tests; all
other tests remain cycle-identical, including `gba_arm` (8,183 / 10,785 / 17,742)
and `gba_thumb` (4,917 / 6,509 / 10,831).

Total over all 231 runs: **21,395,209 → 21,385,393 cycles**, a reduction of
9,816 (**0.046%**). The original 228 runs save 10,014 cycles (0.047%); the new
test adds 198 across its three runs. These are testbench results, not gameplay
estimates. Small regressions are retained and listed: fill ordering changes
front-end availability and bus scheduling, and the full-fill execution gate
remains. No claim that critical-word-first makes every instruction stream
faster is warranted.

Every test whose count moves (before → after):

| Test | 0:0 before → after | 0:3 before → after | 2:9 before → after |
|---|---:|---:|---:|
| btb_early | 59,504 → 59,481 | 86,073 → 86,040 | 153,641 → 153,547 |
| cache | 752,437 → 752,424 | 861,284 → 861,289 | 1,130,306 → 1,130,292 |
| cache_rtl | 60,260 → 60,251 | 87,988 → 87,982 | 158,774 → 158,738 |
| cp15 | 3,847 → 3,821 | 4,930 → 4,933 | 7,675 → 7,678 |
| crand1 | 72,636 → 72,638 | 104,148 → 104,142 | 186,981 → 186,951 |
| crand2 | 73,017 → 73,007 | 104,579 → 104,577 | 187,546 → 187,513 |
| crand3 | 73,082 → 73,104 | 104,977 → 104,971 | 188,125 → 188,103 |
| crand4 | 73,636 → 73,629 | 105,132 → 105,141 | 188,177 → 188,139 |
| crand5 | 73,100 → 73,083 | 104,619 → 104,607 | 187,644 → 187,616 |
| crand6 | 73,195 → 73,192 | 105,036 → 105,031 | 188,616 → 188,592 |
| crand7 | 72,768 → 72,763 | 104,251 → 104,243 | 187,058 → 187,027 |
| crand8 | 73,034 → 73,032 | 104,700 → 104,705 | 187,656 → 187,620 |
| ctrand1 | 72,379 → 72,370 | 102,177 → 102,170 | 178,836 → 178,801 |
| ctrand2 | 72,442 → 72,438 | 102,204 → 102,198 | 179,025 → 178,988 |
| ctrand3 | 72,410 → 72,377 | 102,200 → 102,189 | 178,873 → 178,843 |
| ctrand4 | 72,429 → 72,420 | 102,555 → 102,550 | 179,355 → 179,325 |
| ctrand5 | 72,363 → 72,357 | 102,181 → 102,171 | 178,877 → 178,842 |
| ctrand6 | 72,382 → 72,377 | 102,158 → 102,140 | 178,893 → 178,864 |
| ctrand7 | 72,223 → 72,222 | 102,027 → 102,024 | 178,754 → 178,726 |
| ctrand8 | 72,347 → 72,346 | 102,122 → 102,104 | 178,849 → 178,820 |
| dcwf | 74,403 → 74,362 | 105,986 → 105,964 | 188,165 → 188,022 |
| dcwf_rtl | 59,840 → 59,791 | 87,757 → 87,713 | 159,332 → 159,164 |
| dhold_rtl | 273,120 → 273,080 | 342,784 → 342,690 | 518,764 → 518,563 |
| dhum_rtl | 483,052 → 483,070 | 509,160 → 509,170 | 575,392 → 575,387 |
| dstore_rtl | 188,465 → 187,563 | 214,565 → 213,658 | 280,632 → 279,703 |
| fiq_movs | 16,927 → 16,923 | 18,491 → 18,490 | 22,902 → 22,899 |
| icache_restart | 76,251 → 74,608 | 103,292 → 101,615 | 171,981 → 170,269 |
| icache_rtl | 58,050 → 58,035 | 85,236 → 85,224 | 154,390 → 154,361 |
| icwf_rtl | 60,701 → 60,783 | 88,253 → 88,323 | 158,421 → 158,467 |
| iprefetch_rtl | 73,127 → 73,120 | 104,171 → 104,171 | 184,176 → 184,164 |
| loadpipe | 82,484 → 82,469 | 109,276 → 109,231 | 177,612 → 177,567 |
| loaduse | 60,626 → 60,592 | 88,009 → 87,955 | 158,149 → 158,006 |
| loaduse_irq | 119,676 → 119,642 | 149,477 → 149,467 | 225,624 → 225,614 |
| tcallpipe | 95,080 → 95,074 | 124,702 → 124,675 | 204,675 → 204,645 |

The largest reductions are in `icache_restart` (1,643 / 1,677 / 1,712 clocks)
and `dstore_rtl` (902 / 907 / 929 clocks). The new installed-line test grows by
82 / 70 / 46 clocks despite the independently checked earlier critical-word
arrival. Its retired instructions, uops, architectural values and replay count
are unchanged; it is a correctness/ordering test, not a promised speedup.

Additional checks on the final source:

- `ICACHE_PREFETCH=1`: **24/24** focused runs (eight tests at all three
  latencies), including `icwf_rtl`, `icache_restart`, `iprefetch_rtl`, cache,
  compiled random tests and MMU pages. Prefetch remains disabled in the build.
- Long-latency stress: **18/18** runs, six tests at 2:31 with RNG seeds 2, 7,
  and 19, including all-beat I-fill error injection and mixed I/D traffic.
- `make -C sim sdram ddrflash upp periph top`: all pass. UPP runs both the
  default and 256 KB on-chip RAM configurations. Existing flash coverage
  includes cold/warm wrap-4 at every offset, read-array versus command/status
  modes, writes/erase, and chip-window boundaries. Warm wrap-4 line reads
  remain eight clocks at each of +0/+4/+8/+12 in both UPP configurations.
- Final top bench: **150,622,764 clocks**, all checks pass. The decoder reads
  its actual rendered loader image correctly at the new word positions.
- `make lint` and debug `verilator --lint-only -Wall --top-module emu
  -DNGAGE_DEBUG=1 -f lint/rtl.f`: pass. `tools/gen_cpu.sh` and
  `make cpu-gen-check`: pass; generated `input reg` count **10**.

CPU signatures/traces in `sim/cpu/build/rtl` remain from the final default
231-run suite. Optional/stress runs wrote separate logs, not those references.
Detailed baseline, instrumentation, final CPU counts/logs and board-bench logs
are retained under ignored `build/memside1/` (`baseline/`, `instrument/`, `cwf/`,
`prefetch/`, `stress/`, `board-benches.log`, and `cycles.md`).

### Timing discipline and limits

The demand path adds a two-bit start index and a wrap flag, plus the BTE
sideband through existing registered bus boundaries. Small current/next word
sums are formed from registers before ACK selection; the old wide line-base
addition becomes concatenation. Neither the live cache hit compare nor the
fetch ACK predicate gains a new term. There is no pipeline forwarding,
interlock, cache-data timing, or arbiter priority change. BTE selection adds a
sideband mux into the merger's existing output register, not a mux after its
address register. The exact placement/timing effect is unmeasured.

No Quartus build, firmware boot bench, board deployment, or gameplay measurement
was performed, as requested. No Docker container or server process was started.
`sys/`, ARM9/ARM9-v2, and the parked timing branch are untouched. The shared
cache/merger interfaces now expose I-side BTE and debug outputs; the separate
ARM9-v2 integration must connect the new BTE input when taking these files.
Only ZAP is wired into this master's CPU bench; this is not an ARM9-v2 run.

## Next-task handoff: deferred write-back in the merger

No merger buffer or priority change is implemented here. The current
`UNLOCK_REG` installs the new line and launches saved-victim beat zero on the
same edge, then remains in `CLEAN_SINGLE` until four beats drain. It already
uses the saved immutable `cache_line`/physical tag, without occupying a RAM
read port. The line can serve hits after the registered installation-visibility
delay; the victim line stays excluded. A held access then takes the existing
lookup-repair path before IDLE.

A future handoff must transfer ownership of that immutable line atomically,
keep a buffer-full backpressure path, retain physical-alias ordering (including
same-PA dirty VIVT replacement, which deliberately cleans before filling), and
cover the buffered address after the FSM has returned to IDLE. New misses,
uncached/write-through accesses, TLB walks and maintenance currently serialize
behind the FSM; returning it to IDLE changes that ordering contract. In
particular `o_writeback_busy` and CP15 c7,c10,4 must include the merger's pending
drain, not just the cache's state. Invalidation cannot cancel a dirty buffered
write. Read-priority arbitration must preserve each accepted burst and must
not starve a required maintenance drain. Those are next-task requirements,
not changes folded into this measurement step.

## Exact stopping point

Both requested pieces are implemented and verified. The branch stops with the
critical-word-first change and this report committed on `codex/memside`, with
no uncommitted changes. No merger write-back buffer, arbitration-policy change,
early-execution bypass, extra cache capacity, or CPU pipeline change has been
started. The only `zap_core` edit is the two combinational debug observations.
The next action is the owner's measurement-core build (`NGAGE_DEBUG=1`) and
matched gameplay capture using the new decoder, before deciding the next
memory-side change. No board-speed or timing result is claimed for this branch.
