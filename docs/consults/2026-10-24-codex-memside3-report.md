# memside3: guaranteed I-fill execution

2026-10-24. Branch `codex/memside3`, based on master `8e965db` (the RTL is
`7d429fe`; the following commits only record measurements). No merger victim
buffer was carried over. Implementation and directed tests: `cb49df3`.
`codex/memside` and `codex/timing2` remain parked. The authorized one-bit
fetch-handshake follow-up is documented in the final section below.

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

## Cache-side stopping point at d533b3c (superseded below)

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
the ARM9 v2 core reuse; no ZAP-pipeline changes.” At that commit the scope question was pending;
no permission was inferred from elapsed time. The proposed next change is a
single consumed bit, allowing a held fetch output to enter the FIFO exactly
once while the next cache request waits; it must be verified separately for
full FIFO, redirects, faults and simultaneous replacement of the fetch word.

No board speed gain or timing improvement is claimed. The measurement core can
exercise this cache-side change as it stands, but the fetch handshake limits
its benefit. Stop at the clean `codex/memside3` commits; no merge, push or
whole-core build was performed.

## Authorized follow-up: one-bit fetch/FIFO handshake

The user authorized the specific exception: “allow the one-bit ZAP
fetch-handshake fix ... needed for the shared early-execution gate to pay on
the shipping core.” This follow-up starts from the clean cache-side commit
`d533b3c`; its baseline is a fresh run of all 234 cases and the 57 QEMU
comparisons on that commit. The preceding sections and stopping point describe
that earlier cache-side-only checkpoint, not the final state.

### Implemented ownership rule

The **only new synthesized register in this follow-up** is
`zap_core.fetch_consumed_ff`, one bit. The complete memside3 change therefore
adds three bits including `upp_bus.no_late_error_q` and
`zap_cache_fsm.fill_no_late_error_ff` from the first step.

`fetch_consumed_ff` is set when the fetch register is held, contains a valid
word, and the FIFO has room to accept that word. The FIFO's write inhibit is
this registered consumed bit instead of `code_stall`. The FIFO already rejects
writes while full, in both its data RAM control and pending/fault sidecar.
That full check is unchanged. A held word can consequently enqueue without the
next cache ACK, once only.

On a fetch advance (`!code_stall`), the marker clears: the previous word may
enqueue on this edge, while the replacement starts unconsumed. This also
handles an already-consumed old word: its duplicate write is suppressed and
the newly captured word becomes eligible on the next edge. Invalid replacement
clears the marker but leaves `fetch_valid` false, so it cannot create an entry.
Reset, ALU redirects, decode redirects and writeback clears clear the marker
alongside the existing fetch-register invalidation. Accepted FIFO clears keep
their existing priority over reads and writes.

There are no changes to `zap_fetch_main`, `zap_fifo`, the Thumb decoder,
predecode, branch resolution, instruction cache ACK/data, operand forwarding,
or any pipeline stage boundary. No additional buffer or payload register is
added. The new register consumes existing reset/clear/stall/valid/full controls;
its output is a short registered FIFO write-inhibit path. This adds one load to
those controls, including the existing code-stall qualifier, but adds no term
to the live hit compare or ACK logic. Whole-core timing was not measured here,
as requested.

### Cases and separate verification

`tb_fetch_handshake.sv` instantiates the production `zap_core`. It drives cache
responses, resolved redirect decisions and downstream backpressure; it does
not copy the marker or replace the fetch/FIFO implementation. Its checks cover:

- A held word entering before the next response and never duplicating while
  the fetch register stays valid for multiple clocks.
- Continuous replacements, including enqueue of the old word and capture of
  its replacement on the same edge, and replacement of an already-consumed word.
- A full four-entry FIFO with a fifth word held unconsumed. The held word waits
  for space and the five words emerge once, in order.
