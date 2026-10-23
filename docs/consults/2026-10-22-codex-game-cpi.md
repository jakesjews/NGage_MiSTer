# Codex (gpt-6-astra) on the game CPI, 2026-10-22

Brief: the measurements and the pipeline facts only (no plan of mine; mine is 2026-10-22-game-cpi-mine.md). Run read-only on checkout 344875f.

**The strongest suspects are the long load-use interlock, branch redirection costs, and cache-retry flushes.** I would investigate those before changing the SDRAM controller. Early restart is worthwhile, but neither it nor an LCD write buffer plausibly explains the whole gap.

I reviewed checkout `344875f`. No files were changed, and no simulations or builds were run. All gain estimates below are hypotheses for the measured game workload, not measured improvements.

Several details in the current source materially change the interpretation:

- **A correctly predicted taken branch still costs fetch slots.** The BTB redirects through `zap_pc_shelve`, which invalidates `pc_del`, `pc_del2`, and `pc_del3`. Prediction avoids the ALU recovery penalty; it does not provide uninterrupted fetching. See [zap_writeback.sv:315](rtl/cpu/zap/zap_writeback.sv:315) and [zap_defines.svh:198](rtl/cpu/zap/zap_defines.svh:198).
- **D-cache misses are partly nonblocking, but subsequent memory accesses cause replays.** The first miss acknowledges and locks its destination. During the fill, another memory access receives `o_ack=1, o_err2=1`; writeback redirects to execute that instruction again. The apparent hit-under-miss macro is deliberately disabled. See [zap_dcache_fsm.sv:617](rtl/cpu/zap/zap_dcache_fsm.sv:617), [zap_dcache_fsm.sv:800](rtl/cpu/zap/zap_dcache_fsm.sv:800), [zap_defines.svh:230](rtl/cpu/zap/zap_defines.svh:230), and [zap_writeback.sv:249](rtl/cpu/zap/zap_writeback.sv:249).
- **The overlay’s “retired” count needs qualification.** It counts `(tr_wb_valid || tr_wb_dvalid) && tr_wb_uop_last`, without excluding replay. The simulation bench explicitly excludes `p_dabt & 2`. Replayed instructions can therefore inflate the overlay denominator and make its CPI optimistic. See [NGage.sv:1001](NGage.sv:1001), [zap_core.sv:1679](rtl/cpu/zap/zap_core.sv:1679), and [main.cpp:302](sim/cpu/tb/main.cpp:302).

**The 3.5 clocks are a useful remainder, not a causal pipeline measurement.** The external counter measures request-pending clocks, excludes acknowledgment clocks, and can count activity overlapped with useful execution. Conversely, cache completion, arbitration gaps, and refetching after a memory replay can occur outside that counter. Its exact definition is at [NGage.sv:993](NGage.sv:993).

A plausible allocation of that reported remainder follows. The middle column deliberately adds to 3.5; it is an illustrative budget to test, not an identification of the actual contributions.

| Mechanism | Illustrative clocks/instruction | Plausible range | What sets the cost |
|---|---:|---:|---|
| Useful instruction slot | 1.00 | 1.00 | Single issue; pipeline depth does not itself make every instruction multicycle. |
| Load dependencies, including load destinations overwritten by younger instructions | 1.15 | 0.7–1.5 | Seven interlock positions, including the issue output itself. |
| Correctly predicted taken redirects | 0.35 | 0.2–0.5 | Three invalid fetch-address slots per redirect, before overlap. |
| Wrong predictions and ARM/Thumb state changes | 0.35 | 0.2–0.7 | Approximately 12 clocks per ALU recovery. |
| Extra micro-ops | 0.30 | 0.15–0.6 | Register transfers, setup/finalization, calls and load-to-PC sequences. |
| Shift dependencies and multiply busy cycles | 0.15 | 0.05–0.3 | Conservative issue locks; multicycle multiplier. |
| Uncached-access protocol overhead outside external pending time | 0.10 | 0.05–0.2 | Prepare, launch, registered completion and re-entry. |
| Cache retry/completion overhead and privileged activity | 0.10 | 0–0.5+ | Work discarded by replay; refill completion; CP15 drains. |

These ranges overlap. Their maxima must not be added.

The load estimate is credible for compiled code: a 20–25% load frequency, with many consumers one to three instructions later, readily produces around one lost clock per retired instruction. `determine_load_lock` checks **issue, shifter, ALU, postalu0, postalu1, postalu2 and memory**. An immediately dependent instruction can encounter seven blocked issue opportunities before reading the register file. The memory-stage clause is still active when the load value is already registered. See [zap_issue_main.sv:1048](rtl/cpu/zap/zap_issue_main.sv:1048).

