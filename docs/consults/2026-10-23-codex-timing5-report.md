# timing5: main-core timing closure

Work in progress. Baseline `c03088f`, branch `codex/timing2`. The acceptance
criterion is the median of three whole-core slow-100C setup slacks at
104 MHz, at least −0.300 ns. No CPU-only timing result is used for acceptance.

## Measurement method

Every fit uses the main core (`NGAGE_NO_DEBUG=1`), default 16 KB I-cache and
8 KB two-way D-cache, and disabled sequential I-cache prefetch. The original
worktree's macro remains commented while the dedicated build copies enable
it. Seeds 1 and 2 measure each isolated candidate against the same baseline;
a combined retained tree must subsequently be measured at seeds 1–3.

The concurrently running `NGage_MiSTer-nd-s1`, `-s2`, and `-s3` sweep is this
exact baseline. Local and remote hashes agree for all 150 selected RTL,
framework, lint and project input files. The QSFs agree except for Quartus's
rewrite of `LAST_QUARTUS_VERSION` from Standard to Lite; their seeds and
main-core macro agree. Reusing this sweep avoids three redundant fits.

In addition to the worst-30 full paths and four-corner summary, supplementary
TimeQuest queries report each target family at slow 100C even after it leaves
the worst-30 list. Query definitions and individual paths are archived in
`build/timing5/` and each build copy's `build/timing5-families/`. The family
boundaries include replacement registers, so disappearance of an old register
name alone does not count as an improvement. Both seeds must improve the
family being changed; unrelated placement changes are reported separately.
At most two task-owned Quartus containers and four Quartus containers in
total may run. Every build has a separate local and remote directory.

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
baseline. The fault-summary and issue ports are retained; the tag-read,
multiply, arbiter and BL ports are dropped after their paired fits.

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

## CPU cycle evidence

Existing binaries and QEMU references are reused. The baseline and each of
six isolated ports pass **225/225 runs**, **57 agree / 0 differ**. Across the
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

The tag-read split is dropped because its targeted stage-one family regresses
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

The BL rewrite is dropped: its predecode-to-decode family improves by
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

The broader `tlbsummary` trial is not retained under the per-seed rule:
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

Actual-module equivalence proves all 1,252 points for the configured
predecode; all 225 counts and 57 QEMU comparisons agree, with both lint
modes and generated checks passing. The acceptance family includes all
inputs to the three changed payload registers. The candidate is based on
`combined2`; its two-seed fit is running. The older bus-comparison candidate is
also rebased onto `combined2` as `buscompare3`; its UPP module bytes exactly
match the previously proved candidate, and its CPU counts remain unchanged.
Its paired UPP/peripheral/save/synthetic-top benches also pass, with all 109
clock/result/distribution lines identical to the current combined baseline.
The combined decoder candidate is rebased as `decodeboth3` onto this same
baseline; its module bytes match the proved version, and all CPU/lint/generated
checks pass before its paired fit.

## Scope and risks

No firmware boot bench, `sys/` change, ARM9 change, card-model edit, hardware
upload or board measurement is included. The card-model timing family is
owned by another engineer. Timing figures from the supplied debug-core
reports motivate the investigation but are not the main-core baseline.

The principal risks are physical retiming or merging undoing a source-level
split, register replication increasing routing pressure, and a local gain
moving delay into a neighboring stage. Full-path family queries and paired
seeds address these; the final three-seed median assesses the combined core.
Simulation checks architectural and cycle behavior but cannot establish
104 MHz timing or hardware stability.
