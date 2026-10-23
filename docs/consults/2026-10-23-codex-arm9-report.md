# ARM9 session 6: combined control pass, stopped on timing

The single combined seed-2 CPU-only trial is **−6.958 ns at Slow 100C**, with
**15,891 fitted ALMs**. This is 0.445 ns worse than the retained fetch-boundary
trial, although area falls by 1,357 ALMs and is now 26 below ZAP's reference.
**The lead's “still worse than −2 ns” stopping rule applies. No further timing
change or trial was made.** ZAP remains the default on `codex/arm9`.

All three configurations pass 234 runs and 63 QEMU comparisons each. All 85
windows have their expected visits; hot predictor-on/off counts match the
updated models. Two-clock load-use, two-clock predicted B/BL and the one-edge
cache RAM remain. Five of 21 workload rows still lose to ZAP. Some rare-path
costs exceed the requested allowance, detailed below. Neither 104 MHz timing
nor the original all-rows cycle gate is achieved; these tests do not establish
CPI 2.5 or game frame rates on hardware.

## Continuation and retained work

The session began from `d9c773d`. Commit `3aadad1` registered late backend clears
and fitted at −7.532 ns, with all cycle counts unchanged. The interrupted
fetch-boundary trial had completed its compile on the server; its standalone
TimeQuest report was recovered before further work. Commit `ae3b838` retains
that registered queue boundary, its −6.513 ns / 17,248 ALM fit, measured cycle
cost, verification and worst 30 paths. The prior milestone report is preserved
in [session6c-ab-report.md](arm9/session6c-ab-report.md); the preceding cycle-gate
state is in [session6b-report.md](arm9/session6b-report.md).

The fetch-boundary change is retained because cache hit/permission validity no
longer selects an unregistered word into D. Timing takes priority over its
five lost cycle rows. It was committed separately so the decision and its cost
remain reviewable even though the subsequent combined fit regressed slack.

## Worst-30 grouping and implemented control pass

Before the pass, all 30 worst Slow-100C paths shared decode admission:
registered fetch word -> instruction kind/register tags -> decode forwarding
readiness -> `issue/pop` (28 paths) or `block_issue` (2) -> retimed E/M control
-> E forwarding. Lengths were 13–14 levels, 15.337–15.441 ns; slack was
−6.513..−6.399 ns. Clear, fetch validity, cache hit and redirect were not
separate families in that top-30 set. [Before grouping](arm9/session6c-b-fit-seed2/path-groups.txt).

The combined pass changes only `arm9_core.sv`, `arm9_fetch.sv` and their
generated modules. The execute arithmetic, shared caches, RAM, MMU, ZAP and
bus merger RTL are unchanged.

| Boundary | Implemented behavior |
|---|---|
| Fetch -> D | Retain registered queue word, Thumb translation, abort/fill state, prediction metadata and queue validity. No empty-queue cache-response bypass. |
| D -> E | Remove decoded operand readiness from admission. Capture `serial_ready_e` with the E record and refresh it with held forwarding. A slow operation consumes its captured operands only after their readiness has crossed an edge. Fast E consumers retain their local forwarding/interlock. |
| E -> M1 -> M2 -> W | Keep the existing registered result records, including present/pass, destinations, access mode, memory controls, fault and data. Protect their boundaries with `dont_retime`; do not add a memory stage. |
| E/W -> fetch | Register redirect event/target/Thumb state, predictor feedback and predictor clear. Fetch consumes the registered event. |
| Backend kill | Retain separate registered E and retirement clears. E correction preserves the branch and older records. W fault/PC-write suppresses younger side effects on the decision edge; the late clear invalidates younger records on the next edge. |
| Block sequence | Consume the active sequencer's registered block classification, avoiding a general decode/readiness loop. |

