# Codex (gpt-6-astra) on the three timing families, 2026-10-22

Brief: the facts in docs/PROGRESS-LOG.md's sweep 3 and 4 entries and the full-path reports under build/hardware/sweep4/paths, without my plan (docs/consults/2026-10-22-timing-plan-mine.md). Answer verbatim:

**I would change family 1 first, family 2 second, and leave family 3’s architecture alone unless it remains limiting afterward.** The strongest opportunities are moving word selection ahead of way selection, and moving the merger’s final mux across its existing register boundary.

I reviewed checkout `2b84998` and the saved path reports. No files were changed and no builds were run. All gains below are **estimates of improvement to the affected path at the slow corner**, not measured results or additive improvements to whole-core WNS. Any candidate can lose its benefit through placement.

One correction matters: this tree’s register file is **40 × 32 bits**, with six-bit addresses—not 64 words. Both [the RTL](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_register_file.sv:56) and [the generated netlist](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/arm925t_gen.v:15924) show 1,280 storage bits.

**1. Family 1: shorten the work after the tag comparison.**

| Order | Change | Estimated gain | Cycle cost | Main risk |
|---|---|---:|---:|---|
| 1a | Select the word within each way before selecting the way | **0.5–1.2 ns** | **0** | Separating hit data from victim data incorrectly |
| 1b | Transform each D-cache word before selecting the way | **0.4–1.0 ns additional** | **0** | Wrong load format, double transformation, added routing |

**1a — Add a word output and separate the victim-line path.** Currently, `hit[]` determines `sel`, `sel` controls a 128-bit mux, and the FSM then selects a word. The precise locations are [tag comparison and selection](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_cache_tag_ram.sv:281), [the line mux](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_cache_tag_ram.sv:316), and [D-cache word selection](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache_fsm.sv:429).

Restructure that into:

```systemverilog
word0 = word_select(line_q[0], lookup_word);
word1 = word_select(line_q[1], lookup_word);
o_cache_word = sel ? word1 : word0;

victim_line = victim ? line_q[1] : line_q[0];
```

Use explicit constant slices in `word_select`; preserve the existing `sel` priority and miss fallback initially. The late tag result then crosses a 32-bit mux, without a subsequent 4:1 word mux.

Crucially, remove the hit-selected full-line mux from this path too. Give the FSM a clearly identified victim-line input for dirty eviction. Its current full-line capture is [here](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache_fsm.sv:258); dirty writeback consumes that captured line [here](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache_fsm.sv:745). Keep `walk_line` for maintenance operations and retain `o_cache_way` for way bookkeeping. Apply the same word-before-way structure to [the I-cache output](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_cache_fsm.sv:271).

This also attacks a demonstrated fanout problem: the saved path gives `sel` **131 loads**, followed by **1.656 ns** of interconnect. That is stronger evidence than simply counting RTL muxes. [Path report](/Users/jacob/dev/fpga/mister/NGage_MiSTer/build/hardware/sweep4/paths/vf2-8-full.txt:101)

**Verification:** compare returned words for both ways, every word offset, back-to-back stores and loads, hits under a miss, and forwarded writes at each RAM pipeline stage. Exercise dirty eviction from both ways and VA/index maintenance. Confirm that the mapped hit-select fanout falls and that neither RAM inference nor M10K count changes. The compiled byte-enable RAM is actually [the port implementation](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/port/zap_ram_simple_ben.sv:3); leave its forwarding pipeline intact.

**1b — Move the D-cache transform before the late way mux.** Expose the two raw words to the D-side logic, compute:

```systemverilog
load0 = ld_transform(word0, i_ldfmt);
load1 = ld_transform(word1, i_ldfmt);
cached_load = sel ? load1 : load0;
```

Transform `unc_dat_ff` in parallel, then select cached/uncached data. Keep the final `mem_rd_data_t` register in its present position; its input becomes the formatted load or `i_mem_srcdest_value_ff`.

There is already an appropriate [background-load transform function](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache_fsm.sv:212), and the live format comes from [the post-ALU signals](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_core.sv:572). **Use live `i_ldfmt` for a current hit, not buffered `ldfmt`: a hit under an outstanding miss can have a different format.**

Preserve raw-data transformation for the core-only configuration, and avoid transforming cache data twice in [the memory stage](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_memory_main.sv:234).