This also affects returns: a load-to-PC becomes a load into a temporary followed by a PC-writing micro-op, which must wait for that temporary. Predicting the return target does not eliminate this dependency. See [zap_predecode_uop_sequencer.sv:766](rtl/cpu/zap/zap_predecode_uop_sequencer.sv:766).

For micro-ops, LDM/STM is more than just the register count here: there is a base-copy/setup instruction, the transfers, and a final base operation, with additional handling for PC or base-in-list. ARM BL also takes two micro-ops. See [zap_predecode_uop_sequencer.sv:640](rtl/cpu/zap/zap_predecode_uop_sequencer.sv:640), [zap_predecode_uop_sequencer.sv:908](rtl/cpu/zap/zap_predecode_uop_sequencer.sv:908), and [zap_predecode_uop_sequencer.sv:726](rtl/cpu/zap/zap_predecode_uop_sequencer.sv:726).

Ordinary Thumb decoding is **not inherently one extra clock per instruction**. It is a pipelined conversion that accepts an instruction each unstalled clock. Thumb contributes through its instruction mix, branches, interworking and sequencing—not simply because the decoder exists. See [zap_mode16_decoder_main.sv:154](rtl/cpu/zap/zap_mode16_decoder_main.sv:154).

For the incoming counters, I expect **issue stalls to be the largest actionable category**. Raw `code_stall` may be larger without indicating a fetch problem.

| Counter | Interpretation |
|---|---|
| `data_stall` | CPU-side request waiting for acknowledgment, not external D-bus occupancy. Likely exposes uncached accesses. It can remain low during a background fill because that fill acknowledges early and later accesses replay. Definition: [zap_core.sv:592](rtl/cpu/zap/zap_core.sv:592). |
| `code_stall` | Includes **FIFO full** as well as fetch waiting. High value with a populated FIFO points toward downstream backpressure. [zap_core.sv:625](rtl/cpu/zap/zap_core.sv:625). |
| FIFO output invalid | Useful evidence of starvation only when the consumer could advance. It also rises after redirects; it is a registered output-valid indication, not an occupancy histogram. [zap_fifo.sv:68](rtl/cpu/zap/zap_fifo.sv:68). |
| Issue stall | Combines load and shift locks. Large value supports the dependency hypothesis, but needs those two causes separated. [zap_issue_main.sv:327](rtl/cpu/zap/zap_issue_main.sv:327). |
| Shifter stall | **Multiplier busy**, not the ordinary barrel-shift dependency lock. Those ordinary locks appear under issue. [zap_shifter_main.sv:195](rtl/cpu/zap/zap_shifter_main.sv:195). |
| Decode stall | Micro-op sequencing and CP15 waiting; a useful micro-op can still be advancing. [zap_predecode_main.sv:298](rtl/cpu/zap/zap_predecode_main.sv:298). |
| ALU clear | Wrong target/direction, state changes and CPSR resynchronization. Not exclusively mispredictions. [zap_alu_main.sv:1038](rtl/cpu/zap/zap_alu_main.sv:1038). |
| Writeback clear | Includes D-cache/TLB replay and exceptions. High counts in user code should immediately trigger replay classification. [zap_writeback.sv:366](rtl/cpu/zap/zap_writeback.sv:366). |
| Micro-ops/instructions | After correcting retirement qualification, `U/I − 1` estimates extra execution slots. A ratio around 1.3 supports the illustrative budget; 1.8 changes the priority substantially. |

The counters are overlapping level counts. Some signals remain asserted while another stall holds their registers, so **do not sum them or blindly multiply ALU-clear count by 12**. Count accepted redirects separately. CP15’s post-operation refetch also comes through `clear_from_decode`, which is not one of the two new flush counters: [zap_predecode_main.sv:624](rtl/cpu/zap/zap_predecode_main.sv:624).

My implementation order, after fixing measurement qualification, would be:

1. **Remove demonstrably unnecessary shift locks — approximately 0.02–0.12 CPI.**

   `w_shift_lock` includes the ordinary ALU operand and store-data operand, although both already have ALU-result restoration in the shifter. For **nonmultiply instructions**, restrict the dependency test to operands actually needed before shifting; retain genuine shifted-source and shift-amount dependencies. See [zap_issue_main.sv:755](rtl/cpu/zap/zap_issue_main.sv:755), [zap_shifter_main.sv:386](rtl/cpu/zap/zap_shifter_main.sv:386), and [zap_shifter_main.sv:453](rtl/cpu/zap/zap_shifter_main.sv:453).

   **Cost/risk:** Small control change, potentially less logic; favorable timing risk. The separate blanket flag-update lock deserves a later refinement, but preserve RRX and carry-preservation cases.

   **Verify:** Producer followed by shifted arithmetic/store, varying which operand depends; conditional producers; flag-setting shifts; register shift amounts 0, 31, 32 and larger. Assert a one-cycle improvement only for the intended cases.

