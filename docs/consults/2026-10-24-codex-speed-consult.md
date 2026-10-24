# Codex consult on the phone's speed (2026-10-24, read-only, session 01a16c0b-58c4-7552-a830-606a547e4f0d)

The brief: the facts and four questions in the session's scratch consult-speed-brief.md (the goal 47 M instructions/s, where ZAP and ARM9 v2 stand, the Pocket core as the existence proof). Codex's answer follows verbatim.

**Keep V2. Its unfinished load schedule and avoidable serialization are the best route to phone speed. I would not port the Pocket CPU, and I would not treat the 48% code-stall counter as evidence that instruction misses dominate.** A separate CPU clock is a useful fallback for delivering a reliable core, but lowering the clock makes the 47 M/s requirement harder.

I only read files. I ran no builds, tests, edits, or git commands. Gain and effort estimates below are my engineering estimates, not measured results.

Four findings materially change the brief:

- **“Code stall” includes a full fetch FIFO.** Its actual definition is `fifo_full | (fetch_request & ~fetch_ack)`. Much of that 48% can therefore be the frontend waiting for the backend. The tap cannot distinguish that from instruction-memory starvation. [zap_core.sv:664](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/zap/zap_core.sv:664)
- **V2 already has the fetch-cycle predictor.** Its trained branch window is two clocks including the target marker: no extra fetch slot. The Pocket’s approximately 0.1-CPI advantage over a late BTB is not another gain available to V2. [S5 windows:170–182](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-23-codex-arm9v2-s5.md:170)
- **The selected machine is ARMv4T.** The wrapper explicitly sets `V4T=1` and `TI925T=1`; V2 also selects the v4T Thumb decoder. I would budget no ARMv5 implementation work without identifying an executed opcode that requires it. Upstream ZAP’s broader ISA is irrelevant to that configuration. [arm925t.sv:103](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/arm925t.sv:103), [arm9v2_decode.sv:260](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_decode.sv:260)
- **There is newer, provisional S6 evidence.** The merged baseline is −1.651 ns, 15,881 ALMs, with 264/264 runs and 68 references agreeing. The producer-eligibility cut preserves those counts; its fit was pending in the report I read. Load pickup remains unfinished. This supersedes −2.109 ns as the latest baseline, but establishes neither a timing trend nor closure. [S6:19–53](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s6.md:19), [S6:76–97](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-24-codex-arm9v2-s6.md:76)

**Pocket’s advantage is a cheaper common instruction path, supported by a simpler machine contract.** It does implement exceptions and banked registers; “they can skip precision” is too broad. The important differences are these:

| Area | Pocket implementation | V2 implementation and my assessment |
|---|---|---|
| Load-use | One bubble for an unshifted consumer, two for a shifted consumer. S marks operands for pickup in A from W; a memory hold prevents the schedule outrunning the load. | Five extra slots currently; three planned. False WAW hazards additionally stall independent instructions. These are implementation costs, not EKA1 requirements. |
| Forwarding | Three operands; match flags computed a cycle ahead. S primarily selects registered M/W results; A has narrowly specified late-pickup selectors. | Four operands search six destination lanes using live tag comparisons, then apply priority, PC/CPSR substitution and shifting. Registered producer eligibility helps, but does not remove the comparisons from S. |
| Register file | 32 physical entries, five variable read ports, two writes; SPSRs live separately. | 40 entries, four reads, three writes, including asynchronous-in-program-order background load completion. Banked state is required; the third write port and its bypass/locking machinery are choices associated with nonblocking loads. |
| Prediction | Fetch-cycle BTB, RAS, early direct branches. Current source uses **512**, not 256 entries. | Same essential early-prediction advantage already exists. Remaining opportunities are return recovery, unnecessary clearing and redirect ordering—not moving the ordinary BTB earlier. |
| Cache interface | Address launches directly from A; next cycle supplies hit/word. Cache hit completion and pipeline hold are closely coupled. I-cache can serve arrived words and unrelated hits during a fill. | Registered address/check/format stages, an ordered FSM request, background locks, a reservation and reload/retry states. This deliberately avoids Pocket’s long hit-to-pipeline-enable chain, but currently pays additional recovery and hazard costs. |
| Privileged machinery | Custom page table, no ARM CP15, no FIQ input, no ARM domain/AP checks. | Real CP15/MMU/FCSE, mode-dependent permissions, maintenance, FIQ, fault records and block-transfer abort restoration. These are genuine requirements for the real firmware. |