**Verification:** all byte positions, signed/unsigned byte and halfword loads, unaligned word rotations, uncached loads, hit-under-miss with differing formats, and non-load writeback values. Compare the two transform functions’ results exhaustively over control combinations and representative data patterns. Check new paths from address/format registers as well as tag registers.

I would not register `hit` an extra time: that costs a cycle on ordinary hits. Nor would I move `mem_rd_data_t` back before the transform; [the existing comment documents the writeback timing problem that placement solved](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_memory_main.sv:225).

**2. Family 2: simplify control first, then redistribute the mux delay.**

| Order | Change | Estimated gain | Cycle cost | Main risk |
|---|---|---:|---:|---|
| 2a | Derive wrapper `CYC` directly, bypassing priority selection | **0.2–0.6 ns** on that branch | **0** | Another `STB`/selection branch remains critical |
| 2b | Put the merger’s final mux after the registers | **0.5–1.2 ns** on incoming path | **0** | Moving failure onto the outgoing bus path |
| 2c | Precompute burst alternatives; eliminate unnecessary address carry | **0.3–0.8 ns** on address paths; **0.1–0.4 ns** on completion control | **0** | Last-beat, error, or writeback-data mistakes |

**2a — Avoid deriving `o_wb_cyc_nxt` through `state_nxt`.** The wrapper state is already one-hot. When arbitration is permitted, the chosen manager’s `CYC` is simply the OR of requests; when it is not permitted, use the current manager’s `CYC`.

For the D wrapper:

```systemverilog
advance = !o_wb_stb || i_wb_ack || i_wb_err;
held_cyc = |(state_ff & wb_cyc);
o_wb_cyc_nxt = advance ? (|wb_cyc) : held_cyc;
```

This is an algebraic replacement for [the priority selection](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache.sv:369) followed by [the selected `CYC` mux](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache.sv:401), for reachable one-hot states. Preserve the I wrapper’s actual ACK-based condition [here](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_cache.sv:340).

Leave payload arbitration and ACK ownership unchanged. Do not replace `STB` similarly without establishing the managers’ `CYC`/`STB` invariant.

**Verification:** exhaustive combinational comparison across valid states, all request combinations, ACK/ERR and current strobe values; then sequential comparison through simultaneous manager requests. Inspect whether Quartus already made this simplification. If it did, expect approximately **zero gain**.

**2b — Move the merger mux across the register boundary.** Today [the merger registers the selected NXT tuple](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_wb_merger.sv:174). Register both tuples, register `state_nxt` as today, and select the registered tuples using `state_ff`.

For matched enables and reset behavior:

```text
register(mux(state_nxt, code_nxt, data_nxt))
    =
mux(register(state_nxt), register(code_nxt), register(data_nxt))
```

There is no added transaction cycle. Better still, the wrappers already produce registered tuples: [D wrapper](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache.sv:341), [I wrapper](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_cache.sv:313). Their payload outputs are currently [unconnected in `zap_top`](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_top.sv:685). Reusing these avoids introducing an unnecessary third set of bus registers.

**Keep NXT strobes feeding arbitration.** Only move the payload/output mux; using registered strobes to calculate the grant would change handover timing. Preserve defined reset output values too—the wrappers currently reset some payload fields to X.

A separate implementation needs roughly **74 additional FFs** relative to one registered tuple; reuse can reduce that. No M10Ks are needed.

The limitation is significant: the acknowledge cone still reaches `state_ff`. This removes the final mux from that incoming path; it does not remove the entire arbitration chain. Meanwhile, the outgoing bus gains a mux before [the arbiter](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/upp/wb_arb2.sv:58) and `upp_bus`.

**Verification:** cycle-by-cycle bus comparison through simultaneous I/D requests, EOB handover, wait states, errors and reset. Include CPU/DMA contention through `wb_arb2`, checking ownership of the completing response. Time both the new grant-register endpoint and every outgoing path into `upp_bus`; CPU-only success is insufficient.

**2c — Precompute current/next burst values, rather than calculating them after ACK.** In [D fetch](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache_fsm.sv:780) and [D clean](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_dcache_fsm.sv:736):

