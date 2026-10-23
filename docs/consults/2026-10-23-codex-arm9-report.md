# ARM9 replacement: session 2 continuation report

## Status and stopping point

The new `CORE="ARM9"` selection executes the ARMv4T CPU tests through the existing
CP15/MMU/caches/bus merger. ZAP remains the default. **This is a serialized
correctness baseline, not the requested overlapping ARM9 pipeline.** It is slower
than ZAP. The next session must implement independent stage-valid records and
overlap; do not switch the production default or claim ARM9 cycle behaviour.

Milestone 3's selectable core, fetch-to-retirement path, probes and simple-test
coverage are implemented. Much of milestone 4's architectural functionality is
implemented and tested. The stage overlap, forwarding/interlocks under overlap,
TRM cycle tests and performance acceptance are still unfinished. Milestone 5 is
not complete. This report supersedes the first-session stopping point; the prior
report, execute timing experiments and evidence are preserved in
[arm9/session1-report.md](arm9/session1-report.md).

The first checkpoint is commit `ff544e5`: selectable bring-up, ARM DP/branch/
transfers, reused exception state and initial tests. The second checkpoint adds
multiply, the completion/retirement monitor, LDM corner cases, strict undefined
decode and `arm9_state.S`. This work stays on `codex/arm9`; no push, branch switch,
`sys/` edit, firmware boot or hardware measurement was performed.

## Design actually implemented

`arm925t.CORE` propagates to a generate at `zap_top`'s integer-core instance.
Both cores share the *same* cache, MMU, interrupt synchronizer and bus-merger
instances and wiring. The new implementation is `rtl/cpu/arm9/arm9_core.sv`.
It instantiates the unchanged session-1 `arm9_execute`, `zap_mode16_decoder`,
`zap_cp15_cb` and `zap_writeback`. The latter supplies the original 40-register,
four-read/three-write register file, banked exception state and CPSR. Its old
fetch-PC and predictor outputs are disconnected and have no role in execution.
The new controller owns PC and has no predictor or RAS. There is no ZAP fallback
inside ARM9.

The controller admits one architectural instruction at a time. It captures
operands/control in D, executes in E, waits for memory or CP15 as needed, and
retires in W. All execute producers are disabled because there are no other
in-flight instructions. This avoids inventing forwarding coverage for the
three-edge memory path but is not a substitute for implementing it. No younger
store, branch or CP15 side effect can overtake an older fault. LDM/STM transfer
micro-ops commit in order; only the final transfer has `uop_last`.

The fitted execute leaves were not changed. Multiply is outside their data path:
a registered signed/unsigned product, a separate registered 64-bit accumulate,
and an Rs-dependent wait count. It does not add a multiplier or accumulator to
the shift/ALU cone. Integration nevertheless adds control/result selection and
enable fanout; the earlier +0.018 ns feasibility margin is not an integrated
closure guarantee.

## Cache phase contract

The retained RAM path really has **three enabled read edges**; both ways' data,
tag, valid, dirty and LRU follow that schedule. No RAM stage, collision bypass,
tag hit path, bus side or cache FSM was changed. This resolves the functional
adapter's phase contract, **not** the performance discrepancy with the brief.

For a hit, with E capturing the data address at edge N:

| Edge | Controller / memory action |
| --- | --- |
| N | Capture original VA, aligned lookup address, data, mode, size and destination |
| N+1 | M1: RAM read stage 1 |
| N+2 | M2: RAM read stage 2; M3 then presents the permission check |
| N+3 | M3: RAM read stage 3; M asserts the cache request |
| N+4 | Capture the cache acknowledgement/data or retry/fault |
| N+5 | Classify the post-ack lock, or capture a concurrent completion |
| N+6 | W commits an ordinary hit; a miss waits for completion first |

Fetch likewise preserves F1/F2/F3 before requesting the instruction. PC, lookup
and access metadata stay stable while waiting. The data bus address is word
aligned; low bits remain in the original VA and load format for FAR, alignment
faults, byte lanes and rotation. FCSE adjustment happens on cache addresses.
The data permission check uses the access's captured mode and force-user flag.

An early D-cache miss ack does **not** mean valid load data. The cache sets
`lock_ff` at that edge, so the controller classifies it on the following edge.
It then captures `i_dc_reg_idx/i_dc_reg_dat` before retirement. Completion never
writes ARM9's architectural register file asynchronously. Stores retain the
cache's existing acceptance/write-allocate semantics and subsequent accesses
wait behind a fill. A simultaneous completion in the classify state is accepted
before testing the lock. `err2` repeats the lookup without retirement; an actual
fault suppresses the load and single-transfer writeback.

