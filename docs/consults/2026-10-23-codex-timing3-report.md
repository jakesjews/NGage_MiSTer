# timing3: whole-core control and operand timing

Branch: `codex/timing2`. Baseline: `c113925` (round 2 merged into master).
The supplied whole-core slow-100C setup slack is **−1.088 ns** at 104 MHz.
The acceptance target for this round is at least **−0.300 ns** on the whole
MiSTer core, with unchanged CPU cycles. A CPU-only fit is not acceptance.

The retained implementation improves whole-core slow-100C slack to
**−0.460 ns**, a **0.628 ns** improvement, with unchanged measured CPU cycles.
An independent repeat in the requested build directory reproduced all
corner slacks and resource counts. **The timing target was not met: the
remaining deficit is 0.160 ns.** This is the verified partial result allowed
by the brief; the later experiments were discarded.

## Implemented design

The D-cache FSM keeps its one-hot state register boundary through physical
retiming. RAM write enables are explicit parallel predicates for an idle
store, a completed fill, a completed victim clean, or a saved store. Tag,
address, way and line payloads no longer pass through the state machine's
acknowledge/fault-qualified priority tree. Payloads can change without a
write enable; only enabled bytes and enabled tag writes are observable.
The final fill payload selects the incoming word without ACK in its data
mux; ACK remains in the write enable. A proved state invariant guarantees
that FETCH still has an in-range beat counter, so an enabled fill write
always coincides with the final acknowledged beat. Byte overrides for a
store allocation retain priority. The RAM forwarding stages capture payload
and collision-valid metadata under
the same clock enable, so an unused payload cannot become a valid forwarded
write on a later clock.
The tag RAM similarly leaves its write payload connected during maintenance
rather than zeroing it when writes are disabled. Fill ownership is computed
from next state and registered, so lookup restoration sees the exact current
ownership directly from a flop. The per-byte fill-buffer update is explicit,
replacing a variable-index read/modify/write expression. Bus request control
is decoded in parallel from IDLE, UNCACHEABLE_PREPARE, UNCACHEABLE,
CLEAN_SINGLE and FETCH_SINGLE; the other states provably hold STB low.
CYC and STB remain equal. The direct request equation relies on the
existing, proved one-hot state invariant. The background completion's one-hot register
mask is captured with its data, removing a valid gate before the late pickup
mux. That same registered mask clears the lock on the original edge. Its
payload is allowed to vary when the mask is zero. Single-line completion is
an explicit LINEOP-state predicate rather than a priority-FSM output. No
state transition or acknowledge moves.

Issue captures register-file data, forwarded data and held-slot refresh data
in parallel at the existing edge. Local preserved one-hot selector flops
choose between those banks after the edge. This removes both the cache/
shifter stall and the forwarding mux from the register-file read path,
without delaying late completion or adding a stage. Normal forwarded values
and all refreshed operands retain explicit register boundaries. The source
cost is 256 additional operand flops and twelve selectors before synthesis
reductions. Forwarding retains its original priority but encodes that
priority in single-bit masks and ORs the data in parallel; an additional bit
selects the separately captured RF bank. The four load-interlock operand
indices use the existing separate registered selector and saved-index bank,
reducing the main skid selector's feedback fanout. Late-load admission
compares the live and saved tags independently, then selects four results;
the stall no longer precedes those tag comparisons. Instruction eligibility,
write-after-write exclusion and youngest-writer conflicts keep their original
rules.
A dedicated copy of the shift-source pending bit drives only the barrel
input mux, with the same load, reset, clear and completion updates.

Writeback decodes ALU, load and CP15 write addresses before exception/CP15
selection. The register file consumes one-hot addresses for all three write
ports, preserving port B over A and background completion over both.
Exception destinations are constant one-hot masks. Binary addresses remain
for the existing simulation diagnostics, but are outside the synthesized
write path. Synchronous reset and all forty physical storage entries retain
their behavior.

The bus merger captures code and data write payloads in parallel, then
selects write data with a dedicated copy of its registered owner. The bus
address retains its original register **after** arbitration: selecting
address banks after the edge made the external SDRAM and RAM decode paths
worse in trial 4. Control, CTI and burst type keep their original registers.
The I/D wrapper strobes are computed directly alongside arbitration, with
the same TLB > tag > cache priority and current-owner hold condition. This
removes a state-decode step before the merger. The new strobe formula is
exact even when a manager's CYC and STB differ. The no-cache ONLY_CORE path
is unchanged.

