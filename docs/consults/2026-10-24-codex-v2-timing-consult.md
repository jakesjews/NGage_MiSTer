# Codex consult on ARM9 v2's timing shape (2026-10-24, read-only, session 01a16d0a-0c80-7571-856a-e49aa70df8ae)

The brief: docs/consults/2026-10-24-v2-timing-consult-brief.md. Codex's answer follows verbatim.

**My recommendation is to keep the two-clock late pickup and miss retention while cutting the completion logic and the cache lookup path. Registering request ownership alone will not fix this design.** The full timing paths expose a misleading interpretation in the compact family table: the paths starting at W’s load-owner bit reach cache metadata **through A’s bypass and address adder**, rather than through cache-write ownership.

I verified that all 61 source hashes and the generated netlist match the final fit manifest. No edits or builds were run. The gains below are engineering estimates for this device, not measured results; gains on individual families must not be added together as overall slack gains.

1. **What actually became expensive**

The evidence does **not** isolate the 1.601 ns regression between early/late splitting and miss retention. S7 was never fitted. S8’s leading path was memory-state control through store merging into the short-hit word; S9’s leading path is now completion into next-producer matches. Assigning the entire regression to either feature would exceed the evidence. [S8 attribution and path families](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s8.md:312)

The present RTL establishes three concrete problems:

- **Completion determines the producer identity before the tag comparison.** `done` selects current versus advancing/reloaded M/W records in `forward_tag`; execute then compares those selected tags before registering `a.late`. Thus “registered matches” still means `lock → completion → producer mux → comparison → match register`. Registering the result does not make its input path short. [Producer selection](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:430), [held and admitted A matches](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_execute.sv:341)
- **A registered address is selected combinationally before translation.** `check_record` chooses W or M from `memory_state`, followed by FCSE and check qualification. The fitted path explicitly passes through `o_data_wb_adr_check[28]` and TLB matching. Registering only a request-valid bit would leave that path intact. [Check owner](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:515), [fitted translation path](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/arm9v2/s9-cut4-seed2/detail_Slow_1100mV_100C_Model.txt:650)
- **The A address still does substantial cache work before its first register.** The 11.595 ns metadata path is `w[493] → right_a → ALU → address selection → rd_set → metadata mux → valid_q`. The 11.618 ns short-forwarding path shares that prefix, then compares read/write addresses. The A-match-starting family follows the same address path. These are primarily **lookup-address paths**, not evidence that W’s owner directly writes a distant metadata array. [Metadata path](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/arm9v2/s9-cut4-seed2/detail_Slow_1100mV_100C_Model.txt:755), [collision path](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/arm9v2/s9-cut4-seed2/detail_Slow_1100mV_100C_Model.txt:1306)

That third distinction changes my ranking substantially. `valid_q` is a read-result register; the underlying valid array already updates through registered `pend_*` ownership. The short RAM separately registers `write_enable && write_address == read_address` on the A-launch edge. [Metadata implementation](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/zap/zap_cache_tag_ram.sv:579), [short RAM](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/zap/zap_ram_simple.sv:55)

There is also a schedule correction: this source formats the short word **before** the M/W edge, with `tr_cache_words <= formatted`; W consumes that registered result. It does not have an unregistered formatter in W awaiting a free timing cut. [Formatting and capture](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/zap/zap_dcache.sv:415)

**The Pocket comparison supports the schedule, not 104 MHz closure.** Its unshifted consumer waits while the load is in A, advances when the load is in M, and uses W’s registered result in A. That is already V2’s two-clock spacing, not the proposed three-clock alternative. Its `late_of` uses previously registered matches; its next-match function also expresses comparisons separately from stage-position selection. [Pocket load interlock and late selection](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/rtl/arm_cpu.sv:683), [Pocket next matches](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/rtl/arm_cpu.sv:986)

What Pocket lacks is **this combination of background architectural register locks, W completion/reload arbitration, and retained consumers whose producer identities must be repaired across independent backend movement**. Pocket instead couples A’s movement to M’s hold. It does have cache-response-dependent control; claiming it has no comparable control problem would be wrong. [Pocket movement contract](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/rtl/arm_cpu.sv:973)

