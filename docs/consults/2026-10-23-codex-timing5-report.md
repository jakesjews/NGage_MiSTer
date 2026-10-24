# timing5: main-core timing closure

**Requested margin achieved:** fixed seeds 1/2/3 give **−0.211 / −0.221 /
−0.318 ns** at slow 100C, **median −0.221 ns**, against the −0.300 ns target.
The original main-core median was −1.152 ns: a **0.931 ns whole-tree gain**.
This is close to 104 MHz, not positive static timing closure. The comparison
includes the unchanged owner-supplied card fix and placement effects, as well
as the CPU changes; isolated family measurements are listed below.

Final RTL source is `7d1218c`, on `codex/timing2`. All 225 CPU runs retain
identical cycle and instruction counts; all 57 QEMU comparisons agree.
Normal and MAIN lint, regeneration/current-netlist checks and the ten
`input reg` occurrence check pass. All three whole-core fits have verified
source/project manifests and complete four-corner reports. No CPU-only
result substitutes for a whole-core fit.

Nine CPU changes are retained. These are their isolated family measurements
in ns on the baselines named in the detailed sections; the gains are not
additive. The TLB input/capture audit is reported separately below.

| Retained change | Family before, seeds 1/2 | Family after, seeds 1/2 |
| --- | ---: | ---: |
| Registered TLB fault summary | -0.249 / -0.342 | +0.636 / +0.116 |
| Per-slot interlocks/store forwarding | -0.744 / -0.787 | -0.167 / -0.377 |
| Local barrel pending selects | -0.680 / -0.535 | -0.258 / -0.501 |
| BL and LSL-zero decode | -0.437 / -0.821 | +0.082 / -0.572 |
| Direct cache acknowledgement | -0.812 / -0.639 | -0.346 / -0.092 |
| Binary background-completion tags | +0.061 / -0.639 | +0.321 / +0.567 |
| Effective load-lock factoring | -0.634 / -0.155 | -0.592 / -0.073 |
| Case-local undefined classification | -0.473 / -0.486 | +1.358 / +1.260 |
| Per-slot operand forwarding | -0.645 / -0.273 | -0.095 / -0.302 |

## Measurement method

Every fit uses the main core (`NGAGE_NO_DEBUG=1`), default 16 KB I-cache and
8 KB two-way D-cache, and disabled sequential I-cache prefetch. The original
worktree's macro remains commented while the dedicated build copies enable
it. Seeds 1 and 2 measure each isolated candidate against the same baseline;
a combined retained tree must subsequently be measured at seeds 1–3.

The initially concurrent `NGage_MiSTer-nd-s1`, `-s2`, and `-s3` sweep is this
exact baseline. Local and remote hashes agree for all 150 selected RTL,
framework, lint and project input files. The QSFs agree except for Quartus's
rewrite of `LAST_QUARTUS_VERSION` from Standard to Lite; their seeds and
main-core macro agree. Reusing this sweep avoids three redundant fits.

In addition to the worst-30 full paths and four-corner summary, supplementary
TimeQuest queries report each target family at slow 100C even after it leaves
the worst-30 list. Query definitions and individual paths are archived in
`build/timing5/` and each build copy's `build/timing5-families/`. The family
boundaries include replacement registers, so disappearance of an old register
name alone does not count as an improvement. Compare the worse family
slack across seeds 1/2 before and after; keep both individual results visible.
This is a necessary family gate, with unrelated placement and area effects
reported separately. The initial trials used a stricter requirement that
each individual seed improve; the conservative decisions resulting from
that interpretation are identified below. New trials use the worst-of-pair
criterion, matching the requested measurement across two seeds.
At most two task-owned Quartus containers and four Quartus containers in
total may run. Every build has a separate local and remote directory.
The pending build copies set container `TZ=America/Detroit` when UTC
midnight approaches, keeping the framework-generated `BUILD_DATE` at
`261023`, identical to the baseline. This is a build-copy environment
setting; no framework file or timing constraint is changed.
A simultaneous launch by two independent task drivers briefly raised the
server total to five containers. The task's classification seed-2 mapping
was stopped, its partial build artifacts removed, and the same fixed seed
restarted when a lane opened. No completed fit was discarded. Subsequent
launchers share PID reservations and a launch lock across the rsync and
compile-to-STA gaps; the separate STA launch also checks capacity. Other
engineers' containers were not stopped.

The paired acceptance families are selected before the candidate fits:

| Candidate | Worst slack over these queries |
| --- | --- |
| tag-read split | I-cache stage-one input and its output into stage two |
| multiply | issue operation/classification registers into shifter output registers |
| TLB fault | D-TLB FSR/summary registers into all consumers |
| issue slots | all paths into issue stall copies, pending bits and normal store capture |
| arbiter | arbitration/self-test control and CPU merger address into UPP bus registers |
| BL decode | predecode instruction into decode output registers |

Broader companion queries cover unchanged neighboring paths as a check
against moving the bottleneck outside a narrowly chosen pair of registers.

## Parked ports

All six ports are initially independent of each other, based on `c03088f`.
No original generated netlist was reused: each port regenerated its own from
the current SystemVerilog. All pass 225 CPU runs, 57 QEMU comparisons,
normal and `NGAGE_NO_DEBUG` lint, `make cpu-gen-check`, and the required raw
`input reg` count of 10. Every CPU cycle and instruction count equals the
baseline. The fault-summary and issue ports are retained. The original tag-read,
multiply, arbiter and standalone BL trials are not applied; a combined
BL/LSL-zero decoder trial is retained later, as described below.

1. **262d07a: split stage-one valid/LRU reads.** Register the results of
   small low-index muxes and the high index at the same edge, then select
   the corresponding partial result for the original second stage. Reset,
   clear, hold and pending-write forwarding retain their alignment. The
   shared tag module changes both I- and D-cache; hit-under-miss's stage-two
   early compare remains unchanged. The port preserves the newer cache-size
   index-maintenance fields. Use a constant part slice instead of a sized
   cast to avoid another sv2v helper declaration. Measure both sides of the
   new partial-result registers, and report D-cache effects separately.
2. **ceb793e: registered multiply classification.** Register the multiply
   predicate with the issue output's ALU operation, sharing its hold/clear
   behavior, and use the predicate in the shifter. A cleared invalid slot
   classifies as non-multiply; its operand values are unobservable. No FSM
   edge or multiply latency changes.
3. **b49193a: registered D-TLB fault summary.** The current checker already
   calculates `fsr_nxt` for hit-under-miss. Capture its low-four-bit reduction
   alongside the FSR under the same enable, and feed the FSM's fault output
   from that bit. Preserve the existing `o_hit_ok` logic and FSR contents.
   The shared module also changes the I-TLB; both are measured.
4. **0bcaa1c: per-slot issue decisions.** Resolve interlocks and late-load
   pending masks for live and saved instructions independently. A preserved
   copy of the original stall register selects the finished results. Resolve
   store-data forwarding priorities for each slot before selecting the
   one-hot pick mask. Register-file capture, operand refresh, youngest-writer
   priority, exception exclusion, WAW and shifter locks keep their original
   edges and rules. Other operands retain their original forwarding cone.
   A new helper's argument is named `locked`, avoiding an extra textual
   `input reg` match from `input reg_locked`.
5. **3a5553c: self-test input at the bus arbiter.** Keep CPU and self-test
   signals separate to `wb_arb2`, whose registered one-hot selects form one
   three-input AND/OR. The select uses the same next grant and self-test
   selection captured by the original registers. DMA transaction arbitration,
   acknowledge/error routing, CTI/BTE, and debug observations remain unchanged.
   The existing assertion checks select/grant agreement; system benches cover
   the self-test and DMA paths in addition to the CPU suite.
6. **1297630: BL rewrite after decode.** Decode the normal instruction and
   the constant SUB LR, PC, #4 representation independently, then select their
   decoded fields before the existing output registers. The variable condition
   and exception inputs remain common. The selected instruction still feeds
   the decompiler. No BL micro-op or cycle count changes. Actual-module
   equivalence proves all 2,061 comparison points for the configured ARMv4T
   decoder; the proof harness renames the normal decoder instance to avoid
   matching unlike internal decode inputs.

## Two-seed aggregation and the conservative parked results

The initial per-seed filter was stricter than comparing the worse result
of each two-seed pair. The latter is used for continuing trials, before
`preenable`'s results are available. No path-family boundary or seed is
changed. The original individual numbers and historical dispositions remain
visible; a better worst-of-pair result is not described as a failure merely
because the other seed moves backwards.

- Tag-read split: pair worst −0.165 → −0.068 ns. Parked conservatively:
  the 0.097 ns gain is in a family with little negative slack, at a measured
  cost of 783–889 ALMs; it does not address the present worst families.
