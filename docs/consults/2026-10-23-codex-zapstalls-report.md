# zapstalls: pipeline cycle experiments

Baseline `1e9fe26`, branch `codex/timing2`: round 3 plus the flash line-wide fetch.
The task targets pipeline CPI; no firmware boot, hardware deployment, `sys/`
change or ARM9 change is included. Hardware game rates are motivation, not
measurements made by this task. Test binaries and existing QEMU references
are reused. Only the four new tests (`loadpipe`, `ldmfold`, `blslot` and
`bresolve`) were assembled and run on QEMU.

## Measurement

The nine quick tests passed before editing. Simulation-only probes sample
all six overlapping stall levels before each rising edge, matching the board
bit mapping. Flushes count accepted redirect edges, not clocks during which
a redirect is held. The final bench separates raw ALU redirects from the
new shifter redirects; their sum is the original accepted-clear counter.
The existing PASS
cycle/instruction line and architectural trace format remain unchanged.

`loadpipe.S` runs six operand classes, gaps of zero through four NOPs, and
64 iterations per region. `tools/measure_loadpipe.py` uses the existing
`--watch` probe at named begin/end retirement PCs; it adds no guest timing
loads. Region totals include loop control and initial cache/predictor warmup.
They are measured at all three deterministic bus-latency settings.

## Consult review

Section 2 of `2026-10-23-antigravity-timing.md` was read before selection.
Its path report predates round 3. The enabled tag-payload separation, local
stall selection, registered TLB address preparation and prediction payload
separation are already present. Its claim that both youngest shift-length
forwarding branches are dead is not accepted: the current
`shifter_lock_check` tests the issue output destination, not both ALU
forwarding destinations. Holding just one shared completion across a stall
also needs an overwrite/age proof for multiple pending operands; the current
per-operand capture is retained. No speculative timing estimates from the
consult are treated as fit results.

## Item 1: earlier load admission — tested and discarded

The experiment admitted condition-resolved loads at the registered ALU,
postalu0, postalu1 and postalu2 outputs for all four operand classes. It
retained shifter/unresolved-load, missed-register, WAW/base-writeback,
special-register, multiply, forced-alignment and exception exclusions.
No operand mux, completion capture, cache-data connection or clock enable
changed. The existing shifter/ALU pending slots waited while older stages
drained; transient normal/background completions were captured as before.

All 201 runs (including the new test), and 53 QEMU comparisons, passed.
All instruction counts were unchanged. However, **all 90 region cycle
counts were identical**. In cache at latency 0:0, issue-stall clocks fell
238913 -> 173330 while shifter-stall clocks rose 115349 -> 246722.
Earlier admission mostly relocated the wait; it did not bring forward the
registered load result. The mixed proxy changes below do not justify keeping
this RTL. It was restored to baseline before item 2.

| Test | 0:0 before -> experiment | 0:3 before -> experiment | 2:9 before -> experiment |
| --- | ---: | ---: | ---: |
| cache | 793607 -> 793600 | 921249 -> 921256 | 1253790 -> 1253777 |
| ctrand1 | 77298 -> 77305 | 106778 -> 106781 | 182278 -> 182276 |
| crand1 | 78285 -> 78215 | 109477 -> 109444 | 190634 -> 190630 |
| gba_arm | 8313 -> 8311 | 10935 -> 10932 | 17761 -> 17748 |
| gba_thumb | 4928 -> 4926 | 6529 -> 6527 | 10877 -> 10875 |
| loaduse | 64850 -> 64858 | 91854 -> 91855 | 160799 -> 160796 |
| loadpipe | 86654 -> 86658 | 113075 -> 113075 | 180199 -> 180199 |

Per-case region totals below are **baseline = experiment**, in cycles per
64 iterations. Consumer distance is `gap + 1` instructions.

