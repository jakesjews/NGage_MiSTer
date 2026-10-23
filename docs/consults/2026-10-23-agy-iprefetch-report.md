# I-cache sequential prefetch and a 32 KB option, 2026-10-23

Antigravity's work, on `agy/iprefetch`, starting from `b3a164e`. The
implementation is commit `5e50f59`. The changes are in the instruction cache
(`zap_cache.sv`, `zap_cache_fsm.sv`, `zap_cache_tag_ram.sv`), with plumbing
in `zap_top.sv`, `arm925t.sv`, `NGage.sv`, `NGage.qsf` and the bench
(`tb_cpu.sv`), a new test `sim/cpu/tests/iprefetch_rtl.S`, and a note in
`docs/CPU.md`. No D-cache, pipeline-stage, RAM-primitive or `sys/` file was
touched.

Summary:

- **Both work and are verified.** `make -C sim/cpu run diff` gives 201/201
  pass and 52/52 agree with QEMU in four configurations: 16 KB with prefetch
  (the new default), 32 KB with prefetch, 16 KB without, and 32 KB without.
  `make lint` and `make cpu-gen-check` are clean.
- **With the prefetch off the core is cycle-identical to `b3a164e`** on all
  198 earlier runs (66 tests at three latencies), so `ICACHE_PREFETCH=0` is
  the accuracy build.
- **The prefetch gain in simulation is small.** It saves 0.01 to 0.8 % per
  test, 0.14 % over the whole suite. The reason (section 4) is that
  sequential misses were already nearly back to back: the fetch runs ahead
  through the FIFO, and an early-restart fill is followed at once by the
  next line's miss. The prefetch removes the 2 to 4 clocks between one fill
  and the next. It also uses the idle bus while the FIFO is full. It cannot
  beat the bus bandwidth, and in these tests the bus is the limit. Whether
  the games gain more must be measured on the board (section 7).
- **32 KB costs 16 more M10K blocks** (36 instead of 20 for the I-cache's
  data and tag RAMs). It changes nothing in these tests, because their code
  fits in 16 KB.

## 1. The prefetch

State, in `zap_cache_fsm.sv`, present only when `PREFETCH=1`:

- A one-line buffer: VA line, PA line, four words, `valid`, and the beats
  received so far.
- `active` (a prefetch burst is on the bus), `pend` (one is waiting for the
  bus), and `drop` (the burst in flight is to be discarded when it ends).

**Start.** In `FILL_COMPLETE`, as the demand line is installed, the
prefetch starts if all of these hold:

- the fill had no error and was a read (I-side fills always are);
- the cache is on, not being invalidated or cleaned, and not being
  cleared;
- the current lookup has no fault and no TLB walk, is cacheable, and is
  still in the filled line or already in the next one (sequential flow);
- the next line is in the same 1 KB block;
- the one-cycle tag copy (below) says the next line is not in the cache;
- the buffer does not already hold that line.

If the bus is free, the burst starts at once at `PA + 16`. Otherwise
`pend` is set. The bus counts as busy when:

- the D side has a request, an acknowledge or a lock;
- a CP15 D-side operation is in progress;
- the I-side TLB is walking;
- the I-side tag-RAM or TLB managers hold the bus.

A pending prefetch starts on a later cycle when the bus is free and the
I-side is hitting or idle. Any I-side miss, fault, TLB walk, uncacheable
access, invalidate or clean drops it. The brief said a waiting prefetch is
dropped by a demand request; here a D-side request only holds it back.
Holding it back does not delay the D side, which already owns the bus. The
D side's next request can find the prefetch burst on the bus, as it can
after any I-side fill.

**Page rule.** 1 KB is the smallest unit of translation and permission on
the ARM925T: tiny pages, and the four 1 KB subpage AP fields of a small
page. A line in the same 1 KB as the line just filled has the same
translation, permissions and cacheability. The prefetch therefore needs no
new translation and never crosses a page end. The cost is no prefetch for 1
line in 64, against 1 in 256 with 4 KB pages.

**Use.** A fetch that misses the cache is answered from the buffer when:

- the buffer's VA line equals the lookup's. This 28-bit compare against
  `i_address` runs in parallel with the cache's hit compare in the tag RAM;
- the buffer's PA line equals the live translation's;
- there is no clear.