Existing E controls, serialized controls and packed queue/result records use
`dont_retime` to keep synthesis from moving their registers through forwarding
cones. Packed data stays aligned with control at its existing edge; no new
common data stage was inserted. The attribute is documented by
[Intel/Altera](https://docs.altera.com/r/docs/683283/18.1/design-compilation-user-guide-quartus-prime-standard-edition/disabling-synthesis-netlist-optimizations-with-dont_retime-attribute).
[Boundary audit](arm9/session6c-control-audit.md).

Local ready/hold/cache-acknowledge decisions remain combinational within the
owning stage. This is not a claim that every handshake has become a register;
delaying an acknowledgement without preserving the associated request would
change memory behavior. The remaining integrated E-to-TLB chain demonstrates
that protecting control boundaries alone is insufficient.

## Cases and measured costs

- A D operand may refer to a pending producer. The E record captures both the
  value and its readiness; held forwarding updates both. Serialized execution
  waits for registered readiness. Condition-failed operations can retire
  without an unavailable operand. Fast loads retain their existing two-clock
  use interlock, including base/store/shift dependencies and load-PC ordering.
- A misprediction can coincide with a younger D capture. The late E clear
  cancels it before execution. Predicted-correct branches do not redirect;
  their two-clock hot spacing is unchanged. Feedback travels with registered
  PC, target and predictor state; stale predictions on non-branches are still
  corrected. Predictor-off uses the same registered redirect path.
- Older W faults and loaded-PC redirects have priority over younger E work.
  Younger stores, multiply results and retirement are suppressed; valid older
  records are preserved. Block abort base restoration precedes exception
  entry. Existing LDM/STM, user-bank, PC/SPSR and interrupt tests cover these
  paths; the block sequencer is not discarded by a younger branch correction.
- Fetch permission aborts, pending fills, held requests, epoch cancellation,
  ARM/Thumb transitions and Thumb BL crossing a word retain their queue
  metadata. No cache collision, line-fill, dirty/LRU or bus protocol logic was
  changed. Existing directed cache/hold/critical-word tests remain in the suite.
- CP15/MSR serialize as before, but their fetch fence now traverses the
  registered redirect. Registering this event increases their windows too.

Common DP, streaming load/store, ordinary block and multiply windows are
unchanged from the fetch-boundary milestone. Predicted B/BL window delta is 3
(two clocks plus the marker); immediate aligned load-use remains two clocks.
Unpredicted B/BL window delta rises 6 -> 7 (five -> six clocks); wrong taken
prediction followed by not-taken rises 6 -> 7. Predictor-off Thumb BL windows
rise 7 -> 8; predictor-on stays 4.

**The narrow extra-cycle restriction was not fully met.** CP15/MSR fence
windows gain one clock, LDM-PC gains two (11 -> 13), and exception-through-vector
windows gain three (17 -> 20) relative to milestone (b). These sequences include
serialized redirects/vector instructions, not just exception entry. Ordinary
PC-write windows gain one. The expectation files and [ARM9.md](../ARM9.md)
expose these measured costs; retargeted window passes are not evidence of
meeting the old cost limits. No further optimization follows the stop rule.

## Integrated fit and area

One combined pass, one `TRIAL=arm9_core SEED=2` trial through
`sim/cpu/quartus/run.sh`, on Ubuntu in
`~/dev/mister/ngage-codex-arm9-s6c-control-pass-s2`. The script checked Docker's
four-container limit. Quartus 17.0.2 used Cyclone V 5CSEBA6U23I7 and a 9.615 ns
clock. Compile and standalone TimeQuest completed. No Quartus ran on the Mac.
The final generated-netlist SHA256 matches the fitted input exactly.
[Manifest and reproduction command](arm9/session6c-c-fit-seed2/manifest.json).

| Fit | Slow 100C | Slow -40C | Fast 100C | Fast -40C | ALMs | Registers |
|---|---:|---:|---:|---:|---:|---:|
| Session start ARM9 | -8.332 | -8.246 | -0.008 | +1.485 | 16,755 | 15,236 |
| (a) Registered clear | -7.532 | -7.236 | +0.282 | +1.671 | 17,078 | 16,632 |
| (b) Registered fetch | -6.513 | -6.382 | +0.853 | +2.149 | 17,248 | 16,769 |
| (c) Combined control pass | -6.958 | -6.865 | +0.659 | +1.960 | 15,891 | 16,117 |
| ZAP reference | -2.647 | -2.696 | +2.885 | +4.005 | 15,917 | 17,360 |

Final hold slack is +0.373/+0.311/+0.179/+0.147 ns in the same corner order.
RAM remains 72 blocks / 334,240 bits; DSP count remains 3. ZAP's reference fit
is reused, not rerun: its generated module bodies are unchanged. It is also
not a timing-closed reference. The ARM9 5% area limit is 16,712 integer ALMs;
15,891 passes it and is 0.16% below ZAP.

The original approximately 840 extra ALMs were 838 after rounding. Fitter
hierarchy estimates attributed +935.5 to the pipeline, -156.3 to I-cache,
-15.8 to D-cache and +74.2 to remaining/wrapper logic. Within the pipeline,
the register file accounted for +681.8 (1,774.8 versus 1,093.0); the rest was
+253.7. [Baseline ARM9](arm9/session6c-baseline-arm9-area.csv),
[ZAP](arm9/session6c-baseline-zap-area.csv).

From (b) to (c), fitted pipeline area falls 8,774.0 -> 7,971.8, fetch within it
1,976.0 -> 1,231.0, I-cache 3,608.9 -> 3,131.0, and D-cache changes
4,657.9 -> 4,670.9. The register file is 1,753.4 versus 1,747.6 in (b).
These are physical-synthesis/packing attributions, not intrinsic source-module
costs: cache and RF source were unchanged. Total area drops 1,357 ALMs and
registers drop 652. [Final hierarchy](arm9/session6c-c-fit-seed2/area.csv).

## Remaining chains: exact stopping point

All 30 Slow-100C paths now end at the section D-TLB valid-read register:

`zap_dcache:l_generate_with_cache_mmu.u_data_cache|zap_tlb:u_zap_tlb|zap_mem_inv_block:u_section_tlb|g_short.read_valid_OTERM85_OTERM15817`

The worst starts at `arm9_core:g_arm9.u_arm9_core|tag_e[8]` and goes through
six-producer forwarding match/priority (fanout 23), operand selection, barrel
shift, shift selection, ALU carry chain, effective-address selection bit 22,
and the section-TLB read/write-address equality/valid-read logic. It is
**14 logic levels, 15.906 ns data delay, −6.958 ns slack**. Other starts are E
operand-tag bits and registered `fast_1/fast_m/fast_w` producer controls.

| Corner | Remaining family | Worst-30 count | Logic levels | Data delay (ns) | Slack (ns) |
|---|---|---:|---:|---:|---:|
| Slow 100C | E forwarding/address -> D-TLB valid read | 30 | 13–14 | 15.702–15.906 | -6.958..-6.746 |
| Slow -40C | Same | 30 | 13–14 | 15.605–15.821 | -6.865..-6.636 |
| Fast 100C | Same | 26 | 12–14 | 8.429–8.576 | +0.659..+0.796 |
| Fast 100C | E address -> D-cache RAM port-B address | 4 | 12 | 8.593–8.649 | +0.735..+0.788 |
| Fast -40C | E forwarding/address -> D-TLB valid read | 30 | 12–14 | 7.172–7.279 | +1.960..+2.059 |

[Grouped paths](arm9/session6c-c-fit-seed2/path-groups.txt),
[full Slow-100C paths](arm9/session6c-c-fit-seed2/detail_Slow_1100mV_100C_Model.txt).
The five named control families no longer occupy these top-30 sets. This does
not establish that every lesser path closes. The valid-read tail is currently
`(i_wen && i_raddr == i_waddr) || valid[i_raddr]` in the short TLB RAM wrapper.
No attempt was made to change that collision behavior after the stopping fit.

The execute RTL was not lengthened. However, the historical standalone
+0.018 ns trial used the execute module's default three producers; integrated
ARM9 has six and includes this effective-address/TLB tail. That standalone
number does not establish timing for the integrated path. The lead's next
structural decision needs an exact integrated forwarding/address/TLB model,
and must decide where the valid-read/collision work can be shortened or moved
without breaking two-clock load-use. No such change is included here.

## Workload cycles

ARM9 predictor enabled. Positive saving means faster than ZAP. Latencies are
0:0, 0:3 and 2:9; all compared instruction counts are identical.

| Test | Latency | Before pass (b) | After pass (c) | ZAP | Saving after pass |
|---|---|---:|---:|---:|---:|
| cache | 0:0 | 644,977 | 646,086 | 760,787 | +114,701 |
| cache | 0:3 | 766,283 | 767,407 | 888,787 | +121,380 |
| cache | 2:9 | 1,098,750 | 1,099,983 | 1,222,550 | +122,567 |
| dcache_rtl | 0:0 | 61,209 | 61,265 | 58,301 | -2,964 |
| dcache_rtl | 0:3 | 84,193 | 84,237 | 85,328 | +1,091 |
| dcache_rtl | 2:9 | 153,136 | 153,170 | 154,143 | +973 |
| ctrand1 | 0:0 | 73,537 | 73,689 | 72,594 | -1,095 |
| ctrand1 | 0:3 | 100,374 | 100,529 | 102,419 | +1,890 |
| ctrand1 | 2:9 | 179,218 | 179,438 | 179,154 | -284 |
| crand1 | 0:0 | 74,652 | 74,778 | 73,608 | -1,170 |
| crand1 | 0:3 | 102,973 | 103,041 | 105,167 | +2,126 |
| crand1 | 2:9 | 186,669 | 186,968 | 187,620 | +652 |
| gba_arm | 0:0 | 6,494 | 6,526 | 8,291 | +1,765 |
| gba_arm | 0:3 | 8,803 | 8,809 | 10,887 | +2,078 |
| gba_arm | 2:9 | 15,170 | 15,169 | 17,749 | +2,580 |
| gba_thumb | 0:0 | 4,039 | 4,050 | 4,913 | +863 |
| gba_thumb | 0:3 | 5,444 | 5,453 | 6,523 | +1,070 |
| gba_thumb | 2:9 | 9,416 | 9,433 | 10,877 | +1,444 |
| mmu_page | 0:0 | 80,454 | 80,543 | 77,102 | -3,441 |
| mmu_page | 0:3 | 110,892 | 110,929 | 112,796 | +1,867 |
| mmu_page | 2:9 | 201,250 | 201,431 | 203,209 | +1,778 |

Five losses remain: dcache_rtl 0:0 by 2,964, ctrand1 0:0 by 1,095 and 2:9
by 284, crand1 0:0 by 1,170, and mmu_page 0:0 by 3,441 clocks. The removed
fetch bypass and delayed cold/uncached/serialized redirects add whole-program
cost even though hot predicted branches and ordinary load-use are unchanged.
The one-clock decrease for gba_arm at 2:9 is consistent with changed bus
latency phasing; no hot instruction window became faster. [All 702 final counts](arm9/session6c-c-cycles.json),
[before-pass counts](arm9/session6c-b-cycles.json).

## Verification and limits

After the combined trial, the 14 targeted tests pass 42 runs, followed by 63
QEMU comparisons. Then ARM9 predictor-on, ARM9 predictor-off and ZAP each pass
234 runs across all three bus latencies and 63 QEMU signature/trace comparisons.
All 85 cycle windows have their expected visits on all three configurations
and latencies; exact hot counts are checked at 0:0 for ARM9 on/off. ZAP is not
compared against ARM9 timing expectations.
[Verification record](arm9/session6c-c-verification.txt),
[170 hot window results](arm9/session6c-c-windows.csv).

`make lint`, both explicit ARM9 predictor configurations' lint, and
`make cpu-gen-check` pass. The final generated modules differ from (b) only in
`arm9_core` and `arm9_fetch`. All ZAP cycle/instruction counts are unchanged.
Non-timer instruction counts match the session baseline across all tests;
`fiq_movs`, `fiq_perm`, `irq` and `loaduse_irq` have cycle-driven interrupt
spin loops whose counts can change, with architectural checks still passing.
No existing binaries or QEMU references were rebuilt or rerun. Existing
directed tests exercise the changed control cases, so no new assembly test
was added in this pass.

Functional residual risk is simultaneous events beyond the finite directed
suite: late kill, interrupt/fault priority, predictor update and held operands.
There is no formal exhaustive proof. Timing remains the blocking failure;
area passes only for this CPU-only fit, not a whole-device fit. No firmware
boot, whole-core compile, hardware frame-rate/CPI measurement, push, branch
switch or `sys/` change was performed. Trial containers use `--rm`; no task
server or Docker image was left running/created.

Stop here with the passing implementation and failed timing result committed.
The lead takes the remaining E-forwarding/address/TLB structure from this
handoff; do not resume path-by-path trials under the superseded plan.
