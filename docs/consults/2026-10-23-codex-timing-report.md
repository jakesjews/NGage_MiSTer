# Registered prediction and late operands — 2026-10-23

Worktree branch: `codex/timing`; baseline: `75cce2e`. Changes are confined to
BTB/writeback, late operand handling in core/issue/shifter/ALU, the generated
CPU netlist, and this report. No cache FSM, `sys/`, or other worktree edits.

## Result and stopping point

Both requested path families are removed from the worst ten paths at both
slow corners in four CPU-only fits of the final netlist. The requested
**+0.2 to +0.5 ns overall CPU margin was not achieved**: the best seed is
**-0.117 ns at slow 100C / -0.067 ns at slow -40C**. This is a passing
architectural change and a partial timing result, not 104 MHz closure.

Work stops after the registered boundaries, PC/FCSE selection, and unused
barrel-forwarding path have been fixed and checked. The remaining worst
paths are the D-cache/merger, cache tag forwarding into the lock register,
and issue interlock/skid control; MMU stall control also appears. Cache
FSMs and merger changes are outside this assignment's file ownership, and
cache FSM edits are expressly excluded. No timing constraints were relaxed
to hide these paths. The lost cycles are measured below; the entire merged
performance gain has not been preserved.

## Implementation

### BTB

The synchronous BTB RAM and valid-bit lookup now read `pc_ff`, not `pc_nxt`.
The following registered decision compares the RAM tag with `pc_del_ff`.
That decision belongs to `pc_del2_ff`: an accepted prediction moves this
branch into `pc_del3_ff`, invalidates the two younger slots (`pc_ff` and
`pc_del_ff`), and starts fetching the target. Prediction address/valid and
branch state travel together into the final fetch register. The no-longer
needed intermediate prediction register is removed.

A correctly predicted taken branch therefore discards **two fetch slots**,
versus one in the merged baseline and three before the early-BTB change.
This retains one slot of that change's gain. It introduces no RAM/tag/valid
logic into `pc_nxt`.

The first fit then exposed the existing predecode-to-PC recovery mux and
FCSE mapping as a critical path. Recovery priority is now a one-hot select
of the same ten sources. Each candidate is FCSE-mapped **before** the wide
PC source mux; there is no selected-address zero-tag comparison afterward.
Shelved PCs remain raw until use, preserving the behavior if PID changes
while the PC is held. The complete combinational PC transition (all next-PC,
delayed-PC, prediction, shelve and shelved-address outputs) was proved
equivalent to the first revision using Yosys SAT, with arbitrary state and
input bits, including coincident redirects/stalls and arbitrary PID.

The supplied report's `Mux0~170` names are node identifiers, not 170 serial
logic levels: its path statistics report ten logic levels for the entire
predecode-to-BTB path. The problematic boundary nevertheless was real.

### Late operands

A 41-bit snapshot in `zap_core` registers the already registered memory
load value (32), physical destination (6), DAV, load flag, and destination
lock. The lock is sampled **with the memory output**, not with the input to
memory: a miss asserts its destination lock on the same edge as the early
acknowledge. Sampling the input-side lock would classify that miss as a hit.
The snapshot is updated even during a data stall, and its DAV is cleared
on reset/writeback clear. Ordinary issue forwarding and architectural
writeback keep their original connections and latency.

ALU rn/rm each select either their existing operand register or this
snapshot register through one 2:1 mux, selected by the registered pending
bit. Readiness uses only the snapshot's registered metadata. It cannot
include the D-cache's live state/acknowledge or live RAM output. On a hold,
each resolved operand is retained in its own existing register and its
pending bit clears. Thus two different pending operands need not complete
in the same cycle, and a transient completion survives a global stall.

Shifter source, shift amount, and store data likewise use a single pending
bit to select the snapshot for execution. They no longer execute through
the three-way background/memory/original pickup mux. The separate pickup
mux is used only to capture held operands or plain operands entering the
ALU. The barrel shifter itself receives only the registered raw/snapshot
source. ALU forwarding feeds the unshifted bypass only: routing it through
the barrel too created a physical ALU-to-forwarding-to-barrel path, even
though that barrel result is unselected whenever forwarding is used. Multiply operands remain excluded and retain their raw values.

The background write port already supplies `reg_dat_ff`, selected by the
registered `reg_wr_ff` in the current critical-word-first cache. It is
captured in existing operand registers; it is never selected directly for
ALU/shifter execution. Keeping that capture on the register-file write edge
avoids delaying critical-word completion by another clock.

