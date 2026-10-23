# zapstalls: pipeline cycle experiments

Baseline `1e9fe26`, branch `codex/timing2`: round 3 plus the flash line-wide fetch.
The task targets pipeline CPI; no firmware boot, hardware deployment, `sys/`
change or ARM9 change is included. Hardware game rates are motivation, not
measurements made by this task. Test binaries and existing QEMU references
are reused. The new `loadpipe` binary alone was assembled and run on QEMU.

## Measurement

The nine quick tests passed before editing. Simulation-only probes sample
all six overlapping stall levels before each rising edge, matching the board
bit mapping. ALU flushes count accepted redirect edges (`clear_from_alu &&
!data_stall`), not clocks during which a redirect is held. The existing PASS
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

## Remaining work

Final whole-core timing and remaining candidate disposition are pending.