The implementation evidence is particularly direct: Pocket’s late forwarding and interlocks are at [arm_cpu.sv:664–727](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/rtl/arm_cpu.sv:664); its stated load-use costs are at [core-design.md:681–698](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/docs/core-design.md:681). V2’s live comparisons are at [arm9v2_forward.sv:14–28](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_forward.sv:14), followed by substitution and rotation at [arm9v2_execute.sv:101–149](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_execute.sv:101).

Three concrete V2 changes deserve priority:

1. **Use actual writer masks in hazards.** Today both decoded destination lanes participate in WAW checks regardless of whether the instruction writes them. The six pending-load positions also remain hazards through W. This explains the measured seven-clock *independent* LDR/ADD window. Remove nonexistent dependencies before attempting more speculative execution. [arm9v2_decode.sv:419–430](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_decode.sv:419), [arm9v2_core.sv:363–368](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:363)

2. **Precompute forwarding matches, not just producer eligibility.** S5’s worst family is precisely producer tag/valid → forwarding → substitutions → rotator. Pocket already moved the tag comparisons to the preceding boundary. V2’s design document also calls for this, but the current forwarding module still compares tags combinationally. Carry registered match bits with ownership, update them during holds, and qualify them with registered writer masks. This is my first structural timing choice. [S5 timing families:122–134](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-23-codex-arm9v2-s5.md:122), [ARM9V2.md:125–140](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/ARM9V2.md:125)

3. **Separate “accepted memory operation” from “usable load result.”** The short port already registers formatted words. The difficulty is the FSM contract: an early miss acknowledgement can establish a background lock on the same edge that a consumer observes the old lock. Simply deleting M/W hazards is incorrect. Explicit registered result ownership and replay are warranted; a second general forwarding network is not. The `HOLD → RELOAD0 → RELOAD1` recovery sequence is another measurable implementation tax. [zap_dcache.sv:417–434](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/zap/zap_dcache.sv:417), [arm9v2_core.sv:459–565](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:459), [S5 continuation:214–228](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-23-codex-arm9v2-s5.md:214)

**The 8,260-versus-5,000-ALM difference cannot all be charged to the real kernel.** V2’s measured breakdown is frontend/decode 3,569; S/A 1,563; RF/writeback 2,033; CP15 315; local M/W/recovery 778. Its integer core is essentially the same size as ZAP’s; most integrated savings come from the short cache pipelines. That points toward broad packets, duplicated selection/control and retirement machinery as well as privileged functionality. It does not justify a register-file rewrite as the next task. [S4 area breakdown:353–364](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/docs/consults/2026-10-23-codex-arm9v2-s4.md:353)

EKA1 requires correct architectural state at exceptions, permissions, translation and cache-maintenance boundaries. It does **not** require every MSR to drain and refill, every consumer to wait until a load leaves W, or unrelated accesses to pay a fixed recovery sequence. V2 currently serializes all MSRs and clears prediction on CP/MSR redirects; the S5 flags-only MSR window costs twelve clocks. Those are defensible bring-up choices, not permanent architectural obligations. [arm9v2_core.sv:455–457](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:455), [arm9v2_core.sv:515–528](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_core.sv:515)

Conversely, Pocket’s low CPI is not a controlled comparison with EKA1. Its kernel changes scheduling semantics enough that its documentation attributes **24–32% frame-rate differences** in several games to tick-rounded waits. Its page table is a custom on-chip structure read on misses, without ARM permissions. These differences invalidate a direct transfer of its gameplay CPI or fps. [hardware.md:102–130](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/docs/hardware.md:102), [hardware.md:157–176](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/docs/hardware.md:157)