A provisional I-cache word waits for `fill_done/fill_fault` before D. Thus a late
fill error cannot escape after instruction retirement. There is no stale fetch
in this single-instruction controller: it never launches a younger PC before W.
An overlapping fetch design **must add** epoch/kill tracking and buffering; the
current absence of epochs is not safe to copy into that design.

The bench preserves the existing critical-beat-to-completion and lock-edge
assertions. For ARM9 it also checks that the completion is captured, its value
survives until W, and the right register receives it at W. ZAP retains its
same-edge register-file check. `p_dc_*` remains a cache interface probe;
`p_load_*` describes ARM9 capture/commit. Retirement is never fabricated from
cache completion. ARM9 and ZAP models and results have distinct directories.

## Architectural cases handled

- All sixteen ARM data-processing operations, arithmetic/logical flags,
  condition failures, rotated immediates, immediate/register shifts and PC
  operands. A failed condition has no data-memory or CP15 action. Rs shifts
  take the additional control cycle only when executed. A PC write with S
  reads SPSR using the fourth read port even when the third port is needed
  for Rs; `arm9_state` covers this QEMU-defined corner.
- B/BL, BX, direct/loaded PC and exception returns. ARM loads to PC retain
  ARMv4 state; BX selects T. Thumb BL halves update LR separately, including
  a lone suffix, and remain interruptible. Thumb literal/ADD-PC alignment
  uses the retained decoder's force-alignment indication.
- Word, unsigned/signed byte and halfword loads, stores, pre/post indexing,
  positive/negative offsets, register offsets, base writeback and unprivileged
  accesses. The retained cache does final load formatting. Single unaligned
  word loads rotate; LDM reads aligned words without that rotation. Alignment
  faults retain the original VA and suppress writeback.
- LDM/STM IA/IB/DA/DB, one or several registers, user-bank transfers, loaded
  PC and SPSR restore. Ascending registers use a captured address/count/list.
  A successful LDM containing its base keeps the loaded base instead of
  overwriting it with final writeback. On abort, earlier loads/stores remain;
  the original base is restored by an internal, non-final write before the
  exception edge. That write preserves the old CPSR, even when the failing
  final transfer was an LDM exception return. `ldm` and `arm9_state` cover this.
- MUL/MLA, signed/unsigned long multiply and long accumulate, both halves,
  aliases and NZ flags. Rs controls early-termination counting; signed/short
  multiplication recognizes leading ones, unsigned long only leading zeros.
  Product/accumulate are registered outside E. The temporary serial fetch
  overhead still dominates their total instruction cost.
- SWP/SWPB captures the original store operand, serializes read then write,
  and retires the loaded result once. Same-register operands cannot replace
  the captured store data. A fault suppresses the remaining phase. The
  existing bus interface provides no new external exclusivity guarantee.
- MRS/MSR, user restrictions, reserved PSR bits, banked modes/SPSRs, HIVECS,
  synchronous exceptions, IRQ/FIQ masking and priority. ARMv5 encodings and
  ARM NV words trap as in the existing V4T tests. MSR's register form checks
  its fixed low bits so BLX/BKPT cannot be mistaken for a status write.
- The unchanged TI925T CP15 block supplies MMU/cache enables, geometry,
  maintenance, FCSE, FAR/FSR, TLB operations, permissions and WFI. CP15 is
  conservatively serialized. MRC-to-PC updates NZCV in the ARM9 caller and
  does not redirect; this particular corner is not covered by the current
  shared suite and needs a dedicated reference test before further changes.

## Verification and measurements

The required focused baseline passed 27/27; its cycle/instruction counts were
saved before RTL edits in `arm9/session2-baseline.json`. The existing suite had
66 tests and 52 QEMU references (198 runs), rather than the older counts in the
brief. `arm9_state.S` adds one test/reference. Only this new test was assembled
and run in QEMU; installed `qemu-system-arm` supports the patched TI925T model.
The assembler warns about the register-shift PC destination; QEMU and both RTL
implementations execute the test and agree. This is intentional coverage of
the existing reference's semantics, not a portability claim for other ARMs.

Final generated-netlist results: **ZAP 201/201, ARM9 201/201**; both selections
report **53 QEMU comparisons agree, 0 differ**, including signatures and traces.
The focused/full/diff sequence was completed for both selections. The original
66-test ARM9 suite also passed 198/198 before adding the new state test. Generated ARM9 focused tests plus
`arm9_state`: 30/30, all nine focused instruction counts identical to ZAP.
Source ARM9 smoke (`arm9_state alu align modes exc ldm mul thumb`): 24/24 and
8/8 QEMU comparisons. Source/generated execute leaves still pass their 582,272
reference checks. Top-level lint and the generation check pass; an additional
source lint with `-Wall` and only old ZAP files waived also passes.

