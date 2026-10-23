# ARM9 session 6 continuation: short schedule, prediction and execution slots

## Status and stopping point

Continued on `codex/arm9` from `8acb1f1`. Steps 2–5 are implemented: the
cache/TLB hit schedule has two edges, unpredicted B/BL costs four clocks,
immediate load-use stalls twice, the optional registered BTB is on by default
for ARM9, normal blocks take n+1 clocks, and multiplies occupy E without draining
older instructions. ARM9 now beats ZAP in all 21 requested workload/latency rows.
ZAP remains the default core. The integrated timing/area result is recorded below.

**Stopping point: step 6, after the corrected integrated fit of `2647f62`.**
Functional and cycle gates pass. Timing and area do not: ARM9's worst setup
slack is **-8.332 ns**, and **16,755 ALMs** exceed ZAP's **15,917** by 838
(5.3%). ZAP remains default. No further RTL changes were made after that fit;
backend-clear and cache-source qualification are the next session's first work.

Milestones already committed: `9fef0be` (schedule), `3355340` (BTB), `f238f14`
(blocks/multiply). The final fetch/branch milestone is `0e4601f`, followed by the cycle-identical
timing correction `2647f62`; the integrated fit evidence follows.
The previous handoff is preserved as [session 6a](session6a-report.md);
[session 5](session5-report.md) retains the preceding timing evidence.

## Design and cases handled

### Two-edge hits and short schedule

ARM9 launches the cache RAM and TLB together: fetch from the registered next-PC
or registered BTB target; data from E's effective address. Edge 1 reads the
one-edge RAM inherited from `8acb1f1`. Edge 2 registers the existing tag compare,
way/word selection and load formatting beside the retained TLB permission
check. `SHORT_READ` selects this schedule; ZAP's RAM and metadata chains remain
unchanged. No pipeline stage was added between E and memory.

The I-cache exposes the selected raw word for early Thumb translation. F2
captures the decoded packet. When the queue is empty, a qualified registered
hit enters D directly; queued older instructions retain priority. Uncached ARM
words can also bypass because the FSM already registered them. Uncached Thumb
responses still pass through translation/capture before D. Provisional critical
words remain pending until the fill completes successfully.