2. **Repair predictor maintenance and return recognition before enlarging it — approximately 0–0.25 CPI.**

   Two concrete suspects:
   - The pattern commented “MOV PC, LR” ends with **`4'd15`**, matching PC rather than LR. Correct the recognized source register.
   - The BTB writes `dav[index] <= mem_wr_en` even on cycles without feedback, clearing an entry instead of leaving it alone. Qualify ordinary updates with feedback while retaining explicit invalidation.

   See [zap_predecode_main.sv:504](rtl/cpu/zap/zap_predecode_main.sv:504) and [zap_btb.sv:148](rtl/cpu/zap/zap_btb.sv:148).

   **Cost/risk:** Tiny storage/control cost. These are performance defects or suspects, not proof of a large game benefit. Existing target validation must remain.

   **Verify:** Repeated calls from different sites, conditional calls/returns, predictor-index aliases, idle/stalled cycles, self-modifying code plus invalidation, and `bpred`. Measure prediction availability and accepted recoveries.

3. **Hold a subsequent D-access during a fill instead of flushing it for replay — approximately 0.05–0.4 CPI.**

   In `CLEAN_SINGLE`, `FETCH_SINGLE`, `UNLOCK_REG` and `UNLOCK_WR`, replace the ordinary busy-cache access’s `ack + err2` response with a held request. Let the existing fill and background register write finish independently, then process the held access in `IDLE`. Initially leave TLB-miss replay unchanged. Current behavior is explicit at [zap_dcache_fsm.sv:758](rtl/cpu/zap/zap_dcache_fsm.sv:758) and [zap_dcache_fsm.sv:904](rtl/cpu/zap/zap_dcache_fsm.sv:904).

   **Cost/risk:** Modest control work, no need for a new load-data bypass. The state-to-global-stall path is timing-sensitive. Deadlock is the main functional risk: the pending fill, register unlock and bus arbitration must progress despite the CPU stall.

   **Verify:** Load miss followed by independent load/store, dirty eviction, same-line access, interrupts and faults. Compare actual committed instructions and device transactions. Estimate gain as replay frequency × avoided *exposed* restart clocks, not the entire nominal flush latency.

4. **Forward the registered memory-stage load result into issue — approximately 0.10–0.25 CPI.**

   Add the load result and destination to `get_register_value`; relax the memory-stage load lock only when that value is genuinely available. The existing forwarding function forwards the memory-stage **ALU result**, not its loaded data. The latter already exists as `memory_mem_rd_data`. See [zap_issue_main.sv:1192](rtl/cpu/zap/zap_issue_main.sv:1192), [zap_memory_main.sv:238](rtl/cpu/zap/zap_memory_main.sv:238), and [zap_core.sv:1638](rtl/cpu/zap/zap_core.sv:1638).

   **Cost/risk:** One additional forwarding candidate and validity handling across four operand paths. This directly touches a critical timing family. **An acknowledgment alone is insufficient validity:** a cache miss acknowledges before its result exists. Preserve background-load locks and youngest-writer priority.

   **Verify:** All load formats, consumer distances, both ways, hits/misses, conditional loads, base writeback, load-to-PC, and WAW cases. Expect exactly one saved cycle for qualifying dependencies, not ARM9-like load latency.