Decode registers the LSL-immediate-zero classification with the existing
shift operation and length. Issue saves that bit with its skid instruction
and selects it with the existing local stall copy, replacing a wide
comparison after the skid mux. Predecode's instruction mux similarly uses a
preserved copy of its stall register, with exactly the same D, reset, clear
and enable. The skid captures an already zero-masked instruction when valid
is false; the live input uses the same mask before the skid mux. The word
seen by the coprocessor/sequence decoder is bit-for-bit identical, while a
saved valid bit no longer gates all instruction bits after the capture edge.
The undefined-instruction output keeps its original register boundary; its
classification is unchanged. The late-memory valid
predicate is computed before the existing snapshot edge, instead of ANDing
three snapshots afterwards. It still samples the memory outputs and lock
together, survives a data stall, and clears on writeback flush.

Predecode also holds the CP15 word in two banks. Each edge writes only the
unselected bank, using a registered selector as its enable; an accepted
update toggles the selector. A stall or clear holds the selector, preserving
the exact old payload indefinitely, including CP15's multi-cycle operations.
Reset zeros both banks. This replaces the late global-stall enable on the
32 payload flops with a selector update, at a cost of 32 flops and a short
output mux.

The TLB walker captures a potential L2 descriptor address on the existing
L1 response edge. The next cycle already examines that descriptor and
launches its L2 request. A registered L1-launch indication selects the live
TTBR and saved virtual address on the original L1 launch cycle; the existing
bus-address register supplies subsequent wait cycles. This preserves live
TTBR sampling and address stability through arbitrary bus delays. Only the
address on cycles with no request is allowed to differ.

Writeback stores the prediction-valid bit separately from the target.
Clear/recovery conditions qualify the valid bit; they no longer qualify all
32 target input bits. The externally visible prediction still has an all-zero
target when invalid, and both fields hold during code stalls. Neither the
prediction decision nor the fetch cycle changes.

## Cases and contracts

| Case | Treatment |
| --- | --- |
| Cache idle store hit/miss | Original fault, busy, cache-enable, cacheability and write-through exclusions remain. The RAM's hit-way mask suppresses a store write on a miss. |
| Dirty victim writeback | Clean completion writes the saved victim tag with dirty cleared; the subsequent fill uses the requesting address/PA. |
| Fill completion, every starting beat | The enabled payload equals `buf_nxt`, including the final bus beat and store byte merge; speculative input data is ignored until write enable. Wrap-four order and early critical-word writeback are unchanged. |
| Store allocation | Installs a dirty tag and retains the existing repeated byte write in UNLOCK_REG. The already acknowledged store is not acknowledged again. |
| Write-through hit | Saved data/byte enables update the selected way only in UNC_DONE without an external error; saved dirty status is retained. |
| Uncached, alignment, MMU and bus errors | Original priorities and response cycles remain. Cacheable ERR still completes a beat under the existing port contract. |
| Fill ownership and held accesses | Registered ownership equals the original state predicate; the same three relookup cycles restore held and younger lookups. |
| Maintenance | No new tag/data write is enabled. Idle payload changes cannot affect the forwarding result when its valid bit is clear. |
| Immediate, RAZ, PC, CPSR, banked register | Forwarding retains all special-register priority and Thumb PC alignment rules. |
| Overlapping RF writes | B overrides A; background write overrides both, including dummy/RAZ entries. Exception and CP15 priority is unchanged. |
| Bus owner changes and bursts | Write data uses parallel capture; address stays registered after arbitration. Wrapper priority, control/CTI timing, EOB arbitration and ACK routing are unchanged. |
| Shift LSL #0 versus register/other shift | Classification is registered at the decode operand edge and saved with the same skid slot. Invalid decode slots clear the flag; valid slots retain the original bypass/interlock decision. |
| Late memory completion | Valid is sampled with the same data/index and live lock as before; reset/writeback clear suppresses it, while data stalls do not lose completion. |
| CP15 held word | Two payload banks preserve exactly the original reset/update/hold behavior. Clearing valid does not overwrite the held word. |
| Predecode stall/clear | The local instruction selector is an identical register copy, not a delayed stall. Its reset, writeback clear, qualified ALU clear and sequencer release match the public selector. |
| ARMv4T undefined classification | Existing classifications and valid-bit behavior remain; only physical retiming is restricted. |
| Multiple matching forwarding stages | Youngest source wins; memory load data still precedes that instruction's base-writeback value. |
| Data/shifter stall and transient completion | The refresh bank samples every edge, including nonpending ALU forwarding. A held slot selects that captured value on the same edge as before. |
| Multiply | Its raw accumulator operands still pass through the existing multiply exclusion in the refresh logic. |
| Reset/flush/invalid slot | Original valid/condition/pending controls retain priority. Unselected operand-bank contents are irrelevant. |
| L1 section/fault/coarse/fine descriptor | Request state machine is unchanged; only page/fine descriptors use the prepared L2 address. An ERR still forces the descriptor ID to fault. |
| TTBR change at L1 launch | Sampled on PRE_FETCH as before; the prepared L2 path does not move the TTBR sampling edge. |
| Branch prediction, recovery and code stall | Same accepted-valid decision, same external zero target when invalid, same stall hold. |