| Operand | Gap | 0:0 | 0:3 | 2:9 |
| --- | ---: | ---: | ---: | ---: |
| rn | 0 | 703 | 720 | 773 |
| rn | 1 | 808 | 828 | 865 |
| rn | 2 | 872 | 893 | 929 |
| rn | 3 | 947 | 949 | 992 |
| rn | 4 | 1002 | 1031 | 1096 |
| rm | 0 | 684 | 705 | 759 |
| rm | 1 | 808 | 831 | 878 |
| rm | 2 | 871 | 885 | 930 |
| rm | 3 | 947 | 945 | 1011 |
| rm | 4 | 1002 | 1026 | 1107 |
| both | 0 | 684 | 703 | 745 |
| both | 1 | 808 | 825 | 858 |
| both | 2 | 872 | 882 | 945 |
| both | 3 | 947 | 955 | 992 |
| both | 4 | 1002 | 1034 | 1088 |
| shift | 0 | 744 | 760 | 817 |
| shift | 1 | 871 | 890 | 934 |
| shift | 2 | 946 | 949 | 997 |
| shift | 3 | 1009 | 1006 | 1070 |
| shift | 4 | 1073 | 1087 | 1149 |
| amount | 0 | 743 | 767 | 812 |
| amount | 1 | 871 | 888 | 931 |
| amount | 2 | 946 | 955 | 1001 |
| amount | 3 | 1009 | 1007 | 1064 |
| amount | 4 | 1073 | 1094 | 1173 |
| store | 0 | 743 | 768 | 820 |
| store | 1 | 808 | 832 | 878 |
| store | 2 | 872 | 894 | 949 |
| store | 3 | 947 | 949 | 1005 |
| store | 4 | 997 | 1017 | 1064 |

`rn` is ADD's first operand; `rm` is unshifted second operand; `both` uses
one loaded register twice; `shift` is an immediate shift of the loaded
value; `amount` is a register-specified shift; `store` is store data.
Existing `loaduse`/`loaduse_irq`, abort, cache and random tests cover cold
misses, multiple pending loads, formats, false conditions, WAW conflicts,
base writeback, load-to-PC and interrupt/abort cancellation.

## Item 2a: one younger slot discarded on a BTB hit

The BTB lookup still starts at registered `pc_ff`. Its synchronous RAM
result, registered collision bypass and registered valid bit feed the tag
comparison for `pc_del_ff`. Writeback accepts that result one clock earlier
than before; only `pc_ff` is invalidated. The older `pc_del2` slot and the
branch itself continue. Accepted prediction valid/target travel through
new `pred_del2` registers to the original final fetch slot; the bimodal
state retains its existing alignment. Recovery, shelved redirects, I-cache
restart, CP15 clear, false BTB hit and code-stall priorities remain.
RAM output/collision register boundaries are protected from retiming.
There is no cache data path into the pipeline or change to operand capture.

The changed PC decision now includes the RAM tag comparison, so whole-core
timing is a required acceptance check, not implied by passing simulation.
All 201 runs, 53 QEMU comparisons, lint and generated-netlist check passed.

| Test | 0:0 before -> after | 0:3 before -> after | 2:9 before -> after |
| --- | ---: | ---: | ---: |
| cache | 793607 -> 789485 | 921249 -> 917469 | 1253790 -> 1251216 |
| ctrand1 | 77298 -> 73176 | 106778 -> 102998 | 182278 -> 179704 |
| crand1 | 78285 -> 74163 | 109477 -> 105697 | 190634 -> 188060 |
| gba_arm | 8313 -> 8312 | 10935 -> 10934 | 17761 -> 17761 |
| gba_thumb | 4928 -> 4928 | 6529 -> 6529 | 10877 -> 10877 |

The equal 4122-cycle zero-latency savings on cache and both compiled tests
mainly reflect their shared MMU setup loop. GBA changes are negligible.
These proxy totals do not establish a reduction from the games' 3.7 CPI.

| Test/latency | ALU flushes before -> after | FIFO-empty clocks before -> after |
| --- | ---: | ---: |
| cache/0-0 | 61 -> 61 | 51897 -> 47293 |
| cache/0-3 | 61 -> 61 | 78250 -> 73927 |
| cache/2-9 | 61 -> 61 | 121795 -> 115154 |
| ctrand1/0-0 | 124 -> 124 | 47811 -> 43715 |
| ctrand1/0-3 | 124 -> 124 | 74254 -> 70439 |
| ctrand1/2-9 | 124 -> 124 | 118316 -> 112183 |
| crand1/0-0 | 28 -> 28 | 47151 -> 43055 |
| crand1/0-3 | 28 -> 28 | 73876 -> 70061 |
| crand1/2-9 | 28 -> 28 | 122293 -> 116160 |
| gba_arm/0-0 | 89 -> 89 | 6756 -> 6755 |
| gba_arm/0-3 | 89 -> 89 | 9362 -> 9361 |
| gba_arm/2-9 | 89 -> 89 | 16087 -> 16087 |
| gba_thumb/0-0 | 35 -> 35 | 3963 -> 3963 |
| gba_thumb/0-3 | 35 -> 35 | 5552 -> 5552 |
| gba_thumb/2-9 | 35 -> 35 | 9869 -> 9869 |