5. **Early load completion, followed separately by critical-word-first — approximately 0.15–0.5 CPI combined.**

   First, keep the existing linear burst but capture the requested word when its beat arrives, apply `ld_transform` through a register, and use the background write port before full-line installation. Preserve ownership of the filling way separately from the destination-register lock, and suppress the later duplicate register write. Current completion waits through `UNLOCK_REG` and `UNLOCK_WR`: [zap_dcache_fsm.sv:298](rtl/cpu/zap/zap_dcache_fsm.sv:298), [zap_dcache_fsm.sv:862](rtl/cpu/zap/zap_dcache_fsm.sv:862).

   With linear fills and uniformly distributed requested words, SDRAM’s remaining tail averages **three clocks**, not six. True critical-word-first can make that six, before completion overhead and overlap.

   **Critical-word-first is an end-to-end protocol change.** ZAP currently clears the line offset and starts at word zero; it advertises linear bursts, and the wrapper discards BTE. `upp_bus` already understands wrap-four, but the CPU interface must carry it. See [zap_dcache_fsm.sv:209](rtl/cpu/zap/zap_dcache_fsm.sv:209), [zap_top.sv:180](rtl/cpu/zap/zap_top.sv:180), [arm925t.sv:143](rtl/cpu/arm925t.sv:143), and [upp_bus.sv:157](rtl/upp/upp_bus.sv:157).

   Then give the I-cache a fill-buffer response path for available words. Its present fill continually requests retry until installation: [zap_cache_fsm.sv:562](rtl/cpu/zap/zap_cache_fsm.sv:562).

   **Cost/risk:** Moderate control and metadata; greater risk on I-side redirect/abort handling. Avoid extending the live two-way hit-data path. Early data release must preserve the existing abort contract, including errors on later beats; use a proven nonfaulting fast path where necessary.

   **Verify:** Every starting word, byte/halfword/unaligned loads, dirty victims, redirects during refill, invalidation, late errors and immediate same-line stores. Update the burst checker’s current linear-address assumption at [main.cpp:336](sim/cpu/tb/main.cpp:336).