And 88.7 MHz provides **1.659 ns more period** than 104 MHz. Its reported CPU-only result therefore does not establish that this integrated CPU/cache system ought to close at 104. [Pocket timing results](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/docs/core-design.md:799)

**Why 65–73% routing?** These chains repeatedly cross physical clusters:

- The worst completion path spends 2.822 ns reaching the lock-reduction output, then encounters individual routes of **1.452, 1.336, 1.292 and 1.783 ns**. The fanout-163 completion node is one contributor, not the entire problem.
- The metadata path includes a **fanout-110 read-set node** and a 1.624 ns route toward the metadata mux.
- The short-forwarding path crosses from bypass/ALU placement into cache collision logic and distributed RAM-lane registers.

Those are concrete placement distances and distributed loads. Routing percentage alone does not prove congestion or imply that floorplanning can recover 65% of the delay. [Completion routing](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/arm9v2/s9-cut4-seed2/detail_Slow_1100mV_100C_Model.txt:114), [metadata routing](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/arm9v2/s9-cut4-seed2/detail_Slow_1100mV_100C_Model.txt:778)

2. **Ranked structural options**

Here, “zero cycles” means preserving **3/4/5**, the existing miss/hold/reload schedule, and consequently the existing deterministic firmware milestone clocks. It is a verification requirement, not something a new register automatically guarantees.

| Rank | Concrete cut | Expected timing gain and remaining leader | Cycle cost | Risk / effort |
|---|---|---|---|---|
| **1** | **Compute lock summaries on the lock-update edge.** Register the global nonempty summary alongside `lock_ff`, using its next value; address W-owner lock status separately. | **1.3–2.5 ns on family 1** if its reduction is removed successfully. Overall improvement initially only about **0.21 ns**, because translation remains at −2.658 ns. | **Zero**, with exact next-state alignment. | Medium: simultaneous install/clear and changing W owner. Small implementation; substantial edge-case proof. |
| **2** | **Move cache collision comparison and the final metadata-read selection across A/M into M.** Capture lookup/write descriptors with the RAM read; use a banked/partial metadata read so the full indexed selection no longer follows A’s adder. | **1.5–2.7 ns on families 3–5**, potentially making M compare/format or the RAM address input lead. Family 1 and translation remain until separately cut. | **Zero intended**; retain the M/W response edge. | High: RAM collisions, live versus pending writes, HUM, maintenance and holds. Roughly a session or more, in separate cuts. |
| **3** | **Split next-producer matching from completion.** Compare candidate owners in parallel; register candidate matches and a narrow producer-transition selector at the existing boundary. Select registered matches afterward. | **1.5–3.0 ns on family 1** as an alternative/complement to rank 1. Gains overlap. Translation/cache lookup then lead. | **Zero** if retirement stays on its present edge. | Medium–high: producer age, hold/reload selection and added match storage. About a session. |
| **4** | **Register the complete selected translation owner**, including FCSE address, access mode, user override, format and enables, on the existing lookup-owner edge. Give architectural request control its own aligned registered descriptor. | **1.2–2.5 ns on family 2**. Does **not** remove the A-address paths in families 3–5. | **Zero intended**. A register appended after current selection would instead add a clock. | Medium–high: retry, fill installation, SWP phase, abort and CP15 changes. Half to one session. |
| **5** | **Localize completion fanout.** Separate retirement, producer-transition and request consumers; duplicate narrow registered summaries or local qualification cones. | **0.2–0.7 ns on family 1**, often little overall gain. The reduction and tag-selection depth remain. | **Zero**. | Low functional risk; moderate fitting risk. Small cut. |
| **6** | **Three-clock late pickup**, genuinely moving load consumption into the earlier operand-capture schedule and removing its A-side load selection. | **0 ns from merely adding a stall**; approximately **0.5–1.2 ns on affected bypass/address paths** if the hardware is simplified. ALU late-match and completion paths remain. | **3/5/5**. One extra slot per exposed late load dependency. | Medium; firmware gain must be remeasured. About a session. |
| **7** | **Register accepted cache-write ownership.** Carry write event, address, way, bytes and data together. | **0–0.3 ns expected on the cited leading paths**, because their long side is lookup addressing. Could help other write-control paths. | Zero only with correctly aligned forwarding; otherwise extra collision/maintenance stalls. | High for the expected payoff. Underlying metadata already has pending-write ownership. |
| **8** | **Placement/settings/seeds.** Local regions and duplication experiments after structural cuts. | Budget **0–0.5 ns**, with regressions equally plausible. No family is structurally removed. | **Zero**. | Low RTL risk; potentially high area/routability cost. Several fits. |