- Multiply classification: +0.611 → +1.047 ns. Parked because this measured
  output family already has positive margin. If revisited, also query the
  new classification register's inputs before retention.
- BL rewrite: −0.880 → −0.679 ns. This qualifies by the pair worst; the
  current decoder family is being retested with the complementary LSL-zero
  change as `decodeboth3`, instead of claiming the original pair failed.
- Direct TLB permission summary: −0.653 → −0.425 ns. Parked despite this
  qualifying family gain: whole-core slack worsens from −0.680/−0.732 to
  −1.634/−1.384 ns, and seed 1's targeted family regresses by 0.730 ns.
  The smaller fault-code-bit candidate remains available.

TLB fault, per-slot issue and pending-select qualify under either reading.
The three-input arbiter, rotate-only barrel and standalone LSL-zero trial
regress the pair worst and remain dropped. This clarification changes no
already-fitted RTL or reports and does not itself add a parked change to
the branch.

## Supplementary TLB input-path audit

The original TLB port's selected family measured outgoing FSR/summary paths.
A later audit adds input-side queries to copies of the original routed
baseline and candidate databases, without refitting or changing constraints.
All 150 baseline source inputs and the original corner reports match; only
the reporting hook is added to task-owned copies, leaving the owner's sweep
untouched.

The broad D-TLB checker-input query (FSR, new summary and existing `o_hit_ok`)
changes from +0.515/+0.303 to +0.046/−0.384 ns at seeds 1/2. Its seed-2
limit ends at the pre-existing `o_hit_ok`, from post-ALU1 address bit 30.
Combining this broad query with the original outgoing family changes the
pair worst from −0.342 to −0.384 ns, a 0.042 ns regression. This is recorded
as an additional finding, not silently folded into the earlier outgoing-only
acceptance claim. The original outgoing gain remains +0.458 ns.

The separate FSR/new-summary capture query completes with +0.515/+0.508 ns
before and +0.046/−0.110 ns after. Including those captures and all outgoing
FSR/summary paths improves the D-TLB minimum from −0.249/−0.342 to
+0.046/−0.110 ns: both seeds improve, and the pair worst improves by 0.232 ns.
The I-TLB capture figures are +0.361/+1.044 before and +0.920/+0.094 after;
its capture/output pair worst also improves, from −0.218 to +0.094 ns.
Thus the changed register boundary passes the supplementary check and the
TLB port remains retained. The broader neighboring `o_hit_ok` regression
above is preserved as a separate finding and is included in the final
whole-core assessment, not hidden by the narrower capture result.

## CPU cycle evidence

Existing binaries and QEMU references are reused. The baseline, all fitted trials and retained combinations pass **225/225 runs**, **57 agree / 0 differ**. Across the
225 runs, the baseline totals **20,630,566 cycles**; every candidate has the
same total and every individual cycle/instruction pair agrees. There are no
moved tests. Full per-run JSON tables and logs are in `build/timing5/` and
`sim/cpu/build/timing5/baseline/`.

| Test | 0:0 baseline = each port | 0:3 baseline = each port | 2:9 baseline = each port |
| --- | ---: | ---: | ---: |
| cache | 789362 | 917207 | 1251084 |
| ctrand1 | 72413 | 102215 | 178927 |
| crand1 | 72922 | 104399 | 187183 |
| gba_arm | 8183 | 10785 | 17742 |
| gba_thumb | 4917 | 6509 | 10831 |
| walloc_rtl | 67402 | 97006 | 173816 |

The arbiter also passes `make -C sim upp periph save top`. Filtered bench
output matches the baseline exactly: peripheral 3,643,060 clocks, save
31,071,940 clocks, synthetic whole-core shell/self-test 159,279,244 clocks.
This is the normal small-program top bench, not the firmware boot bench.
An actual-module miter also proves the old two-master arbiter plus external
self-test mux equivalent to the new arbiter for arbitrary bus inputs, with
the self-test selection registered as in `NGage.sv`. Temporal induction
closes at step three. This checks all output bits and reset/arbitration
transitions, not just the exercised self-test transactions.

## Timing results and disposition

Baseline main-core slow-100C setup slack is −1.152 / −1.285 / −0.861 ns for
seeds 1 / 2 / 3: **median −1.152 ns**. The fits use 35,361 / 35,494 / 35,591
ALMs and 477 RAM blocks. The worst seed-one path is predecode skid bit 25
into `o_v5_und_ff`; seed two is CP15 `o_mmu_en` through cache-stall control
into ALU flags; seed three is Thumb instruction-valid into `o_v5_und_ff`.

| Candidate | Family seed 1 before → after | Family seed 2 before → after | Whole core seed 1 / 2 | Decision |
| --- | ---: | ---: | ---: | --- |
| tag-read split | −0.014 → −0.068 | −0.165 → +0.128 | −0.695 / −0.661 | Drop |
| multiply classification | +1.182 → +1.070 | +0.611 → +1.047 | −0.722 / −0.668 | Drop |
| TLB fault summary | −0.249 → +0.636 | −0.342 → +0.116 | −1.055 / −1.148 | Keep |
| per-slot issue decisions | −0.744 → −0.167 | −0.787 → −0.377 | −0.454 / −0.820 | Keep |
| three-input arbiter | −0.562 → −0.334 | −0.382 → −0.982 | −0.924 / −1.468 | Drop |
| BL rewrite after decode | −0.880 → −0.679 | −0.553 → −0.602 | −1.075 / −0.986 | Drop |

Under the initial per-seed filter, the tag-read split was dropped because
its targeted stage-one family regresses
by 0.054 ns at seed 1, despite improving by 0.293 ns at seed 2. The new worst
stage-one paths start at writeback PC bit 18 (seed 1) and the I-TLB state
(seed 2). The following stage stays positive (+1.965 / +3.231 ns). Its
whole-core improvements are insufficient under the paired-family rule; the
extra 889 / 783 ALMs also have no consistent targeted timing benefit. RAM
blocks remain 477. Full 225-run cycles and all 57 QEMU comparisons are
unchanged. No tag-read RTL from this trial is applied to the main branch.

The multiply classification is dropped because its output family regresses
by 0.112 ns at seed 1, despite improving by 0.436 ns at seed 2. Its wider
operation-to-shifter family, including the multiplier's own input capture,
also remains separate from the targeted output classification. No multiply
RTL from this trial is applied to the main branch.

The TLB fault summary is retained: the D-TLB family improves by 0.885 /
0.458 ns at seeds 1 / 2. Its I-TLB companion improves from −0.218 / +0.255
to +0.588 / +0.279 ns. The fits use 35,655 / 35,615 ALMs and 477 RAM blocks.
The new whole-core worst paths are UPP `ack_q` into merger data capture
(seed 1) and D-cache lookup repair into the stage-one LRU read (seed 2).
After applying the port to this branch, all 225 counts, 57 comparisons,
both lint configurations and generated-netlist checks pass again. Only the
three TLB modules change in the generated netlist; sv2v also reorders module
text, accounting for the large generated diff.

The per-slot issue port is retained: the preselected worst over interlock
feedback, pending-mask capture and store capture improves by 0.577 / 0.410
ns at seeds 1 / 2. The feedback endpoints alone improve from −0.744 / −0.787
to −0.010 / −0.377 ns. Pending capture moves from +0.648 / −0.049 to
−0.167 / −0.186 ns; store capture moves from −0.113 / −0.036 to
−0.086 / −0.274 ns. These neighboring regressions are included in the
family minimum, rather than omitted. The fits use 35,963 / 35,823 ALMs and
477 RAM blocks. New worst paths are decode condition into predecode CP15
capture (seed 1) and self-test selection into UPP bus decode (seed 2).
The TLB+issue combination passes all 225 unchanged counts, 57 comparisons,
both lint modes and generated checks. Its combined timing is reported below.

The three-input arbiter is dropped: the worst over arbiter control and
merger address improves by 0.228 ns at seed 1 but regresses by 0.600 ns at
seed 2. Separately, arbiter control is −0.154 / −0.982 ns and merger address
is −0.334 / −0.668 ns. Its passing CPU, system-bench and equivalence results
do not compensate for the timing regression. No arbiter, NGage or harness
changes from this trial are applied to the branch.

Under the initial per-seed filter, the BL rewrite was dropped: its
predecode-to-decode family improves by
0.201 ns at seed 1 but regresses by 0.049 ns at seed 2. All six isolated
ports now have completed paired fits. Source manifests for both seeds of
every port match their remote build inputs (149 files, with only Quartus
version metadata differing in the QSF). Baseline timing constraints and
project/QIP files also match at all three seeds.

The retained TLB+issue tree has completed its first three-seed combined
measurement. No candidate is retained on simulation results alone.

## First combined tree