**My ranking of the four routes follows.** Costs are additional from the inspected state; CPU trial fits are separate from whole-core builds.

| Rank and route | Expected outcome | Cost | Main risk | One measurement that settles it |
|---|---|---|---|---|
| **1. Finish and streamline V2 at 104 MHz** | Session-6 load work alone: roughly **+2–5 M/s**, if representative dependency frequencies support it. Broader load/recovery/serialization work: planning range **38–45 M/s**. Reaching 47 requires ≤2.21 CPI; that remains a further gate. | **6–10 sessions**, **4–8 whole-core builds**, roughly **8–14 CPU fits** | Timing and CPI improvements fight each other; first real firmware integration may expose gaps outside the suite | Matched gameplay run on timing-clean whole-core RTL: busy CPI ≤2.21, with Asphalt frame time meeting its cap |
| **2. V2 on its own clock, after CPI work** | Useful reliable fallback; budget approximately **35–41 M/s**, not automatic phone speed. At 88 MHz, 2.0 CPI gives only 44 M/s before any additional crossing cost | **2–4 sessions**, **3–5 whole-core builds**, additional to CPU work | A beat-by-beat crossing destroys burst latency; whole-core placement may still limit frequency | Same V2 revision and gameplay sequence, comparing wall-time instructions/frame with a measured burst crossing |
| **3. Continue ZAP memory work** | Likely **+1–3 M/s** beyond today from worthwhile remaining changes. Treat **36–38 M/s** as an optimistic envelope, not an established ceiling | **3–5 sessions**, **3–6 whole-core builds** | Double-counting already-hidden store/writeback latency; ordering bugs in posted writes | Same-scene A/B showing reduced exposed memory waiting and improved frame time |
| **4. Adapt Pocket’s CPU** | No defensible speed forecast after adding our system contract. Even an illustrative 0.3-CPI integration tax changes 80/1.7 = 47.1 into **80/2.0 = 40 M/s** | **10–20+ sessions**, **6–12+ whole-core builds**, assuming source-use permission first | Recreating the hardest parts of V2 integration while losing its verification progress | Real EKA1 gameplay on the adapted CPU, with the same caches/bus—not the NGVM benchmark |

The V2 estimate is deliberately below its aspiration. Reducing five load bubbles to three saves `2 × exposed_dependency_frequency` CPI. At one such dependency per ten instructions, that is **0.2 CPI**, not the approximately **1.14 CPI** needed to move 31 to 47 M/s at 104 MHz. False hazards and other stalls can add meaningful savings, but the desired 35% reduction needs evidence across several causes.

Also, **Pocket did not close its predictor-equipped CPU at 96 MHz** in the cited comparison. Its documented median is 88.7 MHz with BTB versus 100.3 without; integrated operation settled at 80 MHz. That is a stronger warning than the earlier 96-MHz milestone suggests. [core-design.md:799–812](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/docs/core-design.md:799)

For V2, adding the negative slack to the 9.615-ns period gives a rough screening estimate of **85.3 MHz for S5**, **88.8 MHz for the merged S6 baseline**. This is not a replacement for an Fmax report or refit. I would budget **80–90 MHz as the current fallback range**, **96 MHz as a plausible structural-work target**, and **104 MHz as an unproven stretch requiring the identified paths to improve**.

| CPU frequency | Maximum effective CPI for 47 M/s |
|---:|---:|
| 104 MHz | 2.213 |
| 96 MHz | 2.043 |
| 90 MHz | 1.915 |
| 88 MHz | 1.872 |
| 80 MHz | 1.702 |

A negative-slack 104-MHz design still clocks at 104 MHz; it does not silently run at its estimated Fmax. Lowering its frequency improves timing margin, not throughput. It beats today’s ZAP only if its improved CPI compensates.