Three implementation qualifications matter:

**For rank 1, register next locks, not old locks.** `summary <= |lock_ff` would introduce a stale cycle. A miss ACK installs a lock on the accepting edge; consumers must see that new lock immediately afterward. The FSM clears through `o_reg_idx` and sets miss ownership in the same next-state calculation. W also has both global-lock and owner-specific completion conditions: replacing only `w_locked` does not address every reduction feeding completion. [Lock update](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/zap/zap_dcache_fsm.sv:637), [installation](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/zap/zap_dcache_fsm.sv:812), [completion conditions](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:551)

A next-lock reduction could itself become a new critical path. Prefer event-based summaries where the outstanding-owner invariant is proved, or registered partial reductions otherwise. Do not assume “only one lock” without proving installation/clear overlap.

**For rank 3, do not simply delay `wb_complete`.** That changes completion, reload and retirement timing. The useful boundary registers the transition decision alongside independently computed candidate matches, so completion no longer precedes the tag mux and comparator. The existing post-acceptance return-lock qualification must remain intact. [Return qualification](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:341)

**For rank 4, there is already an instructive failed experiment.** S6 registered a selected check record without changing cycles; overall timing worsened by 0.148 ns because the frontend became limiting. That supports feasibility, but not a promised whole-design gain. Its owner-selection proof should be reused conceptually and extended to S8’s new transitions. [S6 selected-check experiment](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s6.md:144)

For placement, the fitted QSF already enables physical synthesis, register duplication, retiming and router duplication. “Turn them on” is not a new experiment. Keep the RF retiming restriction: removing it previously bought only **0.476 ns** while costing **1,816 ALMs**. [Fitted settings](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/arm9v2/s9-cut4-seed2/cpu_trial.qsf:14), [RF tradeoff](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s9.md:139)

