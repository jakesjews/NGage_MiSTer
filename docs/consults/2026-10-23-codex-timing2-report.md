# timing2: shorten the front-end stall and issue-lock paths

Branch: `codex/timing2`. Baseline: `4db5857`.

The retained change removes the two targeted stall families from the worst
ten CPU paths and preserves every measured cycle and instruction count.
The matched seed-1 CPU trial improves from **-0.398 to +0.196 ns** at slow
100C. **The exact +0.200 ns acceptance gate remains unmet by 0.004 ns.**
This is a passing functional change with an explicitly incomplete timing
target, not a claim of whole-core closure.

## Design

The supplied whole-core report has a -1.151 ns slow-100C setup path from
the multiplier state through the sequencer's hold logic, the predecode
stall selector and a predecode data register. The RTL already registers
both the sequencer state and predecode's stall/skid selector. Quartus's
physical register retiming is enabled in both the whole-core project and
the CPU trial. The fitted path runs through logic on both sides of those
source-level boundaries.

The change protects those existing boundaries with `dont_retime`:

- `zap_predecode_uop_sequencer.state_ff` stays before the uop output decode.
- `zap_predecode_main.o_stall_from_decode` stays before the skid data mux.
- `zap_issue_main.o_stall_from_issue`, `stall_idx_ff` and `stall_late_ff`
  retain their boundaries. The last two retain their existing `preserve`
  attributes, which keep the low-fanout index/late-admission copies separate.

The sequencer enum is a named typedef so that the attribute attaches only
to its state register. Putting the attribute on the original anonymous
enum declaration caused sv2v to leave an unresolved `IDLE` reference;
lint caught that intermediate version before CPU simulation.

The fitted candidates then exposed two further paths, handled
without delaying any control signal:

1. **Predecode skid capture.** Its 140-bit input buffer now captures whenever
   its registered selector is zero, just as issue's skid buffer already does.
   Previously capture also depended on the shifter/issue/data stalls and the
   sequencer's request. On the edge that raises the selector, both versions
   capture exactly the same input. While selected, both hold. Extra writes
   occur only while the buffer is unselected. The shifter's stall and uop
   decision now drive the selector register, rather than the enable of all
   140 data bits. Keeping that selector out of retiming is essential.
2. **Issue lock-bitmap lookup.** The live 64-bit D-cache lock bitmap is read
   for the incoming and saved instruction indices in parallel. Five one-bit
   results (four operands and the destination) are then selected by the
   existing registered `stall_late_ff`. `keep` retains the lookup boundaries
   so synthesis cannot put the selector back before the 64:1 reads. The same
   selected bits feed load interlocks, WAW protection and late admission.
   A six-bit saved destination index is captured on the same edge as the
   existing saved operand indices and instruction bundle.

No lock bitmap, lock assertion, or unlock is sampled a cycle early. All
reads use the current `i_dc_lock`. The register-file read and operand-value
forwarding muxes are unchanged. There is no added pipeline stage, RAM,
delayed stall, speculative instruction advance, or change to multiply
latency. Stall qualification in `zap_core` and late-operand holds are
unchanged. No cache FSM, `rtl/cpu/arm9`, or `sys/` file is edited.

## Cases and coverage

Architecturally visible state transitions and output equations retain their
values and cycles. The attribute-only candidate's 40 generated modules were
also compared textually against the baseline, ignoring synthesis attributes,
whitespace and declaration order: there were no functional text changes.
The final version additionally changes issue's bitmap expression and
predecode's unused-buffer capture. Only those three generated modules
change; neither cache implementation changes
despite module reordering.

