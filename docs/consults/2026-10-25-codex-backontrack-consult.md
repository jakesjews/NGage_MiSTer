# Codex consult: are we still on the shortest path? (2026-10-25, read-only, session 01a16fee-1a9d-71d3-aef1-64a299798960)

The brief follows, then Codex's answer verbatim.

## Brief

# Consult: are we still on the shortest path to the goal? (read-only; do not edit or build anything)

You are consulting on the Nokia N-Gage MiSTer FPGA core (Cyclone V 5CSEBA6, DE10-nano). The user, Jacob, is worried the project is "spinning off into the weeds" and asked for your sceptical, independent view on how to get back on track. Answer with facts and file citations, not reassurance. Do not run builds or simulations.

## The goal
The phone's speed in play: about 47 M ARM instructions/s. At the shipping 104 MHz that is CPI <= 2.21. A lower clock does not help: the SDRAM and video are tied to it and the per-clock CPI only gets worse.

## Where the shipping core is
- Shipping CPU: ZAP (ARM925T-shaped, ARMv4T). Main slot today: ~32 M instr/s in Sonic N (play medians; docs/PROGRESS-LOG.md around lines 4700-4870). Its CPI in play is 3.3, so ~70 % of its clocks are non-retiring.
- Memory side on ZAP is tapped out: deferred write-back (+4-6 %), I-cache critical-word-first, cache metadata in M10K + 16 KB D-cache (+2-2.6 %) all merged; a merger write-back buffer and an I-fetch early-execution gate measured nil and were parked. The device is at 539/553 M10K and ~80 % ALMs with the 16 KB D-cache.

## The one line of development: ARM9 v2 ("V2")
rtl/cpu/arm9v2/ in this worktree (branch codex/arm9v2, docs/ARM9V2.md; 14 sessions over 2026-10-23..25, reports docs/consults/2026-10-24-codex-arm9v2-s6..s11.md and 2026-10-25-codex-arm9v2-s12/s13.md). 8 stages F1 F2 D1 D2 S A M W, fetch-cycle predictor + RAS, early/late operand split, 2-clock late / 3-clock early load pickup, hit-under-miss with register locks, miss retention on a registered lock (no replay).
- Correctness: 267-282/282 directed CPU-suite runs, 69-71 QEMU-reference tests agree; boots the EKA1 kernel in simulation 13.8 % faster to the EFile entry than ZAP.
- Profile (s13): in the kernel init (identical 270.6 M-instruction streams) V2 removes 42 % of ZAP's non-retiring clocks (dependency 17.2 M -> 2.6 M, branch recovery 22.7 -> 7.6 M, fetch starvation 9.9 -> 1.4 M, structural 69 -> 28 M; data wait rises 15 -> 30 M). ZAP retires on 70 % of the clocks in that phase, so 13 % is what that phase can give; in play ZAP's non-retiring share is 70 %, the regime V2 was designed for. V2's in-play number is NOT yet measured.
- Timing: the integrated fit at 104 MHz is -2.9 ns at the best seed (ZAP -0.58 in the same wrapper; the board runs reliably at about -0.8). Zero-cycle cuts were exhausted in sessions 9-11 (each moved the leader without moving the slack). Your own read-only consult on the timing shape is docs/consults/2026-10-24-codex-v2-timing-consult.md (eight ranked structural cuts: lock summaries on the lock-update edge, moving the cache collision compare and metadata selection into M, splitting next-producer matching from completion, registering the selected translation owner, ...; estimates 1.2-3 ns per family, overlapping, not additive).
- The blocker right now: on the real board (and in simulation) V2 dies about 25 s into the firmware boot, before the idle screen, in every V2 revision that boots the firmware (session 8 onward). A hardware trace (rtl/mister/dbg_trace.sv, dumped from the board) pinned the first wrong value: a load launched right after an `msr CPSR_fc` (which V2 serialises with a W redirect/flush), which also missed the D-TLB and the D-cache with a dirty victim, lost the lock/ownership of its destination register: a reader two instructions later was not stalled and the late return overwrote a younger writer of the same register; a `mov pc, r0` then jumped to 0xAAAAAAA8. Seven other background misses in the same window interlocked correctly. The full analysis: /private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/trace-v2-analysis.md (sections 0, A.2, A.4). A directed test and a fix are being written right now in this worktree by another agent (do not touch sim/cpu/tests or rtl/cpu/arm9v2).