- Define `take = o_wb_stb_ff && (i_wb_ack || i_wb_err)`.
- Compute current and incremented two-bit word indices independently of `take`.
- For active beats, form addresses by concatenation: `{base[31:4], word_index, 2'b00}`.
- Decode completion directly from `take && adr_ctr_ff == 3`, preserving the sentinel behavior outside active beats.
- Compute current/next CTI and clean-data words in parallel; let `take` select them last.

Apply the equivalent changes to [I-cache bursts](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_cache_fsm.sv:505) and [the clean walker](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_cache_tag_ram.sv:771).

Be sceptical about the “32-bit addition” diagnosis: multiplication by four is wiring, and synthesis may already simplify much of the aligned addition. Inspect the mapped carry chain before claiming its removal. I would not start by adding two 32-bit address registers per manager.

Also, the timing-plan note overgeneralizes the TLB walker: its addresses are already [concatenations of descriptor/base and index fields](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_tlb_fsm.sv:137), not this burst-counter expression.

**Verification:** every beat with zero and multiple wait cycles; final-beat ACK and ERR; clean-to-fetch transition; correct write-data word accompanying each address; no beat crossing into the next line.

I would leave the arbiter’s `gnt` architecture alone. Its address/data copy already exists [here](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/upp/wb_arb2.sv:53). Registering ACK indiscriminately costs a cycle on responses and requires corresponding changes to data and ownership timing.

**3. Family 3: defer architectural changes; use narrow experiments if necessary.**

The standalone CPU result and the saved placement suggest a locality problem before a fundamental register-file architecture problem. The issue path has **365 loads on `o_stall_from_issue`**, a subsequent control node with **192 loads**, and register-file logic spread between X50 and X70. [Saved path](/Users/jacob/dev/fpga/mister/NGage_MiSTer/build/hardware/sweep4/paths/vf-2-full.txt:96)

My contingency order would be:

| Order | Change | Estimated gain | Cycle cost | Risk and verification |
|---|---|---:|---:|---|
| 3a | Local copies of the issue-stall register for operand-index consumers | **0–0.4 ns** | **0** | Low functional risk, uncertain placement benefit. Prove copies equal and inspect actual fanout/placement. |
| 3b | Explicit banked register-file read mux | **0.3–0.9 ns** | **0** | Moderate area/routing risk. Compare all ports and write collisions; reject a large ALM increase. |
| 3c | Separate forwarding priority from the wide data mux | **0.2–0.6 ns** | **0** | Priority mistakes or synthesis reconstructing the old topology. Compare simultaneous matches exhaustively. |

For **3a**, each copy must implement the same reset, clear, hold and `lock` update as [the original register](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_issue_main.sv:400). Do **not** clock a copy from `o_stall_from_issue`, which delays it. Use targeted preservation against merging only if necessary; blanket preservation can prevent helpful physical optimization.

For **3b**, retain the flop storage and all write semantics. Replace [the four variable-index reads](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_register_file.sv:88) with five groups of eight words: local low-three-bit selection, followed by a five-way high-bit selection. Try one port first. Preserve the coprocessor override on [port A](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_writeback.sv:204), and the current write priority **C over B over A**. Do not alias addresses 40–63 onto real registers.

This offers a controllable placement structure, not guaranteed fewer LUT levels. A flat one-hot implementation can create thousands of distributed gating connections. Nor does simple RAM replication solve three independent writes plus four asynchronous reads.

For **3c**, compute forwarding matches in parallel, derive mutually exclusive priority grants, then combine masked data with a balanced OR. Preserve exactly [the current ordering](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_issue_main.sv:1133): immediate, RAZ, PC, CPSR, youngest forwarding result through memory, then register-file fallback. Place the late register-file fallback behind one final selection where mapping permits.

For the **lock-path variant**, a smaller zero-cycle experiment is factoring per-stage `valid && load` terms and balancing the source/stage match reduction; expect only **0–0.4 ns**. Include the destination hazard check—this tree checks more than four read sources. [Destination check](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_issue_main.sv:895), [lock function](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_issue_main.sv:1023)

I specifically reject simply sampling `i_dc_lock` one stage earlier as “cycle-identical,” as suggested in [the existing plan](/Users/jacob/dev/fpga/mister/NGage_MiSTer/docs/consults/2026-10-22-timing-plan-mine.md:69). A lock can assert or clear while the instruction is stalled. Making that correct needs current-cycle forwarding/invalidation and skid handling. That is disproportionate risk for a 0.27 ns deficit.