| Case | Handling |
| --- | --- |
| Multiply entry, busy, completion; low/high long-multiply uops; accumulation | Original multiplier FSM, issue operands and stall equations are unchanged. `mul`, `cache`, `loaduse`, random and GBA tests exercise these. |
| Condition-failed or invalid instruction | Original NV/bubble and condition handling are unchanged. |
| Late load source, amount or store-data wait | Original registered operand capture, pending bits and release condition are unchanged; `loaduse` exercises these. |
| Simultaneous data/issue/shifter stalls | Original enable and priority expressions hold the same pipeline state and selected skid contents on the same edge. Only the unselected predecode buffer may capture extra inputs. |
| Skid capture, hold and release | The selector retains its original equations. On entry, both versions capture the input; while selected, both hold. Unselected extra captures cannot affect outputs. No added capacity or release bubble. |
| LDM/STM/SWP, branch, Thumb BL and CP15 sequencing | The same sequencer state advances only on the original enable. No uop is consumed early or repeated. |
| Writeback clear, ALU clear during a data stall, decode clear | Each original clear priority and stall qualification is retained, including their differences between stages. |
| IRQ/FIQ/abort and invalid front-end slots | Original masks, exception bits and core stall-valid qualifications remain unchanged. |
| Issue control/index/late-selector copies | All copies retain identical reset, clear, hold and update semantics. The saved destination is captured with the same instruction as the saved operands. |
| Live lock set/clear while issue is held | Both lookup banks read the current bitmap combinationally. Selecting the result instead of the address does not defer an update. |
| Immediate, RAZ, PC, banked and dummy registers | Existing immediate/RAZ exclusions, physical indices and late-admission restrictions remain; the refactor only distributes the bitmap read over the slot mux. |
| User/system, FIQ, IRQ, SVC, abort and undefined banks; forced-user aliases; SPSRs | Decode and its architectural-to-physical translation are unchanged. The lock lookup consumes the same physical indices. |
| Reset or flush while the skid is selected | Selector reset/clear wins exactly as before. Stale buffer contents become unselected; the next selector-raising edge captures fresh data. |

Yosys proves two focused properties: the predecode buffer's selected-data
invariant by temporal induction (all 140 bits, arbitrary input/control
values), and the five-lane identity `locks[select ? saved : live] ==
(select ? locks[saved] : locks[live])` for arbitrary indices and all 64 lock
bits. The buffer invariant is `!selected || old_data == new_data`; it covers
reset, all clear priorities, indefinite holds and selector entry/exit.
Proof inputs and logs are in `sim/cpu/build/timing2/proofs/`.
The buffer proof starts with the selector cleared, as after reset; it does
not claim defined output before reset.

These are focused transformation proofs, not a full-core formal claim.
Whole-issue `equiv_induct` attempts left internal interlock comparisons
unproven, and an eight-cycle full-issue SAT attempt timed out. No successful
whole-module formal proof is claimed.

No new assembly test is needed: existing `loaduse`, `loaduse_irq`, `mul`,
`dhold_rtl`, `dcwf`, `dcwf_rtl` and `irq` exercise lock changes, stalls,
multiplies and clears (21 additional runs passed for the bitmap variant).
Banked-register coverage is supplied by `modes`, `fiq_movs`, `fiq_perm`
and `ldm` in the full suite.
Existing binaries and QEMU results were not rebuilt or rerun.

## CPU measurements

The required nine-test baseline passed **27/27** before editing. The same
27 runs after the change pass with **identical cycles and instruction
counts in every run**. Latencies below are `0:0`, `0:3`, `2:9` in that order.

| Test | Baseline cycles | Final cycles | Instructions at each latency |
| --- | --- | --- | --- |
| cache | 793607 / 921249 / 1253790 | 793607 / 921249 / 1253790 | 293427 |
| ctrand1 | 77298 / 106778 / 182278 | 77298 / 106778 / 182278 | 16159 |
| crand1 | 78285 / 109477 / 190634 | 78285 / 109477 / 190634 | 15982 |
| gba_arm | 8313 / 10935 / 17761 | 8313 / 10935 / 17761 | 1192 |
| gba_thumb | 4928 / 6529 / 10877 | 4928 / 6529 / 10877 | 774 |