- Taken-target and fall-through redirects while the cache response is absent,
  each with consumed and unconsumed held words. It separately discards a cache
  response coincident with a redirect. Decode redirects and writeback exception
  clears are also exercised with their existing accepted-clear priorities.
  The unit supplies the resolved branch decision; the full suite separately
  checks actual branch resolution and prediction.
- An abort-marked fetch entering once while the next response waits. Sleep
  suppresses repeats. Translation and permission aborts have this same fetch
  interface; the new CPU test additionally generates both faults through the
  actual I-TLB and checks their exact abort PCs.
- Error-capable provisional words enqueuing with the marker set, but remaining
  unavailable for execution. Errors corresponding to beats two, three and four
  resolve the queued word to an abort, even though the duplicate held fetch
  copy is suppressed. The original cache/FIFO late-error unit and all unchanged
  ARM/Thumb assertions in `icache_restart.S` also pass.
- All eight Thumb halfword entry positions, preserving instruction data and
  PC+4 alignment; reset with the marker set, followed by reuse of the address.

`ifetch_rtl.S` is the new end-to-end test. At each ARM offset +0/+4/+8/+12 and
each Thumb halfword offset +0/+2/.../+14 it invalidates the I-cache, enters the
code line, checks noncommutative instruction results and requires retirement
of the critical instruction **after beat one and strictly before beat two**.
This is stronger than retirement before the terminal beat and before the next
line's response. Its directed section uses 20-clock beat spacing to allow the
instruction to traverse the full pipeline; instantaneous bus responses cannot
be expected to leave that much retirement time. Warm installed-line calls
also check word placement. A missing translation and an AP=00/S=R=0 cacheable
mapping then verify precise instruction aborts, with no execution from either
faulting address.

The observation is from writeback retirement, not from an implementation
eligibility bit. Bench register `+0x4C` reports words retired in the interval
after the first fill beat and before the second; the existing `+0x48` check now
excludes retirement on the terminal beat itself. These probes and C++ masks
are test-only and add no synthesized state. `icexec_rtl` retains its original
binary and old cache-side baseline counts; only its explanatory source comment
points to the stricter new test.

### Follow-up cycle comparison

All counts below use generated RTL. The **234 existing runs** total
**21,699,562 → 21,411,745 cycles**, saving **287,817 (1.326%)** against the
cache-side gate. All 78 existing tests move at one or more latencies; the table
includes every run, including increases. The new `ifetch_rtl` has no old
baseline: **92,112 / 117,726 / 182,738 cycles**, **13,242 instructions** at each
latency.

The literal “every instruction count identical” check has **nine exceptions**
in four clock-timed IRQ/FIQ tests. The other **225 runs are identical**.
These four tests poll memory waiting for a clock-based interrupt; changing
pipeline speed changes how many polling instructions retire before it is
handled. All their architectural checks pass, and all 57 QEMU comparisons agree.
The exceptions are disclosed below rather than normalized away or hidden by
changing the test binaries, interrupt timers, or reported retirement counts.