The word comes from `pf_word_ff`, a register loaded with the next lookup's
word (indexed like the fill buffer's `response_dat_ff`). The FSM copies the
four words into the fill buffer and goes to `FILL_COMPLETE`. That state
installs the line into the LRU victim way exactly as a demand fill would,
answering ready words directly as before. Words served from the buffer are
not provisional: the whole line has already arrived without error.

A miss on the line currently being prefetched **adopts** the burst. The
words received so far become the fill buffer's valid words, and the FSM
continues in `FETCH_SINGLE` as a normal early-restart fill: the remaining
beats come from the same burst, the words are provisional until it ends,
and errors behave as before. A burst that has already seen an error is not
adopted. The demand miss then waits and refetches, so the abort is precise
and comes from its own fill. A miss on any other line waits for the burst
in flight to end. A cache hit on the line in the buffer invalidates the
buffer.

**The tag copy** (`zap_cache_tag_ram.sv`, `g_prefetch`). A second tag store
holds only the VA tag: one `LINES x TAG_W` RAM per way, written with the
demand tag RAM and read in one cycle at `o_pf_addr` (the line after the
current lookup). It is compared with the valid bits, forwarding the pending
write-behind tag write. Its only use is to avoid prefetching a line already
in the cache. A wrong answer either costs a useless prefetch or skips a
useful one; it cannot affect correctness. The demand tag RAM, its 3-stage
pipeline and its hit compare are untouched.

**Clears.** The buffer is dropped, in any FSM state, and a burst in flight
is marked to be discarded, on:

- the I-cache invalidate (c7,c5,0; c7,c5,1 is implemented as the whole
  flush) and the I-side clean request;
- the cache turned off;
- an I-TLB invalidate;
- a D-cache clean, invalidate or line operation (the code-modification
  sequence);
- any change of MMU enable, S/R, TTB or DACR;
- an error beat in its own burst.

The TLB, D-side and control-register terms are registered, so they act one
cycle late. This keeps eight 32-bit compares off the fetch acknowledge. It
is safe because a buffer hit is checked against the live translation
(fault, cacheable, PA), exactly as a cache hit is; the virtually tagged
cache itself is not flushed by any of these.

**Fix found on the way.** `fill_valid_ff`, `fill_fault_ff` and
`fill_ready_ff` were cleared only in IDLE-to-IDLE cycles. A fill started
from IDLE in the cycle right after `FILL_COMPLETE` therefore inherited the
previous line's valid mask. `FILL_COMPLETE -> IDLE -> FETCH_SINGLE`
happens all the time with the prefetch on, and the result was stale words
(`icache_restart`, `cache`, `dcwf`, `dhold_rtl` failed). They are now
cleared whenever the next state is IDLE. Without the prefetch, all 198
earlier runs are cycle-identical to before, so this path does not occur
there.

**Switch.** `ICACHE_PREFETCH` on `arm925t` (default 1), passed through
`zap_top`'s `CODE_CACHE_PREFETCH` to `zap_cache`. With 0, the prefetch
state, the tag copy and the extra ports are constant or absent: the
generate branch and the `PREFETCH &&` terms remove them.

## 2. 32 KB

ZAP's index and tag fields (`ZAP_VA__CACHE_INDEX`, `ZAP_VA__CACHE_TAG`,
`ZAP_CACHE_TAG_WDT`) are already derived from the size. With
`ICACHE_SIZE=32768`:

- each way has 1,024 sets (VA[13:4]);
- the VA tag is VA[31:14] (18 bits; the tag RAM word is 46 bits instead of
  47);
- the LRU array is 1,024 bits, the valid array 2,048 bits;
- the prefetch's tag copy is 1,024 x 18 per way.

The CP15 cache type register still reports 16 KB (it is a separate
parameter, `CP15_CTYPE`). Software sees the phone's geometry; I-cache
maintenance is whole-cache, so the difference is invisible to it.

Building it:

- **Quartus:** uncomment
  `set_global_assignment -name VERILOG_MACRO "NGAGE_ICACHE_32K=1"` in
  `NGage.qsf`. `NGage.sv` turns the macro into `ICACHE_SIZE=32768` on
  `arm925t`. The neighbouring `NGAGE_ICACHE_NO_PREFETCH=1` line gives the
  accuracy build. Macros are used because `set_parameter` in the qsf
  applies to `sys_top`, not to `emu`.
- **Bench:** `make -C sim/cpu MODEL_DIR=... VEXTRA=-GICACHE_SIZE=32768 run`
  (and `-GICACHE_PREFETCH=0`). The generated netlist keeps both parameters.

The `emu` top lints clean with neither, one or both macros defined.

