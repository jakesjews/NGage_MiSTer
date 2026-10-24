# memside3: guaranteed I-fill execution

2026-10-24. Branch `codex/memside3`, based on master `8e965db` (the RTL is
`7d429fe`; the following commits only record measurements). No merger victim
buffer was carried over. Implementation and directed tests: `cb49df3`.
`codex/memside` and `codex/timing2` remain parked.

## Design and target contract

The memory bridge supplies `wb_no_late_error` with the first acknowledged beat
of a full-word, 16-byte wrap-four read. A true value promises that the remaining
three beats cannot return a bus error. It is a guarantee of the target and the
accepted transaction, not a prediction based on the absence of an error so far.
A target with no such guarantee supplies zero. Reset cancels both producer and
consumer; it is not a successful continuation of an accepted transaction.

`upp_bus.no_late_error_q` records the class when accepting the target, before
its registered first ACK. The flash mode must be sampled there: accepting a
flash line read makes `bus_array` go low while the line port is active. Sampling
the live mode at ACK would incorrectly reject a valid array fill.

| Target | Early execution class | Reason |
|---|---|---|
| SDRAM, including its mirror | Guaranteed | The controller returns busy/data-valid/data; there is no per-beat error channel. Wrap-four stays inside one decoded 16-byte line. |
| On-chip RAM, including mirrors | Guaranteed | BRAM reads cannot report ERR. The optional 256 KB SDRAM-backed implementation uses the same error-free SDRAM response. |
| CS0 and CS1 flash, ordinary array line reads, including mirrors | Guaranteed | `fl_line_ok` requires the flash array port to be idle and in read-array mode. NOR line reads and the DDR3 backing interface return data-valid/data without an error channel. Accepted bursts retain ownership, so another bus master cannot issue a mode-changing command between beats. |
| Flash autoselect, CFI, command sequences, program/erase busy, erase suspend and read-while-write | Conservative | These use the halfword command/status path, not the guaranteed array line port. Even other-bank array data while an operation is active stays conservative. |
| EMIF registers, peripherals, empty CS2/CS3 and unmapped targets | Conservative | No executable-memory guarantee is assigned. Unmapped errors are decided on access; they never earn the attribute. |
| Classic/uncached reads, writes, partial-word reads, linear or wrap-eight/sixteen bursts | Conservative | Outside the promised transaction shape. |

A hung SDRAM/DDR3 transaction still hangs; the guarantee does not promise a
completion deadline or detect physical memory corruption. If a future target
adds a late-error response, it must stop advertising this guarantee or provide
its own stronger validation before the first ACK.

The sideband travels through `ngage_mem`, `NGage`, `arm925t`, `zap_top`, the
CODE owner of `zap_wb_merger`, and `zap_cache`. ACK ownership already selects the
consumer; the sideband is sampled only with that consumer's accepted beat.
The merger adds no state and does not alter ACK, request arbitration or address
selection. The cache wrapper's existing CCH/TLB ACK selection prevents a page
walk's response from being mistaken for a fill beat.

`zap_cache_fsm.fill_no_late_error_ff` samples the first demand beat together
with its data and valid bit. Only a successful first beat of a 16-byte wrapped
demand fill qualifies. `o_fill_pending` then deasserts during `FETCH_SINGLE`;
`fill_ready_ff` still checks the requested word's validity and line identity,
and the existing registered `response_dat_ff` supplies the word. There is no
new term in the hit compare, cache ACK or data select.

`o_fill_pending` describes execution quarantine, not physical fill occupancy.
The debug fill/wait taps still count the complete bus transaction. The tag is
still installed only after the entire fill succeeds. Translation, permissions,
cacheability, cache controls and redirect checks are unchanged. Uncached
fetches still use `UNC_DONE`. Prefetch is off by default; an adopted linear
prefetch remains quarantined, including adoption after its first beat.
Non-16-byte cache-line configurations remain conservative.