| Test | 0:0 cycles before → after | 0:3 | 2:9 |
|---|---:|---:|---:|
| align | 5,291 → 5,076 | 6,945 → 6,433 | 11,373 → 10,287 |
| alu | 2,994 → 2,842 | 4,033 → 3,811 | 6,811 → 6,277 |
| blslot | 1,299 → 1,256 | 1,731 → 1,601 | 2,859 → 2,572 |
| bpred | 1,599 → 1,544 | 2,094 → 1,962 | 3,456 → 3,137 |
| bresolve | 3,007 → 2,830 | 3,960 → 3,707 | 6,376 → 5,902 |
| btb_early | 59,464 → 59,403 | 85,992 → 85,262 | 153,500 → 151,147 |
| cache | 752,427 → 752,357 | 861,275 → 860,838 | 1,130,174 → 1,127,776 |
| cache_rtl | 60,236 → 60,163 | 87,964 → 87,242 | 158,594 → 156,381 |
| cp15 | 3,821 → 3,633 | 4,927 → 4,482 | 7,668 → 6,721 |
| crand1 | 72,620 → 72,510 | 104,118 → 103,452 | 186,941 → 184,617 |
| crand2 | 72,998 → 72,835 | 104,531 → 103,807 | 187,447 → 185,198 |
| crand3 | 73,079 → 72,909 | 104,936 → 104,187 | 188,060 → 185,805 |
| crand4 | 73,628 → 73,534 | 105,075 → 104,273 | 188,074 → 185,824 |
| crand5 | 73,065 → 72,885 | 104,564 → 103,912 | 187,540 → 185,332 |
| crand6 | 73,171 → 73,056 | 105,026 → 104,375 | 188,548 → 186,302 |
| crand7 | 72,745 → 72,642 | 104,223 → 103,471 | 186,932 → 184,677 |
| crand8 | 73,015 → 72,916 | 104,681 → 103,917 | 187,518 → 185,364 |
| ctrand1 | 72,345 → 72,299 | 102,025 → 101,341 | 178,528 → 176,329 |
| ctrand2 | 72,419 → 72,370 | 102,057 → 101,400 | 178,692 → 176,434 |
| ctrand3 | 72,336 → 72,289 | 102,078 → 101,432 | 178,575 → 176,304 |
| ctrand4 | 72,393 → 72,345 | 102,421 → 101,684 | 179,033 → 176,773 |
| ctrand5 | 72,344 → 72,297 | 101,970 → 101,356 | 178,540 → 176,285 |
| ctrand6 | 72,375 → 72,320 | 102,017 → 101,324 | 178,539 → 176,264 |
| ctrand7 | 72,177 → 72,128 | 101,878 → 101,247 | 178,424 → 176,208 |
| ctrand8 | 72,336 → 72,282 | 101,937 → 101,264 | 178,437 → 176,167 |
| dcache_rtl | 58,193 → 58,061 | 85,271 → 84,294 | 154,102 → 151,324 |
| dcsize_rtl | 111,795 → 111,540 | 145,327 → 142,206 | 237,271 → 226,456 |
| dcwf | 74,379 → 74,203 | 105,959 → 105,346 | 188,342 → 185,682 |
| dcwf_rtl | 59,743 → 59,667 | 87,725 → 87,013 | 159,122 → 156,785 |
| dhold_rtl | 272,925 → 272,454 | 343,025 → 341,238 | 518,849 → 514,826 |
| dhum_rtl | 483,318 → 481,506 | 509,422 → 507,077 | 575,635 → 571,724 |
| dstore_rtl | 187,484 → 184,654 | 213,558 → 210,110 | 279,622 → 274,639 |
| exc | 4,228 → 4,072 | 5,663 → 5,329 | 9,815 → 9,122 |
| fiq_movs | 16,933 → 16,921 | 18,490 → 18,496 | 22,897 → 22,613 |
| fiq_perm | 106,828 → 102,702 | 141,222 → 135,727 | 236,952 → 226,587 |
| gba_arm | 8,183 → 7,912 | 10,785 → 9,781 | 17,742 → 15,543 |
| gba_arm_q | 8,002 → 7,743 | 10,537 → 9,529 | 17,217 → 14,986 |
| gba_thumb | 4,917 → 4,803 | 6,509 → 5,967 | 10,831 → 9,687 |
| gba_thumb_q | 4,601 → 4,484 | 6,092 → 5,561 | 10,062 → 8,994 |
| icache_restart | 74,438 → 73,922 | 101,272 → 100,107 | 169,440 → 166,404 |
| icache_rtl | 58,023 → 57,996 | 85,176 → 84,457 | 153,956 → 151,764 |
| icexec_rtl | 67,477 → 67,151 | 93,717 → 92,781 | 160,349 → 157,845 |
| icwf_rtl | 60,730 → 60,671 | 88,182 → 87,488 | 158,077 → 155,910 |
| iprefetch_rtl | 73,056 → 72,923 | 103,926 → 103,177 | 183,817 → 181,396 |
| irq | 77,438 → 76,691 | 111,804 → 109,805 | 212,332 → 207,287 |
| ldm | 4,159 → 3,980 | 5,587 → 5,233 | 9,501 → 8,753 |
| ldmfold | 2,347 → 2,249 | 3,109 → 2,923 | 5,189 → 4,829 |
| ldst | 3,667 → 3,504 | 4,931 → 4,655 | 8,311 → 7,833 |
| loadpipe | 82,460 → 82,329 | 109,181 → 108,383 | 177,374 → 175,028 |
| loaduse | 60,576 → 60,511 | 87,970 → 87,221 | 157,942 → 155,543 |
| loaduse_irq | 119,641 → 119,624 | 149,464 → 148,787 | 225,582 → 223,365 |
| mmu_page | 77,070 → 76,793 | 112,738 → 111,327 | 203,065 → 199,161 |
| mmu_sect | 72,139 → 71,867 | 104,442 → 102,346 | 185,914 → 180,799 |
| modes | 3,009 → 2,888 | 4,028 → 3,712 | 6,539 → 5,973 |
| mul | 2,236 → 2,143 | 2,926 → 2,759 | 4,911 → 4,497 |
| rand1 | 19,876 → 19,933 | 27,914 → 27,443 | 50,983 → 50,471 |
| rand2 | 20,061 → 20,119 | 28,181 → 27,579 | 51,279 → 50,715 |
| rand3 | 20,240 → 20,288 | 28,411 → 27,900 | 51,691 → 51,237 |
| rand4 | 20,111 → 20,178 | 28,098 → 27,653 | 51,389 → 50,792 |
| rand5 | 20,217 → 20,274 | 28,395 → 27,844 | 51,807 → 51,231 |
| rand6 | 20,400 → 20,460 | 28,724 → 28,216 | 52,530 → 51,874 |
| rand7 | 20,254 → 20,324 | 28,488 → 27,945 | 52,090 → 51,524 |
| rand8 | 20,230 → 20,284 | 28,382 → 27,878 | 51,605 → 51,040 |
| rtl_misc | 8,032 → 7,917 | 9,017 → 8,687 | 11,422 → 10,864 |
| shift | 2,530 → 2,360 | 3,328 → 3,107 | 5,559 → 4,972 |
| tbl_irq | 115,069 → 106,020 | 134,865 → 123,283 | 205,774 → 174,879 |
| tcallpipe | 95,060 → 94,947 | 124,651 → 123,944 | 204,604 → 202,054 |
| thumb | 3,026 → 2,916 | 4,042 → 3,772 | 6,881 → 6,291 |
| trand1 | 21,870 → 21,841 | 30,940 → 30,034 | 56,039 → 54,769 |
| trand2 | 21,946 → 21,904 | 31,190 → 30,137 | 56,508 → 55,056 |
| trand3 | 22,014 → 21,965 | 31,171 → 30,208 | 56,488 → 55,267 |
| trand4 | 22,103 → 22,016 | 31,290 → 30,346 | 56,883 → 55,606 |
| trand5 | 22,024 → 21,986 | 31,170 → 30,327 | 56,479 → 55,248 |
| trand6 | 21,744 → 21,694 | 30,769 → 29,889 | 55,726 → 54,728 |
| trand7 | 21,795 → 21,739 | 30,800 → 29,920 | 55,659 → 54,534 |
| trand8 | 21,776 → 21,735 | 30,750 → 29,951 | 55,728 → 54,579 |
| v5und | 4,188 → 4,060 | 5,327 → 4,993 | 8,685 → 7,827 |
| walloc_rtl | 67,392 → 66,775 | 97,004 → 95,873 | 173,816 → 170,785 |