The initial unrestricted `make -C sim/cpu diff` found missing RTL signatures
for tests outside the nine-test baseline. Its five available comparisons
agreed; the other 47 failed because the files did not exist. After producing
the missing RTL results from the existing binaries, the same command reports
**52 agree, 0 differ**. This checkout's default suite has 66 tests / 198 runs
and 52 QEMU comparisons, exceeding the brief's older 177/49 counts.

`make lint` and `make cpu-gen-check` pass. Detailed local evidence is under
`sim/cpu/build/timing2/`, including the baseline logs, quick comparison JSON,
and generated-module comparison.

The retained implementation also passes the entire default suite:
**198 passed, 0 failed**, followed by **52 agree, 0 differ** from
`make -C sim/cpu diff`. The final full-suite logs reproduce all 27 baseline
cycle and instruction counts. The generated netlist SHA-256 is
`c1fce2784ce33bd7a12730a7d37a1a5480dc9a1bdd4c074145dd5481523bc608`.

## Timing, final verification and limitations

All fits use Quartus Prime Lite 17.0.2, the CPU trial's Cyclone V device
`5CSEBA6U23I7`, and the unchanged 104 MHz / 9.615 ns constraint. They ran
in the existing Quartus Docker image on Ubuntu, in separate directories
under `~/dev/mister/`. Every launch used the script's four-container check.
A concurrent launch by another worktree briefly raced that non-atomic
check and produced five containers; the newest timing2 trial was immediately
stopped, restoring four. No other worktree's jobs were stopped.
No Quartus process ran on the Mac. No false/multicycle paths or timing
constraint changes were introduced.

| Implementation | Seed | Slow 100C setup, ns | Slow -40C setup, ns | ALMs | Registers |
| --- | --- | --- | --- | --- | --- |
| Matched baseline | 1 | -0.398 | -0.233 | 16574 | 17346 |
| Register boundaries only | 1 | +0.022 | -0.017 | 16861 | 18131 |
| Register boundaries only | 2 | -0.090 | -0.065 | 16782 | 18031 |
| Plus parallel lock lookup | 1 | -0.311 | -0.561 | 17243 | 18111 |
| Retained: plus speculative skid capture | 1 | +0.196 | +0.278 | 17192 | 17858 |
| Retained: plus speculative skid capture | 2 | -0.006 | +0.150 | 17184 | 17972 |
| Retained: plus speculative skid capture | 3 | -0.188 | -0.097 | 17329 | 17864 |
| Retained: plus speculative skid capture | 4 | +0.019 | +0.096 | 17194 | 17846 |
| Retained: plus speculative skid capture | 5 | -0.053 | +0.026 | 17028 | 18119 |
| Retained: plus speculative skid capture | 6 | -0.146 | +0.019 | 17269 | 18001 |
| Retained: plus speculative skid capture | 7 | +0.051 | +0.102 | 17231 | 17887 |
| Retained: plus speculative skid capture | 8 | +0.084 | +0.365 | 17232 | 18004 |
| Retained: plus speculative skid capture | 9 | -0.056 | -0.065 | 17171 | 17939 |
| Rejected: plus decode-map refactor | 1 | -0.161 | -0.101 | 16571 | 17227 |
| Rejected: plus decode-map refactor | 2 | -0.124 | +0.060 | 16564 | 17147 |
| Rejected: plus separate issue capture-stall register | 1 | -0.218 | -0.254 | 17156 | 18135 |

The retained seed-1 implementation uses **618 more ALMs and 512 more
physical registers** than the matched baseline. The RTL adds only the
six-bit saved destination index; the remaining register-count difference
comes from physical optimization. All variants retain **75 RAM blocks**,
**335,840 block-memory bits**, and **4 DSP blocks**.