[`dont_retime`](https://docs.altera.com/r/docs/683283/18.1/design-compilation-user-guide-quartus-prime-standard-edition/disabling-synthesis-netlist-optimizations-with-dont_retime-attribute) marks the new snapshot and the existing issue/shifter operand
registers. These are functional timing boundaries, not timing exceptions.
No false/multicycle paths or new issue-to-memory pipeline stages are added; there are no
new RAMs or extra register-file ports. Late load tag comparisons use a dedicated preserved copy of the issue
stall bit and their own small tag mux; they do not load the RF read-index
mux or start at the control stall bit's hundreds of loads. Reset, clear,
update and hold are identical to the existing stall copy.

The source-level net storage change is seven bits: 41 snapshot bits plus
one stall copy, minus 35 removed BTB metadata bits.
Physical resource use must be read from the fitted result below.

Regeneration also reorders modules. Comparing each complete generated
module against the baseline finds changes only in `zap_core`,
`zap_issue_main`, `zap_shifter_main`, and `zap_writeback`. All other generated
modules, including both cache FSMs, are byte-identical. BTB/ALU source
comments explain the changed contracts; their internal netlists are unchanged.

The synchronous snapshot costs one clock when a late hit/uncached load
would previously have executed directly from memory's output. Plain
operands retain one of the former two clocks of gain. Early shifter/store
users give back their former one-clock gain. Background completion keeps
its original capture edge. This is not a universal additional clock per
load: existing stalls and ready operands can hide it.

## Cases and coverage

| Case | Handling |
| --- | --- |
| BTB hit, miss, tag collision | Registered read, registered tag decision, valid-bit check. Only accepted redirects set the instruction's prediction metadata. |
| Consecutive branches and branch targets | The older branch survives; both younger speculative slots are invalidated. A target that is itself a branch is looked up normally when it reaches `pc_ff`. |
| ARM/Thumb and halfword targets | Existing halfword index and PC alignment remain. ISA state changes still resolve through the normal flush path. |
| Fetch/code stalls | RAM read, decision, and final metadata hold on the same code stall. Invalid PC slots suppress stale decisions. |
| CP15 BTB invalidation | Existing clear priority invalidates table DAV and decision, including a stalled clear. Nonbranch instructions still do not clear trained entries. |
| Exceptions, ALU/decode redirects, I-cache clear | Existing higher-priority PC recovery wins; no prediction is recorded as accepted. |
| FCSE | Lookup uses the already FCSE-adjusted registered PC. |
| Cache hit and uncached success | Coherent registered value/tag/valid/load/lock snapshot. The cache-formatted value is used without adding rotation/sign extension. |
| Early acknowledged miss | Snapshot lock rejects the placeholder memory result. Background register write resolves the operand instead. |
| Writeback clear/replay/abort | Snapshot DAV and existing pending instruction state clear. No stale completion can make a flushed instruction execute. |
| Data stall coincident with completion | Snapshot updates independently of stall, and held issue/shifter registers capture matching results independently of pipeline advance. |
| Two pending operands | Independent tags/bits and retained values; a first completion survives until the second arrives. Same-register duplicates resolve together. |
| Younger writers / base writeback | Original WAW and conflicting ALU-writer checks remain, including the producer's base writeback. They also prevent a delayed snapshot from matching a newer same-register producer. |
| Conditional load | No admission before condition resolution; failed loads do not create pending operands. |
| Loads to PC, banked/special registers, alignment | Original conservative admission rules and architectural flush/forwarding rules remain. |
| LDM/STM, temporary registers, interrupts | Existing uop ordering, special-register locks, exception flush priority, and IRQ handling are unchanged. |
| Flags, shifts, multiplies | Original shift/flag locks remain. Shift inputs use registered values; multiply exclusion and raw-operand retention remain. |

Existing `btb_early.S`, `bpred.S`, `loaduse.S`, `loaduse_irq.S`, `cache.S`,
`dcwf*`, `dhold_rtl`, MMU/exception/unaligned tests, random ARM/Thumb and GBA
tests already exercise these architectural cases. No new binary or QEMU
reference was needed or rebuilt. `loaduse_irq` is timer driven, so its
executed instruction count can change when cycle timing changes; it is not
one of the nine fixed-instruction baseline comparisons.

## Verification

Baseline nine tests: **27 passed, 0 failed**. Baseline executable/logs are
saved locally in `sim/cpu/build/timing-baseline/`.

Current candidate: nine quick tests plus `loaduse`, `loaduse_irq` and
`btb_early`: **36 passed, 0 failed**. QEMU diff: **52 agree, 0 differ**.
Pre-fit full suite: **198 passed, 0 failed**, then **52 agree, 0 differ**.
`make lint`, `make cpu-gen-check`, and `git diff --check` passed.
The post-fit full suite passed **198 runs, 0 failed**, followed by
**RTL vs QEMU: 52 agree, 0 differ**. All 27 requested before/after cycle and
instruction counts were rechecked against the original baseline logs.
Final run/diff logs are `/tmp/ngage-timing-final-run.log` and
`/tmp/ngage-timing-final-diff.log`; the PC equivalence proof is
`/tmp/ngage-pc-equivalence.log` and its generated comparison module is in
`sim/cpu/build/timing-isolation/pc_equiv.sv`.

The checkout has 66 tests / 198 latency runs and 52 QEMU references, rather
than the brief's earlier 59 / 177 and 49. The first post-edit diff encountered
missing RTL outputs for tests outside the nine-test baseline; a complete
run populated them. The subsequent complete comparisons above are clean.

## Cycles

All nine tests have identical before/after instruction counts. Latencies
are initial:subsequent bus waits; numbers are before → after (delta).

| Test | Instructions | 0:0 cycles (delta) | 0:3 cycles (delta) | 2:9 cycles (delta) |
| --- | ---: | ---: | ---: | ---: |
| cache | 293,427 | 760,787 → 793,607 (+32,820) | 888,787 → 921,249 (+32,462) | 1,222,550 → 1,253,790 (+31,240) |
| dcache_rtl | 12,771 | 58,301 → 62,433 (+4,132) | 85,328 → 89,143 (+3,815) | 154,143 → 156,717 (+2,574) |
| icache_rtl | 12,771 | 58,201 → 62,332 (+4,131) | 85,393 → 89,179 (+3,786) | 154,521 → 157,119 (+2,598) |
| ctrand1 | 16,159 | 72,594 → 77,298 (+4,704) | 102,419 → 106,778 (+4,359) | 179,154 → 182,278 (+3,124) |
| crand1 | 15,982 | 73,608 → 78,285 (+4,677) | 105,167 → 109,477 (+4,310) | 187,620 → 190,634 (+3,014) |
| gba_arm | 1,192 | 8,291 → 8,313 (+22) | 10,887 → 10,935 (+48) | 17,749 → 17,761 (+12) |
| gba_thumb | 774 | 4,913 → 4,928 (+15) | 6,523 → 6,529 (+6) | 10,877 → 10,877 (+0) |
| mmu_page | 16,887 | 77,102 → 82,602 (+5,500) | 112,796 → 117,874 (+5,078) | 203,209 → 206,614 (+3,405) |
| align | 549 | 5,427 → 5,469 (+42) | 7,001 → 7,022 (+21) | 11,223 → 11,425 (+202) |

### Isolating the cycle costs

Temporary simulation-only netlists combined the baseline with only the new
writeback (BTB timing), or the new operand logic with baseline writeback.
They reused the existing binaries; all 30 runs passed. Deltas relative to
the same baseline, at `0:0 / 0:3 / 2:9`:

| Test | BTB-only delta | Operand-only delta |
| --- | ---: | ---: |
| cache | +4,122 / +3,780 / +2,574 | +28,698 / +28,682 / +28,666 |
| ctrand1 | +4,122 / +3,780 / +2,574 | +582 / +579 / +550 |
| crand1 | +4,122 / +3,780 / +2,574 | +555 / +530 / +440 |
| gba_arm | +1 / +2 / 0 | +21 / +46 / +12 |
| gba_thumb | 0 / 0 / 0 | +15 / +6 / 0 |

These deltas happen to add exactly to the combined change for these five
tests. They are measurements of these binaries, not a prediction of game
CPI. The common BTB delta in the first three includes their shared setup.

## Quartus

The first completed trial of the registered snapshot (`trial2`, seed 1)
was **-1.455 ns at slow 100C**, **-1.594 ns at slow -40C**, +3.104/+4.263 ns
at the fast corners. It used 16,020 ALMs, 16,874 registers, 75 RAM blocks,
and four DSP blocks. The original next-PC-to-BTB and live-cache-to-ALU
cones were absent from its worst twelve paths, but an ALU-to-forwarding-to-
barrel path and the predecode-to-PC/FCSE path remained. That result prompted
the follow-up structural changes above; it was not timing closure.

Four follow-up fits use the identical final netlist, Quartus Lite 17.0.2,
Cyclone V 5CSEBA6U23I7, and unchanged CPU-only 104 MHz constraints. All
compilations completed with 0 errors and 76 warnings; standalone timing
report generation completed with 0 errors and 0 warnings. The compilation
warnings include the genuine negative setup slack.

| Seed | Slow 100C setup ns | Slow -40C setup ns | Fast 100C setup ns | Fast -40C setup ns | Minimum hold ns, all corners | ALMs | Registers |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | -0.398 | -0.233 | +3.765 | +4.747 | +0.123 | 16,574 | 17,346 |
| 2 | -0.117 | -0.067 | +3.841 | +4.831 | +0.146 | 16,521 | 17,327 |
| 3 | -0.264 | -0.064 | +3.965 | +4.921 | +0.126 | 16,628 | 17,485 |
| 4 | -0.380 | -0.405 | +3.833 | +4.814 | +0.132 | 16,548 | 17,391 |

All four use 335,840 block-memory bits, 75 RAM blocks and four DSP blocks.
There is no matched CPU-only baseline fit here from which to claim an ALM
or slack delta. In particular, the supplied whole-core -3.014/-3.047 ns
result is not directly comparable with these CPU-only figures.

Neither family A nor B appears in the worst ten at **either slow corner
in any seed**. The worst paths are:

| Seed | Slow 100C worst path | Slow -40C worst path |
| --- | --- | --- |
| 1 | D-cache FSM `state_ff[0]` to Wishbone merger `o_wb_dat[17]_OTERM149` (tied with bit 24) | D-cache FSM `state_ff[9]~DUPLICATE` to the same merger outputs |
| 2 | D-cache wrapper `state_ff[2]` to merger `o_wb_dat[20]_OTERM123` | Same path |
| 3 | Way 0 tag RAM `fwd_st3~DUPLICATE` to D-cache FSM `lock_ff[59]` | Same path |
| 4 | Decode `o_mem_srcdest_index_ff[2]~DUPLICATE` to issue `stall_idx_ff` | Issue `skid[51]~DUPLICATE` to `stall_idx_ff` |

Seed 2's next path is CP15 `o_mmu_en` to shifter
`o_shifted_source_value_ff[5]` (-0.107 ns), a stall/capture-control path,
not a late operand execution mux. Seed 3 also exposes MMU control into
Thumb prefix state. These are remaining timing work, not false paths.

A separate seed 1 query of all paths starting at the 41 snapshot
registers gives **+0.203 / +0.299 ns** at the two slow corners. All paths
starting at the writeback PC read registers give **+0.718 / +0.816 ns**.
These source groups meet timing in that fit; this does not establish
overall closure or promise the same margins in whole-core placement.

Results are retained locally under `sim/cpu/build/timing-trial2/`,
`sim/cpu/build/timing-trial3-seed1/`, and
`sim/cpu/build/quartus-{2,3,4}-104/`. Each final run used
`SEED=<1..4> BUILD_DIR=dev/mister/ngage-cx-timing-trial3[-seedN] sim/cpu/quartus/run.sh`;
seed 1 omitted the optional suffix. The final source was unchanged between
these fits and the post-fit acceptance run.

The generated-netlist SHA-256 is
`a6d13bc23154754b873876510cab6dc673fa5f5429a579c1237b7c1c8c5d5de5`.

The preliminary capture-only trial was cancelled during synthesis, before
any fit result, and its container removed when the coherent-snapshot
version superseded it. Each final trial used its own isolated remote directory,
not another engineer's build directory. The script's four-build limit was
respected; an initial refusal was followed by a retry after a slot opened.
All task-owned build containers exited and were removed by `--rm`; no new
Docker image or persistent server was created. Other engineers' containers
were left alone.

## Limits and next work

No whole-core fit/seed sweep, physical board test, game-CPI measurement, or
76,975-access firmware trace comparison was performed here. This worktree
has no prepared firmware boot inputs. The CPU-only fit cannot establish
whole-core placement margin at 80% device utilization. Next, the owners of the cache/merger and issue interlock logic should
shorten the remaining paths without altering lock or acknowledge timing.
Repeat the CPU-only seed sweep, then a whole-core fit checking both slow
corners and hold, followed by the ordered firmware trace and matched game
measurements on hardware.

Functional tests cover many overlapping stalls but are not exhaustive
proof of all interrupt/abort positions and same-register schedules. The
coherent snapshot, per-operand retention and existing flush priority are
the critical invariants to retain when integrating other CPU changes.

Next performance work should recover the surrendered prediction slot with
a separately timed registered lookahead design, and assess earlier operand
capture using measured game workloads. Do not reconnect next-PC control
to BTB lookup or live cache readiness/data to execution to regain cycles.