For a separate clock, put the **CPU, caches, TLBs, CP15 and merger together**. Cross below them; crossing the hit path would defeat the purpose. Keep UPP timers, LCD, audio, MMC and DMA on 104 MHz. Timer semantics explicitly depend on 104/3 MHz, and audio uses `CLK_HZ=104_000_000`. [upp_timers.sv:3–8](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/upp/upp_timers.sv:3), [upp_haudio.sv:58–60](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/upp/upp_haudio.sv:58)

Budget **2–3 destination clocks each way** for a conventional crossing. At 88/104 MHz that is about **42–63 ns**, or **3.7–5.5 CPU clocks**, added to a transaction. A 12–15-clock 104-MHz fill then becomes roughly **14–18 CPU clocks**, before extra arbitration. Crucially, amortize the crossing over a line and stream returned words. A request/ack toggle for **each of four beats** pays much of that overhead four times. The current wrapper is a beat handshake, so a burst-aware adapter is real protocol work. Pocket already crosses line requests and streams word availability. [arm925t.sv:13–28](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/arm925t.sv:13), [Pocket crossing:398–412](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/docs/core-design.md:398)

IRQ/FIQ levels, reset release and debug snapshots also need proper crossings. Preserve peripheral event ordering at the actual bus acceptance edge. Instruction counts at interrupt boundaries will change; wall-time timer, LCD and audio rates must not.

**The memory thread should first measure exposed losses, then implement true instruction early restart if those measurements support it.**

The present evidence does not establish I-fetch as the first-order loss:

- The 48% tap conflates starvation and backpressure.
- The log’s approximately 500 K I-fills/s is inferred from residual traffic, not counted. At 12–15 clocks each, that is approximately **6–7% of clocks in fill service**, before arbitration/recovery—not 48%. [PROGRESS-LOG.md:3827–3839](/Users/jacob/dev/fpga/mister/NGage_MiSTer/docs/PROGRESS-LOG.md:3827)
- The 12% FIFO-invalid tap includes redirect recovery and provisional-fill blocking as well as an empty queue. It is not an independent miss-stall bucket.

I would add these registered events and cycle accumulators in one instrumentation build:

| Measurement | What it distinguishes |
|---|---|
| Demand lookups accepted; unique demand misses launched; fills completed/faulted | True MPKI, without counting held requests or retries repeatedly |
| FIFO-full clocks; fetch-without-ACK clocks; their intersection | Backend pressure versus fetch response delay |
| Queue empty versus head present-but-pending; each intersected with backend-ready | Fetch loss that actually prevents useful issue |
| Miss launch → first requested word → fill completion → first consumer issue | Bus latency versus the completion gate and recovery |
| I-bus arbitration wait, service clocks and beats, split SDRAM/flash; I-TLB walk and maintenance counts | Where miss time goes |
| Load dependency, false destination hazard, return redirect and serial-fence cycles | Whether V2 improvements target the dominant remaining losses |

Count user/privileged retirement and idle separately, retaining today’s exclusion of replays. Normalize both per instruction and per completed frame. The existing event-counter route is suitable, but counters are not free: the progress log attributes 523 ALMs to the existing 25 accumulators. [NGage.sv:1133–1160](/Users/jacob/dev/fpga/mister/NGage_MiSTer/NGage.sv:1133), [PROGRESS-LOG.md:3843–3847](/Users/jacob/dev/fpga/mister/NGage_MiSTer/docs/PROGRESS-LOG.md:3843)

My structural fetch ranking is:

| Priority | Change | Expected board gain | Cost; risk | Decisive measurement |
|---|---|---|---|---|
| **1** | **True early execution from a validated fill, plus I-side critical-word-first** | **+0.3–1.5 M/s on ZAP**; potentially **+0.5–2 M/s on faster V2** | **1–2 sessions, 2 builds**; medium risk around faults/redirects | Reduction in backend-ready, pending-head clocks, accompanied by higher same-scene throughput |
| **2** | Remove measured fill-installation/relookup bubbles; consider I-hit-under-fill | **0–1 M/s**, strongly workload dependent | **1–2 sessions, 1–2 builds**; ownership and maintenance risk | Cycles between an available word/hit and its consumer, separated from bus service |
| **3** | 32-byte I-lines | Budget **0–1 M/s**, with regression possible | **2–3 sessions, 2–3 builds**; burst geometry and extra traffic | Same trace/run: exposed I-miss cycles fall despite increased bytes fetched |
| **4** | Two-line fetch buffer | Budget **0–0.5 M/s** until refill/redirect evidence says otherwise | **1–2 sessions, 1–2 builds**; extra muxing/placement | Queue starvation removed while miss count stays unchanged |
| **5** | Larger I-cache or BTB | I-cache: existing evidence approximately **+0.3 M/s**; larger BTB likely small | **½–1 session, 1–2 builds** per variant; poor area/timing return | Matched MPKI/mispredict reduction converted into saved exposed cycles |