The decode-map experiment precomputed the current-mode physical index for
every architectural index before selecting the decoded index. It passed
39 CPU runs and a full generated-decoder equivalence proof (2,437 cells
proven). Although it saved area, both fits had negative setup slack on
external-error-to-cache/merger paths. It is not included in the commit;
`zap_decode_main.sv` is unchanged.

A separate issue capture-stall register was also tried, with the same
reset/clear/hold/update rules as the existing stall register. It moved the
skid-buffer enables off the operand-mux selector and passed 27 quick runs
with identical cycles and instructions, plus 52 QEMU comparisons. Its fit
was worse, so that extra register is not retained.

Retained seed 1 has no multiplier-to-predecode path or
issue-stall-to-`stall_idx_ff` path in the worst ten at either slow corner.
Its overall worst path is issue `skid[91]~DUPLICATE` to
`o_shift_source_value_ff[8]`, at **+0.196 ns**. Targeted timing queries give
**+0.412 / +0.641 ns** for multiplier state to predecode and
**+0.469 / +0.536 ns** for issue stall to `stall_idx_ff`
(100C / -40C). Its minimum hold margin across all corners is **+0.123 ns**.
Querying all shifter registers gives the same predecode minimum and
**+0.808 / +1.074 ns** to decode, covering the late-operand hold as well
as the multiplier state.

Retained seeds 2 through 9 also exclude both targeted families from their
worst ten at both slow corners. Their slow-100C limiting paths are,
for seeds 2 through 4, external `ack` to merger `o_wb_dat[29]`, I-cache wrapper
`state_ff[1]` to merger `o_wb_dat[30]`, and decode `o_alu_source_ff[2]`
to issue `stall_idx_ff`. Seeds 5 through 7 limit on decode shift-length
to issue load-pending, memory FIQ to register-file data, and I-cache RAM
forwarding, respectively.
Seed 8 limits on issue `stall_idx_ff` to `o_shift_source_value_ff[7]`;
seed 9 limits on issue stall feedback. The predecode is not an endpoint in
the worst ten of any retained-netlist fit at either slow corner.

Stopped after **16 completed fits**: the matched baseline, nine placements
of the retained netlist, and six fits of the other implementations above.
Seed 1 remains the best retained result. Seed 10 was stopped during the
container-limit race; seed 11 was refused by the script. Neither is counted
as a timing result. The exact +0.2 ns CPU gate is still open; no cycle
regression or failing functional change is retained.

The selected netlist and reports are in `sim/cpu/build/timing2/trial3/`;
`fit/final_paths_Slow_1100mV_100C_Model.txt` contains the full worst paths.
All completed-fit summaries are recorded in
`sim/cpu/build/timing2/metrics.json`, with the capture-copy experiment in
`sim/cpu/build/timing2/trial5/fit/`. The final functional logs are
`sim/cpu/build/timing2/validation/ngage-timing2-final-*.log`.
To reproduce the selected trial from this commit:

```sh
SEED=1 BUILD_DIR=dev/mister/ngage-cpu-timing2-reproduce sim/cpu/quartus/run.sh
```

Functional risks are a slot/index mismatch in the parallel lookup and an
incorrect capture on selector entry. The identical selector/capture rules,
focused proofs, and CPU regressions address those cases. Speculative buffer
writes can increase switching while the slot is unused; no instructions
execute speculatively as a result. The timing tradeoff is less freedom for
retiming at these control boundaries and extra bitmap-read logic;
other paths can become the limiting ones. CPU-only placement does not prove
whole-core timing closure on the 80%-full FPGA. Hardware gameplay and the
76,975-access firmware boot comparison have not been rerun for this change.

To finish the CPU gate, the next measured change should shorten the issue
skid/index-to-operand-value path that now limits the selected fit. The
capture-register experiment did not improve it. The integrated tree also
needs a whole-core 104 MHz fit, inspecting both slow corners, hold, area
and the actual worst ten paths. The supplied whole-core -1.151 ns
measurement must not be reported as the new whole-core margin.
