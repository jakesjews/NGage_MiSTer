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

## Remaining work

Item 2 is in progress. Final retained changes, full-core timing, aggregate
cycle/counter tables and exact stopping point will be recorded here.