## Item 3a: finish LDM/STM at its last useful beat

No-writeback transfers skip the trailing empty uop. Incrementing transfers
with writeback direct the last memory uop's address result to the original
architectural base, using internal instruction metadata decoded before
physical register translation. Data accesses and register order remain
unchanged. The existing writeback exception priority suppresses that base
write if the last beat aborts; earlier faults flush it before retirement.
PC loads still finish with WRITE_PC, and deferred base loads with BASE_LOAD.
Empty lists, decrementing writeback, PC bases and writeback loads whose base
is in the list retain their original sequence. This achieves n+1 useful
uops for the supported ordinary cases; it is not a claim for every LDM/STM.

`ldmfold.S` tests two-register final-beat load/store aborts, one-register
first-and-final-beat aborts, and failed conditions. It passes at all three
latencies and matches a newly generated QEMU reference. The complete suite
passes **204 runs and 54 QEMU comparisons**; lint and gen check pass.

| Test | 0:0 item 2 -> item 3a | 0:3 item 2 -> item 3a | 2:9 item 2 -> item 3a |
| --- | ---: | ---: | ---: |
| cache | 789485 -> 789435 | 917469 -> 917317 | 1251216 -> 1251118 |
| ctrand1 | 73176 -> 73105 | 102998 -> 102913 | 179704 -> 179659 |
| crand1 | 74163 -> 73977 | 105697 -> 105416 | 188060 -> 187935 |
| gba_arm | 8312 -> 8314 | 10934 -> 10937 | 17761 -> 17761 |
| gba_thumb | 4928 -> 4933 | 6529 -> 6522 | 10877 -> 10882 |
| ldm | 4236 -> 4203 | 5707 -> 5658 | 9574 -> 9577 |

## Item 3b: ARM BL in one slot

ARM BL becomes SUB LR, PC, #4 for the ordinary ALU/writeback path, with a
separate target prepared from registered PC/instruction at decode and carried
through issue (including its skid) and shifter. ALU branch resolution uses
that target; its ordinary result and physical destination remain the link
write. This adds no term to issue's operand-forwarding function. Conditional
failure suppresses the link write as usual. Bank translation selects the
current mode's LR. Misprediction flushes younger instructions while the
branch's own link write drains normally. Holds/flushes keep the sideband
aligned with its instruction. Thumb BL/prefix/suffix and their interrupt
semantics retain the original sequencer.

`blslot.S` checks adjacent-target BL, failed conditions, the callee's first
instruction reading LR, both operands reading LR, and banked LR. The new
binary and reference pass all latencies and QEMU. Full verification is
**207 runs, 55 QEMU agreements**, lint and generated-netlist check passing.

| Test | 0:0 item 3a -> 3b | 0:3 item 3a -> 3b | 2:9 item 3a -> 3b |
| --- | ---: | ---: | ---: |
| cache | 789435 -> 789419 | 917317 -> 917315 | 1251118 -> 1251118 |
| ctrand1 | 73105 -> 73097 | 102913 -> 102911 | 179659 -> 179659 |
| crand1 | 73977 -> 73969 | 105416 -> 105414 | 187935 -> 187935 |
| gba_arm | 8314 -> 8302 | 10937 -> 10938 | 17761 -> 17761 |
| gba_thumb | 4933 -> 4929 | 6522 -> 6522 | 10882 -> 10882 |

## Item 2b: resolve safe direct branches in the shifter

The decode target sideband also marks ordinary PC-relative branches,
including normalized Thumb branches. The shifter evaluates the condition
from registered ALU flags only when its immediately older instruction
cannot update flags (ordinary S-bit writes and FMOV/MSR are excluded).
Otherwise the branch uses the original ALU resolution. The target and
redirect are registered at the shifter output. Correct predictions keep
flowing; only wrong direction/target predictions redirect early.

An older ALU redirect wins over the shifter redirect. Writeback exceptions
retain their existing priority. The early branch still executes and retires
normally, including an ARM BL's link write, but suppresses its second ALU
redirect/training event. BTB feedback uses the matching branch PC and
prediction state. A simultaneous older confirmation is omitted when the
single feedback port trains the early misprediction. Data holds preserve
the decision, and reset/flush/bubble handling clears its valid bit.
Instruction-side exceptions disable early resolution. No live cache data,
new issue operand-mux input, or operand clock-enable change is involved.

`bresolve.S` covers flag writers at distances one through three,
alternating branch directions, MSR flag changes, and conditional BL.
An enabled bench assertion checks each accepted early redirect against
actual ALU execution one stage later, including not-taken fallthrough.
The suite now enables Verilator assertions by default. All **210 runs and
56 QEMU comparisons** pass, as do lint and the generated-netlist check.