For an error-capable fill, successful early words retain their provisional FIFO
bits. Any later error is sticky, suppresses installation and resolves those
words to precise prefetch aborts on completion. Reset and redirects retain the
existing discard rules. An assertion rejects a producer that advertises the
guarantee and subsequently returns an error.

## Interface for ARM9 v2

New ports are explicit, with no input-port defaults:

- `upp_bus.wb_no_late_error`, `ngage_mem.wb_no_late_error`: output, meaningful
  with the requesting master's first ACK of the specified burst.
- `arm925t.bus_no_late_error`, `zap_top.i_wb_no_late_error`: input.
- `zap_wb_merger.i_wb_no_late_error` and CODE output
  `o_c_wb_no_late_error`: the registered owner routes the response attribute.
- `zap_cache.i_wb_no_late_error`, `zap_cache_fsm.i_wb_no_late_error`: input,
  sampled on the first demand-fill beat.

Tie the new input low on an unclassified bus. ARM9 v2 can reuse this cache-side
contract: accept `o_ack/o_dat` during `FETCH_SINGLE`, subject to its normal
request/stall handshake, and permit execution only when `o_fill_pending` is
zero. A consumer that accepts provisional words must retain and resolve their
pending status using `o_fill_done/o_fill_fault`, as ZAP already does. A consumer
without that quarantine must withhold acceptance while pending is true.
`i_cache_hit` alone does not represent the early response. No ARM9 files changed.

## State and timing

Two synthesized one-bit registers are added by the cache-side change:

- `upp_bus.no_late_error_q`: target class, reset to zero.
- `zap_cache_fsm.fill_no_late_error_ff`: active demand fill's first-beat promise,
  reset/cleared at IDLE.

No line buffer, RAM, cache tag, data-path stage or live data forwarding is added.
The target decode and flash-array qualifier end at the bridge register. The
cache samples that registered response with its first-beat condition. The new
bit qualifies only execution-pending metadata; ACK and hit timing cones are
unchanged. The assertions and CPU-bench watch counters are simulation-only.
There is no fit or claimed timing number for this task. The board baseline
supplied by the user is the stripped master seed-9 build at -0.734 ns; memside2
was -1.137 ns and was rejected. No Quartus job, firmware boot or board operation
was run here.

## Fetch-register finding

The standalone cache/FIFO test releases the guaranteed first word before beat
two. An end-to-end CPU test found a second, independent wait: `zap_core` uses
`code_stall` both to hold the fetch output register and to inhibit its FIFO
write. A received instruction therefore waits for the *next* fetch ACK before
it is queued. With sequential execution starting at offsets +0/+4/+8, that next
word arrives in this fill, and actual retirement precedes the terminal beat.
At +12 the next sequential word is in another line, so the critical instruction
waits for the current fill and the next response.

This is not a failure of the no-late-error classification. It is a fetch/FIFO
handshake limitation outside the earlier memory-only scope. A one-bit consumed
marker can allow the held fetch word to enqueue once while the next fetch
waits. Scope clarification was requested before changing the ZAP pipeline.

## Verification and cycles

Baseline: 231 runs (77 tests at 0:0, 0:3 and 2:9), 57 QEMU comparisons agree,
21,385,393 total cycles. Existing binaries and QEMU references were reused.
The cache-side gate passes all 231 existing runs, with every instruction count
identical and 57 QEMU comparisons agreeing. Total cycles are 21,378,019
(-7,374); 100 runs of 34 tests move. These synthetic working sets spend much of
their runtime in setup; board measurement remains the performance decision.

Each entry is **before → cache-side gate** cycles. All unlisted existing tests
are cycle-identical at all three latencies.