The first item is materially different from what is already implemented. Our “early restart” permits words into the FIFO but **forbids them leaving until the entire fill succeeds**. V2 preserves that gate. Pocket executes from each arrived word. [I-cache report:3–14](/Users/jacob/dev/fpga/mister/NGage_MiSTer/docs/consults/2026-10-23-codex-icache-report.md:3), [arm9v2_fetch.sv:104](/Users/jacob/dev/fpga/mister/NGage_MiSTer-cx-arm9/rtl/cpu/arm9v2/arm9v2_fetch.sv:104), [Pocket I-cache:5–15](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/rtl/ngvm_icache.sv:5)

**Critical-word-first alone cannot remove that gate.** The credible shortcut is to retain precise translation/permission faults and generic faulting-bus behavior, while allowing early execution for a registered, validated physical-memory class whose remaining beats cannot report errors. The board bridge generates bus errors for unmapped targets; its SDRAM return path has no per-beat error source. Make that guarantee explicit and verify it rather than globally deleting fault handling. [upp_bus.sv:475–482](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/upp/upp_bus.sv:475), [upp_bus.sv:575–590](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/upp/upp_bus.sv:575)

This is an attractive place to use the permitted accuracy latitude. Waiting for every possible late external I-fill error is a chosen contract; it is not synonymous with running EKA1 correctly.

I rank longer lines lower because the board bridge physically fetches **16-byte blocks** and starts another operation when a burst crosses that boundary. A 32-byte cache line does not automatically become one efficient SDRAM transaction. The wrapper also currently shares one line-size parameter between I and D. [upp_bus.sv:21–30](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/upp/upp_bus.sv:21), [arm925t.sv:110–115](/Users/jacob/dev/fpga/mister/NGage_MiSTer/rtl/cpu/arm925t.sv:110)

The **+1% versus −5.8% cache-size result is unsurprising**. Pocket’s model assumes a 1.6-CPI execution engine, 33-clock lines and a different gameplay stream; its −5.8% is a model result for Virtua Cop, not our hardware workload. Our slower backend can cover misses, and our fills are cheaper. The observed reduction in bus traffic proves that the larger cache removed traffic, not that those misses were critical. [Pocket cache model:483–502](/private/tmp/claude-501/-Users-jacob-dev-fpga-mister-NGage-MiSTer/a3d3155e-0d5b-4fb6-bc9d-97caf4499fda/scratchpad/pocket-src/n-gage/docs/core-design.md:483), [our board A/B:3605–3621](/Users/jacob/dev/fpga/mister/NGage_MiSTer/docs/PROGRESS-LOG.md:3605)

The settling measurement is **16 versus 32 KB, same scene, measuring both MPKI and backend-ready fetch-starvation cycles**. Lower MPKI with unchanged exposed starvation means capacity is not the bottleneck. Revisit it once V2 consumes instructions faster.

For the **write buffer**, I would budget **+0.8–2 M/s on current ZAP**, with perhaps **+1–3 M/s on faster V2**, not reuse the older 5–8% estimate unchanged. Deferred writeback has already removed some exposed waiting, and the UPP bridge already posts SDRAM writes. Also, the “uncached” event counts reads and writes and excludes write-through stores; it cannot establish postable-store volume. [write-allocation report:55–60](/Users/jacob/dev/fpga/mister/NGage_MiSTer/docs/consults/2026-10-23-codex-walloc-report.md:55)