| Test | 0:0 item 3b -> 2b | 0:3 item 3b -> 2b | 2:9 item 3b -> 2b |
| --- | ---: | ---: | ---: |
| cache | 789419 -> 789368 | 917315 -> 917253 | 1251118 -> 1251084 |
| ctrand1 | 73097 -> 73043 | 102911 -> 102937 | 179659 -> 179631 |
| crand1 | 73969 -> 73935 | 105414 -> 105359 | 187935 -> 187907 |
| gba_arm | 8302 -> 8183 | 10938 -> 10785 | 17761 -> 17742 |
| gba_thumb | 4929 -> 4917 | 6522 -> 6509 | 10882 -> 10831 |

The small ctrand1 regression at 0:3 is retained alongside the gains at
the other latencies and in both GBA tests. Earlier redirects change bus
arbitration/cache-fill overlap; savings need not equal the redirect count.

## Whole-core timing acceptance

The starting merged tree has a fresh full-core seed-2 fit in server build
`dev/mister/NGage_MiSTer-b14`: **-1.398 ns at slow 100C**, not the older
round-3 figure. Its 151 tracked HDL/configuration/constraint/data inputs
were compared with `1e9fe26`; the only difference was Quartus's cosmetic
LAST_QUARTUS_VERSION stamp. The generated CPU SHA-256 is
`2f3f2e6a97bd58f9c12d797e2a86a9988ba7a64bfbf58736df4517961fe4f666`.
The allowed 0.3 ns regression therefore sets a **-1.698 ns** floor.
The baseline's worst path is predecode `o_instruction_ff[15]` to decode
`o_shift_is_lsl0_ff` (10.289 ns data delay). It uses 35018 ALMs and
43361 registers. Baseline reports and source comparison are archived in
`build/zapstalls/baseline-fit/`.

The intermediate BTB-only full-core build (`f84cda5`) measured
**-0.924 ns at slow 100C**, with 35260 ALMs and 43792 registers.
Its worst path is the memory bus `ack_q` into the Wishbone merger's
registered data. This is evidence for that intermediate candidate only;
the complete candidate's full-core fit is running in the requested
`dev/mister/NGage_MiSTer-s1` directory. Intermediate reports are archived
in `build/zapstalls/item2/`.

## Combined cycle and front-end results

Latencies are `0:0`, `0:3`, `2:9`; all instruction counts below are
identical before and after. Uop counts include condition-failed uops and
are identical across the three latency settings.

| Test | 0:0 baseline -> final | 0:3 baseline -> final | 2:9 baseline -> final | Instructions | Uops before -> after |
| --- | ---: | ---: | ---: | ---: | ---: |
| cache | 793607 -> 789368 | 921249 -> 917253 | 1253790 -> 1251084 | 293427 | 293648 -> 293629 |
| ctrand1 | 77298 -> 73043 | 106778 -> 102937 | 182278 -> 179631 | 16159 | 17287 -> 17174 |
| crand1 | 78285 -> 73935 | 109477 -> 105359 | 190634 -> 187907 | 15982 | 16861 -> 16796 |
| gba_arm | 8313 -> 8183 | 10935 -> 10785 | 17761 -> 17742 | 1192 | 1318 -> 1298 |
| gba_thumb | 4928 -> 4917 | 6529 -> 6509 | 10877 -> 10831 | 774 | 828 -> 817 |

| Test/latency | ALU flushes before -> after | New early flushes | FIFO-empty clocks before -> after |
| --- | ---: | ---: | ---: |
| cache/0-0 | 61 -> 14 | 47 | 51897 -> 47247 |
| cache/0-3 | 61 -> 14 | 47 | 78250 -> 73972 |
| cache/2-9 | 61 -> 14 | 47 | 121795 -> 115106 |
| ctrand1/0-0 | 124 -> 88 | 36 | 47811 -> 43716 |
| ctrand1/0-3 | 124 -> 88 | 36 | 74254 -> 70528 |
| ctrand1/2-9 | 124 -> 88 | 36 | 118316 -> 112245 |
| crand1/0-0 | 28 -> 10 | 18 | 47151 -> 42988 |
| crand1/0-3 | 28 -> 10 | 18 | 73876 -> 70239 |
| crand1/2-9 | 28 -> 10 | 18 | 122293 -> 116280 |
| gba_arm/0-0 | 89 -> 29 | 60 | 6756 -> 6623 |
| gba_arm/0-3 | 89 -> 29 | 60 | 9362 -> 9257 |
| gba_arm/2-9 | 89 -> 29 | 60 | 16087 -> 16056 |
| gba_thumb/0-0 | 35 -> 21 | 14 | 3963 -> 3947 |
| gba_thumb/0-3 | 35 -> 21 | 14 | 5552 -> 5527 |
| gba_thumb/2-9 | 35 -> 21 | 14 | 9869 -> 9730 |