Both selections' focused cycle counts follow. Bus latency columns are 0:0,
0:3 and 2:9. **ZAP before = ZAP after** in every cell; ARM9 numbers show the
serialized controller's extra overhead, not an improvement.

| Test | ZAP 0:0 / 0:3 / 2:9 | ARM9 0:0 / 0:3 / 2:9 | Instructions (both) |
| --- | --- | --- | ---: |
| cache | 760787 / 888787 / 1222550 | 2553475 / 2613823 / 2803925 | 293427 |
| dcache_rtl | 58301 / 85328 / 154143 | 163476 / 189557 / 259170 | 12771 |
| icache_rtl | 58201 / 85393 / 154521 | 163204 / 189350 / 259203 | 12771 |
| ctrand1 | 72594 / 102419 / 179154 | 202854 / 231634 / 309047 | 16159 |
| crand1 | 73608 / 105167 / 187620 | 203684 / 234675 / 318037 | 15982 |
| gba_arm | 8291 / 10887 / 17749 | 13315 / 15305 / 20663 | 1192 |
| gba_thumb | 4913 / 6523 / 10877 | 8538 / 9804 / 13270 | 774 |
| mmu_page | 77102 / 112796 / 203209 | 216632 / 250908 / 341968 | 16887 |
| align | 5427 / 7001 / 11223 | 8847 / 10171 / 13817 | 549 |

Machine-readable evidence: `arm9/session2-zap-final.json` and
`arm9/session2-arm9-final.json`; the initial checkpoint has its own files.
The current state sequence derives seven clocks per independent hot-cache
DP/branch instruction, twelve for a single hot data transfer, plus eight per
additional LDM/STM transfer. These are **controller-state counts**, not a passed
TRM cycle microbenchmark; waits, fill handling and exceptions add more. The
intended Table 7-2 model in `docs/ARM9.md` is still the performance specification.
`arm9_cycles.S` has not been added because the current serial state machine
intentionally does not implement that model. It must accompany stage overlap,
with real retire-window measurements rather than hiding the fetch overhead.

## Timing, risks and next session

Integrated CPU-only Quartus trial: pending below. No firmware boot, full-system
fit or physical result is claimed. The execute leaf's original +0.018 ns result
remains only a feasibility measurement, not permission to lengthen its paths.

Functional risks still open: empty register lists are currently undefined;
unpredictable encodings/operand combinations outside the suite are not exhaustively
matched to QEMU; MRC R15 needs directed coverage. The shared suite checks much,
not all, of ARMv4T. The reused register file/exception block still contains ZAP
fetch/predictor code, but its outputs are disconnected and its control inputs
are tied off. Refactoring that dead logic is lower priority than pipeline overlap.

The large remaining architectural risk is adding overlap: a younger branch or
store must not escape an older abort, flags/SPSR selection must obey age, and a
cache completion must not be confused with register retirement. The current
serial controller avoids these races but does not test their future resolution.
Native three-edge memories still exceed the intended cache-latency allowance;
there is no demonstrated two-edge implementation or honest early-launch scheme.

Continue here:

1. Preserve this architectural baseline and the selectable ZAP path. Start with
   independently held F/D/E/M/W records and a fetch queue with epoch cancellation.
   Do not simply permit another instruction into the current global `ins`, PC,
   CPSR and memory metadata registers: those intentionally belong to one instruction.
2. Pipeline ordinary DP/branch instructions first, forwarding registered results
   and newest flags. Account for all M1/M2/M3/W producer ages and separate base/load
   destinations; the execute leaf has three producer slots, so extend coverage
   or interlock explicitly without a long extra mux in its 18 ps-margin path.
3. Integrate blocking loads, precise faults and ordered stores with those records.
   Preserve the measured three-edge phase contract and the new completion-to-W
   monitor. Investigate actual early address launch or a separately proven cache
   solution; the current adapter alone cannot reduce RAM latency.
4. Pipeline the transfer sequencer and multiply/CP15 drains. Add `arm9_cycles.S`
   and retire-window checks for each TRM row and dependency role. Keep architectural
   and performance assertions separate; the temporary serial schedule is not the
   target to encode as permanent expected timing.
5. Repeat focused/full/QEMU, source/gen/lint and integrated timing before changing
   the default. Firmware boot, full-system fitting and hardware measurements stay
   with the other engineer. Do not run the server firmware boot here.

No push was made. Only task-related CPU, bench, timing-script and documentation
files changed; the retained cache internals and `sys/` were untouched.