## Functional evidence

Before editing, all 27 quick runs passed and their complete logs/counts were
saved under `sim/cpu/build/timing3/baseline/`. The selected candidate's quick
repeat has identical cycle and instruction counts. The full suite has grown
since the common brief: it now has **198 runs** and **52 QEMU comparisons**.
The required repeat after the selected whole-core fit passed: **198 runs,
zero failures; 52 QEMU agreements, zero differences**. All 198 count pairs
also agree with the later experimental candidates.
No existing binaries or QEMU references were rebuilt or rerun. `make lint`
and `make cpu-gen-check` pass on the selected generated RTL.

The following focused Yosys checks are additional evidence, not a full-core
formal proof:

- Combinational equivalence of the baseline forwarding function and the
  final forwarded-data/RF-bank selection, extracted from the actual sources,
  for arbitrary operands, indices, validity flags and alignment inputs:
  proved (`forwarding3.log`).
- The three-bank operand capture identity for arbitrary 128-bit forwarded, RF and
  refresh data, reset, clear and stall sequences: proved by induction.
- One-hot write selection versus the retained binary write addresses, using
  the actual writeback priority block: combinational proof passed.
- Full register-file state with decoded versus binary write addresses:
  induction passed from the common reset state, including overlapping writes
  and addresses outside the forty stored entries.
- Old/new bus merger outputs through eight clocks after reset with arbitrary
  bus inputs: bounded proof passed (`merger5.log`).
- Wrapper strobe selection, registered classification and combined late-memory
  valid: the control identities passed induction (`control5.log`). The
  predecode selector copies, extracted from the actual RTL, also compare
  equal after reset, with induction from their common reset state
  (`skid5-induct.log`).
- Prediction valid/payload separation with reset and arbitrary stalls:
  proved by induction.
- Old/new TLB modules through 40 clocks after reset, including arbitrary
  TTBR changes, descriptors, acknowledgements and errors: bounded proof
  passed. Bus addresses are compared when their corresponding STB is high;
  the first reset/initialization clocks are excluded because the original
  saved-address register is not reset.

- The initial D-cache RAM-control extraction (through trial 5) passed
  combinational cut-point equivalence for every legal one-hot
  state and arbitrary shared saved-register/input values, with idle equal to
  its state bit. All enables and control outputs are compared; tag/address
  and each data byte are compared when written. Idle way selection is masked
  because the RAM uses the hit vector in that case. Registered fill-busy is
  outside this combinational proof. A larger 20-cycle whole-FSM SAT attempt
  was stopped after several minutes without a result; it is not claimed as
  a successful proof.
- Trial 6's actual D-cache FSM: the one-hot state, in-range FETCH counter and
  enabled-fill payload equality to `buf_nxt` passed induction. The original
  buffer update remains the reference for the incoming-beat and byte-merge
  comparison (`fill_counter6.log`). Repeats for 8-, 16- and 32-byte lines
  with an 8 KB cache also passed (`fill_line8/16/32.log`).