The first retained combination is `35aa83e` (TLB summary + per-slot issue,
plus the six-port disposition report). Seeds 1 / 2 / 3 are **−0.680 / −0.732 / −1.350 ns**,
using **34,872 / 35,032 / 34,960 ALMs**, with 477 RAM blocks. All three
source manifests match the remote builds. The median is **−0.732 ns**, a
0.420 ns improvement over the original median, but below the −0.300 ns
goal. No timing closure is claimed.

Seed 1's worst path is issue `o_load_pending_ff[1]` through the barrel shifter
into `o_shifted_source_value_ff[16]` (−0.680 ns); the next paths are saved
operand index into normal ALU-source capture (−0.650 ns) and the externally
owned card model (−0.600 ns). Seed 2's worst path is predecode instruction
bit 4 into decode's LSL-zero summary (−0.732 ns). The TLB RAM into the new
fault-summary register is next at −0.653 ns. The shifter-output family is
−0.535 ns in seed 2.

Seed 3 is led by I-cache tag forwarding into the fetch FIFO empty flag
(−1.350 ns), followed by the D-cache lock into CP15 command capture
(−1.304 ns), UPP acknowledge into merger address (−1.187 ns), and the
barrel shifter (−1.038 ns). Its card model is −0.602 ns, close to seeds
1 / 2 at −0.600 / −0.584 ns. The card owner's fix has since merged into
master; it is integrated unchanged in the second combined tree below.
The independent paired comparisons retain their original baseline.

Supplementary queries include both sides of the new TLB summary. The
checker-input family is +0.511 / −0.653 / −0.644 ns; the normal issue
forwarding captures are −0.650 / −0.565 / −0.865 ns. These remain separate
from the issue interlock family improved by the retained port.

The combined issue acceptance family is −0.195 / −0.372 ns, still better
than both original seeds. The D-TLB summary's outgoing family is +0.705 /
−0.360 ns: seed 2 is 0.018 ns worse than the original baseline despite the
isolated port's paired improvement. The new incoming summary path also
needs attention. These interactions are reported rather than treating the
isolated results as a guarantee for the combination. The next TLB trial
measures both incoming and outgoing paths.

The equivalent rotate-barrel candidate, rebased onto this combination as
`rotate2`, is **dropped**. The shifter-output family is −0.680 → −0.572 ns
at seed 1 but −0.535 → −0.864 ns at seed 2. Whole-core results are
−0.806 / −0.864 ns. Both source manifests match the remote builds. Its
full suite, 57 QEMU comparisons, both lint modes and generated checks pass,
with all 225 cycle/instruction pairs unchanged; that is insufficient to
retain a timing regression. The first fit attributes about 155 ALMs to the
barrel versus 213 in the combined baseline, but total utilization rises
from 34,872 to 35,885 because physical optimization and packing differ.
No rotate RTL is applied to the branch.

The decoder LSL-zero trial is **dropped**. Its complete predecode-to-decode
family is −0.348 → −0.262 ns at seed 1 but −0.732 → −0.991 ns at seed 2;
whole-core slack is −0.879 / −1.128 ns. Both input manifests match. All
225 cycle/instruction pairs and 57 QEMU comparisons agree, and lint and
generated checks pass. Removing the translation mux from one summary does
not produce a consistent routed gain across this family. No decoder RTL
from this trial is applied to the branch.

## Second combined tree, with the card fix

`combined2` fits source `d8b1d1c`: the retained TLB and issue ports, plus
the card owner's change merged unchanged through `e0c34d0`. MAIN seed
1 / 2 / 3 setup slack is **−0.812 / −0.854 / −0.703 ns**: **median −0.812 ns**.
The goal remains unmet. The 0.340 ns improvement over the original median
includes the external card fix and placement effects; it is not attributed
entirely to the CPU edits. All three input manifests match. Fits use
35,666 / 35,552 / 35,571 ALMs and 477 RAM blocks. Minimum hold slack across
the four reported corners is +0.026 / +0.077 / +0.078 ns.

| Family | Seed 1 | Seed 2 | Seed 3 |
| --- | ---: | ---: | ---: |
| card model | +0.159 | +0.363 | +0.461 |
| predecode prediction payload | −0.812 | −0.301 | +0.236 |
| shifter output | −0.561 | −0.854 | −0.450 |
| predecode to decode | −0.437 | −0.821 | −0.348 |
| issue interlock feedback | −0.346 | −0.334 | −0.703 |
| issue forwarding captures | −0.526 | −0.559 | −0.314 |
| D-TLB outgoing fault | −0.289 | +0.410 | +0.225 |
| D-TLB checker inputs | −0.373 | +0.118 | +0.079 |
| merger address to UPP | −0.673 | −0.149 | −0.525 |
| arbitration control to UPP | −0.683 | −0.329 | −0.151 |
| all merger register inputs | −0.400 | −0.451 | +0.219 |

Seed 1 is led by D-cache early hit through stall/clear into predicted-PC
capture. Seed 2 is led by issue shift-source into the barrel result, followed
by predecode instruction bit 17 into the LSL-zero summary. Seed 3 is led by
decode shift-source into issue's stall-index register. The card family is
positive throughout. The input and output sides of the TLB change and the
remaining issue feedback are kept visible; isolated gains still do not
predict every combined seed.

The predecode payload query was added before seeds 2/3's timing analysis;
a report-only rerun on seed 1's existing routed database supplies the same
query there. No fit, source, clock constraint or seed changed. The pending
select change is retained after this measurement, with the full suite and
57 QEMU comparisons repeated on the integrated branch and every count
unchanged. Its combined three-seed timing is still to be measured.

## Third combined tree, all six retained CPU changes

`combined3` fits source `11bbda3` at the same three fixed MAIN seeds.
Slow-100C setup slack is **−0.645 / −0.486 / −0.880 ns**, with **median
−0.645 ns**. This improves the original median by 0.507 ns and the previous
retained combination by 0.167 ns, but still misses −0.300 ns. The original
comparison includes the external card fix, so it is not attributed solely
to the CPU changes. All 149 source/configuration manifest entries match at
every seed, apart from Quartus version metadata in the QSF.

Fits use 34,859 / 34,872 / 34,779 ALMs and 479 M10Ks. Minimum hold slack over
all four corners is +0.016 / +0.068 / +0.108 ns. The source combination passes
all 225 exact cycle/instruction counts, 57 QEMU comparisons, both lint modes,
generation/checks and the ten-occurrence check.

| Family | Seed 1 | Seed 2 | Seed 3 |
| --- | ---: | ---: | ---: |
| issue forwarding capture | −0.645 | −0.273 | −0.400 |
| issue interlock feedback | −0.634 | −0.155 | −0.391 |
| issue pending inputs | +0.050 | +0.382 | −0.296 |
| predecode undefined classification | −0.473 | −0.486 | −0.373 |
| predecode to decode | +0.014 | −0.101 | +0.035 |
| shifter output | +0.032 | +0.184 | −0.226 |
| D-cache FSM state to merger address | +0.168 | +0.686 | +0.242 |
| all merger register inputs | −0.340 | +0.317 | −0.202 |
| cache/CP15 control to core | −0.345 | −0.023 | −0.296 |
| background completion pickup | +1.023 | +0.898 | +1.184 |
| D-TLB outgoing fault | +0.405 | +1.167 | +0.549 |
| D-TLB checker inputs | +0.485 | −0.072 | +0.034 |
| I-cache valid/LRU capture | −0.260 | +0.041 | −0.599 |
| all UPP register inputs | −0.100 | −0.056 | −0.527 |
| owner-supplied card model | +0.180 | +0.618 | +0.583 |

Seed 1 is led by memory-load validity through ALU late-hold qualification
and forwarding into issue's normal shift-source bank, followed by decode's
shift-length index through late admission into the issue stall. Seed 2 is
led by Thumb instruction-valid through predecode classification into
`o_v5_und_ff`. These motivate the next isolated trials below.

Seed 3 is led by UPP `fl_chip` through flash-save control into the bitmap
RAM's write-enable register (−0.880 ns), followed by writeback PC into I-cache
LRU/valid capture (−0.599/−0.561 ns). Its bus-address-to-UPP family reaches
−0.527 ns. These remain reported even though they do not set this tree's
median. The seed-2 compiler emitted a loader shutdown assertion after
completion; its separate corner/family analysis completed, its bitstream
exists, and its fitted source manifest matches. No refit or seed replacement
was used.

## Further candidates prepared from the main-core baseline

**Predecode classification:** classify the live instruction for both ARM
and Thumb before selecting the skid slot. Classifying zero is false in both
modes, so instruction-valid qualifies the final two classification bits
instead of all 35 instruction bits. Save those bits and a Thumb-BL marker
with the skid payload under its existing enable. Current mode selects the
appropriate result, preserving behavior across a held slot. In ARMv4T IDLE,
the sequencer selects this early result and masks the Thumb BL markers and
NV link micro-op using the preclassified marker. Other sequencer states and
non-V4T configurations retain classification of the generated micro-op. No
instruction-valid, stall or clear edge changes. This extends the earlier
parallel-classification experiment in timing3 trial 16 by moving the logic
before the skid mux and saving its result with the held instruction.

