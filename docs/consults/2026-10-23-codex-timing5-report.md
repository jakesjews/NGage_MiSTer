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
baseline. The fault-summary port is retained; the tag-read and multiply
ports are dropped. The other fits remain pending.

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

Other candidate whole-core fits are pending. No candidate is retained on
simulation results alone.

## Further candidates prepared from the main-core baseline

**Predecode classification:** classify the zero-masked live instruction for
both ARM and Thumb before selecting the skid slot. Save both bits with the
skid payload under its existing enable. Current mode selects the appropriate
bit, preserving behavior even across a held slot. In ARMv4T IDLE, the uop
sequencer selects this early result, masking the Thumb BL markers and its
NV link micro-op. Other sequencer states and non-V4T configurations retain
classification of the generated micro-op. No instruction-valid, stall or
clear edge changes. This builds on the parallel-classification experiment
recorded in timing3 trial 16, but additionally moves classification before
the skid mux and saves its result with the held instruction.

The full 225-run suite and 57 QEMU comparisons pass with identical counts.
A SAT check using the actual current uop sequencer proves the classification
identity for arbitrary defined inputs and state wherever the early result
is selected; later states use the identical original classifier. This is
not a full-core formal proof. Main/debug lint and generated-netlist checks
pass. The timing acceptance family is all paths into `o_v5_und_ff`.

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

The optional issue-stage formal check remains unclosed: the full miter
reached its time limit and partitioned checks leave interlock/select state
relationships unresolved. No formal equivalence is claimed for that port;
its required full-suite, QEMU and cycle checks pass.

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