- The final parallel late-load admission predicate and per-byte buffer
  rewrite, extracted from the source, passed combinational equivalence
  (`late7.log`, `buffer7.log`). The dedicated pending-bit copy passed
  induction (`pending7.log`).
- Parallel D-cache CYC/STB generation passed induction against the previous
  FSM's actual outputs, together with the one-hot state and strobe-owner
  invariants (`bus7.log`).
- The masked-instruction skid capture passed induction (`controls9.log`).
  That check also covered two predicate copies tried in trial 9 and removed
  after its worse fit; the retained mask identity is independent of them.
- CP15 two-bank hold and background-mask registration identities passed
  induction, including arbitrary stalls, clears, resets and payloads
  (`banks6.log`).

Proof inputs and logs remain in this worktree under
`sim/cpu/build/timing3/proofs/` as ignored build artifacts. The existing
`loaduse`, `loaduse_irq`, `dcwf`, `dcwf_rtl`, `dhold_rtl`, cache, MMU, multiply,
branch and random tests cover the affected contracts, so no new assembly
program is needed for this timing-only transformation.

## Cycles

Every entry below is **before = after**. The instruction count is identical
at all three latencies and before/after.

| Test | 0:0 cycles | 0:3 cycles | 2:9 cycles | Instructions |
| --- | ---: | ---: | ---: | ---: |
| cache | 793,607 | 921,249 | 1,253,790 | 293,427 |
| ctrand1 | 77,298 | 106,778 | 182,278 | 16,159 |
| crand1 | 78,285 | 109,477 | 190,634 | 15,982 |
| gba_arm | 8,313 | 10,935 | 17,761 | 1,192 |
| gba_thumb | 4,928 | 6,529 | 10,877 | 774 |
| dcache_rtl | 62,433 | 89,143 | 156,717 | 12,771 |
| icache_rtl | 62,332 | 89,179 | 157,119 | 12,771 |
| mmu_page | 82,602 | 117,874 | 206,614 | 16,887 |
| align | 5,469 | 7,022 | 11,425 | 549 |

## Whole-core timing

The retained implementation is the best completed candidate, trial 10, at the
original **seed 2**. Its generated netlist is SHA-256
`ad188e2c0bb8ca298a9e55b173f74fcaf766425faf1892b3d61339d42c24a19c`.
The repeat completed in the requested canonical server directory, with
identical corner results, resource counts and generated-netlist hash:

```sh
BUILD_DIR=dev/mister/NGage_MiSTer-t3 ./build.sh remote compile
```

The completed trial-10 fit measured **−0.460 ns at slow 100C**, **−0.403 ns
at slow −40C**, with 10.984 ns total negative slack at slow 100C. It used
**35,006 / 41,910 ALMs (84%)**, **43,503 registers**, **470 RAM blocks** and
**43 DSP blocks**. Its worst path was CP15 MMU enable through D-cache
fault/request qualification into the merger's data-payload register
(`data_data_ff[8]`). The next two paths were saved shift-length index through
forwarding selection into `shift_length_normal_ff`, at −0.448 and −0.446 ns.
The −0.300 ns target is missed by **0.160 ns**.

| Final corner | Setup (ns) | Hold (ns) | Recovery (ns) | Removal (ns) |
| --- | ---: | ---: | ---: | ---: |
| Slow 1100mV 100C | −0.460 | 0.199 | 4.437 | 1.025 |
| Slow 1100mV −40C | −0.403 | 0.089 | 4.560 | 0.952 |
| Fast 1100mV 100C | 3.028 | 0.135 | 5.252 | 0.544 |
| Fast 1100mV −40C | 3.642 | 0.089 | 5.507 | 0.445 |

The original D-cache state-to-RAM forwarding/write-enable, TLB
state-to-address, and prediction-metadata families are absent from the
worst thirty paths. Shift-length forwarding remains at −0.448/−0.446 ns.
MMU busy/global stall into shifter operand capture is −0.398 ns, and a
self-test control path into an external RAM write enable is −0.393 ns.
Issue-stall feedback into `stall_idx_ff` is now −0.216 ns. Thus removing
the initial families did not close the whole core: the remaining operand,
bus-payload and board-level paths still constrain it.