## What the last two days bought, and what they cost
- 2026-10-24: Sonic simulations on both cores (Verilator whole-core bench, ~6 wall minutes per guest second; play starts at ~200 guest seconds: a day per run). The user killed them all: too slow.
- Built instead: (a) a 78 MHz board build path (PLL + SDRAM parameter; V2 meets timing at 78 MHz, +0.06 ns), so V2 runs on the real MiSTer and the instruction rate per 104 M clocks is read from the overlay counters in a 20-minute game run; (b) snapshots for the Verilator bench (--save/--restore, proven identical to an unbroken run); (c) the hardware trace that found the bug in one capture. Also tried: Quartus design-rule check (nothing V2-specific), Ghidra/radare2 on the ROM.
- The user's standing rules: one line of development (V2), no more ZAP pipeline work; build fix attempts in parallel (4 Quartus containers on a server + 1 on the Mac, ~1 h each); write code directly rather than through long agent sessions.

## Questions (answer each, ranked where it is a list; be concrete and sceptical; cite files/lines)
1. Given the goal (47 M/s at 104 MHz) and the numbers above, is V2 still the right and only line? What is the realistic ceiling of V2 in play at 104 MHz if its timing closes, from the s13 profile? Is there a cheaper line we are not seeing (including anything on the ZAP side that the memory-side measurements have not already ruled out, or a different approach to the CPU)?
2. What is the shortest sequence from here to a go/no-go decision on V2, and what are the decision thresholds? Which of the things we are doing are waste, and which are missing (e.g. is the single hardware-trace-found bug likely one of a class that the 282-run suite does not cover: what kinds of directed tests would catch the class)?
3. Is 104 MHz closure of V2 credible at all with the device at ~80 % ALMs, given your eight cuts? If the answer is "probably not with this shape", what is the alternative that still reaches the goal (e.g. a redesign of specific stages, fewer features, a different cache-side split), and how many sessions is it?
4. Name the three concrete next actions you would take, in order, with the measurement that decides each.

Keep the answer under 1500 words. Do not propose re-running the day-long Verilator game simulations.

## Answer

**V2 is still the best next experiment. It is not yet a demonstrated route to 47 M/s.** The shortest path is now correctness → measured gameplay CPI → a bounded timing redesign. More optimisation before the gameplay measurement risks extending an unproven design.

I made no edits and ran no builds or simulations.

**1. Performance: the profile supports V2, but does not establish its gameplay ceiling.**

The strongest comparison is the identical 270.6 M-instruction pre-executive stream: V2 removes **42.1% of non-retiring clocks**. The dependency/branch/structural numbers quoted in the brief instead extend through EFile, where instruction counts differ. Those categories are priority attribution, not independently recoverable penalties. [S13 equal-work comparison](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-25-codex-arm9v2-s13.md:180), [attribution limitations](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-25-codex-arm9v2-s13.md:25).

Using 32 M/s as the baseline gives CPI 3.25. If fraction \(r\) of its non-retiring clocks disappears:

\[
CPI_{V2}=1+2.25(1-r)
\]

| Assumption in play | Result at 104 MHz |
|---|---:|
| Same 42.1% removal as kernel | **45.2 M/s** |
| 50% removal | **48.9 M/s** |
| Required for 47 M/s | **46.1% removal** |

Using rounded CPI 3.3 instead gives 44.6 M/s and requires 47.3% removal.

Thus **about 45 M/s is the simple extrapolation, not 47–55**. Better gameplay results are plausible, but S13 supplies neither a credible upper bound nor evidence for a particular optimistic number. Its cached random bodies also show dependency savings being consumed by memory/fetch/recovery costs. [S13](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-25-codex-arm9v2-s13.md:245).

Ranked alternatives:

1. **Finish and, if justified, repartition V2.** It reuses the already integrated semantics, MMU, caches and exceptions.
2. **ZAP pipeline surgery:** technically possible, but not an evidenced cheaper route and contrary to the standing direction. Memory results do not prove every possible ZAP improvement exhausted; they do eliminate the tested easy candidates. The larger D-cache delivered only 2–2.6%, while early execution and the merger buffer were effectively nil. [Measurements](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/PROGRESS-LOG.md:4710), [D16 results](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/PROGRESS-LOG.md:4851).
3. **Another CPU:** no demonstrated shortcut. Pocket’s different movement contract and 88.7 MHz result do not establish integrated 104 MHz feasibility here. Amber implements ARMv2a without an MMU, so is not a replacement. HPS emulation changes the FPGA-CPU objective and needs its own integration/performance proof. [Pocket comparison](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-v2-timing-consult.md:23), [Amber project](https://opencores.org/projects/amber).

**2. Correctness coverage is missing a transition combination, not simply more instructions.**

The trace establishes failed RAW/WAW ordering. It explicitly cannot distinguish an older return overwriting the RF, incorrect forwarding priority, or a dropped younger write. The initiating RTL defect remains to be proved. Also, this particular S11/D8 capture faults at **4.83 seconds at 78 MHz**, not 25 seconds; keep different firmware configurations and failures separate. [Trace analysis](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/trace-v2-analysis.md:120), [capture timing](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/trace-v2-analysis.md:44).

Ranked coverage additions:

1. **Exact reproducer:** MSR flush → D-TLB retry → dirty-victim miss → reader → younger same-register hit. Sweep return arrival across acceptance, retry, younger write and consumption edges.
2. **Independent ownership assertions:** every accepted pending load retains its physical destination/age until completion; readers obtain the newest older successful writer; an older return cannot supersede a younger successful write.
3. **Transition variants:** clean/dirty victims, TLB hit/miss, conditional younger writers, banked destinations, IRQ/FIQ/exception returns, simultaneous lock clear/install, D8/D16.

Existing tests already cover younger-writer shadowing and IRQ timing separately. Existing lock assertions compare summaries with internal lock state; both can agree while omitting the same required owner. That explains why more passing runs alone are insufficient. [Writer test](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/sim/cpu/tests/arm9_memory.S:41), [IRQ sweep](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/sim/cpu/tests/loaduse_irq.S:33), [assertions](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:354).

Ranked waste to stop:

1. Further seed hunting or zero-cycle tuning of the unchanged shape.
2. Unprofiled feature additions: S12’s second-miss opportunity was below 0.4% in measured firmware intervals. [S12](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-25-codex-arm9v2-s12.md:373).
3. Broad ROM archaeology or more debugging infrastructure after a reproducible ownership failure exists.

The hardware trace, 78 MHz diagnostic path and snapshots were useful investments. Parallel builds help only when testing distinct, correctness-qualified hypotheses.

**3. Probably not at 104 MHz with the present stage boundaries.**

First, a scope correction: S12’s **−2.951 ns is a CPU/cache trial**, not a whole-DE10 fit. Its 13,262 ALMs cannot be combined directly with shipping ZAP’s whole-device utilisation. Eighty percent utilisation alone does not prove impossibility; the failing paths do. [Fit scope](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-25-codex-arm9v2-s12.md:167).

The old eight-cut consultation is no longer an untouched opportunity list. S10 implemented lock summaries, parallel producer matches and translation descriptors; S11 moved collision/metadata selection and changed forwarding grants. Overall timing remained around −2.9 ns. [S10](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s10.md:34), [S11](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s11.md:323).

S12 still has independent failures:

- address→metadata: **−2.951 ns**;
- address→TLB capture: **−2.666 ns**;
- load word→late ALU/flags: **−2.564 ns**;
- short response: **−2.226 ns**.

An address-launch stage cuts only part of this. [Endpoint table](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-25-codex-arm9v2-s12.md:199).

My preferred redesign would separate **late operand selection from arithmetic/flags**, then **registered address generation from cache lookup**, carrying request ownership explicitly across both boundaries. Preserve prediction and ordinary ALU forwarding; restructure frontend selection where its independently measured paths require it. This costs dependency/recovery cycles, which must fit the gameplay budget. Removing retention first has weaker evidence and previously associated substantial miss-workload regressions. [Boundary analysis](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s11.md:358), [retention comparison](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-v2-timing-consult.md:99).

**Budget 3–5 focused implementation/validation sessions after correctness and gameplay qualification**, as an estimate, not a closure promise. There is currently no evidenced redesign guaranteed to reach both targets.

**4. My three next actions, in order**

1. **Finish the ownership fix and prove the failure class.** Require the reproducer to fail before/pass after, independent ownership checks to pass, then repeated board boots through idle and into gameplay using recorded source/image/cache identities. A passing short kernel run is insufficient.

2. **Measure V2 gameplay on the 78 MHz board.** Use matched scenes, busy-window retirements per CPU clock, frame progress and a same-frequency ZAP control. Report \(104\times\Delta instructions/\Delta clocks\). **≥52 M/s normalised** provides about **0.213 CPI** of redesign headroom; **47–52** is fragile; **below 47** does not justify timing-only work without a quantified recoverable deficit. Because lower-clock memory behaviour differs, quantify that effect before treating a low result as a definitive 104 MHz rejection. Polling instructions must not substitute for game progress. [Measurement contract](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/ARM9V2.md:24).

3. **Fund one bounded stage redesign only if its projected CPI remains ≤2.213.** Measure every failing endpoint family. Stop that shape if the completed pass remains below **−2 ns**, as the existing contract requires. The intermediate **−1 ns median CPU gate permits integration only**; acceptance requires whole-device 104 MHz setup/hold closure and actual ≥47 M/s busy gameplay with correct frame/timer behaviour. [Existing gates](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/ARM9V2.md:49).