The initial candidate and its refined `classify2` port onto the retained
TLB+issue tree pass all 225 unchanged counts and 57 QEMU comparisons. A SAT
check of the actual sequencer proves the rewrite classification identity
for arbitrary defined inputs and state wherever the early result is
selected. A separate induction check of the actual predecode and its child
modules proves the saved classification/marker relationships and equivalence
to the original classifier on every valid emitted instruction after reset.
Main/debug lint and generated checks pass. The target family includes all paths
into `o_v5_und_ff` and the new saved classification/marker registers; paired
fits are still pending.

**ALU flag enable:** extract the flags register from the broad pipeline
output priority block. Its dedicated enable includes the original data
hold, fault, sleep, redirect and instruction-condition qualifications.
Reset still wins and writeback can still replace CPSR during a data stall.
The normal D input is `flags_nxt`, with failed conditions expressed as holds.
No other ALU outputs or pipeline edges change. The full suite and QEMU diff
pass with identical counts; equivalence of the original and changed ALU
modules is proved (1,566 comparison points, no unproved points). Main/debug
lint and generated-netlist checks pass. The acceptance family is cache/MMU
control into ALU and shifter registers, including both the flags path and
neighboring stall consumers. Whole-core timing acceptance is pending.

**D-cache address payload:** remove request/fault/cacheability and final-beat
qualification from the bus address mux. Registered FSM/context selects the
translated uncached address, saved clean/fill line address or held bus
address. STB/CYC, byte enables, write controls and FSM transitions are
unchanged. Inactive addresses may change; active transfers retain the same
address and launch edge. All 225 cycle/instruction pairs and 57 QEMU
comparisons agree; normal/main lint and generated checks pass. A full-module
bounded check also reaches nine clocks from reset without a mismatch, but
induction did not close, so this is not claimed as an equivalence proof.
The timing acceptance family is D-cache FSM state into merger address.

**Rotate barrel:** express ROR/RORI/ROR_1 as the low word of a doubled
source shifted right by the low five amount bits, replacing two shifts,
`32 - amount`, and an OR. Carry, zero-amount and saturation rules are
unchanged. Combinational equivalence of the actual shifter modules passes;
all 225 runs and 57 QEMU comparisons have identical counts. The acceptance
family covers all paths into shifter result/carry/saturation registers,
including unchanged neighboring stall paths. Its baseline worst paths are
present in the unfiltered worst-30 reports: −0.583 / −0.961 / −0.749 ns.

**D-cache acknowledge factoring:** express the existing IDLE and UNC_DONE
acknowledge cases directly, outside the FSM's hit/victim priority mux. Every
cacheable write-back request acknowledges in IDLE, whether it hits or starts
a background miss; write-through and uncached requests still wait, and the
alignment/MMU/walk outcomes retain their existing acknowledge edge. HUM is
unchanged. All 225 counts and 57 QEMU comparisons agree, both lint modes and
generation checks pass. Actual-module equivalence proves 1,763 comparison
points under the FSM's one-hot-state invariant; a separate induction check
on the actual changed FSM proves that invariant after reset. The acceptance
family is cache/MMU control into ALU/shifter registers. The candidate is
prepared; no fit is counted yet.

**CP15 command payload:** the issue-only fit exposes pipeline-empty control
into predecode's command banks. A prepared candidate presents the instruction
in coprocessor IDLE and the saved command in BUSY; DAV alone qualifies the
payload. Launch, completion, stalls, interrupts and clears keep their
original logic. Full-suite counts and 57 QEMU comparisons agree, with lint
and generation checks passing. A two-valued protocol miter proves matching
valid command data and controls by induction; it includes state, valid and
valid saved-word observers to preserve the induction relationship. Inactive
command words may differ. This candidate has not been fitted or retained.

**UPP next-line comparison (`buscompare`):** capture the predecessor of
the SDRAM line beside `blk`, then compare the unincremented live bus address
with the current or predecessor line. Wrap-four keeps the line; wrap-eight
and wrap-sixteen use their small wrapped low-bit comparisons. This removes
the live wide increment from the line-boundary control decision. All request,
acknowledge, data and address-register edges remain unchanged. The saved
predecessor is updated on every existing `blk` write, including read-line
continuations. The proof covers arbitrary addresses and all four BTE modes,
not an assumption that the master always addresses the current line.

Actual-module induction proves the saved-predecessor invariant and both
old/new line comparisons whenever the SDRAM states use them. The CPU suite
and QEMU comparisons are unchanged. UPP, peripheral, save and synthetic top
benches pass with the same 26 clock/result lines as the baseline (including
159,279,244 clocks for the synthetic top bench). Main/debug lint and generated
checks pass. Paired whole-core fits against the combined tree are pending;
acceptance covers arbiter control and merger addresses into all UPP registers,
including the new predecessor register.

**Background-load index (`bgindex`):** capture a six-bit index and nonzero-mask
valid bit with the miss context, then emit them at the same critical-beat edge
as the existing registered write mask and data. The shifter and ALU compare
this binary index for late pickup, replacing six 64:1 mask selections. The
one-hot mask continues to write the register file and clear locks. Stores,
uncached accesses, critical-word-first, hit-under-miss and error completion
keep their existing state transitions. Reset clears both completion-valid
representations; an inactive binary payload is not observed.

The core already produces a one-hot mask from the same binary index. Under
that interface relationship (also allowing an empty mask), induction on the
actual FSM proves the saved and emitted representations agree. A separate
SAT check proves the old mask-select and new compare for every operand index.
All 225 counts and 57 QEMU comparisons agree; both lint configurations and
generated checks pass. Before any paired results, the target is fixed as
completion mask/index/valid into ALU and shifter registers; the broader
cache/MMU stall query remains a companion check. The reporter-only query
is added to the in-flight combined baseline without changing any synthesis
inputs. This candidate is prepared on the TLB+issue tree but not yet fitted.