| Clock-timed case | Instructions before | After | Delta |
|---|---:|---:|---:|
| fiq_movs.0-3 | 3,532 | 3,556 | +24 |
| fiq_movs.2-9 | 3,475 | 3,466 | -9 |
| fiq_perm.0-0 | 16,544 | 16,592 | +48 |
| fiq_perm.0-3 | 16,508 | 16,529 | +21 |
| fiq_perm.2-9 | 16,436 | 16,457 | +21 |
| irq.0-0 | 14,633 | 14,640 | +7 |
| irq.0-3 | 14,623 | 14,633 | +10 |
| irq.2-9 | 14,612 | 14,620 | +8 |
| loaduse_irq.0-3 | 21,225 | 21,201 | -24 |

A before/after retirement-trace audit of all nine exceptions accounts for
**every** added or removed instruction as complete iterations of these loops:

| Test | Only PCs whose execution counts differ | Loop purpose |
|---|---|---|
| `fiq_movs` | `0x240`, `0x244`, `0x248` | Poll the round's FIQ count (`ldr/cmp/bls`). |
| `fiq_perm` | `0x398`, `0x39c`, `0x3a0` | User-mode poll until the round's FIQ (`ldr/cmp/blo`). |
| `irq` | `0x22c`–`0x238`, `0x3e4`–`0x3ec`, `0x582`–`0x588`, `0x7b0`–`0x7b8` | ARM IRQ polling, FIQ polling, Thumb IRQ polling, and the IRQ handler waiting for nested FIQ. |
| `loaduse_irq` | `0x3a8`, `0x3ac`, `0x3b0` | Poll `irq_seen` (`ldr/cmp/beq`). |