I would try a loose region around the **backend and its adjacent D-cache control**, respecting RAM locations, before boxing the entire CPU tightly. A CPU-only region can lengthen precisely the CPU/cache paths that matter. Altera’s Standard guidance itself cautions against treating LogicLock as a general timing cure; region sizing must leave room for optimization. [LogicLock guidance](https://docs.altera.com/r/docs/683230/18.1/quartus-prime-standard-edition-user-guide-design-optimization/logic-lock-standard-assignments?contentId=xWpmgoVfDvUfDdT_F_TvRw), [region sizing](https://docs.altera.com/r/docs/683283/18.1/quartus-prime-standard-edition-user-guide/modifying-region-size-and-origin)

3. **The plausible ceiling and fallback**

**The thread’s two proposals, interpreted narrowly, leave roughly −2.6 ns lookup paths.** Completion and translation can improve substantially while overall timing barely moves.

With those cuts **plus** successful cache metadata/collision restructuring, my planning estimate is:

| Outcome | CPU-trial slack at 104 MHz | Whole-device slack using your stated penalty |
|---|---:|---:|
| Plausible successful structural result | **−1.5 to −0.8 ns** | **−2.5 to −1.1 ns** |
| Strong upside case | Around **−0.5 ns** | **−1.5 to −0.8 ns** |

I would **not budget for zero slack** from this eight-stage shape. These ranges are forecasts, anchored by the older approximately −1.2 ns shape and the newly identified removable chains. They are not a bound: the current worst-30 reports hide other endpoints, and older fits exposed frontend/decode limits. [Older remaining frontend paths](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s6.md:194)

To obtain approximately **−1 ns on the whole device**, the CPU trial needs **−0.7 to 0.0 ns**—an improvement of **2.171–2.871 ns** from today. That is a demanding target. Negative slack remains a timing violation even if a particular board runs reliably.

My preferred fallback is a **registered address-launch stage between A and the cache RAM-read stage**:

`F1 F2 D1 D2 S A L M W`

A ends at a registered result/address. L drives cache RAM, metadata and collision handling; M performs comparison/formatting/translation as aligned by the new contract. This directly cuts the bypass–adder–cache chain. Preserve forwarding from L’s registered ALU result so ordinary ALU dependencies do not acquire an unnecessary stall.

Expected consequences:

- **Approximately 2–3 ns reduction on the existing address-to-cache families**, before another family takes over; completion still needs its own fix.
- Steady warmed windows should become **3/5/6**: independent spacing stays one, late load spacing increases to three, early to four.
- Correct prediction and A-resolved branches need not gain a fetch penalty; W recovery is one stage deeper.
- Serialized memory/relookup paths can gain a launch clock. Extra in-flight storage and precise exception ownership need explicit redesign.
- High effort and verification risk, but it preserves the useful predictor, ALU late forwarding and miss retention.

The alternatives are less attractive:

| Fallback | Expected timing benefit | Cycle consequence |
|---|---|---|
| **Remove the complete late bypass** | Roughly **1–2 ns on bypass/address families**, provided replacement S forwarding does not become critical. Completion/translation remain. | **3/5/5** for loads; an immediately dependent unshifted ALU consumer generally gains **one stall**. This taxes common integer code. |
| **Remove miss retention and restore scalar replay** | I would budget only **0.3–1.0 ns**, with low confidence; no isolated fit proves it. It does not inherently remove A’s address path or all completion matching. | Hits remain **3/4/5**; misses/held accesses discard younger work and refill. |

The replay fallback has especially poor evidence behind it. S7’s replay design took **1,165,512** clocks on `cache` at 2:9 versus S8’s **1,014,159**—about **14.9% more**. That includes associated policy changes, so it is not a pure retention ablation, but it is a strong reason not to discard retention first. [S7 counts](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s7.md:275), [S8 counts and recovery evidence](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s8.md:30)

**No cycle-changing fallback can honestly promise to preserve the measured 13% boot gain.** The EFile advantage is **58,346,799 clocks**. That is the available headroom before losing the entire measured advantage; every additional 10 million unhidden clocks costs approximately **0.0962 guest seconds** at 104 MHz. Measure it rather than inventing a boot percentage. [Exact milestone clocks](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s9.md:233)

4. **The next two implementing sessions**

Keep seed 2 and identical constraints for each structural cut. Record family-specific worst paths as well as global slack: a successful first cut may improve global slack by only 0.21 ns because another family immediately takes over.

| Session / order | Cut | Decisive measurement |
|---|---|---|
| **Session 10, first** | Install-edge lock summaries. | **Every-edge equality** between the new summaries and the actual post-edge lock/owner state, including simultaneous installation and completion; the fitted lock-to-match family should shorten by at least about **1 ns**. |
| **Session 10, conditional second** | Split completion from candidate producer matching, **if family 1 remains limiting**. | The mapped path to S/A matches must **no longer contain completion → selected tag → equality in series**. Direct-match/age assertions must agree on transfers and holds. |
| **Session 10, next** | Register the selected translation/request descriptor. | An **edge-by-edge owner tuple comparison**—address, mode, user override, format and enables—must match the old schedule; the memory-state-through-address-mux TLB path must disappear. |
| **Session 11, first** | Move short-RAM collision comparison after its lookup-capture edge. | A **cycle-exact RAM-output comparison** across every byte-enable collision and hold; the A-adder-to-`forward_write` path must disappear. |
| **Session 11, second** | Split/bank metadata reads across the existing A/M boundary, keeping final response at M/W. | **Cycle-exact hit/way/victim/dirty/valid outputs** under stores, fills and maintenance; no full metadata selection should remain after A’s adder. |

These are separate cuts and separate fits. For every zero-cycle cut, retain all existing suite cycle/instruction pairs, all 85 windows at all latencies and both predictor modes, and the QEMU references. At each session’s accepted endpoint, require the firmware milestone clocks and logs to match S9.

Finally, request **worst paths per distinct endpoint/family**, beyond the first 30 near-duplicate paths. That is the measurement needed to judge the ceiling after removing these chains. If the completed structural result remains below approximately **−1.5 ns**, move to the address-launch-stage decision; do not spend the next session searching seeds for a 2 ns rescue. If it approaches the integration target, then characterize seeds 2/3/4 and the whole device.