**Local barrel pending selects (`pendingselect`):** the existing preserved
source-pending register was used by the forwarding bypass but the barrel
instance still used the general pending vector. Quartus reports this copy as
protected: the attribute survived synthesis. Its documented
[`preserve` attribute](https://resources.altera.com/quartushelp/17.0/hdl/vlog/vlog_file_dir.htm)
prevents synthesis removal of the register; the missed barrel connection is
the issue here. Route the barrel's source
mux from that existing copy, and add the corresponding amount-pending copy
at the same issue edge. Both have the original pending bits' reset, clear,
load and held-completion behavior. No new mux, operand source or pipeline
edge is introduced. This targets the actual pending-bit paths seen in both
combined seeds; the acceptance minimum includes shifter output and issue
pending capture, including the new copy's D path. Induction on the actual issue module proves both copies equal their
original pending bits after reset, for arbitrary inputs, clears and holds.
The full suite and QEMU diff retain all counts; both lint modes and generated
checks pass. Paired timing results are recorded below.

**Direct TLB permission summary (`tlbsummary`):** compute each domain's
one-bit permission outcome before the domain selection, then register the
selected outcome directly instead of reducing the encoded FSR after its
mux. Small-page and section invalid-descriptor/external-abort cases still
force a fault; large/fine pages keep their original rules. The encoded FSR,
FAR, translations, cache attributes, walk behavior and checker enable stay
unchanged. HUM's registered permission uses the same new summary. All 149
actual-module equivalence points prove in both MMU-off cacheability configurations, and all 225 counts / 57 QEMU
comparisons remain identical. Its pre-fit acceptance family includes both
all D-TLB fault/permission-register inputs and the outgoing fault summary;
I-TLB inputs and outputs are companion queries. Paired results are recorded below.

**LSL-zero summary before translation (`lslzero`):** compare the decoder's
raw shift length with immediate zero before register-bank translation.
Immediate operands pass translation unchanged; index operands have their
immediate bit clear on both sides and cannot match. The instruction decoder,
translated operand and every register edge are unchanged. This removes the
bank-translation mux from the summary path identified as seed 2's worst.
Actual-module equivalence proves all 2,345 points for the configured decoder.
All 225 cycle/instruction counts and 57 QEMU comparisons agree; both lint
modes and generated checks pass. Its two-seed trial is queued after the
supplemental baseline timing queries, with the entire predecode-to-decode
output family as the acceptance criterion.

The issue-stage equivalence check proves all 2,135 comparison points after
supplying the saved-slot mirror invariants. Separate two-valued induction
checks on the original and changed modules prove those invariants after
reset without initializing the hardware state: the stall copies agree and,
while selected, the index/immediate/store copies match the packed skid slot.
The proof uses a reset-seen flag only in its harness. Removing duplicate
alias cut points avoids treating the same stall register as independent
state. The first monolithic proof timed out; no RTL change was needed to
close the refined proof. Required suite, QEMU and cycle checks also pass.

**Fetch FIFO flags (`fifoflags`):** compute incremented pointer values and
empty/full comparisons from the registered pointers before the late cache
acknowledge. The read/write enables select the finished comparisons;
advancing both pointers preserves their modular separation, including the
wrap bit. Pointer registers use the same precomputed increments. Reset,
clear, simultaneous read/write, empty/full guards and memory writes retain
their original edges. Actual-module equivalence proves all 1,730 points for
the configured 100-bit, 16-entry FIFO without reachable-state assumptions.
All 225 counts and 57 QEMU comparisons agree; both lint modes and generated
checks pass. The acceptance family includes all paths into FIFO flags and
read/write pointers, so shortening flags at a pointer's expense cannot hide
in the comparison. Supplemental baseline queries precede the paired trial.

**Shared barrel (`sharedshift`):** a separate candidate from the dropped
rotate-only rewrite uses one five-level right barrel for LSL, LSR, ASR and
ROR. Bit reversal handles LSL; zero, sign or repeated-source fill supplies
the upper word. The original results/carry for zero, exactly 32, larger
amounts and rotate multiples of 32 are preserved. RRX and saturating shift
remain unchanged. Actual-module equivalence proves all 35 comparison points
for every operation, source, carry and 8-bit amount. The full suite, 57 QEMU
comparisons, both lint modes and generated checks pass with all counts
unchanged. Its target remains the complete shifter-output family; no fit or
retention is claimed yet.

**Saved special-register picks (`staticpick`):** capture nine classification
bits with the existing issue skid indices: PC, zero and CPSR for each of
ALU source, shift source and shift length. The late slot selector chooses
these classifications instead of placing a selected-index equality compare
before forwarding priority. Live operands are classified before selection;
store forwarding retains its existing per-slot combinational classification.
Immediate priority, dynamic producer matching, youngest-writer priority,
PC alignment, register-file capture and all operand clock enables are
unchanged. No pipeline edge is added.

Induction on the actual issue module proves the saved/selected classification
identity after reset, including holds and clears. Under that separately
proved identity, all 4,045 actual-module equivalence points prove. All 225
counts and 57 QEMU comparisons agree; main/debug lint and generated checks
pass. The pre-fit acceptance minimum includes normal operand captures,
inputs to the new saved classification registers, and issue interlock
feedback. Paired fits are pending.

The card owner's merged change is integrated unchanged in `e0c34d0`.
The CPU suite, all cycle/instruction counts, 57 QEMU comparisons, both lint
modes and generated checks pass again after integration. Candidate pairs
already prepared against `35aa83e` retain that baseline; the next combined
three-seed trial will include the card fix.

**Combined decoder follow-up (`decodeboth`):** the standalone early-zero
trial's seed-2 worst path moves to BL-rewrite control through normal shift
length decode. A prepared combined trial therefore selects the BL fields
after decode and computes the LSL-zero summary before bank translation.
The acceptance family still includes every predecode-to-decode output,
not just the summary. All 2,061 actual-module equivalence points prove for
the configured decoder. The full suite and QEMU diff retain every count,
with both lint modes and generated checks passing. This is a new candidate;
it does not reinstate either dropped trial without a paired fit.

**Fault-code bits (`tlbbits`):** every nonzero FSR emitted by this checker
is odd or has bit 3 set: section/page translation, domain and permission
faults are odd; L1/L2 external aborts are 12/14. Reduce bits 3 and 0 for the
registered fault summary and the registered hit-permission qualification.
The full architectural FSR is unchanged. All 157 actual-module equivalence
points prove with MMU-off cacheability both zero and one; all 225 counts
and 57 QEMU comparisons agree, with both lint modes and generated checks
passing. The input/output TLB family remains the same acceptance group.
This simpler candidate is prepared but not fitted.

The broader `tlbsummary` trial remains parked (see the aggregation note):
its D-TLB input/output family changes from +0.511 to −0.219 ns at seed 1,
and from −0.653 to −0.425 ns at seed 2. Whole-core slacks are −1.634 and
−1.384 ns. Both source manifests match, and all 225 cycle/instruction
counts remain unchanged with 57 QEMU agreements. Although the worse of
the two family results improves, the first seed regresses by 0.730 ns;
that distinction is preserved for review rather than treating the pair as
an unqualified gain.

The `pendingselect` trial is retained after its paired result: the minimum over the
complete shifter-output and issue-pending input families improves from
−0.680 to −0.258 ns at seed 1 and from −0.535 to −0.501 ns at seed 2.
The second seed's shifter result is −0.396 ns; the new limiting member
is a pending-bit input at −0.501 ns. Whole-core slacks are −1.286 and
−0.899 ns, with 477 RAM blocks in both fits. The 0.034 ns second-seed
improvement is small; it is not evidence that the whole core closes.
Both source manifests match and every count is unchanged. Its paired fits
use the original combined1 baseline. It is applied only after `combined2`
completes, so the −0.812 ns median above does not include this change. The
integrated branch also passes all 225 identical counts, 57 QEMU comparisons,
both lint modes and generated checks.

**Shared D-cache bus request (`dcstrobe`):** all three internal managers
(cache FSM, tag maintenance FSM and TLB walker) assert CYC and STB together.
Reuse the wrapper's existing parallel CYC result for STB, removing its
separate priority selection. Arbitration priority, error completion, burst
boundaries, payload and acknowledgement routing are unchanged. This candidate
is based on `combined2`, including the card fix.

Actual-module induction proves both registered and next CYC/STB equality
for each manager after reset. The tag proof treats RAM outputs as arbitrary;
it does not depend on particular memory contents. Under those separately
proved invariants, all 1,249 wrapper equivalence points prove. All 225
cycle/instruction counts agree, 57 QEMU signatures agree, and both lint
modes, generation and generated-file checks pass. The pre-fit acceptance
query includes every registered merger input, including owner, control,
address and speculative data captures. It is prepared, not retained or
fitted; the current combined build takes priority.

**Prediction-payload enables (`preenable`):** the first `combined2` seed's
worst path is registered D-cache early hit through global stall/clear into
predecode's predicted PC, at −0.812 ns. Extract the predicted PC, redirect PC
and RAS pointer into a separate sequential block with their direct enable.
An update already requires no stall, so the ALU and decode clear predicates
need no additional stall qualification. These payloads retain their exact
hold-on-clear behavior; valid/control outputs retain their original clears.
There is no new register, mux source, prediction, pipeline edge or cycle.

Actual-module equivalence proves all 1,121 points with the configured
four-entry RAS, and all 1,252 with an eight-entry RAS; all 225 counts and 57 QEMU comparisons agree, with both lint
modes and generated checks passing. The acceptance family includes all
inputs to the three changed payload registers. The candidate is based on
`combined2`. Drop it after the paired fit: the payload family changes
from −0.812 to −0.942 ns at seed 1 and from −0.301 to −0.243 ns at
seed 2, a 0.130 ns regression in the worse result. Whole-core slacks are
−1.173/−1.058 ns. Both source manifests match; every count is unchanged.
The older bus-comparison candidate is
also rebased onto `combined2` as `buscompare3`; its UPP module bytes exactly
match the previously proved candidate, and its CPU counts remain unchanged.
Its paired UPP/peripheral/save/synthetic-top benches also pass, with all 109
clock/result/distribution lines identical to the current combined baseline.
The combined decoder candidate is rebased as `decodeboth3` onto this same
baseline; its module bytes match the proved version, and all CPU/lint/generated
checks pass before its paired fit.

Retain `decodeboth3` after the paired fit: the decoder family improves from
−0.437 to +0.082 ns at seed 1 and from −0.821 to −0.572 ns at seed 2
(worst-of-pair gain 0.249 ns). Whole-core slacks remain −0.811/−1.024 ns;
the worst paths move to issue lock selection and late-memory pickup into
the shifter. The fits use 35,100/35,058 ALMs and 477 RAM blocks, versus
35,666/35,552 ALMs for their matching baseline seeds. Both source manifests
match. The integrated branch, including the retained pending-select copies,
also passes all 225 identical counts, 57 QEMU comparisons, both lint modes
and generated checks. A fresh combined three-seed fit remains required.

**Binary cache destination tags (`dctags`):** extend the background-index
candidate to the issue interlock and memory-load-valid check. Save the six-bit
destination with the existing miss context, and use equality comparisons
instead of variable selections from a 64-bit mask. The unchanged lock mask
still supplies active/clear timing and all barriers; the unchanged completion
mask still writes the register file. Binary completion index/valid are
registered at exactly that completion edge. No live cache data or additional
pipeline edge enters operand pickup.

Induction on the actual FSM proves the lock is zero or exactly the bit named
by the saved context, and proves that completion index/valid encode the
original completion mask. The only interface assumptions are facts wired
by `zap_core`/`zap_top`: the request mask decodes its binary index, and read
and write are mutually exclusive. Supporting beat-counter, state and context
invariants are proved as assertions, not assumed. Checks pass for 8 KB/two-way/
16-byte lines, 8 KB/one-way/8-byte lines, 8 KB/two-way/32-byte lines and
16 KB/two-way/16-byte lines. Under that proved identity, all 4,045 actual
issue-module equivalence points prove; the mask-select/equality identity
also proves for every six-bit operand. All 225 counts and 57 signatures
agree, with both lint modes and generated checks passing.

The acceptance minimum covers issue feedback, pending-bit capture,
background pickup into ALU/shifter, and all inputs to the saved/emitted cache
destination tags. A supplementary baseline query includes the original
one-hot registers too, so moving delay into the new binary captures cannot
hide. Drop this combined trial after its paired fit. The acceptance minimum changes
from −0.346 to −0.088 ns at seed 1 and from −0.639 to −0.768 ns at seed 2;
the worse result regresses by 0.129 ns. Background pickup itself improves
from +0.061/−0.639 to +1.194/+0.965 ns, but seed 2's issue-feedback path
from post-ALU1 load-valid to `stall_idx_ff` becomes limiting. The previously
selected family boundary is retained; the background-only result cannot
justify applying the wider lock-index change. Whole-core slacks are
−0.651/−0.917 ns, at 34,989/35,085 ALMs and 477 RAM blocks. Both source
manifests match.

An integration preview on the retained tree resolves only the shifter
input-list overlap, keeping the pending-select copy and replacing the old
completion-mask input with the binary interface. That preview also passes
all 225 exact counts, 57 QEMU comparisons, both lint modes and generated
checks. Neither it nor the isolated trial is applied. The
single-outstanding-miss invariant is essential; a future cache supporting
multiple outstanding misses would need a matching multi-entry interlock.

**Prediction-payload banks (`prebank`):** a separate replacement for the
failed direct-enable trial stores predicted PC and redirect PC in two banks.
The inactive bank captures their next values; the exact original acceptance
condition toggles a one-bit selector. Reset zeroes both banks, and stalls or
flushes retain the selected payload exactly. The RAS pointer and all valid,
clear and exception registers retain their original implementation. This
adds 65 flip-flops and a two-input output mux, without a pipeline edge.

All 1,121 actual configured predecode comparison points prove, including
induction for the 64 changed payload bits with the sequencer and coprocessor
modules flattened. All 225 CPU counts remain exact, 57 QEMU comparisons
agree, both lint modes pass, and generation/checks retain ten textual
`input reg` occurrences. The paired acceptance group covers all original
payload/RAS inputs, replacement bank/selector inputs, and paths from the
old payload or replacement banks into all consumers. It is prepared on
`combined2`, not retained or fitted.

**Direct cache acknowledgement (`dcack3`):** rebase the already-proved
acknowledge candidate onto `combined2`. Cacheable write-back hits and misses
all acknowledge in IDLE; express their shared result directly alongside
UNC_DONE, outside the FSM's hit/victim priority mux. Preserve alignment,
translation and walk outcomes, uncacheable/write-through holds, CP15 handling,
and the separate hit-under-miss acknowledgement. No cache data path changes.

The actual module is byte-identical to the earlier proved candidate: all
1,763 equivalence points pass under an independently proved one-hot state
invariant. The current-baseline rebase passes 225 exact counts, 57 QEMU
comparisons, both lint modes and generated checks. Its pre-fit acceptance
family is deliberately broad: every path from the D-cache or CP15 MMU-enable
register into the core, so predecode/fetch consumers of the late stall cannot
escape the check.

Retain `dcack3`: the cache-to-core minimum improves from −0.812 to
−0.346 ns at seed 1 and from −0.639 to −0.092 ns at seed 2, a
0.466 ns worst-of-pair gain. Whole-core slacks are −0.505/−0.444 ns;
the remaining worst paths start in arbitration/self-test address control
and end in the UPP bus. Four-corner minimum hold slacks are +0.108/+0.114 ns.
Fits use 35,735/35,738 ALMs and 479 M10Ks. The two extra M10Ks in the
seed-1 packing are an inferred post-ALU `o_flags_ff` shift-register group;
I-cache and D-cache physical RAM counts are unchanged (26/43, including
their TLBs). Logical RAM-table entries share physical blocks, so their
individual block counts must not be summed. Both source manifests match.
The integrated retained tree also passes all 225 exact counts, 57 QEMU
comparisons, both lint modes and generated checks.

**Background completion tags only (`bgindex3`):** rebase the earlier
background-only candidate onto `combined2`. It changes the registered
completion index/valid and the ALU/shifter match; it leaves the issue lock
bitmap, issue interlocks and memory-load-valid check untouched. This is a
smaller implementation than the dropped `dctags` trial, requiring its own
paired measurement. The pre-fit minimum includes background pickup and all
old/new cache destination-register inputs. It reuses the unchanged actual-FSM
completion identity and arbitrary-operand match proof. All 225 counts,
57 QEMU comparisons, both lint modes and generated checks pass. Retain the separately measured `bgindex3`: the minimum over background
pickup and tag capture improves from +0.061 to +0.321 ns at seed 1 and
from −0.639 to +0.567 ns at seed 2 (worst-of-pair gain 0.960 ns).
Background pickup alone is +0.769/+0.567 ns; tag inputs are +0.321/+0.958 ns.
Whole-core slacks are −0.509/−0.593 ns at 35,213/35,216 ALMs and 477 M10Ks.
Four-corner minimum hold slacks are +0.070/+0.080 ns. Both source manifests
match. The seed-1 worst path is flash pending control into DDRAM ownership
address; seed 2's is shift-length data into the barrel shifter. The wider
lock-index changes remain dropped. The integrated retained tree, including
direct acknowledgement, also passes all 225 exact counts, 57 QEMU comparisons,
both lint modes and generated checks.

**Registered post-ALU load-valid (`loadvalid`):** capture `DAV && mem_load`
in one added bit at each existing post-ALU edge. Reset and writeback clear
zero it; data stalls hold it; fault/sleep states zero it with DAV. Issue uses
these bits for late-load candidacy, conflicts and load interlocks. Ordinary
forwarding still uses the original DAV; memory requests and all operand
register enables remain unchanged. There is no extra pipeline edge.

Induction on the actual post-ALU module proves the new flag equals the old
pair after reset, for arbitrary stalls, clears, faults and payloads. Under
that separately proved interface identity, all 4,045 actual issue-module
comparison points prove. All 225 counts remain exact, 57 signatures agree,
and both lint modes, generation/checks and the ten-occurrence check pass.
The pre-fit minimum covers issue feedback, pending capture and inputs to
both original DAV/load registers and the new flag in all three stages.
This targets the post-ALU1 load-control path exposed by `dctags` seed 2;
it is prepared on `combined2`, not fitted or retained.

**Fallbacks on the six-change tree:** `sharedshift3` rebases the shared
barrel onto `combined3`; the changed module is byte-identical to the proven
version. All 225 counts, 57 QEMU comparisons, both lint modes and generated
checks pass again. It remains unfitted and unretained pending the combined
three-seed result.

`buscompare4` similarly rebases the UPP next-line comparison. Before any
candidate fit, its acceptance group is broadened to include every incoming
UPP register path, as well as the original arbitration and CPU-address
queries. This includes self-test addresses and the new saved predecessor's
capture; a gain cannot be claimed merely by moving the carry chain into that
register. The supplemental query is installed in all three `combined3`
baseline copies before their timing reports run. This fallback is also
unfitted and unretained.

**Current predecode classification (`classify4`):** rebase the prepared
live/saved classification split onto `combined3`, whose predecode undefined
flag path is −0.473 / −0.486 ns. Both changed modules are byte-identical to
the proven `classify3` versions. All 225 counts, 57 QEMU comparisons, both
lint modes and generated checks pass. Drop `classify4`: the target changes from −0.473/−0.486 to
−0.556/−0.228 ns, a 0.070 ns regression in the worse result. Whole-core
slacks are −0.643/−0.450 ns. Both seeds use 35,467 ALMs and 479 M10Ks;
minimum four-corner holds are +0.078/+0.103 ns. All source manifests match.
The source of both target limits is Thumb instruction-valid, so the late
fallback classifier remains a real path. No RTL from this trial is applied.

**Issue forwarding validity (`forwarddav`):** seed 1's new worst path runs
from registered memory-load validity through the ALU late-load hold and its
qualified DAV, then forwarding priority and data selection, into issue's
normal shift-source bank (−0.645 ns). Issue never selects that normal bank
while the shifter stalls: it selects the separate refresh bank instead.
The ALU late hold always propagates into the shifter hold.

Expose the ALU's existing condition/exception predicate as `o_forward_dav`
and connect it only to issue's `i_alu_forward_dav`. Retain the original
`o_dav_nxt = o_forward_dav && !o_stall_from_alu` for execution, flags, the
shifter's refresh and every other consumer. The unused normal forwarding
capture can now omit the late hold; normal operands at every advancing edge
remain identical. No pipeline stage, operand selector, clock enable, load
interlock or cache path changes.

Assertions on the actual configured ALU and shifter establish the two
interface identities. Under those identities, actual issue equivalence
proves all 2,806 comparison points, including every output and unchanged
state boundary. The intentionally unselected normal banks and combinational
temporaries are excluded from internal equality, rather than assuming that
they match. All 225 CPU counts and 57 signatures remain exact; both lint
modes, generation/checks and the ten-occurrence check pass. The pre-fit
acceptance group includes normal forwarding captures, store captures and
all four registered operand selectors. Supplemental queries of the existing
baseline databases precede the paired fit. Drop the standalone trial:
its family changes from −0.645/−0.273 to −0.715/−0.354 ns, regressing
both seeds and the pair minimum by 0.070 ns. Whole-core slacks are
−0.798/−0.543 ns. Store inputs are +0.346/+0.154 ns, and operand-selector
inputs +0.649/+0.906 ns. The seed-1 forwarding limit moves to decode's
shift-source index into the normal shift-source bank; the original late-hold
path disappears, but the broader target does not improve.

The fits use 35,553/35,561 ALMs and 479 M10Ks, with minimum four-corner
holds +0.096/+0.097 ns. All 149 source/project inputs and the generated
build-date string match. The global limits are D-TLB fault-summary control
into retimed sequencer control (seed 1) and post-ALU2 validity into issue's
stall register (seed 2). No RTL from this standalone trial is applied.

**Direct effective load interlock (`factoredlock`):** the remaining seed-1
issue-feedback path is decode's shift-length index through `late_live`,
`slot_lock`, and the registered issue stall, at −0.634 ns. Compute each
operand's final blocking condition directly instead of forming a full load
lock and cancelling it through the late-admission tree. With `E` = earlier
loads, `P` = eligible late-stage loads, `W` = conflicting writers, `A` =
late admission allowed, `K` = the register lock, and `X` = the original
live exception lock, the expression is:

```text
K || E || (P && (W || !A)) || (X && (!P || W || !A))
```

The original immediate/RAZ guard remains outside it. Locked registers and
earlier loads always block. Special registers, multiply, force-alignment
and exception slots cannot defer. Shift and store operands keep their
existing early/late eligibility. The separate destination/WAW lock and
pending-bit calculation are unchanged. The final exception term preserves
the original live-input exception behavior even when selecting the saved
slot; it does not silently change that ordering rule.

All 4,038 actual issue-module comparison points prove without assumptions.
All 225 counts, 57 QEMU comparisons, both lint modes and generated checks
pass. There is no new register, RAM or pipeline edge. The pre-fit group
covers all issue-stall and pending-register inputs. Keep the factoring: the combined family improves from −0.634/−0.155 to
−0.592/−0.073 ns, improving both seeds and the pair minimum by 0.042 ns.
Stall-feedback inputs are −0.228/−0.073 ns; pending inputs −0.592/−0.072 ns.
Seed 1's limit moves to a saved operand index through writer/admission logic
into shift-source pending. Whole-core slacks are −0.694/−0.476 ns: the
limits are Thumb validity into a retimed PC register and SDRAM ready into a
DDR-flash RAM read-address register, respectively.

The fits use 35,360/35,334 ALMs and 479 M10Ks, with minimum four-corner
holds +0.081/+0.047 ns. All source/project inputs and build dates match.
The retained branch is regenerated and revalidated: 225 identical counts,
57 agreements, both lint modes and generation/checks pass. Its source hashes
match both fitted candidates. This small paired family gain does not establish
the final whole-core median.

**Classification before each micro-op case (`classifycase`):** the failed
first classification seed still runs from Thumb instruction-valid into
`o_v5_und_ff`. Splitting IDLE's live/saved classification was insufficient:
the non-IDLE fallback still decoded the fully rewritten micro-op word.
This separate trial computes the classification inside each of the
sequencer's 25 case branches, where constant opcode fields can simplify
before state selection. ARMv4T IDLE retains the proven early input
classification; other configurations and micro-op cases classify the exact
word constructed by that branch. The registered predecode output keeps its
original reset, clear, hold and capture edge.

The encoding definition lives in one new `zap_predecode_classify.svh`,
included within both modules. Extracting it leaves the generated Verilog
byte-identical; no port has a default value. Actual predecode induction
proves equality with classification of the original rewritten word on every
advancing edge, including invalid slots, in both V4T=1 and V4T=0 with the
configured four-entry RAS. The proof also establishes saved-classification
and skid-selection alignment, under arbitrary mode changes, holds and clears.

All 225 counts, 57 QEMU comparisons, both lint modes, generated checks and
the ten-occurrence check pass after the shared include is installed. Its
manifests include the new header at both seeds. The acceptance family covers
original undefined-output capture and the saved-classification inputs. The first seed improves the family from −0.473 to +1.358 ns; its limiting
path is now the registered skid selector into `o_v5_und_ff`. Whole-core
slack is −0.457 ns, limited by D-cache FSM state into post-ALU2 address
capture. The fit uses 35,330 ALMs and 479 M10Ks, minimum four-corner hold
+0.098 ns; all 150 inputs, including the shared header, and the build date
match. Fixed seed 2, after the capacity-related mapping restart described
above, improves the family from −0.486 to +1.260 ns. Its limit is the D-TLB's
write-through flag through pipeline hold into `o_v5_und_ff`; whole-core
slack is −0.449 ns, limited by D-TLB page data into physical-address capture.
It uses 35,413 ALMs and 479 M10Ks, minimum four-corner hold +0.093 ns.
All 150 inputs and the build date match at both seeds. Keep the classifier:
both seeds improve, with a worst-of-pair gain of 1.746 ns. The branch is
regenerated and revalidated after combining it with the retained factoring.

**Per-slot forwarding plus unqualified issue capture (`forwardslots`):**
the first `forwarddav` seed removes the original late-hold-qualified
critical path but exposes decode's selected operand index through forwarding
priority (−0.715 ns). This new combined trial retains the raw forwarding
predicate and computes each of the three other operands' complete priority
vectors separately for live and saved slots, before selecting the finished
vector. It extends the retained store-data technique. Preserved intermediate
wires prevent synthesis from simply moving that slot choice back before
the comparisons. The wide data OR tree, immediate values and PC value keep
their existing inputs. PC alignment reuses the priority vector's PC bit;
it no longer repeats a comparison of the selected index.

Actual issue equivalence proves all 2,806 state/output comparison points
under the separately proved forwarding-validity contract. All 225 counts,
57 QEMU comparisons, both lint modes and generation/checks pass; the raw
`input reg` count remains ten. There is no new pipeline edge or register.
The target is the same broad forwarding/store/operand-selection capture
group, measured against `combined3`; the failed standalone result is not
used as an easier baseline.

The first forwarding seed improves the group from −0.645 to −0.095 ns;
store capture is +0.294 ns and operand selection +1.267 ns. The remaining
forwarding limit is a saved operand index into the normal shift-source bank.
Whole-core slack is −0.500 ns, limited by the framework's host-configuration
path (`gp_outr` to `cfg_custom_p2`), which is outside the permitted `sys/`
edit scope. The fit uses 35,256 ALMs and 479 M10Ks, minimum four-corner hold
+0.089 ns. All 149 input files,
project settings and the build date match. Seed 2's family is −0.302 ns,
against −0.273 ns before: a 0.029 ns regression, while the worst-of-pair
improves by 0.343 ns. Its store capture is −0.194 ns and operand selection
−0.027 ns. The forwarding limit is again a saved operand index into normal
shift-source capture. Whole-core slack is −0.478 ns, limited by Thumb
instruction-valid into the undefined classifier addressed by `classifycase`.
The fit uses 35,267 ALMs and 479 M10Ks, minimum four-corner hold +0.087 ns;
all 149 source/project inputs and build date match. Keep it under the stated
worst-of-pair rule, with the individual seed-2 regression visible. The full
retained combination is regenerated and revalidated before its commit.

A separate `nextjoin` preview combining `forwarddav`, `factoredlock` and
`classifycase` also passes 225 exact counts, 57 comparisons, both lint modes
and generated checks. Its joined issue proof passes 2,806 points, and its
predecode modules/header match the separately proved source byte-for-byte.
That preview is unfitted and unretained; standalone `forwarddav` has failed
its gate, so this preview must not be applied as a bundle.

**Registered flash-save bitmap write (`bitmapwrite`):** `combined3` seed 3
exposes a separate −0.880 ns path from UPP's registered flash-chip select,
through DDR request arbitration, to the dirty-bitmap RAM write enable.
This fallback queues the bitmap's write enable/address/data in 16 preserved
registers. The RAM physically writes one clock later, while two registered
forwarding bits supply the same read value at the original edge. A read
forwards the previous clock's queued write, never the current write, retaining
`sdp_ram`'s old-data collision behavior. Mark/clear priority, dirty-block queue,
read request, save ordering, reset/sweep and all controller edges remain
unchanged. No processor or DDR request acquires a cycle.

An induction proof extracts the changed RTL block and tracks an arbitrary
14-bit RAM address. It proves the memory-refinement invariant and every read
of that address, universally covering all 16,384 locations with no reduced
geometry and arbitrary consecutive writes/collisions. The sole initial-memory
assumption is equality of the compared original memories; the pending-write
enable starts clear. All 225 CPU counts, 57 QEMU comparisons, both lint modes,
generated checks and the ten-occurrence check pass. Paired save benches each
take 31,071,940 clocks with 4,119 marks. The complete shell benches also match all 12 result lines, including
159,279,244 clocks and every reported memory transaction count. Pre-fit acceptance covers both sides of the original RAM and all
new pending-write/read-forward registers. This remains an unfitted fallback.
The final combined baseline includes its input/output queries; a future trial
would first rebase it onto that source and repeat validation.

**Raw metadata banks with shared forwarding (`icread4`):** a new version
of the parked valid/LRU split targets `combined3` seed 3's PC-to-LRU path
(−0.599 ns). Capture raw 16-set partial reads, the high set index, and one
pending-update forwarding decision per metadata field at the original
stage-one edge. Apply that registered forwarding decision after selecting
the partial result. This removes the replicated forwarding logic from each
bank's input. No valid/LRU array update, dirty bit, tag compare, replacement
policy or hit-under-miss behavior changes. The dedicated high-index capture
keeps the metadata enable, including clear while held; it does not reuse the
lookup index register, whose enable differs.

Equivalence of the extracted actual capture/forwarding RTL passes with
shared arbitrary metadata-array/control inputs: two-way caches with 256,
512 and 1,024 sets, a 128-set direct-mapped cache and an eight-set two-way
case. This covers every original metadata output under arbitrary holds,
resets, clears and update collisions; the array-write and control producers
are unchanged. All 225 CPU counts, 57 comparisons, both lint modes and
generation/checks pass, with ten `input reg` occurrences. The prospective
family includes both incoming and outgoing stage-one paths on both caches,
including the new forwarding registers. It remains unfitted, so area savings
are unmeasured. The final combined baseline includes the I- and D-cache input
and output queries needed for a future rebased trial.

The newer `nextjoin2` preview combines the complete per-slot forwarding
trial with factoring and case-local classification. It passes all 225 exact
counts, 57 comparisons, both lint modes and generated checks. Its joined
issue proof passes all 2,806 points under the independently proved ALU/shifter
contract, and its predecode sources match the classifier proof. It remained
unretained until the independent family gates passed; that exact source was
then retained and measured as `combined4`.

The fixed-seed whole-core sweep (`combined4`) started from that tested
preview while forwarding seed 2 was still running, using the otherwise free
task lane. Every one of its 150 source/project inputs matches the validated
preview, apart from the intentional MAIN macro and seed. This was speculative
build scheduling, not early retention. Forwarding has now passed its independent
pair gate, and the retained branch matches every non-QSF input byte-for-byte
in all three build copies. Its base commit, exact patch and hashes remain
archived separately from the retained commit. Each fixed seed's
status is recorded below. None replaces a completed seed or changes its value.

## Fourth combined sweep: final result

Source `7d1218c`: all nine retained CPU changes plus the unchanged owner card
fix. The previously speculative preview matches that commit for every
compiled RTL/project input; its original base/patch record is preserved.
All 150 inputs at each seed match, including the header, generated netlist,
constraints, MAIN macro, fixed seed and build date. Quartus's QSF version
metadata rewrite is the sole excluded metadata difference.

| Seed | Slow 100C setup | ALMs | M10Ks | Minimum hold, four corners |
| --- | ---: | ---: | ---: | ---: |
| 1 | -0.211 ns | 35,845 | 479 | +0.104 ns |
| 2 | -0.221 ns | 35,913 | 479 | +0.082 ns |
| 3 | -0.318 ns | 35,969 | 479 | +0.075 ns |

**Median −0.221 ns: the requested margin is met.** Seed 3 is 0.018 ns below
the individual −0.300 ns line; it is retained in the fixed three-seed result.
The median improves by 0.931 ns over the original −1.152 ns baseline, and by
0.424 ns over `combined3`'s −0.645 ns. Median area is 35,913 ALMs, 419 above
the original baseline median of 35,494; RAM usage is 479 versus 477 blocks.
No further seed was selected to improve these figures.

The worst paths are:

- Seed 1: `upp_periph.own_au` into UPP SDRAM write-data capture
  (`sdr_wdata[82]`), −0.211 ns. Next is D-cache valid through pipeline hold
  into the pipeline-not-empty logic at −0.169 ns.
- Seed 2: D-cache `state_ff[0]` into the merger's `o_wb_adr[30]`, −0.221 ns.
  Peripheral ownership into `fe_next[30]` follows at −0.156 ns.
- Seed 3: post-ALU1 destination index into issue `stall_idx_ff`, −0.318 ns.
  The arbiter's audio grant into `fe_next[20]` follows at −0.211 ns.

| Final family | Seed 1 | Seed 2 | Seed 3 |
| --- | ---: | ---: | ---: |
| Issue interlock feedback | -0.130 | -0.060 | -0.318 |
| Issue pending capture | +0.000 | +0.508 | -0.194 |
| Issue forwarding capture | +0.217 | -0.084 | +0.134 |
| Undefined classification | +1.337 | +1.875 | +1.419 |
| Predecode to decode | +0.298 | +0.101 | +0.001 |
| Shifter output | -0.095 | -0.065 | -0.195 |
| D-cache control into pipeline | -0.169 | -0.060 | -0.119 |
| D-cache into merger | -0.136 | -0.221 | -0.132 |
| All UPP bus register inputs | -0.211 | -0.156 | -0.211 |
| I-cache stage-one metadata input | +0.277 | +0.678 | +0.442 |
| Flash-bitmap input | +0.278 | +0.410 | +0.539 |
| Background-completion pickup | +0.128 | +0.522 | +0.667 |
| Owner card model | +0.292 | +0.750 | +0.491 |

The retained combination passes all 225 exact cycle/instruction pairs,
57 QEMU agreements, both lint modes, generation/current-netlist checks and
ten `input reg` occurrences. Existing test binaries were not rebuilt, and
QEMU references were reused without reexecuting QEMU. Full reports and input
receipts are in `build/timing5/combined4/`;
the source-matched MAIN build copies and their RBFs are
`../NGage_MiSTer-t5-combined4-s1`, `-s2` and `-s3`. Remote directories have
the same suffix under `dev/mister/`. All task-owned Quartus jobs have finished.

## Exact stopping point and next work

Stopped at the nine retained CPU changes in `7d1218c` because the requested
whole-core median criterion is met. No common-path cycle or pipeline stage
was added. The first three combined snapshots failed the goal; the fourth
passes using the fixed seeds. Rejected and parked trials above remain outside
the retained RTL. In particular, the bitmap-write and metadata-bank fallbacks
were validated but not fitted or applied; their final-tree families are now
positive in all three seeds.

Positive static timing closure remains future work. The next useful targets
are post-ALU destination/index control into the issue interlocks, peripheral
ownership/grant into UPP address/data capture, and the D-cache state into the
merger address. Rebase any prepared experiment onto this final source,
repeat functional checks, predefine both sides of any new register boundary,
and require its two-seed family improvement before another fixed three-seed
combined sweep. These timing results apply to MAIN with I16KB/D8KB two-way;
other cache sizes and the debug core need their own fits.

## Scope and risks

No firmware boot bench, `sys/` change, ARM9 change, hardware upload or board
measurement is included. The card owner's fix was integrated unchanged; its
implementation was not edited in this task. Timing figures from the supplied
debug-core reports motivate the investigation but are not the main-core baseline.

The principal risks are physical retiming or merging undoing a source-level
split, register replication increasing routing pressure, and a local gain
moving delay into a neighboring stage. Full-path family queries and paired
seeds address these; the final three-seed median assesses the combined core.
Simulation checks architectural and cycle behavior but cannot establish
104 MHz timing or hardware stability.