A useful implementation needs translated physical addresses, byte masks, bufferability, CP15 W/drain, ordering against loads/aliases and DMA handoff. A merger FIFO alone does not remove store-miss allocations or know those semantics. Cost: **2–3 sessions, 2–3 whole-core builds; medium-to-high correctness risk**. The deciding measurement is the same-scene decrease in **unhidden store-related waits**, not queue occupancy or bytes saved alone. [write-buffer requirements:183–195](/Users/jacob/dev/fpga/mister/NGage_MiSTer/docs/consults/2026-10-23-codex-walloc-report.md:183)

**For the next week, I would assign the two threads this sequence.** Gains are marginal estimates and must not be added mechanically.

| Order / owner | Concrete deliverable | Expected board gain | Sessions / whole-core builds | Risk and acceptance measurement |
|---|---|---:|---|---|
| **1 — Memory** | Split the misleading stall tap; add I-fill and exposed-starvation measurements, plus uncached read/write classification | **0 directly** | **½–1 / 1** | Low functional risk. Reconcile unique fills, beats and latency totals over the existing three-game replay |
| **1 — V2** | Complete the structural cuts; register forwarding matches if eligibility alone leaves S critical | **0 CPI directly**; enables useful frequency | **1–2 / 0**, plus 3–5 CPU fits | Hold/owner mismatch. Require unchanged cycle counts and a multi-seed improvement in the named path families |
| **2 — V2** | True-writer masks, three-clock load pickup, miss/hold replay, W RAS checkpoint | **+2–5 M/s at 104 MHz** | **1–2 / 1** | High ownership risk. Window traces must show the promised slots for hits and correct replay for misses; then board CPI |
| **2 — Memory** | If pending-head exposure warrants it, validated-memory early execution and I-side CWF | **+0.3–1.5 M/s now** | **1–2 / 2** | Fault/redirect risk. Exposed pending-head clocks must fall by enough to explain the gain |
| **3 — V2** | Real EKA1 boot/game integration and a matched gameplay profile | **0 directly** | **1–2 / 1–2** | Significant untested integration risk. Reach the same gameplay/save/device milestones, then obtain V2’s actual CPI breakdown |
| **3 — Memory** | Posted/combining store path only if classified exposure supports it; otherwise fix the measured cache recovery bottleneck | **+0.8–2 M/s on ZAP**, possibly more on V2 | **2–3 / 2–3** | Ordering/alias/drain risk. Same-scene throughput must improve with correct read-after-write and maintenance behavior |
| **4 — V2** | Attack the largest remaining measured loss: unshifted W→A load pickup, small-LDM tails, flags-only MSR fences or return barriers | **+2–6 M/s**, conditional | **2–3 / 1–2** | Timing or exception regression. Saved event frequency × saved slots must account for the board improvement |
| **5 — Joint** | Freeze combined RTL; whole-core timing comparison; clock-island fallback only if justified | No new CPI gain | **1–2 / 3–4**; crossing work additional | Placement and CDC. Timing-clean matched runs, peripheral rates unchanged, approximately 48–50 M/s capacity or measured Asphalt cap |

Budget roughly **10–14 sessions across both threads and 10–14 whole-core builds**, plus CPU trials; stop low-yield branches early. Four build slots permit concurrent independent candidates, not four seeds of an unfinished schedule.

I would make two explicit decisions during that week:

- **After the load fix:** if V2 remains close to ZAP on representative gameplay, stop calling the remaining gap “timing work.” The cycle architecture still needs improvement.
- **Before building a clock island:** use measured CPI and the frequency table. If V2 needs 104 MHz to reach 47 M/s, moving it to 88 MHz is a reliability fallback, not completion of the speed goal.

The missing evidence with the highest value is **one real EKA1 gameplay profile of corrected V2**. Pocket demonstrates that a small FPGA ARM pipeline can deliver the required throughput. It does not demonstrate that V2’s planned three-bubble loads, current retirement contract and shared-cache recovery will do so.