**M10K cost.** From the last whole-core fit's hierarchy table
(`NGage_MiSTer-sweep`, 470 of 553 blocks). The 16 lane RAMs of a way share
one address and are packed together. One M10K is 512 x 20 or 1,024 x 10.

| I-cache RAM | 16 KB | 32 KB |
|---|---:|---:|
| data, 2 ways x (sets x 128) | 14 (7 per way, 512 x 20) | 26 (13 per way, 1,024 x 10) |
| tag, 2 ways x (sets x 47 / 46) | 6 (3 per way) | 10 (5 per way) |
| subtotal | **20** | **36 (+16)** |
| prefetch tag copy, 2 ways x (sets x 19 / 18) | +2 | +4 |

Totals against the last fit:

| Build | M10K |
|---|---:|
| Default (16 KB + prefetch) | about 472 |
| 32 KB + prefetch | about 490 |
| 32 KB without prefetch | about 486 |

All fit in 553. The 32 KB figures are computed, not fitted. The ALM side
grows too:

- the valid and LRU arrays are flip-flops with read multiplexers;
- 32 KB adds 1,024 valid and 512 LRU bits and doubles their multiplexers;
- the prefetch adds a third read of the valid bits (at the next line's set)
  and its own state: a few hundred flip-flops (the four-word buffer, its
  addresses and word register, and the copies of TTB and DACR for change
  detection).

Expect some hundreds of ALMs at 80 % utilisation; a fit will say.

## 3. The test, `iprefetch_rtl`

The test is RTL only (`@@ qemu: no`: bench cycle counter, MMU set-ups). It
uses its own MMU map: identity sections, cacheable, with a coarse table at
0x00500000.

1. **Sequential code over 32 lines.** Each line is
   `mla; add; add; add`; the last ends with `mov pc, lr`. The test runs:
   - a cold pass;
   - a warm pass, after rewriting line 1 behind the I-cache: the old code
     still runs, which shows that the line served from the buffer was
     installed;
   - a cold pass over 32 lines that branch backwards, line by line, with no
     sequential reuse.

   It checks the results exactly and the shape loosely:
   warm < cold sequential < cold backward.
2. **1b. Execution-bound lines** (`mla; mla; mla; add`), cold and warm.
   It checks the results exactly and warm < cold.
3. **Branch away.** A line ends in a branch to another set, so the line
   after it is prefetched and abandoned. Then the target's next line is
   prefetched, overwriting the buffer. Checks: the results; that both lines
   run correctly afterwards; and that after the abandoned line is rewritten
   and invalidated by MVA, the new code runs.

   I first wrote this case to check that the abandoned line was *not*
   installed. That check is wrong even with the prefetch off: the
   wrong-path fetches past the branch fill that line, and they do so on the
   phone too. Only the contents are architectural, so the test now checks
   only those.
4. **Invalidation with code rewritten behind the buffer**, each a separate
   case: invalidate all (c7,c5,0), and invalidate by MVA (c7,c5,1). The new
   code must run, not the buffered line.
5. **Page ends.**
   - (a) Sequential code from the last 64 bytes of a 4 KB page into the
     next VA page. That page is mapped to a different PA (0x00504000), and
     poison (`mov r0, #0xEE`) sits at the contiguous PA (0x00501000).
   - (b) Sequential code up to the last instruction of a page whose
     successor is unmapped. It must take no abort and give exact results.

The test passes with and without the prefetch, at 16 KB and at 32 KB, at
all three latencies.

## 4. Cycles

All counts are bench cycles from the logs' `PASS (N cycles, M
instructions)` lines. Before = `b3a164e`. Instruction counts are identical
in every configuration, except three runs of two interrupt tests:
`fiq_movs` (0:3) and `loaduse_irq` (0:3, 2:9). Their interrupts are raised
a number of *cycles* after a bench write, so the instruction count follows
the timing (their baseline counts also differ between latencies). Both
pass and agree with QEMU.

| test | lat | instr | before | no prefetch | 16 KB + pf | 32 KB, no pf | 32 KB + pf | pf vs before |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| icache_rtl | 0:0 | 12,771 | 62,332 | 62,332 | 62,312 | 62,332 | 62,312 | -0.03 % |
| icache_rtl | 0:3 | 12,771 | 89,179 | 89,179 | 89,102 | 89,179 | 89,102 | -0.09 % |
| icache_rtl | 2:9 | 12,771 | 157,119 | 157,119 | 157,143 | 157,119 | 157,143 | +0.02 % |
| cache | 0:0 | 293,427 | 793,607 | 793,607 | 793,516 | 793,607 | 793,516 | -0.01 % |
| cache | 0:3 | 293,427 | 921,249 | 921,249 | 921,100 | 921,249 | 921,100 | -0.02 % |
| cache | 2:9 | 293,427 | 1,253,790 | 1,253,790 | 1,253,714 | 1,253,790 | 1,253,714 | -0.01 % |
| ctrand1 | 0:0 | 16,159 | 77,298 | 77,298 | 77,171 | 77,298 | 77,171 | -0.16 % |
| ctrand1 | 0:3 | 16,159 | 106,778 | 106,778 | 106,569 | 106,778 | 106,569 | -0.20 % |
| ctrand1 | 2:9 | 16,159 | 182,278 | 182,278 | 182,106 | 182,278 | 182,106 | -0.09 % |
| crand1 | 0:0 | 15,982 | 78,285 | 78,285 | 78,122 | 78,285 | 78,122 | -0.21 % |
| crand1 | 0:3 | 15,982 | 109,477 | 109,477 | 109,063 | 109,477 | 109,063 | -0.38 % |
| crand1 | 2:9 | 15,982 | 190,634 | 190,634 | 190,341 | 190,634 | 190,341 | -0.15 % |
| iprefetch_rtl | 0:0 | 15,255 | - | 77,734 | 77,530 | 77,734 | 77,530 | -0.26 % (vs no pf) |
| iprefetch_rtl | 0:3 | 15,255 | - | 108,457 | 108,232 | 108,457 | 108,232 | -0.21 % (vs no pf) |
| iprefetch_rtl | 2:9 | 15,255 | - | 187,156 | 187,045 | 187,156 | 187,045 | -0.06 % (vs no pf) |

Whole suite, 198 earlier runs: 17,452,549 before, the same without the
prefetch, and 17,428,449 with it (-0.14 %).

| Largest gains | lat | before | change |
|---|---|---:|---:|
| `dhold_rtl` | 0:3 | 350,616 | -2,760 (-0.79 %) |
| `dhold_rtl` | 0:0 | 279,732 | -2,112 (-0.76 %) |
| `dcwf` | 0:3 | 110,449 | -635 (-0.57 %) |
| `crand2`, `crand3` | 0:3 | | -0.45 % |

The few increases are at 2:9: `icache_rtl` +24, `btb_early` +66. A
prefetch burst that turned out useless was on the bus when the branch
target missed, and the demand fill waited for it. That is the one cost the
design accepts.

With 32 KB, every test's code fits in 16 KB, so the size changes nothing
except `dhold_rtl`. There the different set mapping costs +10 to +167
cycles without the prefetch, and +33/+14/-12 with it.

`iprefetch_rtl`'s own sections are 32 lines (512 bytes) each, in cycles
read from the bench counter:

| section | lat | no prefetch | prefetch | warm |
|---|---|---:|---:|---:|
| sequential, cold | 0:0 | 411 | 345 | 278-284 |
| | 0:3 | 622 | 562 | 304-306 |
| | 2:9 | 1,166 | 1,112 | 315-338 |
| execution-bound, cold | 0:0 | 673 | 673 | 662 |
| | 0:3 | 698 | 701 | 678-682 |
| | 2:9 | 1,186 | 1,134 | 713-716 |
| backward (no sequential use), cold | 0:0 / 0:3 / 2:9 | 862 / 1,104 / 1,710 | 871 / 1,101 / 1,702 | |

**Why so little.**

- **Sequential code is bus-bound.** Without the prefetch, an early-restart
  fill hands its words to the FIFO as they arrive. The fetch, a FIFO ahead
  of decode, is already at the next line when the fill ends, and the next
  demand fill starts within a few clocks. The bus log of the cold pass at
  0:0 shows bursts 9 clocks apart with the prefetch, 4 beats in 7 clocks
  plus a 2-clock gap. That is the execution rate of the code (warm: about 9
  clocks a line), so the stream became execution-bound.

  At 0:3 and 2:9 a line fill takes longer than executing it, so both
  versions run at the bus rate. The prefetch saves only the turnaround
  between bursts: 54 to 66 cycles over 32 lines, about 2 a line, at
  every latency.
- **The execution-bound variant**, slower than a fill at 0:0 and 0:3, has
  almost no miss cost to remove even without the prefetch (673 cold
  against 662 warm). The fetch already reaches the next line, through the
  FIFO, before decode needs it. At 2:9 the fill is slower again, and the
  prefetch saves about 1.6 clocks a line.
- **Branchy code is unaffected.** The backward pass (a miss on every line,
  no sequential use) costs the same either way, within ±10 cycles.

So the prefetch helps where the bus is idle between misses and the miss
latency is exposed:

- when the FIFO is full behind a stalled issue stage and the fetch has
  stopped (the case the board counters show half the time);
- in the 2 to 4 clocks of each fill-to-fill turnaround.

The games' fills are 12-15 clocks from SDRAM and 8-24 from flash, against
about 15 clocks to execute a line at CPI 3.7. The first case may be more
common there than in these tests. Only the board can say how much.

## 5. Timing

- **Demand path unchanged.** The tag RAM's compare and select and the
  pipelined demand RAMs are as before. The tag copy is a separate RAM, and
  its compare goes only to the prefetch's start condition (registered
  path).
- **The fetch acknowledge** (`o_ack`, which `code_stall` uses
  combinationally) gains one term for a cache miss:
  `pf_va_hit && !pf_clear && pa_match`. These are a 28-bit compare of a
  register with `i_address`, in parallel with the tag RAM's compare, and a
  28-bit compare with the TLB's physical address. The TLB output already
  feeds `o_ack` through `i_fault` and `i_cacheable`, so this term is not on
  a deeper path than those, but it widens the `o_ack` cone.
- **The control-register and D-side clear terms are registered** (section
  1), so only `i_cache_en` and the invalidate/clean requests stay
  combinational.
- **The data** comes from a register (`pf_word_ff`) into the existing
  `o_dat` select, which gains one 2:1 level ahead of the ways' word
  select.

If the fit shows `o_ack` or `o_dat` getting worse, two changes are cheap.
The PA compare could be registered: a VA match implies a PA match, since
every translation change drops the buffer. Or the buffer hit could be
answered a cycle later through `FILL_COMPLETE`, as a fill is.

## 6. Risks

- **A useless prefetch delays the next demand miss**, I-side or D-side, by
  up to one line fill, because a burst in flight completes. In the suite
  the net effect is still positive, but a workload of short sequential runs
  ending in branches to cold code could lose. The `+24`/`+66` at 2:9 are
  examples.
- **Extra bus traffic.** Prefetched lines that are never used still cost an
  SDRAM or flash burst. With the D side already waiting 20-23 % of clocks
  on SDRAM, this traffic competes with it. The prefetch never starts while
  the D side holds or requests the bus, but it can be on the bus when the D
  side's next request comes.
- **The early-restart interaction** is the delicate part. Adoption of a
  burst in flight, buffer hits through `FILL_COMPLETE`, and the
  `fill_valid` clearing bug found here are all in it. `icache_restart`
  (errors on every beat, every offset, ARM and Thumb), `icache_rtl`,
  `cache`, `dcwf`, `dhold_rtl`, the random cached tests and
  `iprefetch_rtl` cover it at three latencies. Bus errors *in a prefetch
  burst* are covered only indirectly: an erroring burst is never used, and
  the demand fill gets the error itself. No test injects an error into a
  prefetch burst that is later adopted (adoption is refused after an error
  beat).
- **32 KB:** the valid and LRU arrays and their multiplexers double. That
  costs ALMs, and the valid read sits on the hit path (`valid_q`, already
  pipelined). It needs a fit.

## 7. Not covered

- **No whole-core build or fit, and no board measurement.** The M10K
  numbers are computed from the last fit's packing; the ALM and timing
  effects are unknown. The board counters (FIFO empty, code stall, SDRAM
  and flash wait, instructions a second) are the real measure.
- **The whole-core bench `make -C sim top`** does not build in this
  worktree, before or after the change: `build_id.v` is generated by the
  Quartus flow. The `emu` top was linted instead, with and without the
  macros.
- **Thumb-specific prefetch sequences** are covered only through the
  existing Thumb tests (`icache_restart`, `trand*`, `ctrand*`, `gba_thumb`),
  not by `iprefetch_rtl`.
- **Self-modifying code without the required invalidate** is
  architecturally unpredictable. With the prefetch, a line can be stale in
  the buffer as well as in the cache; the D-side clean/invalidate clear
  narrows the window but does not define it.
- **Prefetching further ahead (two lines, or a stream buffer)** was not
  tried. Section 4 suggests it would not help here: with sequential streams
  bus-bound and the FIFO already covering one line ahead, more lookahead
  mostly adds useless bursts.