| Test | 0:0 | 0:3 | 2:9 |
|---|---:|---:|---:|
| btb_early | 59,481 → 59,464 | 86,040 → 85,992 | 153,547 → 153,500 |
| cache | 752,424 → 752,427 | 861,289 → 861,275 | 1,130,292 → 1,130,174 |
| cache_rtl | 60,251 → 60,236 | 87,982 → 87,964 | 158,738 → 158,594 |
| cp15 | 3,821 → 3,821 | 4,933 → 4,927 | 7,678 → 7,668 |
| crand1 | 72,638 → 72,620 | 104,142 → 104,118 | 186,951 → 186,941 |
| crand2 | 73,007 → 72,998 | 104,577 → 104,531 | 187,513 → 187,447 |
| crand3 | 73,104 → 73,079 | 104,971 → 104,936 | 188,103 → 188,060 |
| crand4 | 73,629 → 73,628 | 105,141 → 105,075 | 188,139 → 188,074 |
| crand5 | 73,083 → 73,065 | 104,607 → 104,564 | 187,616 → 187,540 |
| crand6 | 73,192 → 73,171 | 105,031 → 105,026 | 188,592 → 188,548 |
| crand7 | 72,763 → 72,745 | 104,243 → 104,223 | 187,027 → 186,932 |
| crand8 | 73,032 → 73,015 | 104,705 → 104,681 | 187,620 → 187,518 |
| ctrand1 | 72,370 → 72,345 | 102,170 → 102,025 | 178,801 → 178,528 |
| ctrand2 | 72,438 → 72,419 | 102,198 → 102,057 | 178,988 → 178,692 |
| ctrand3 | 72,377 → 72,336 | 102,189 → 102,078 | 178,843 → 178,575 |
| ctrand4 | 72,420 → 72,393 | 102,550 → 102,421 | 179,325 → 179,033 |
| ctrand5 | 72,357 → 72,344 | 102,171 → 101,970 | 178,842 → 178,540 |
| ctrand6 | 72,377 → 72,375 | 102,140 → 102,017 | 178,864 → 178,539 |
| ctrand7 | 72,222 → 72,177 | 102,024 → 101,878 | 178,726 → 178,424 |
| ctrand8 | 72,346 → 72,336 | 102,104 → 101,937 | 178,820 → 178,437 |
| dcwf | 74,362 → 74,379 | 105,964 → 105,959 | 188,022 → 188,342 |
| dcwf_rtl | 59,791 → 59,743 | 87,713 → 87,725 | 159,164 → 159,122 |
| dhold_rtl | 273,080 → 272,925 | 342,690 → 343,025 | 518,563 → 518,849 |
| dhum_rtl | 483,070 → 483,318 | 509,170 → 509,422 | 575,387 → 575,635 |
| dstore_rtl | 187,563 → 187,484 | 213,658 → 213,558 | 279,703 → 279,622 |
| fiq_movs | 16,923 → 16,933 | 18,490 → 18,490 | 22,899 → 22,897 |
| icache_restart | 74,608 → 74,438 | 101,615 → 101,272 | 170,269 → 169,440 |
| icache_rtl | 58,035 → 58,023 | 85,224 → 85,176 | 154,361 → 153,956 |
| icwf_rtl | 60,783 → 60,730 | 88,323 → 88,182 | 158,467 → 158,077 |
| iprefetch_rtl | 73,120 → 73,056 | 104,171 → 103,926 | 184,164 → 183,817 |
| loadpipe | 82,469 → 82,460 | 109,231 → 109,181 | 177,567 → 177,374 |
| loaduse | 60,592 → 60,576 | 87,955 → 87,970 | 158,006 → 157,942 |
| loaduse_irq | 119,642 → 119,641 | 149,467 → 149,464 | 225,614 → 225,582 |
| tcallpipe | 95,074 → 95,060 | 124,675 → 124,651 | 204,645 → 204,604 |

`gba_arm` remains 8,183 / 10,785 / 17,742 cycles; `gba_thumb` remains
4,917 / 6,509 / 10,831. A few counts rise (including cache at 0:0 by three);
the gate permits earlier progress, which can change redirect/replay and
arbitration scheduling. The full table retains those increases.

Final checks:

- Generated RTL: **234 passed, 0 failed** (the original 231 plus
  `icexec_rtl` at three latencies). **RTL vs QEMU: 57 agree, 0 differ**.
  Every original run has the same instruction count as baseline.