The total accepted misprediction count is unchanged: eligible events moved
from ALU to shifter resolution. FIFO-empty clocks fall in all fifteen
comparisons. Overlapping stall levels must not be summed or interpreted as
exclusive CPI components. In particular, earlier load admission reduced an
issue counter without reducing load-use latency.

## Item 4: multiply barrier measured; no RTL change retained

The multiply FSM operates on the instruction held at issue's output. Its
busy signal also holds the selected younger instruction and the predecode
output. Removing only the sequencer hold would advance its state without
consuming its output, losing or repeating memory/long-multiply uops.
Decoupling it needs explicit queued-output acceptance across these stages;
the existing skid holds the input instruction, not an arbitrary queue of
generated uops. The long-multiply second uop is already generated in
LMULT_BUSY before the first reaches the multiplier.

Bench-only occupancy probes count busy clocks, non-cancelled multiply
releases, and releases with a valid younger instruction selected at issue.
They change no cycles or instruction counts. The full 210-run suite and
56 QEMU comparisons pass with these probes.

| Test | Busy clocks 0:0 / 0:3 / 2:9 | Releases at each latency | Younger waiting 0:0 / 0:3 / 2:9 |
| --- | ---: | ---: | ---: |
| cache | 65537 / 65537 / 65537 | 16384 | 16384 / 16384 / 16384 |
| ctrand1 | 44 / 44 / 44 | 11 | 11 / 11 / 10 |
| crand1 | 434 / 447 / 476 | 130 | 130 / 128 / 110 |
| gba_arm | 112 / 112 / 112 | 35 | 14 / 14 / 14 |
| gba_thumb | 4 / 4 / 4 | 1 | 0 / 0 / 0 |

Every cache-test multiply already has its successor queued at release;
advancing predecode alone does not remove its four busy clocks. The GBA
cases leave room for a more elastic front end, but this measurement does
not prove that their missing successors could have been fetched in time.
No cycle-saving implementation of that queue protocol was completed in
this task. This is an explicit stopping point, not a claim that decoupling
can never help the games.

## Remaining uop cases and risks

SWP remains three uops: load DUMMY0, store Rm, move DUMMY0 to Rd. Loading
directly into Rd would change the stored value for Rd=Rm, can change the
address for Rd=Rn, and would expose Rd's new value before a store abort.
Two-uop SWP needs a separate loaded-result payload and destination carried
with the store until successful retirement. That data path and its
forwarding/abort proof were not implemented. The proxy traces contain zero
SWP encodings in cache/ctrand1/gba_thumb, 17 in crand1, and four in gba_arm
(including condition-failed instructions). These counts do not measure
SWP frequency in the games.

The remaining LDM/STM cases are decrementing writeback, base-in-load-list
with writeback, PC bases, empty lists and the existing deferred PC/base
finishing uops. Thumb BL retains split-prefix/suffix behavior, including
interrupt entry between halfwords. None is claimed to reach the reduced
uop count. The new LDM folding tests exercise first/final-beat aborts but
do not constitute an exhaustive proof for every banking/abort combination.

Functional risk is concentrated in branch metadata alignment during holds,
redirect/exception priority, and folded base/link writes. Directed tests,
the full random/ARM/Thumb/exception/cache suite, QEMU traces and the
early-decision assertion cover these cases dynamically; no formal proof
was run. Timing risk is in the earlier BTB tag comparison, decode target
adder, shifter condition check and redirect/feedback mux. All branch
payloads cross registers; issue's operand forwarding and completion
capture paths are unchanged. The complete whole-core fit, rather than a
CPU-only estimate, decides timing acceptance.

The larger game goal remains open: no game was run on hardware in this
task, and these proxy gains do not demonstrate CPI 2.9 or 2.5. Next, measure
the same in-game counters with this candidate, separate actual multiply
occupancy from late-load holds, and identify exposed load-result latency.
Earlier admission without earlier data was ineffective. An elastic front
end or two-uop SWP should follow only with a bounded queue/retirement design
and dedicated abort, alias, interrupt and hold tests.