Every other retired-PC execution count is identical in those nine runs.
This establishes that the changed totals are polling-loop work, not dropped or
repeated fetches. The original clock-timed tests and their counters remain
unchanged. The literal all-runs total-instruction-equality requirement is not
met for these nine asynchronous cases; no claim to the contrary is made.

### Final verification and stopping point

- **237 CPU runs pass**: the 234 existing cases plus `ifetch_rtl` at all three
  latencies. **RTL vs QEMU: 57 agree, 0 differ**. Existing binaries and QEMU
  references were reused; only `ifetch_rtl` was assembled.
- `check_fetch_handshake.sh` passes all production-wiring cases, including
  deferred redirects held across data/issue backpressure and accepted on the
  release edge. The original `check_icache_restart.sh` also passes.
- Negative control: compiling the current observation bench against the
  archived cache-side-only netlist makes `ifetch_rtl` fail early-retirement
  check 2. With the one-bit handshake it passes every ARM/Thumb entry offset.
  The bench's new first-beat interval counter exists in both comparisons;
  this is not a failure caused by a missing observation register.
- Both stripped/debug lints pass, `tools/gen_cpu.sh` has regenerated the
  committed netlist, `make cpu-gen-check` passes, and generated `input reg`
  count remains **10**.
- `make -C sim sdram ddrflash upp periph top`: all pass. The top diagnostic
  bench completes **150,622,764 clocks**; its memory-test first pass is
  **92,213 clocks**, versus 92,221 in the cache-side-only run.

Evidence for this follow-up is under ignored `build/memside3/handshake/`:
fresh baseline netlist/model/logs and counts, final run/diff/count snapshots,
unit logs, the stricter directed test and negative-control logs, both lint
logs, gen-check, board log, and the nine before/after interrupt traces with
per-PC counts in `interrupts/summary.json`.

The authorized handshake is implemented. Guaranteed words can leave the held
fetch register once while the next cache request waits; +12 no longer waits
for the next line's response. Error-capable fills still quarantine their
queued words until the whole fill resolves. All implementation and functional
verification are finished; the nine fully explained clock-timer instruction
count exceptions above remain the sole discrepancy from the literal requested
count criterion. No additional pipeline work, timing work, whole-core fit,
firmware boot, `sys/` change, ARM9 change, victim buffer, merge or push was done.
The branch stops at a clean commit for the user's measurement-core build and
board run. The two parked branches remain untouched.