6. **A small ordered write buffer, only for eligible stores — approximately 0–0.2 CPI at present frame rates; additional WT benefit unmeasured.**

   Capture translated address, data, byte enables and attributes after fault checks; acknowledge queue acceptance and drain through the existing data master. Start with two or four entries. The current WT and uncached paths serialize through prepare, request and registered completion: [zap_dcache_fsm.sv:561](rtl/cpu/zap/zap_dcache_fsm.sv:561), [zap_dcache_fsm.sv:683](rtl/cpu/zap/zap_dcache_fsm.sv:683).

   At 10 fps, LCD writes are about **0.035 stores/instruction**. Saving four clocks each saves about **0.14 CPI**. Even at 30 fps and the same instruction rate, that is about 0.42 CPI—not several CPI.

   **Eligibility is essential.** “Uncached” does not imply “bufferable.” TI’s rules depend on MMU attributes and CP15 W; WT stores can be buffered, NCNB stores cannot. Buffered external-abort behavior also differs. See the repository’s [SPRU671 extract:756](research/arm925t/downloads/OMAP5910_MPU_Subsystem_spru671.txt:756) and [TI’s original guide](https://www.ti.com.cn/cn/lit/ug/spru671/spru671.pdf). **The LCD gain is zero if its mapping requires unbuffered completion.**

   **Cost/risk:** A few hundred payload bits plus control, potentially hundreds of ALMs after integration. Substantial architectural verification: ordering, faults, SWP, DMA visibility and maintenance. Do not merge LCD byte transactions. Conservatively drain before subsequent reads and ordered device operations; implement CP15 drain, currently a no-op at [zap_cp15_cb.sv:696](rtl/cpu/zap/zap_cp15_cb.sv:696).

   SDRAM writes are already posted below the CPU, so do not claim the full physical SDRAM write latency as additional savings: [upp_bus.sv:451](rtl/upp/upp_bus.sv:451).

7. **Move prediction earlier before moving branch execution earlier — approximately 0.08–0.25 CPI versus 0.02–0.05 CPI for one clock off mispredict recovery.**

   The BTB starts from `pc_del_ff`, then registers its decision. Moving lookup and its aligned metadata earlier could recover one or two slots on common taken branches. See [zap_writeback.sv:524](rtl/cpu/zap/zap_writeback.sv:524) and [zap_btb.sv:195](rtl/cpu/zap/zap_btb.sv:195).

   **Cost/risk:** Moderate frontend restructuring. Keep registered boundaries; verify prediction/address alignment, stalls, redirects and outstanding wrong-path fetches.

   Resolving selected branches in the shifter saves only one clock per qualifying recovery and requires correct, current NZCV. At a 3% recovery rate that is **0.03 CPI**. It is a weaker first investment than avoiding bubbles on correctly predicted branches.

8. **Reduce avoidable micro-ops, then consider deeper load-use changes — approximately 0.05–0.2 CPI and 0.2–0.5 CPI respectively.**

   Micro-op candidates are BL link creation and common LDM/STM setup/finalization. Preserve per-register transfer order and base-restored abort behavior. Do not attempt multiple register transfers per clock with the current datapath.

   Thumb BL prefix construction also uses two micro-ops; optimize its immediate construction only if measured frequent. Preserve the architectural boundary between its two halfwords: [zap_predecode_uop_sequencer.sv:439](rtl/cpu/zap/zap_predecode_uop_sequencer.sv:439).

   A deeper load improvement would carry unresolved operand tags into later stages and supply registered load data nearer consumption. That can recover additional dependency clocks, but requires a real late interlock/skid design. Merely deleting issue locks is incorrect.

   **Cost/risk:** High design and verification cost; new bypasses and control fanout threaten timing. Test every abort position in LDM/STM, temporary-register dependencies, interrupts between Thumb BL halves, and pipeline stalls with unresolved operands. Multiplier work belongs here only if its busy counter warrants it; the existing FSM already identifies its fixed busy sequence at [zap_shifter_multiply.sv:284](rtl/cpu/zap/zap_shifter_multiply.sv:284).

9. **Open-page SDRAM — approximately 0.05–0.25 CPI, conditional on row locality.**

   Retain the last row per bank and skip ACTIVATE/precharge for row hits. Preserve the timing constraints and refresh deadlines; do not shorten device timing parameters. The current controller explicitly precharges every transaction: [sdram.sv:339](rtl/mem/sdram.sv:339).

   **Cost/risk:** Modest row-state storage, substantial scheduler verification. A row hit can avoid command overhead, but the 16-bit burst still consumes eight data transfers. With only 1.1 reported SDRAM-pending clocks/instruction, a 20% reduction of wholly exposed SDRAM time would save about **0.22 CPI**.

   **Verify:** Row hits/conflicts, read/write turnaround, masked writes and refresh against the SDRAM model, followed by hardware memory tests. Measure row-hit frequency first.

10. **Bank interleaving — approximately 0–0.15 CPI with the present request stream; last priority.**

    Bank bits currently come from high address bits, so adjacent cache lines remain in the same bank. The controller accepts one operation at a time, and the CPU merger preserves complete bursts. Effective overlap needs queued requests or lookahead, bank timing state and possibly a consistent address remapping. See [sdram.sv:242](rtl/mem/sdram.sv:242), [sdram.sv:355](rtl/mem/sdram.sv:355), and [zap_wb_merger.sv:81](rtl/cpu/zap/zap_wb_merger.sv:81).

    **Cost/risk:** Disproportionate scheduler and ordering complexity for current evidence. Verify all CPU/DMA mappings, bank conflicts, refresh and response ordering. It cannot hide the latency of a dependent request whose address is not yet known.

For every retained change, I would use the same acceptance sequence: focused cycle-count tests, the full **177-run/49-QEMU** regression on source and regenerated Verilog, the ordered **76,975-access** boot comparison, CPU-only timing screening, then matched whole-core seed sweeps at **104 MHz**. The generated-file workflow is documented at [CPU.md:19](docs/CPU.md:19); the boot comparison at [CPU.md:551](docs/CPU.md:551). A CPU-only pass is not evidence of whole-core closure. Compare both slow corners, hold, area and path families across seeds—not just the best seed.

On hardware, compare identical play segments using corrected instructions, micro-ops, cycles and device transactions per completed frame. Gains are not additive: reducing one stall exposes another, and game tick limits eventually cap frame rate.

I would leave the following alone initially:

- **The three post-ALU timing boundaries.** Removing them combines precisely the lookup/data paths already struggling to close.
- **The register-file storage architecture.** Four asynchronous reads and three writes do not map trivially into block RAM; a replacement introduces latency, arbitration or replication. Current semantics include background-write priority: [zap_register_file.sv:56](rtl/cpu/zap/zap_register_file.sv:56).
- **RAS authority.** Keep validating predictions. Conditional calls, stack manipulation and exceptions prevent treating its contents as architectural truth.
- **Blanket removal of CP15 drains, permission checks or WAW locks.** These guard documented correctness problems.
- **Larger caches/TLBs/predictors without conflict evidence.** In particular, the current TLB defaults are already enlarged to 256 small-page entries per side: [zap_top.sv:70](rtl/cpu/zap/zap_top.sv:70).
- **Any changes under `sys/`.**

**If the counter build failed, my first diagnostic change would be selectable ideal external RAM/ROM latency in the RTL bench.** Keep this CPU, caches, MMU, arbitration and device behavior intact; run the same representative compiled workload twice, with calibrated external memory latency and with zero added RAM/ROM wait. The bench already has the latency mechanism at [main.cpp:328](sim/cpu/tb/main.cpp:328).

A large reduction establishes external-memory sensitivity, including replay effects it triggers. A residual CPI near 3–4 directs work toward dependencies, redirects and internal cache protocol. It does **not** prove the ALU pipeline alone is responsible. Use the cycle trace from that same experiment to distinguish them. The existing zero-wait **boot** result cannot answer this for **game** code.