Every completed row below is a whole-core build on `ubuntu`, using Quartus
Prime Lite 17.0.2 in Docker. No Quartus job ran locally. Container occupancy
was checked before launch; no more than four Quartus containers were used.
A negative-slack exit from `tools/report_timing.tcl` occurs after fitting
and bitstream generation. Reports were fetched explicitly when that exit
prevented `build.sh` from copying them automatically. Negative slack is
still a timing violation; a successful fit does not mean timing closure.

| Trial | Change or placement | Slow 100C (ns) | Slow −40C (ns) | Disposition / leading path |
| --- | --- | ---: | ---: | --- |
| Supplied baseline | `c113925` | −1.088 | −1.012 | Original cache/issue/TLB/prediction families |
| 3 | Initial control/payload separation | −1.377 | −1.151 | CP15 write-address selection into RF write enable |
| 4 | One-hot RF writes, parallel operand capture | −1.002 | −0.810 | LSL-zero classification; post-register bus address mux |
| 5 | Registered LSL-zero and memory-valid; restored bus address register | −1.063 | −0.677 | ACK into fill payload; CP15/global-stall fanout |
| 6 | Fill payload, CP15 banks, background mask | −0.801 | −0.722 | Issue late-admission feedback; D-cache bus control |
| 8 | Parallel bus request and per-byte fill; early late-tag comparisons | −0.496 | −0.505 | Saved instruction-valid into undefined flag |
| 9 | Skid masking plus two predicate copies | −0.644 | See archived TSV | Forwarding and interlock; removed the extra copies |
| 10, seed 2 | Retain only skid masking over trial 8 | **−0.460** | **−0.403** | Best completed result |
| 10, seed 3 | Identical RTL | −0.742 | −0.803 | Worse placement |
| 11, seed 2 | D-cache bus payload extraction and RF/special grouping | −0.939 | See archived TSV | I-cache validity and interlock; discarded |
| 11, seed 1 | Identical RTL | −0.824 | −0.695 | Worse than trial 10 |
| 12, seeds 4 / 1 / 5 | Exact trial-10 RTL | −0.893 / −0.869 / −0.932 | See archived TSVs | Seed 2 retained |
| 13 | Dedicated forwarding-selector copy | −0.659 | −0.629 | Thumb classifier and cache-lock admission |
| 14 | Direct D-cache/wrapper bus write payload | −0.690 | −0.783 | Barrel input and classifier; discarded |
| 15 | Parallel TLB request decode over trial 14 | −0.835 | −0.714 | MMU enable into merger arbitration; discarded |
| 16 | Cache-lock algebra; parallel undefined classification | −0.707 | −0.627 | ALU late-wait qualification into forwarding |
| 17 | Compare live/saved forwarding tags before slot mux | −1.204 | −1.120 | Merger owner through cache next-address selection |
| 18 | Resolve youngest writer before operand matching | −0.613 | −0.460 | Maintenance payload after ACK; shifter non-NV predicate |
| 19 | Single capture register for shift operands | −0.609 | −0.495 | Forwarding into shift capture; issue feedback |
| 20 | Unqualified ALU condition-valid for unused normal bank | −0.609 | −0.800 | Issue interlock; ACK into bus address; discarded |
| 21, seed 2 | Registered shifter non-NV; direct maintenance write payload | −1.114 | −1.053 | ACK into bus address; discarded |
| 21, seed 3 | Identical RTL | −1.123 | −1.461 | Worse placement; discarded |
| Trial-10 repeat | Canonical directory, identical RTL/seed | **−0.460** | **−0.403** | Identical corner results, resource counts and netlist hash |

Trial 1 was stopped before fitting to correct live TTBR sampling at L1
launch. Trial 2 hit Quartus settings synchronization error 125085, followed
by flow error 293007; its cached databases were cleared and the same RTL
retried. Trial 7 was stopped when Quartus ignored sv2v's `parallel_case`
attribute (warning 10335). Trial 8 removes that ineffective hint and is
otherwise byte-identical to the tested generated logic.

Trials 16–21 each passed all 198 CPU runs and 52 QEMU comparisons; all
198 cycle/instruction pairs agree between them, including every fresh
baseline pair. None improved the selected whole-core result, so none is
included in the retained implementation. Additional checks for those
discarded experiments include:

- Actual-module induction for the forwarding selector copy (`selector13.log`),
  cache-lock factoring (`lock16.log`), and shifter non-NV predicate
  (`shifter_valid21.log`).
- Combinational classification identity for trial 16, including Thumb BL
  prefix/alone markers and the first Thumb NV BL uop (`classification16.log`).
- Forwarding identity for preselected tag comparisons and independent
  youngest-writer priority (`forward17.log`, `forward18.log`); single shift
  capture versus the three banks (`capture19.log`).
- Trial 20's normal forwarding is equal whenever the ALU is not held.
  An ALU hold always holds issue and selects refreshed data, so differing
  normal banks are unobservable (`qualified20.log`, `qualify_capture20.log`).
  Qualified validity continues to drive execution and interlocks.
- Trial 21's maintenance payload proof uses the original tag-RAM FSM with
  arbitrary shared current/next words and unrestricted dirty-search/line-hit
  decisions. Induction proves the strobe-owner invariant and both active
  next and registered write-data equality (`tag_payload21-cut.log`).
  The larger unabstracted attempts were stopped or timed out and are not
  claimed as proofs.

Timing reports, summaries, input hashes and count snapshots are preserved
under `build/timing3/`. The supplied report is in its `baseline/` directory.

## Firmware, risks and next step

The selected trial-10 generated netlist completed firmware boot at
PC `0x5031e394`, **1,272,264,977 cycles**, **581,232,737 retired instructions**.
All **76,975 device accesses**, **61 register entries**, and **79 CBUS entries**
matched the existing model logs. Device comparison uses the repository's
standard free-running timer exclusions; register comparison excludes CTSI
`0x0c150100–0x0c150103`. This task did not measure a fresh baseline firmware
cycle count, so the boot count is a result, not a claimed baseline speedup.
Completed repeats through trial 21 reached that same halt cycle and retired
count; trials 4–7, 10–11 and 13–21 were explicitly compared for all three logs.

The operand banks add a short mux after their registers. Those register
boundaries and the cache's registered ownership must survive physical
retiming. The final whole-core fit, rather than CPU-only slack, determines
whether their placement is acceptable. RAM and bus payload simplification
relies on the existing enable/valid qualification. Inactive payloads can
toggle; they must never be interpreted without their corresponding enable.
Legal one-hot state from reset is assumed; the original undefined-state
behavior is not a fault-tolerance contract.

The checks establish substantial functional evidence, not full-core formal
equivalence or physical gameplay validation. No hardware was flashed, and
there is no new in-game CPI measurement. No pipeline stage or instruction
cycle was added. `sys/` and `rtl/cpu/arm9` have not been edited.

Work stopped after trial 21's seed-3 fit and the canonical trial-10 repeat.
The retained source and generated netlist are exactly trial 10, with the
original seed 2. The required final full-suite run and QEMU comparison
completed after that repeat fit. The canonical server directory
`dev/mister/NGage_MiSTer-t3` contains that fit and bitstream; the local
`build/critical-paths.rpt` and `build/timing-corners.tsv` contain its fetched
reports. The best result is committed despite the unmet timing target,
rather than retaining a functionally passing change with worse whole-core
placement. No task-owned Quartus containers or firmware simulations remain
running; the shared Quartus image is retained for the other engineers.

Next investigations should use these remaining paths, rather than the
CPU-only result:

- Prepare a dedicated clean/uncached bus-payload selector at the existing
  FSM transition, removing live MMU/fault qualification from the payload
  capture while retaining the bus-address register after arbitration.
  The attempted combinational payload extraction made placement worse.
- Prepare forwarding tag choices at an existing handoff, with explicit
  proofs for skid hold, transient completion and youngest-writer priority.
  The attempted parallel tag comparisons and single shift capture did not
  improve the complete design.
- Recheck the downstream bus-address and barrel-input paths after either
  change: multiple trials moved the bottleneck into those paths.
- Investigate the external self-test RAM-enable path separately within its
  authorized board-level files. No change to `sys/` or the other engineers'
  ARM9 work was attempted here.

Each proposal still needs functional verification and a whole-core fit.
Physical gameplay and hardware timing validation remain outstanding.