**Fitter and floorplan: cheaper experiments exist, but no obvious unused magic switch.**

The QSF already enables substantial effort and physical optimization. [Settings](/Users/jacob/dev/fpga/mister/NGage_MiSTer/NGage.qsf:29)

| Experiment | Estimated affected-path gain | Assessment |
|---|---:|---|
| `ALM_REGISTER_PACKING_EFFORT LOW`, versus current `MEDIUM` | **0–0.4 ns** | Worth one controlled run; may improve locality at increased ALM usage |
| Separately disable `PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA` | **0–0.3 ns** | Sharing reduction may help fanout, but increased area can worsen congestion |
| Increase placement effort beyond 2.0 | **0–0.2 ns** | Low engineering cost, weak expected return after thirteen seeds |
| Small, targeted placement region, if supported | **0.2–0.8 ns** | Plausible from the measured detours; can also regress neighboring paths |

All have **zero cycle cost**. Evaluate area, routing congestion, every timing corner and all three families—not just the previously worst endpoint. Altera documents the timing-versus-density tradeoff of ALM packing explicitly. [Fitter settings reference](https://resources.altera.com/quartushelp/20.4/comp/comp/comp_tab_physical.htm)

For placement, the first target would be the cache output/compare logic and its post-ALU/memory endpoints, followed by the wrapper/merger control. The bus report visibly travels **X39 → X55 → X40**. [Report](/Users/jacob/dev/fpga/mister/NGage_MiSTer/build/hardware/sweep4/paths/vf2-7-full.txt:97)

However, **do not assume LogicLock is available in Lite**: Altera’s edition comparison lists it for Standard/Pro, not Lite. Verify the actual 17.0.2 installation/license before spending effort on region assignments. [Edition comparison](https://www.intel.com/content/dam/www/central-libraries/us/en/documents/quartus-prime-compare-editions-guide.pdf) If available, start with a small floating, non-reserved region with adequate RAM resources and placement slack; do not tightly box the whole CPU. Keep assignments in core-owned files.

Two other qualifications:

- **Keep `OPTIMIZE_HOLD_TIMING ALL PATHS` initially.** Positive hold slack may be the result of those repairs. A diagnostic comparison with reduced hold optimization is useful only if the reports show relevant detours; expected benefit without that evidence is approximately **0 ns**. It is acceptable only if full minimum-delay analysis still passes.
- [Whole-core `TIMEQUEST_MULTICORNER_ANALYSIS OFF`](/Users/jacob/dev/fpga/mister/NGage_MiSTer/NGage.qsf:27) is not proof that fitter multicorner optimization is disabled. Check effective `OPTIMIZE_MULTI_CORNER_TIMING` separately. The repository’s [report script already iterates operating corners](/Users/jacob/dev/fpga/mister/NGage_MiSTer/tools/report_timing.tcl:13). Enabling additional analysis alone buys **0 ns**.

**The verification gate should distinguish functional agreement from cycle identity.**

For each retained RTL candidate:

1. Regenerate through [the existing sv2v flow](/Users/jacob/dev/fpga/mister/NGage_MiSTer/tools/gen_cpu.sh:29), run `cpu-gen-check`, and inspect the mapped structure and resource delta.
2. Run the 177 CPU cases and 49 QEMU comparisons, then the full 2.7-billion-cycle boot comparison.
3. Add an original-versus-candidate cycle comparison at the changed interfaces: cache data/ACK/stall, bus tuple/ownership, or issue operands/lock. QEMU agreement alone cannot establish cycle identity. The boot comparator explicitly compares access sequences rather than timing, and currently accepts a matching common prefix. [Comparator](/Users/jacob/dev/fpga/mister/NGage_MiSTer/sim/cpu/boot/cmp_dev.py:9)
4. Use the CPU-only fit as an early rejection gate, then run matched whole-core seeds **2, 7, 8 and 11**. Compare family-specific paths and global WNS at both slow corners, plus hold/recovery/removal everywhere. Export detailed paths *inside* the corner loop; the current script emits its detailed report before that loop.

I would spend the first implementation effort on **1a**, the first small control experiment on **2a**, and the next substantial experiment on **2b**. Those offer useful structural improvement without changing instruction or bus timing.