- New `icexec_rtl`: **67,477 / 93,717 / 160,349 cycles**, **12,788
  instructions** at each latency. It uses a fixed 20-clock response interval
  during the directed section, measures retirement of the watched VA line,
  checks noncommutative instruction results and warm installed-line execution,
  and records all four entry offsets. It requires early retirement at +0/+4/+8;
  the +12 exception is explicit in the test, rather than hidden by a loose
  cycle threshold. This new bench-dependent test is `qemu: no`.
- `sim/cpu/tools/check_icache_restart.sh`: passes the corrected wrap-four
  address/order checks, first-word FIFO release before beat two at all four
  offsets, per-word waits, line installation, errors on beats two/three/four,
  FIFO full, redirect, reset and provisional-word fault resolution. Changing
  the attribute on a *later* beat cannot release an unsafe fill. Existing
  `icache_restart.S` and its ARM/Thumb late-error assertions are unchanged.
- Conservative negative control (`--icache-quarantine`): **30 runs** of
  cache, dcache_rtl, icache_rtl, ctrand1, crand1, gba_arm, gba_thumb, mmu_page,
  align and icache_restart reproduce baseline cycles **and** instruction
  counts exactly. The new `icexec_rtl` fails its first early-retirement check
  with the attribute forced low, proving that it detects the removed gate.
- Direct SystemVerilog: the three I-cache directed tests also pass all nine
  runs, including assertions. Their instruction counts match generated RTL;
  source-model cycle counts differ slightly. All before/after numbers in this
  report use the generated netlist that Quartus compiles, not a mixed-model
  comparison. The final directed logs were restored with generated-RTL runs.
- `make lint`, debug lint (`verilator --lint-only -Wall --top-module emu
  -DNGAGE_DEBUG=1 -f lint/rtl.f`), `tools/gen_cpu.sh`, and
  `make cpu-gen-check`: pass. Generated `input reg` count remains **10**.
- `make -C sim sdram ddrflash upp periph top`: all pass. UPP checks both
  64 KB BRAM and 256 KB SDRAM-backed on-chip configurations. Its first-ACK
  checks cover every target at every wrap-four start offset, classic/linear
  accesses, both flash chips and mirrors, array reads before/after commands,
  autoselect, program status, erase status and suspended-erase other-bank
  reads. Existing flash word-order, SDRAM protocol and bus checks remain.
  The emu diagnostic bench completes **150,622,764 clocks** with all checks
  passing; this is the requested top bench, not the firmware boot bench.

Evidence is under ignored `build/memside3/`: baseline netlist/model/logs and
`counts.json`, cache-gate/final count snapshots, full run/diff logs, unit and
source-model runs, negative-control logs, both lint logs, gen-check, UPP and
board logs. Existing test binaries and QEMU references were not rebuilt or
rerun; only the new directed test was assembled.

## Exact stopping point

The registered target guarantee and cache execution-quarantine change are
implemented and verified. There are **two new synthesized bits** and no ZAP
pipeline, D-cache, ARM9, `sys/`, arbiter scheduling or victim-buffer changes.
The shared cache now advertises each guaranteed word as executable when its
registered bypass becomes valid. Error-capable fills retain the complete-fill
quarantine.

The original request's strongest end-to-end goal—executing a critical word
without waiting for the next fetch response—is **not fully achieved in ZAP**:
its existing fetch-to-FIFO handshake still delays the word. The +12 case above
makes that visible. That follow-up needs a small ZAP pipeline exception to the
user's earlier rule, “this thread does only memory-side work that both ZAP and
the ARM9 v2 core reuse; no ZAP-pipeline changes.” The scope question is pending;
no permission was inferred from elapsed time. The proposed next change is a
single consumed bit, allowing a held fetch output to enter the FIFO exactly
once while the next cache request waits; it must be verified separately for
full FIFO, redirects, faults and simultaneous replacement of the fetch word.

No board speed gain or timing improvement is claimed. The measurement core can
exercise this cache-side change as it stands, but the fetch handshake limits
its benefit. Stop at the clean `codex/memside3` commits; no merge, push or
whole-core build was performed.