The D-cache registers the formatted M2 value. The following ordinary result
record supplies E forwarding; there is no combinational cache-data-to-E path.
An immediate dependent waits while the load occupies M1 and M2, then uses its
registered value. Base, store-data and shift-count dependencies retain their
specific interlocks. The 76 original windows were retargeted; the current table
and TRM comparison are in [ARM9.md](../../ARM9.md#session-6-two-edge-cache-schedule).

The earlier cache collision bypass remains necessary, and advancing the RAM
launch exposes one additional position:

- A store coincident with a new RAM read uses the per-byte registered RAM
  collision bypass from session 6a.
- A store arriving while the younger lookup has already left RAM merges its
  enabled bytes into the selected per-way word and victim line before M2.
  Dirty metadata is forwarded with that update. Different words, bytes, sets
  and ways retain their unmodified lanes.
- ARM9 writes use the FSM's registered hit way. A store miss cannot use the
  unrelated younger raw lookup's way or write its RAM row.
- Fills hold/restore lookups. Re-read selects the held request; only the final
  aligned reload edge enables permission checking. The two-edge TLB retains
  its original permission, FCSE, alignment and fault priorities.
- Valid/dirty/LRU updates stay aligned to the raw lookup. Hits and pending
  updates preserve the forwarding/priority established in session 6a.
  Cache maintenance retains its conservative FSM waits.

Existing cache, dcache_rtl, icache_rtl, dhold_rtl, dcwf, dcwf_rtl,
arm9_cache_edge and arm9_cache_lru_rtl cover these cases, including dirty
writeback bytes and replacement through uncached aliases.

### Registered predictor and redirect handling

`ARM9_PREDICTOR=1` is a CORE-level wrapper option. Setting it to zero provides
the prediction-off configuration without changing ZAP. The unchanged
`zap_btb` reads a register-sourced PC and registers the tag match, direction and
target on its next edge. Neither lookup nor decision uses next-PC arithmetic.
The registered target can launch immediately when F2 predicts taken. The
sequential F1 packet is killed, while older queue entries remain ordered.

Prediction metadata travels to E. E compares the predicted next PC with the
resolved target or condition-failed sequential PC. Correct predictions do not
flush. Wrong direction, wrong target and stale entries on nonbranches redirect.
Only a branch or a stale predicted entry trains the table. A missing/non-taken
entry starts from weakly not-taken because the shared BTB does not expose a
separate tag-valid state output; a predicted-taken entry retains its valid
counter state. CP15/MSR completion clears prediction state. A W exception wins
over younger work, and cache fills still drain before lookup reuse.

B/BL consumes flags and its immediate offset, not the nominal register fields
inside that offset. Thumb BL halves now retire separately through the ordinary
result pipeline: the prefix writes LR, the suffix forwards it through the E
adder, writes the return address and validates/trains prediction. Both same-word
and cross-word encodings have timing windows. Interruptible half semantics
are preserved; the halves are not fused. A standalone suffix using an aligned
LR has a QEMU-compared check. The old target-alignment rule is retained.
An exploratory odd-LR standalone suffix differs from QEMU: QEMU left Thumb
state and faulted after branching to an unaligned ARM PC. DDI0100I A7.1.17,
page A7-28, requires paired halves and classifies violations as UNPREDICTABLE.
The final aligned standalone test is a compatibility check outside that
architectural contract. The odd-LR experiment is excluded; existing ARM9 target
alignment is retained, without redefining the port's unpredictable-case policy.

Fetch deasserts its core-facing request on redirect and while draining a killed
lookup. This stops an idle cache from starting a wrong-path bus access on the
very edge E redirects. An already active cache transaction drains normally.
The eight-entry queue remains; reducing it to four regressed timing windows
and the high-latency ARM random workload.

Hot predicted B/BL takes two clocks (window delta 3); prediction off takes four
(delta 5). The trained-taken/not-taken window is delta 5 with prediction, delta 2
without. Thumb BL's two halves take three clocks hot, five without prediction
(window deltas 4/6). A new load-followed-by-branch window checks that an immediate
offset resembling r0 cannot interlock on the load.

`arm9_predict` also overwrites a trained uncached branch with ADD. A readback and
untrained dependent redirect order the store before the modified call, without
clearing the BTB. The first test draft permitted prefetch ahead of the write
and failed ZAP at 0:0; the ordered final test passes on both cores.

No RAS is added. Return classification, speculative push/pop recovery and
interworking would add another mechanism to verify; the BTB alone meets the
requested cycle gate. BX, ordinary data-processing writes to PC and LDM-to-PC
retain their ordered later redirects and remain optimization candidates.

### Blocks and multiplies

The first block transfer launches from E. Subsequent registers use the normal
ordered memory records at one request per enabled clock. The sequencer releases
D after its last launch; a separate pending bit retains immutable original
base, mode, list and restoration context through final retirement. A new block
can reuse that context on the same edge its predecessor retires. Ordinary
following instructions need no block drain.

Every STM source is interlocked, including a nonfirst register supplied by an
older load. The first implementation missed that later-source wait: ctrand2
first differed at instruction 14975 / PC 0xb32, after push at 0xb2e consumed a
pending LDRSB result; four other random tests exposed the same case. A directed
load-to-second-STM-register case was added and the entire verification repeated.

Base-in-list, writeback, user-bank transfers, own-mode permissions, PC loads,
partial completion and base-restored data aborts keep their existing behavior.
The old empty-list-as-undefined policy is unchanged. Hot isolated blocks take
n+1 clocks. A dependent block boundary can take n+2 while retaining restoration
context. Eight-register windows are delta 10; dependent LDM4/STM4 is delta 12.
LDM3 including PC remains delta 10 because it redirects from ordered retirement.

Normal MUL/MLA/long multiplies register the product and accumulator while older
instructions continue toward W. E remains occupied for the iteration-dependent
count, then the result enters the normal pipeline. Long multiply carries a
separate paired-result flag; both halves forward and retire together without
pretending to be a cache load/lock. Failed conditions incur no multiply wait.
Older faults suppress younger results and stores. PC-destination multiply
encodings retain the tested serialized fallback rather than changing existing
unpredictable-case behavior. MUL/MLA takes 2+m and long multiply 3+m, matching
the referenced TRM table.

## Cycle comparison

These are whole-test clocks, including setup, with predictor enabled. The
selected test instruction counts are identical to the session-start baseline;
all ZAP cycle counts are unchanged. The margin is measured, not a claim about
hardware game CPI.

| Test | Bus latency | ZAP | ARM9 | Clocks saved |
| --- | --- | ---: | ---: | ---: |
| cache | 0:0 | 760,787 | 639,745 | 121,042 |
| cache | 0:3 | 888,787 | 764,132 | 124,655 |
| cache | 2:9 | 1,222,550 | 1,097,644 | 124,906 |
| dcache_rtl | 0:0 | 58,301 | 56,947 | 1,354 |
| dcache_rtl | 0:3 | 85,328 | 82,975 | 2,353 |
| dcache_rtl | 2:9 | 154,143 | 152,747 | 1,396 |
| ctrand1 | 0:0 | 72,594 | 69,278 | 3,316 |
| ctrand1 | 0:3 | 102,419 | 99,236 | 3,183 |
| ctrand1 | 2:9 | 179,154 | 179,061 | 93 |
| crand1 | 0:0 | 73,608 | 70,348 | 3,260 |
| crand1 | 0:3 | 105,167 | 101,657 | 3,510 |
| crand1 | 2:9 | 187,620 | 186,313 | 1,307 |
| gba_arm | 0:0 | 8,291 | 5,973 | 2,318 |
| gba_arm | 0:3 | 10,887 | 8,074 | 2,813 |
| gba_arm | 2:9 | 17,749 | 13,794 | 3,955 |
| gba_thumb | 0:0 | 4,913 | 4,014 | 899 |
| gba_thumb | 0:3 | 6,523 | 5,418 | 1,105 |
| gba_thumb | 2:9 | 10,877 | 9,371 | 1,506 |
| mmu_page | 0:0 | 77,102 | 74,763 | 2,339 |
| mmu_page | 0:3 | 112,796 | 109,212 | 3,584 |
| mmu_page | 2:9 | 203,209 | 200,922 | 2,287 |

Milestone totals below are **0:0 / 0:3 / 2:9**:

| Revision / mechanism | cache | ctrand1 | crand1 |
| --- | --- | --- | --- |
| 8acb1f1 | 906731 / 1027432 / 1375538 | 96199 / 128266 / 221271 | 97504 / 131692 / 231254 |
| 9fef0be | 864763 / 984961 / 1333851 | 95981 / 128853 / 223776 | 97332 / 131639 / 231643 |
| 3355340 | 737688 / 859486 / 1191959 | 73966 / 100711 / 179601 | 75370 / 103501 / 187347 |
| f238f14 | 643887 / 765197 / 1097681 | 73540 / 100406 / 179425 | 74716 / 103044 / 187073 |
| Final fetch/branch | 639745 / 764132 / 1097644 | 69278 / 99236 / 179061 | 70348 / 101657 / 186313 |

## Verification

ARM9 with prediction on, ARM9 with prediction off and ZAP each pass **234/234
runs** and **63/63 QEMU signature/trace comparisons**. All 85 timing windows
have their required visits at all three bus latencies; hot ARM9 counts match
exactly for both predictor configurations. The final branch test includes its
standalone-suffix addition. `make lint`, explicit ARM9 on/off `-Wall` lint and
`make cpu-gen-check` pass.

The [cycle counts](session6b-performance.json) remain identical across all
702 runs after the timing correction. The [final verification ledger](session6b-timing-verification.txt)
identifies netlist SHA-256
`da63d8ea9f9422c81935fe3caa681ae6c6dd7930de955a93dac356cb0dded4ad`.
The preceding [performance ledger](session6b-performance-verification.txt)
retains the earlier netlist identity.
Earlier [schedule](session6b-schedule-verification.txt),
[BTB](session6b-btb-verification.txt) and
[block/multiply](session6b-slots-verification.txt) ledgers retain each
passing milestone. The only newly built
binaries/references in this continuation are arm9_predict, arm9_slots and
arm9_branch_slots. Existing binaries and QEMU references were reused.

No firmware boot bench or hardware measurement was run. No `sys/` changes,
branch switch, push or other worktree edits were made.

## Integrated Quartus trial

Both initial trials completed on `ubuntu` via `sim/cpu/quartus/run.sh`,
with seed 2, 104 MHz, Cyclone V 5CSEBA6U23I7 and Quartus Lite 17.0.2. The
ARM9 wrapper sets `CORE="ARM9"`; the ZAP wrapper uses the default. No Quartus
process ran on the Mac. At most two trials from this task ran concurrently;
the server's four-container limit was respected.

The initial ARM9 fit at `0e4601f` used 15,942 ALMs and had worst slack
-23.310 ns. ZAP used 15,917 ALMs, worst slack -2.696 ns. This failed both ARM9
gates. The [rejected ARM9 fit](session6b-arm9-rejected-mux-seed2/manifest.json)
and [ZAP baseline](session6b-zap-fit-seed2/manifest.json) retain the inputs,
corner reports and worst paths.

The ARM9 path was `fast_w[228]` -> E forwarding -> shifter/ALU ->
`early_redirect` -> fetch direct/queue data mux -> D decode -> read forwarding
-> `value_e[71]`. It had 26 logic levels and 32.210 ns data delay, including
21.228 ns interconnect. This was a control-to-data selection problem, not the
intended cache tag/way path. The correction selects instruction data only from
registered queue count; redirect and response still gate validity. Thumb BL
now uses the existing dedicated branch adder with forwarded LR, keeping the
general shifter/ALU out of its target-validation path. No stage or cycle was
added. All generated modules except `arm9_core` and `arm9_fetch` are byte-identical
to the fitted ZAP baseline, so its resource/timing measurement remains applicable.

The [corrected ARM9 fit](session6b-arm9-fit-seed2/manifest.json) uses
`2647f62`, SHA-256 `da63d8ea9f9422c81935fe3caa681ae6c6dd7930de955a93dac356cb0dded4ad`,
in `~/dev/mister/ngage-codex-arm9-s6b-arm9-datamux-s2`. Remote input hashes,
constraints and the [module comparison](session6b-arm9-fit-seed2/baseline-module-comparison.txt)
are retained with the reports. The unchanged ZAP baseline remains the same
seed-2/104 MHz trial from `0e4601f`.

| Configuration | ALMs | Registers | RAM blocks | RAM bits | DSP blocks |
| --- | ---: | ---: | ---: | ---: | ---: |
| ZAP baseline | 15,917 | 17,360 | 75 | 335,840 | 4 |
| ARM9 initial fit | 15,942 | 14,114 | 72 | 334,240 | 3 |
| ARM9 corrected fit | 16,755 | 15,236 | 72 | 334,240 | 3 |

These counts include the same registered trial I/O wrapper. The correction
improves timing substantially but its fitted area is larger; it does not meet
the area requirement. A smaller source diff or synthesis cell count was not
used as a substitute for the fitted ALM result.

| Corner | ARM9 setup | ARM9 hold | ZAP setup | ZAP hold |
| --- | ---: | ---: | ---: | ---: |
| Slow 1100mV 100C | -8.332 ns | +0.362 ns | -2.647 ns | +0.319 ns |
| Slow 1100mV -40C | -8.246 ns | +0.343 ns | -2.696 ns | +0.279 ns |
| Fast 1100mV 100C | -0.008 ns | +0.179 ns | +2.885 ns | +0.130 ns |
| Fast 1100mV -40C | +1.485 ns | +0.124 ns | +4.005 ns | +0.113 ns |

All holds pass; ARM9 setup fails three corners. The current ZAP baseline also
fails setup at both slow corners. These are CPU-only results, not a whole-core
fit or hardware frequency demonstration.

The remaining worst ARM9 families are:

1. **Held operand -> branch target/validation -> backend clear.** At slow 100C,
   `u_held_forward|always0~2_OTERM11155` reaches `Mux20~20_OTERM11173` through
   held forwarding, `u_execute|Add0`, target equality, `early_redirect`,
   `fast_w[118]~2` (fanout 807), and the retimed Mux20 endpoint. It has 14 logic
   levels and 17.280 ns data delay: 10.891 ns interconnect, 6.389 ns cells.
   See the [full path](session6b-arm9-fit-seed2/detail_Slow_1100mV_100C_Model.txt).
   The RTL still derives backend clearing from `(f_redirect && !early_redirect)`.
   This keeps the E branch decision in the clear network even though an early
   redirect must preserve older backend records.
2. **I-TLB qualification -> fetch data -> D operand selection.** At slow -40C,
   `u_code_cache|u_zap_tlb|u_zap_tlb_check|o_fsr[2]` reaches
   `u_execute|u_forward|always0~12_OTERM15185`, via `o_fault`, cache `o_hit`,
   fetch instruction selection, `kind_d`, `read_tag[15]` (fanout 200), decode
   forwarding, `issue`, and retimed operand controls. It has 16 logic levels
   and 17.214 ns data delay. See the
   [full path](session6b-arm9-fit-seed2/detail_Slow_1100mV_-40C_Model.txt).
   Queue/direct selection is now independent of validity, but the remaining
   cache/response selection still uses the permission-qualified hit signal.

`OTERM`/`NEW_REG` names are fitter retiming artifacts, not added RTL stages.
The [ZAP worst paths](session6b-zap-fit-seed2/paths_Slow_1100mV_-40C_Model.txt)
start at D-cache way-1 tag `g_three_edge.fwd_st3` and reach the shifter's
`pickup_value[61]~37_OTERM2195`; that baseline family was not changed here.

The next session should first give backend clearing its own late-event signal,
independent of E redirect, preserving older-fault priority and the separate
block-base-restoration/fetch-redirection sequence. Then separate the registered
cache data-source choice from hit/permission validity, retaining current
response, provisional-fill and fault gating. Consider clearing only valid
bits on squash where payloads are demonstrably unobservable; this may reduce
clear fanout and fitted area. Re-run both cores and prediction off, require
unchanged cycle counts, then repeat the integrated fit. Do not add another
memory stage or silently change the four-clock branch/two-clock load interlock.
No implementation or verification of those next changes is claimed here.

## Risks, exclusions and next action

- Passing this suite establishes the tested instruction signatures, traces,
  cache semantics and cycle windows. It is not exhaustive formal verification.
  No firmware/device boot trace or physical 104 MHz game measurement is claimed.
- Speculative fetch still drains an already started wrong-path transaction.
  The redirect gate only prevents a new one. Misaligned/aliased predictors,
  self-modifying code ordering, fills and faults remain important regression
  cases whenever fetch changes again.
- The cache comparison logic is retained, but early Thumb translation follows
  way selection before F2. E still contains register forwarding, shift, ALU and
  flags, now also feeding the first block address and multiplier input. The
  measured clear and qualification paths above take priority.
- SWP, PSR/CP15 operations, PC-writing data processing, BX, LDM-PC and exception
  entry retain conservative serialization. No RAS, new memory pipeline stage,
  cache maintenance redesign or new architectural behavior was introduced.
- Keep ZAP default until both timing and area gates pass for this integrated
  configuration. The next session should start from the exact fit/stopping
  point recorded above, not repeat the already passing functional milestones.
  The requested cycle gate is achieved; the 104 MHz and area gates remain open.
