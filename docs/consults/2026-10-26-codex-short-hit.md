# Codex consult, 2026-10-26: the W short-hit cluster at 104 MHz

Read-only consult (codex exec -s read-only, session 01a17697-d140-7020-adc1-ef7d599b8aa5) on master 1ff0fa8. The brief carried the k2/k3 fit measurements, the family table and the cell paths; it is reproduced after the answer.

## Answer

**The structural problem is identifiable; the cause of k3’s additional regression is not yet isolated.** The existing short-hit logic controls both pipeline movement and the forwarding metadata describing that movement. k3’s changes can alter synthesis and placement without introducing a new functional dependency.

I inspected `1ff0fa8`; this consult checkout is detached at that commit and clean. No files were modified.

**1. What explains the regression**

The TLB-IDLE substitution is logically justified:

- `o_hit_ok` and `o_walk` capture the same check: `o_hit_ok=1` implies `o_walk=0`. See [zap_tlb_check.sv:105](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_tlb_check.sv:105).
- Walker busy is `walk || !state_ff[IDLE]`; its walk request requires the check’s walk bit. See [zap_tlb_fsm.sv:181](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_tlb_fsm.sv:181).
- The additional stale-check busy term also requires `walk`. See [zap_tlb.sv:445](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_tlb.sv:445).

Consequently, **under `i_hit_ok`, `!i_busy == i_tlb_idle`**. The new fast-ack expression uses that guard and asserts the equality at [zap_dcache_fsm.sv:608](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache_fsm.sv:608). This removes logic from the RTL expression; it does not add a stage or a new short-hit dependency.

Furthermore, fast ACK uses the ordinary `i_hit_ok`; the short-hit path uses the separately preserved `o_hit_ok_short`. Their downstream logic can interact during optimization, but they are distinct RTL roots.

The troublesome dependencies already exist:

| Route | Structural dependency |
|---|---|
| Short hit → S/A readiness → D2 | `s_load_hit/a_load_hit` → per-source waits → `o_valid/finish/space/o_ready_payload` → decode `step_raw/d2_load`. See [execute:169](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_execute.sv:169), [execute:456](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_execute.sv:456), [decode:584](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:584). |
| Trusted short hit → D2 hazard | W’s WAW exemption directly uses `i_w_load_hit`; that feeds `o_hazard` and `step`. See [decode:600](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:600). |
| A readiness → D2 hazard | `a_a_can_finish` qualifies `early_valid`, which decode reduces into `early_hazard`. This is another short-hit route into D2. See [core:522](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:522). |
| Short hit → completion → forwarding metadata | `fast_pc_hit` → `defer_load` → `complete_class/done_forward` → producer masks/movement → `late_accept`, matches and grants. See [core:805](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:805), [core:558](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:558). |
| Fast ACK → completion → forwarding metadata | `request_done` remains combinational for fast acknowledgements. `REG_DONE` only registers the other acknowledgements. See [core:779](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:779). |

Two details in the supplied paths matter:

- **`d2[81]` is `d2.dest[0][1]`**, a destination-tag bit updated during block expansion as well as record replacement. **`d2[130]` is `d2.kind[2]`**, which has a simpler load/hold schedule. The packed definition and block updates are at [decode:130](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:130) and [decode:715](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:715). Thus k3’s D-input path versus k2’s enable-input path does **not** establish that synthesis changed the implementation of the same endpoint.
- **`a[1]` is `a.take[0][1]`**, the W lane-1 forwarding select. Its path through `late_accept` and priority selection is exactly what the source describes. See [execute:384](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_execute.sv:384) and [generated assignment:3833](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm925t_gen.v:3833).

The supplied k3 D2 path has **10.529 ns from launch Q to destination D**, comprising 7.815 ns of listed interconnect and 2.714 ns of combinational cells: approximately **74% routing**. The 2.271 ns launch-clock increment is separate. This supports reducing logic depth **and** geographic fanout; it does not support attributing everything to the first source net.

My diagnosis is therefore **a reproducible synthesis/mapping/placement regression acting on an already fragile control structure**. All four seeds worsening argues against one unlucky seed. It does not distinguish the TLB rewrite, predictor-clear duplication, cleanup-induced netlist changes, or interactions among them.

Your three reversion fits are the right discriminator. If reverting both still loses, compare the cleanup/generated-Verilog baseline separately. Functional equivalence does not imply identical mapped logic or placement. The parent commit also contains round-1 rather than an isolated k2 snapshot, so its diff cannot independently isolate k3.

**2. Ranked options**

The ranking below favors useful zero-cycle changes with bounded scope. Timing effects are hypotheses to fit, not promised nanosecond gains.

1. **Factor readiness so the late hit joins after age selection and reductions.**

   Change [execute:187](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_execute.sv:187) and the readiness equations at line 456.

   Each source’s existing priority loop can be expressed exactly as:

   ```text
   wait = fixed_wait || (needs_W_hit && !qualified_hit)
   ```

   `fixed_wait` covers an overriding M load or an unmatched pending operand. `needs_W_hit` identifies a W load that survives the newer-producer priority. Neither needs the current hit.

   Reduce those classes **before** applying the hit:

   ```text
   any_wait = any_fixed_wait || (any_needs_W_hit && !qualified_hit)
   ```

   Use `i_early` when reducing S’s admission blockers. Preserve S/A’s different self-dependency qualification: ordinary readers may use the plain hit; self-dependent writers require trust.

   Then carry the hit/no-hit alternatives far enough downstream that the hit selects a finished readiness or D2-update decision. Merely factoring individual `s_wait` bits still leaves `space → ready → step → d2_load` in series. Include the WAW hazard and `early_valid` routes identified above.

   For D2’s mutable fields, explicitly separate replacement, block-step and hold candidates at [decode:715](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:715). Resolve update priority before the final late selection.

   **Expected effect:** directly shortens short-hit → D2, A acceptance, preparation controls, and issued/values enables.

   **Cycles:** zero.

   **Area:** no additional registers for the combinational form; some duplicated small control logic. Registering the two wait classes beside existing S/A metadata would add roughly 16 classification bits before duplication, but requires proving every hold/advance update.

   **Risks:** synthesis can refactor the late select upstream again. Registering classifications can simply move the critical path into their D inputs. Preserve newest-producer priority and the trust distinction exactly.

2. **Flatten completion, then select complete forwarding alternatives—including priority results.**

   First simplify the normal memory-completion term at [core:570](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:570). Algebraically:

   ```text
   request_done && !retry && !defer_load
   =
   request_done && !retry &&
     (resp_err || w.store ||
       (w.kind != SWP && (w.dest[0] != 15 || fast_pc_hit)))
   ```

   This removes the nested `request_done → defer_load → completion` dependency. Keep the outer exception/CP/state selection and aborting-block restoration override intact. Static W classes—ordinary completion, PC load, SWP, block restoration—can be registered with W if their next-state equations include every reload and SWP transition.

   The larger cut is downstream:

   - Form producer candidates for stay, RUN advance, skid reload and W removal before late completion chooses among them.
   - Compute each candidate’s **qualified matches and finished grants**.
   - Apply completion and incoming-versus-held-owner selection at the end.

   Relevant sites are [core:578](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:578), [decode:501](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:501), [execute:543](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_execute.sv:543), and the `a.take` assignments at lines 609/662.

   **The existing parallel tag comparisons are only part of this cut.** `forward_write` still arrives late, and `take_of(late_accept)` performs priority resolution afterward. Likewise, decode’s existing hit/no-hit grants do not remove the late producer-movement and owner-selection logic preceding grant construction.

   Include `input_record.writes/load_writer` eligibility in the alternatives: it depends on A’s hit-sensitive validity at [core:625](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:625).

   **Expected effect:** specifically attacks the supplied `hitok_a` path and fast-ack paths into forward-match/grant and A late-select registers. Combined with option 1, it addresses both major branches of the cluster.

   **Cycles:** zero.

   **Area:** modest-to-moderate LUT growth for alternative masks/grants; a few classification registers if used. Existing candidate comparisons can be reused.

   **Risks:** incomplete alternatives mishandle W removal, HOLD quick reload, flushes, failed-condition writers or producer aliasing. Leaving any late mask ahead of grant priority preserves the bottleneck.

3. **Remove readiness from S’s wide hold payload enables.**

   At [execute:583](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_execute.sv:583), `held<=operand` currently requires `i_valid&&!accept`.

   Let the 128-bit payload capture whenever `i_valid`; keep `holding`, pending-state ownership and acceptance unchanged. An extra capture on an accepted instruction is unobserved because acceptance clears `holding`.

   Also separate the preparation payload at line 592 from `space` and wait reductions: capture amount/rotate/offset candidates while the relevant S instruction is **not prepared**. Keep the original condition for setting `prepared`, and freeze the payload once prepared.

   There is an additional exact simplification in the return-repair muxes:

   ```text
   no live producer match ⇒ s_wait is the saved/input pending bit
   no live A match        ⇒ a_wait is a.pending
   ```

   Express that directly in the repairs at lines 588, 600 and 678. Otherwise, the syntactically hit-dependent wait signal can remain on a wide data mux despite being irrelevant under the no-match guard.

   **Expected effect:** removes acceptance/readiness from held-operand and preparation-payload endpoints; removes redundant hit dependencies from S/A return repairs. It does not remove D2 capacity dependencies.

   **Cycles:** zero.

   **Area:** approximately neutral, potentially fewer enable/mux terms; increased switching from extra captures.

   **Risks:** never overwrite a prepared shift amount or offset. Preserve return priority. Compare payloads when their owner consumes them, since unused captures intentionally differ.

4. **Duplicate the actual registered roots by consumer region.**

   Give execute readiness, decode hazards, and completion/forwarding local copies of the relevant registered predicates:

   - Permission: [zap_tlb_check:117](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_tlb_check.sv:117).
   - Cache hit: [zap_dcache:496](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache.sv:496).
   - W candidate: [core:939](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:939).
   - Trust: [zap_dcache_fsm:574](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache_fsm.sv:574).

   Each copy must sample the **same D expression on the same edge**, with identical enables. A consumer flop sampling the existing Q would add latency.

   **Expected effect:** shorter launch and intermediate routes, especially when paired with options 1–2. No logical-depth reduction by itself.

   **Cycles:** zero.

   **Area:** a small number of flops, potentially additional D-driver logic.

   **Risks:** merged copies, copies placed together, increased upstream fanout, or congestion. `tr_cache_hit~DUPLICATE` already demonstrates that automatic duplication alone has not solved the cluster.

   Also, `keep,maxfan` on combinational `complete_class/done_forward` is not proof of independent physical completion trees. Quartus 17 documents `maxfan` as a **register duplication** attribute; `keep` preserves combinational nets. Verify the implemented copies and their sinks. [Quartus 17 synthesis attributes](https://resources.altera.com/quartushelp/17.0/hdl/vlog/vlog_file_dir.htm).

5. **Fuse response predicates at the existing M/W boundary.**

   Replace the post-register AND at [zap_dcache:201](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache.sv:201) with a register computing the conjunction of the constituent registers’ **effective next values**:

   ```text
   permission_next = tlb_hold   ? permission_q : permission_check
   tag_hit_next    = cache_hold ? tag_hit_q    : raw_cache_hit
   short_hit_q'    = permission_next && tag_hit_next
   ```

   The separate next-value muxes matter: the TLB has an additional fill/request hold at [zap_dcache:528](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache.sv:528), whereas `tr_cache_hit` uses `!hold&&!i_stall`.

   A second step could form local plain/trusted W tokens using the effective next values of `w_hit_candidate` and `o_live_trust`.

   Fast ACK needs its own treatment. Its IDLE arm acknowledges **cacheable misses too**, while HUM uses `i_cache_hit_early`. It cannot be replaced with the short-hit token. A zero-cycle ACK register would need the next state, permission, alignment, cache-enable, HUM eligibility and UNC_DONE/error ownership.

   **Expected effect:** replaces distributed response conjunctions with local register roots. Potentially helps every family, particularly if fused tokens are duplicated by consumer.

   **Cycles:** zero only with exact next-state construction.

   **Area:** few output flops; potentially substantial duplicated next-state logic.

   **Risks:** highest upstream-timing risk among these zero-cycle choices. It can move the failure into TLB checking, cache comparison or FSM next-state logic. A simple fused AND may save no LUT level because the existing AND can already pack with downstream logic. I would try options 1–4 first.

6. **Use narrowly targeted cycle concessions before delaying all completion.**

   Two bounded experiments are available:

   | Change | Benefit and cost |
   |---|---|
   | Disable direct fast-PC-hit retirement at [core:805](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:805) | Removes the explicit short-hit → `defer_load` completion branch. Adds one LOAD_RETURN clock for an otherwise eligible first-pass PC hit, assuming its return lock is clear. Small area impact. It leaves S/A readiness and general fast ACK paths. |
   | Remove only the W-hit WAW exemption at [decode:609](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:609) | Removes the direct trusted-hit exemption from D2’s hazard equation. Normally adds one D2 hold for an independent younger writer that otherwise passes on W’s hit clock; other stalls can overlap it. Small area reduction. It leaves the readiness route and requires retaining the separate self-dependent-reader rules. |

   Registering **all** acknowledgements is a larger fallback. Each newly delayed fast completion gains one W clock, and the current RUN→HOLD machinery can add two reload clocks when M or skid contains memory work: [core:673](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:673). Existing late-response storage limits area growth, but ownership/replay verification is substantial. This also leaves the independent short-hit readiness cone intact.

   None of these has a defensible suite percentage without measurement. The existing **+0.24% REG_DONE** result does not predict their cost.

**What I would reject as a sufficient fix**

- Simply registering `o_ready` without spare storage: upstream can overwrite an occupied slot before delayed backpressure arrives.
- Making `issued`, `values`, or A freely load every clock: unlike the S hold snapshot above, these can own live stalled instructions.
- Treating short hit as accepted completion: departing-victim and fill-end behavior explicitly invalidate that assumption. The ordering failures are documented at [core:961](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:961).
- Adding more tag precomparisons alone: those already exist; masks, priority and movement selection remain late.
- Assuming retiming settings will cross the pipeline boundaries: the relevant records and short permission copy are explicitly protected with `dont_retime`.
- False-path or multicycle exceptions: these are functional same-cycle control paths.

For each zero-cycle cut, retain a default-on parameter and the old implementation. Assert control equality every applicable cycle, and payload equality whenever the payload is live or consumed. Cycle-changing options require latency-aware architectural comparison rather than claiming per-cycle equivalence.

I exhaustively checked the local wait factorization over 256 Boolean combinations and the completion identity over 128. Those checks establish the algebra only; no new RTL simulation or fit was run. Acceptance should use the suite’s cycle totals and matched four-seed endpoint/TNS measurements, including the upstream paths onto which a cut moves work.



## Brief

# Consult: the W short-hit cluster in the N-Gage V2 CPU at 104 MHz

Read-only consult. Repository: the worktree you are started in (master,
commit 1ff0fa8). Do not modify files.

## Target and tools
- Device Cyclone V 5CSEBA6 (MiSTer DE10-Nano), Quartus Prime Lite 17.0.2.
  The CPU is SystemVerilog under rtl/cpu (arm9v2 = this project's 8-stage
  ARMv4T pipeline; rtl/cpu/zap = caches, MMU, CP15, writeback derived from
  ZAP), converted by sv2v into rtl/cpu/arm925t_gen.v for Quartus.
- Clock 104 MHz (9.615 ns). Judged at the slow 1100 mV 100C corner. The
  board-proven envelope is about -0.6 ns worst setup slack; the goal is to
  get every endpoint above that, then to zero.
- Synthesis/fitter settings already on (NGage.qsf): OPTIMIZATION_MODE high
  performance effort, physical synthesis combo logic + register duplication
  + retiming, router timing optimization maximum, placement effort 2.0.
- The device is 81 % full (34 k of 41.9 k ALMs); unrelated area changes do
  not move these paths (measured earlier).

## Measurements (16 KB D-cache V2 core, 104 MHz, server fits)
Worst setup slack (ns) at seeds 2/3/5/9:
- round 2 (call it k2): -2.134 / -2.058 / -1.913 / -1.866
- round 3 (k3, = k2 + three changes listed below + a source cleanup that
  should be logic-neutral): -2.262 / -2.277 / -2.358 / -2.258
Failing setup endpoints / endpoints below -0.6 / total negative slack:
- k2: 2649/627/-1053, 3314/835/-1482, 2591/501/-938, 2421/562/-932
- k3: 4246/1412/-2152, 3637/1212/-1738, 4746/1550/-2401, 3675/1163/-1804
The round-3 changes: (a) zap_dcache_fsm o_ack_fast uses i_tlb_idle (the
TLB walker FSM's IDLE register) instead of !i_busy; (b) maxfan 32 on the
core's predictor_clear register; (c) parameter defaults / dead ZAP options
removed (netlist-equivalent by design).
Seed-2 fits of k3's tree with (a) reverted, (b) reverted, and both reverted
are running; their results may follow.

Per destination family, summed over the four seeds (endpoints below -0.6 /
total negative slack / worst), k2 -> k3, largest losses first:
- u_front_decode|u_decode|d2: 606/-777/-1.87 -> 1150/-1372/-2.28
- u_execute|a: 326/-414/-1.73 -> 534/-708/-2.36
- u_execute|held: 58/-92/-1.08 -> 308/-364/-1.72
- u_front_decode|u_decode|values: 1/-47/-0.74 -> 145/-220/-1.21
- ngage_mem|flash_cs0|sel: 0/-0/-0.21 -> 54/-159/-0.92
- u_front_decode|u_decode|issued: 0/-3/-0.42 -> 93/-147/-0.99
- ngage_mem|flash_cs1|sel: 0/-0/-0.04 -> 93/-110/-1.37
- u_front_decode|u_decode|write_through_data: 4/-16/-1.28 -> 63/-117/-1.00
- u_zap_writeback|u_zap_register_file|g_write_ff.held_a: 0/-34/-0.56 -> 99/-112/-1.35
- u_data_cache|tr_cache_words: 93/-120/-1.80 -> 170/-197/-1.91
- m: 109/-152/-2.05 -> 166/-223/-2.26
- u_execute|held_offset: 11/-25/-1.13 -> 88/-89/-1.61
- u_front_decode|u_decode|redirect_ff: 36/-64/-1.41 -> 94/-123/-1.94
- u_zap_writeback|u_zap_register_file|g_write_ff.held_b: 17/-53/-0.72 -> 100/-109/-1.51
- phoenix_load|errors: 0/0/0.00 -> 40/-56/-1.82
- u_front_decode|u_decode|d1: 112/-145/-1.82 -> 142/-192/-1.81

Source families of the worst regressed destination (decode's D2 register),
endpoints below -0.6 / TNS, four seeds:
- k2: decode issued 170/-189; w 125/-142; decode d2 122/-205;
  TLB check o_hit_ok_short 62/-60; decode d1 44/-52
- k3: TLB check o_hit_ok_short 621/-751; decode out_valid 185/-241;
  w 125/-147; D-cache FSM o_live_trust 107/-105; decode d1 41/-52

Cell-level worst paths (slow 100C; total arrival, increment, type, node;
interconnect hops under 0.25 ns omitted):
```
=== hitok_d2
slack -1.940 from zap_dcache:l_generate_with_cache_mmu.u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short to arm9v2_core:g_arm9.u_arm9_core|arm9v2_front_decode:u_front_decode|arm9v2_decode:u_decode|d2[81]
  7.876  2.271 ic   emu|arm925t|u_zap|u_data_cache|u_zap_tlb|u_zap_tlb_check|o_hit_ok_short|clk
  8.445  0.569 cell zap_dcache:u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short
  8.445  0.000 utco zap_dcache:u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short
  8.445  0.000 cell emu|arm925t|u_zap|u_data_cache|u_zap_tlb|u_zap_tlb_check|o_hit_ok_short|q
 10.278  1.833 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|s_wait[0]~1|dataf
 10.371  0.093 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|s_wait[0]~1|combout
 12.294  1.923 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|s_wait[2]~7|dataf
 12.380  0.086 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|s_wait[2]~7|combout
 12.943  0.563 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|always12~5|datac
 13.441  0.498 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|always12~5|combout
 13.745  0.304 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~10|datad
 14.096  0.351 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~10|combout
 15.607  1.511 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~11|dataa
 16.178  0.571 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~11|combout
 17.030  0.852 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[81]~41|datad
 17.460  0.430 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[81]~41|combout
 18.048  0.588 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~59|dataf
 18.135  0.087 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~59|combout
 18.376  0.241 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~60|dataa
 18.974  0.598 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~60|combout
 18.974  0.000 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[81]|d
 19.236  0.262 cell arm9v2_decode:u_decode|d2[81]
=== hitok_a
slack -1.642 from zap_dcache:l_generate_with_cache_mmu.u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short to arm9v2_core:g_arm9.u_arm9_core|arm9v2_execute:u_execute|a[1]
  7.876  2.271 ic   emu|arm925t|u_zap|u_data_cache|u_zap_tlb|u_zap_tlb_check|o_hit_ok_short|clk
  8.445  0.569 cell zap_dcache:u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short
  8.445  0.000 utco zap_dcache:u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short
  8.445  0.000 cell emu|arm925t|u_zap|u_data_cache|u_zap_tlb|u_zap_tlb_check|o_hit_ok_short|q
 10.309  1.864 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|defer_load~0|dataa
 10.878  0.569 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|defer_load~0|combout
 11.144  0.266 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|defer_load~1|datad
 11.582  0.438 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|defer_load~1|combout
 11.849  0.267 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|complete_class[2]|dataf
 11.941  0.092 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|complete_class[2]|combout
 13.667  1.726 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|done_forward|dataf
 13.752  0.085 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|done_forward|combout
 14.773  1.021 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|forward_write[0]~2|dataf
 14.854  0.081 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|forward_write[0]~2|combout
 15.885  1.031 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|late_accept[0]|datac
 16.399  0.514 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|late_accept[0]|combout
 17.458  1.059 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a~176|datad
 17.893  0.435 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a~176|combout
 18.141  0.248 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a~177|dataa
 18.718  0.577 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a~177|combout
 18.718  0.000 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a[1]|d
 18.980  0.262 cell arm9v2_execute:u_execute|a[1]
=== cachehit_values
slack 0.012 from zap_dcache:l_generate_with_cache_mmu.u_data_cache|tr_cache_hit~DUPLICATE to arm9v2_core:g_arm9.u_arm9_core|arm9v2_front_decode:u_front_decode|arm9v2_decode:u_decode|values[77]
  7.945  2.340 ic   emu|arm925t|u_zap|u_data_cache|tr_cache_hit~DUPLICATE|clk
  8.507  0.562 cell zap_dcache:u_data_cache|tr_cache_hit~DUPLICATE
  8.507  0.000 utco zap_dcache:u_data_cache|tr_cache_hit~DUPLICATE
  8.507  0.000 cell emu|arm925t|u_zap|u_data_cache|tr_cache_hit~DUPLICATE|q
  9.788  1.281 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_load_hit~0|datac
 10.295  0.507 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_load_hit~0|combout
 11.872  1.577 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_wait[1]~4|datag
 12.331  0.459 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_wait[1]~4|combout
 12.602  0.271 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|space|datad
 13.032  0.430 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|space|combout
 13.814  0.782 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|always15~0|datae
 14.067  0.253 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|always15~0|combout
 14.308  0.241 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|shift_pre_ff[1]~0|dataf
 14.402  0.094 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|shift_pre_ff[1]~0|combout
 16.514  2.112 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|values[77]|ena
 17.233  0.719 cell arm9v2_decode:u_decode|values[77]
=== hitok_d2 (k2 seed 2)
slack -1.234 from zap_dcache:l_generate_with_cache_mmu.u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short to arm9v2_core:g_arm9.u_arm9_core|arm9v2_front_decode:u_front_decode|arm9v2_decode:u_decode|d2[130]
  7.863  2.258 ic   emu|arm925t|u_zap|u_data_cache|u_zap_tlb|u_zap_tlb_check|o_hit_ok_short|clk
  8.432  0.569 cell zap_dcache:u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short
  8.432  0.000 utco zap_dcache:u_data_cache|zap_tlb:u_zap_tlb|zap_tlb_check:u_zap_tlb_check|o_hit_ok_short
  8.432  0.000 cell emu|arm925t|u_zap|u_data_cache|u_zap_tlb|u_zap_tlb_check|o_hit_ok_short|q
 10.606  2.174 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_load_hit~0|datac
 11.086  0.480 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_load_hit~0|combout
 11.427  0.341 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_wait[0]~8|dataf
 11.521  0.094 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|a_wait[0]~8|combout
 11.796  0.275 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|space|datac
 12.199  0.403 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_execute|space|combout
 13.031  0.832 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~2|datae
 13.331  0.300 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~2|combout
 14.148  0.817 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~3|dataa
 14.716  0.568 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|comb~3|combout
 14.991  0.275 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[105]~1|dataa
 15.562  0.571 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[105]~1|combout
 17.835  2.273 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[130]|ena
 18.556  0.721 cell arm9v2_decode:u_decode|d2[130]
```

## Where the logic is
- rtl/cpu/zap/zap_tlb_check.sv: o_hit_ok_short (a preserved copy of
  o_hit_ok).
- rtl/cpu/zap/zap_dcache.sv: o_short_hit = tr_cache_hit && hit_ok_short.
- rtl/cpu/zap/zap_dcache_fsm.sv: o_ack_fast, o_err_fast.
- rtl/cpu/arm9v2/arm9v2_core.sv: w_hit, w_load_hit, the execute
  instance's i_load_hit, REG_DONE completion (request_done, late_done),
  complete_class, done_forward, forward_advance, forward_write.
- rtl/cpu/arm9v2/arm9v2_execute.sv: s_load_hit/a_load_hit, s_wait/a_wait,
  space, o_ready/o_ready_payload/o_valid, late_accept, the A register.
- rtl/cpu/arm9v2/arm9v2_decode.sv: step_raw, d2_load, step, o_hazard
  (load_hazard uses i_w_load_hit), the issued/values payload enable,
  o_forward_match/o_forward_grant.
- docs/ARM9V2.md describes the pipeline; docs/PROGRESS-LOG.md (end) the
  timing history.

## Constraints
- Changes should be zero-cycle where possible; a change that costs cycles
  must say how many and where (the suite's cycle total is the yardstick;
  REG_DONE cost +0.24 %).
- House pattern: each cut has a parameter (default on) keeping the old
  form, and a simulation assertion that the new form equals the old.
- No changes under sys/ (the MiSTer framework).

## Question
1. Is there an identifiable structural cause for k3's regression (the jump
   in o_hit_ok_short -> D2 endpoints), or is it a synthesis/placement
   outcome? Cite the lines.
2. Give ranked, concrete options to take the W short-hit / fast-ack cone
   (o_hit_ok_short, tr_cache_hit, w_hit_candidate, o_ack_fast into D2, A,
   S/A holds, decode values and the forward match/grant registers) off the
   critical paths: for each, the change (file/line), expected effect on
   these paths, cycle cost, area, and risks. Be sceptical: say what would
   not work and why.
Write the answer as plain Markdown.

## Follow-up (2026-10-26, same session): D2's hazard -> enable loop

### Question

Follow-up (read-only again; the worktree is still 1ff0fa8, the new RTL is
not in it). Since your answer I fitted a tree with these zero-cycle cuts
(all asserted equal and passing the full suite): the fast ack back on
!i_busy (the TLB-idle form fitted worse at seed 2: -2.206 vs -1.953 ns,
TNS -1592 vs -1273); your option 1 in the form "S/A waits, valid,
ready_payload and can_finish computed for both values of i_load_hit, the
hit selecting last; decode computes hazard (including W's WAW exemption
and the early hazard from A's finish), step, d2_load and the payload
enable for both values with (* keep *) on the per-value wires, and
selects by the hit"; planned writes from decode's registered writes mask;
registered PC/PSR tag classes; the held-operand capture without the
acceptance enable (your option 3); keep+maxfan on d2_load (Quartus did
create d2_load~SynDup).

Result, seeds 2/3/5/9: -2.760 / -2.819 / -1.989 / -1.784, TNS -2877 /
-1913 / -1534 / -1197 (k2 was -2.134/-2.058/-1.913/-1.866, TNS -1053 /
-1482 / -938 / -932). At seed 2 decode's D2 is the worst family (313
endpoints, all below -0.6, TNS -632), its paths now from D2's own tags
and W:

```
=== w_d2
slack -2.652 from arm9v2_core:g_arm9.u_arm9_core|w[6] to arm9v2_core:g_arm9.u_arm9_core|arm9v2_front_decode:u_front_decode|arm9v2_decode:u_decode|d2[291]
  8.505  0.565 cell w[6]
  9.282  0.777 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|load_speculate[4]~0|datad
  9.775  0.493 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|load_speculate[4]~0|combout
 11.850  2.075 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_rest~26|dataf
 11.942  0.092 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_rest~26|combout
 12.203  0.261 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~23|datae
 12.504  0.301 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~23|combout
 13.291  0.787 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~24|datad
 13.863  0.572 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~24|combout
 14.063  0.200 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~25|dataa
 14.622  0.559 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~25|combout
 15.214  0.592 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load_by[0]|dataa
 15.779  0.565 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load_by[0]|combout
 16.064  0.285 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load~SynDup|datad
 16.423  0.359 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load~SynDup|combout
 17.274  0.851 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~1|dataf
 17.358  0.084 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~1|combout
 19.228  1.870 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[291]|ena
 19.942  0.714 cell arm9v2_decode:u_decode|d2[291]
=== any_d2
slack -2.760 from arm9v2_core:g_arm9.u_arm9_core|arm9v2_front_decode:u_front_decode|arm9v2_decode:u_decode|d2[121] to arm9v2_core:g_arm9.u_arm9_core|arm9v2_front_decode:u_front_decode|arm9v2_decode:u_decode|d2[245]
  8.474  0.564 cell arm9v2_decode:u_decode|d2[121]
  9.908  1.434 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|Equal261~1|dataa
 10.477  0.569 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|Equal261~1|combout
 11.389  0.912 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|waw_w_by[1]~1|datae
 11.640  0.251 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|waw_w_by[1]~1|combout
 11.871  0.231 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~23|dataa
 12.459  0.588 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~23|combout
 13.246  0.787 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~24|datad
 13.818  0.572 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~24|combout
 14.018  0.200 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~25|dataa
 14.577  0.559 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|hazard_by~25|combout
 15.169  0.592 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load_by[0]|dataa
 15.734  0.565 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load_by[0]|combout
 16.019  0.285 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load~SynDup|datad
 16.378  0.359 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2_load~SynDup|combout
 17.229  0.851 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~1|dataf
 17.313  0.084 cell emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2~1|combout
 19.375  2.062 ic   emu|arm925t|u_zap|g_arm9.u_arm9_core|u_front_decode|u_decode|d2[245]|ena
 20.095  0.720 cell arm9v2_decode:u_decode|d2[245]

```

So with the hit moved to the end, D2's hazard tree itself (tag compare ->
OR -> step/d2_load -> enable broadcast to ~350 flops) leads. Question:
what are concrete zero-cycle ways to shorten D2's hazard -> d2_load ->
enable loop in this design (rtl/cpu/arm9v2/arm9v2_decode.sv: load_hazard,
o_hazard, step_raw, d2_load, the d2 update block; the core's load_valid /
load_tag / load_speculate / locked / early_valid inputs)? For each: what exactly is registered or moved, how
the next values are formed (which selects become critical instead), the
expected effect, area, and what could break. If you think a one-cycle
hazard register (with its cycle cost) is the only realistic route, say so
and estimate where the cycles go. Be sceptical and cite lines in the
1ff0fa8 tree.

### Answer

**I would not add a cycle yet. There are still credible zero-cycle cuts, including one that actually removes the wide enable broadcast.** But your results weaken the case for further hit/no-hit expansion: moving the hit last has exposed—and potentially lengthened—the paths from every other input. I would stop adding preserved cofactors until those paths are shortened.

In `any_d2`, **2.997 ns remains between `d2_load~SynDup`’s output and the destination enable**, before the 0.720 ns endpoint increment. Reaching −0.6 requires recovering 2.160 ns. Thus removing one comparator level alone is unlikely to suffice; the wide enable distribution deserves a structural change.

All references below are to the unchanged `1ff0fa8` checkout. I have not inspected the new RTL.

**1. Register a per-destination “this instruction reads its destination” bit.**

This is the smallest targeted cut for the new `d2.tag → waw_w_by` path.

At [decode:608](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:608), WAW blocking requires:

```text
destination == producer_tag
```

Under that condition:

```text
any used source == producer_tag
```

is equivalent to:

```text
any used source == that destination
```

Therefore register two bits:

```text
reads_dest[d] = OR_s(used[s] && tag[s] == dest[d])
```

and express each WAW term as:

```text
writes[d] && load_valid[p] && dest[d] == load_tag[p] &&
!(load_speculate[p] &&
  (reads_dest[d] || (p == 4 && w_load_hit)))
```

That removes the source-tag comparisons and four-source OR from the exemption. It directly attacks the supplied `d2[121] → Equal261 → waw_w_by` route, assuming the new tree retains the old packing.

**Next values:** calculate `reads_dest` separately for:

- `admitted`, selected by `d2_load`;
- the block-step candidate, selected by `step && !d2.last`;
- the existing D2 record, retained otherwise.

Replacement wins over block stepping, matching [decode:715–733](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:715). Compute each candidate’s comparisons **before** selecting the candidate. Do not calculate them from a muxed `d2_next`.

The block candidate must include the new destination, source 3, `used[0]`, and `used[2]`. Simply retaining these bits across LDM/STM expansion is wrong.

**New critical paths:** D1 decode/banking → candidate self-read comparison → two-bit selection; and current hazard → `step/d2_load` → that selection. The latter terminates in two flops rather than another comparison tree.

**Area/cycles:** two flops, candidate comparison logic, zero cycles. Some logic can be recovered by deriving the existing aggregate `d2_self_dep` as `|(writes & reads_dest)`.

**Risk:** the existing single `self_dep` at [decode:482](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:482) is insufficient: one destination reading itself must not waive another destination’s WAW hazard. Preserve physical banked tags and per-destination qualification.

**2. Register producer hazard classes, then flatten the common hazard and capacity logic.**

The supplied `w[6] → load_speculate[4]` path begins with a classification that can travel with the producer.

For M/W/skid, define:

```text
v = record.valid &&
    ((record.memory && !record.store) || record.load_writer)

s = (record.kind == MEM ||
     (record.kind == BLOCK && record.last)) &&
    record.dest[0] != 15

non_spec_load = v && !s
spec_load     = v &&  s
```

These are the functions at [core:530](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:530). Register them alongside their records.

**Next values:** use the actual `m_next`, `w_next`, and `skid_next` ownership schedule at [core:670](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:670). Prefer classifying each possible source record first and selecting the finished two-bit class with the record movement:

- W: held W, current M, cleared W, or SWP’s modified W.
- M: held M, `input_record`, or skid.
- Skid: held skid, `input_record`, or cleared skid.

Include flushes, W removal, and `LOAD_RETURN` changing SWP’s store state. Do not assume “W always receives M.”

For S and A, register the instruction’s load/speculation classification with the payload. Qualify it with the correct valid state. S’s payload can load without `step`, so its class must follow [decode:693](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:693), not just valid admission. A’s class follows acceptance; its valid state follows finish/accept/kill priority. The existing A load definition is at [execute:469](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_execute.sv:469).

These classes permit a more direct hazard reduction. For producer `p`, form:

```text
R[p] = any used source matching its tag
E[p] = any used early source matching its tag
D[p] = any written destination matching its tag
B[p] = any written destination matching its tag
       whose reads_dest bit is clear
```

Then its load hazard is:

```text
non_spec_load[p] && (R[p] || D[p])
||
spec_load[p] &&
  (early_read_block[p] ||
   (B[p] && (p != 4 || !w_load_hit)))
```

Here `early_read_block` is `R` for slot 0, `E` for slot 1, and zero for the other active slots. Slot 2’s `load_valid` is permanently zero in this integration.

This exposes parallel producer contributions instead of repeatedly combining source matches, destination matches, speculation and exemptions.

Also flatten the final load equation from [decode:584](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:584):

```text
available = count != 0 || (i_valid && count < 2 && fast_select)
empty     = available && !d2_valid
replace   = available && (!out_valid || i_ready_payload) &&
            d2.last && (!redirect_ff.valid || redirect_in_d2)

d2_load = empty || (replace && !hazard_body)
```

`hazard_body` is the hazard expression without its outer `d2_valid`. Keep hit-independent blockers common where useful; do not force every such blocker through a preserved `hazard_by → d2_load_by → final-hit-mux` sequence.

**New critical paths:** backend movement → small class-register selection; D2 destination equality → parallel hazard reduction → final load gate. Registering classes removes W’s kind decode, but does not automatically shorten the W-to-decode wire.

**Area/cycles:** approximately two class bits per active producer, plus small candidate logic; zero cycles. The combinational flattening adds no state and may reduce duplicated logic.

**Risks:** adding condition-pass filtering that the original hazard classes do not contain changes behavior. For early ALU hazards, register only the static eligibility; retain A’s current `!can_finish` qualification at the end. Its same-clock release is explicit at [core:526](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_core.sv:526).

**3. Put D2’s immutable packet payload in two banks, switching ownership on `d2_load`.**

This is the strongest direct attack on the enable broadcast.

In the **1ff0fa8 packing**:

- `d2[291]` is `d2.p.pc_base[14]`.
- `d2[245]` is `d2.p.next_pc[0]`.

Both belong to `packet_t`, which block stepping never changes. Verify those mappings against the new generated Verilog before relying on the bit numbers. The packet definition is at [decode:119](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:119); the generated output mappings are at [arm925t_gen.v:2765](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm925t_gen.v:2765).

Replace the single packet register with two banks and a registered active-bank bit. Conceptually:

```text
every edge:
    inactive_bank <= admitted.p

on the original d2_load edge:
    active_bank <= !active_bank

logical d2.p = bank[active_bank]
```

Use the **old active-bank bit** to determine which bank captures. The bank being selected after the edge receives `admitted.p` on that same edge.

This preserves the original logical packet transition exactly:

```text
d2.p_next = d2_load ? admitted.p : d2.p
```

No extra pipeline clock is introduced.

Keep tags, masks, block counters and other hazard-driving metadata in the current small D2 header initially. Preserve the existing `step`, valid, queue-count, redirect and fence schedules.

**What moves:** the hazard no longer enables the packet’s hundreds of flops. It updates an owner bit. Bank write enables and packet read muxes start from that registered owner.

**New critical paths:**

- Hazard → `d2_load` → owner-bit toggle.
- Owner Q → packet mux → issued/redirect/block-control consumers.
- D1 decode → inactive packet bank.

The wide control still exists, but it now starts at a flop rather than after the entire hazard tree.

**Area/cycles:** `packet_t` is 241 bits: roughly **241 additional flops, 241 output mux bits, and an owner register**, before optimization and any owner duplication. Zero cycles, including consecutive replacements and prolonged holds.

**Risks:**

- The packet mux can become critical into issued, prediction checks, or block-next metadata. Keep particularly sensitive packet fields duplicated in the header if measurement justifies it.
- Accidentally writing the active bank destroys a stalled instruction.
- Pointer copies must remain identical through reset.
- Keep the dynamically updated `redirected` field outside this immutable bank.

This is materially different from freeing D2’s existing enable: the second bank supplies the storage needed to preserve its live owner.

**4. Register conflict summaries at the existing D2 boundary—but compute all ownership candidates before selection.**

This is a larger zero-cycle option if the first three leave the comparator/reduction loop dominant.

Register a small set of per-producer conflict summaries—such as `R/E/D/B` above—whose invariant is:

```text
summary_q = conflict(current logical D2, current producer)
```

Therefore their D inputs must describe **both records after the upcoming edge**.

For D2 there are three candidates:

```text
admitted
block_next
held_d2
```

For each producer there are its legal movement candidates. For example, W can hold or receive M; M can hold or receive A/skid. S can receive the old D2 while D2 receives `admitted` or `block_next`.

Compute:

```text
candidate_conflict[d2_case][producer_case]
```

in parallel, and select the finished bits using the actual D2 and producer transitions. Do not write:

```text
summary_next = conflict(muxed_d2_next, muxed_producer_next)
```

That puts `step/done/accept` ahead of comparisons and reductions, recreating the feedback cone at the new register inputs.

For early hazards, carry static matches/eligibility and apply current A-finish qualification afterward. For W, retain current hit qualification afterward. Those events need not be predicted to register the static conflict.

**Expected effect:** current D2 tags stop launching the live comparator tree. The recurrent path becomes summary Q → small hazard reduction → small metadata-selection registers, plus whatever D2 payload enable remains. This combines particularly well with option 3.

**New critical paths:** D1 decode → candidate comparisons/reductions → summary D; backend completion and S acceptance → candidate selectors. Held D2 must refresh summaries when producers move, even when D2 itself does not.

**Area/cycles:** tens of summary flops, but potentially substantial replicated comparison logic. Zero cycles with the exact next-owner invariant. Start with W and the measured WAW branch rather than constructing the full Cartesian product immediately.

**Risks:** this is the highest implementation-risk option here. Partial LDM expansion, producer invalidation, simultaneous S/A movement and backend reloads all matter. Existing `i_next_load_tag/valid` covers only two slots for the S-entry spacing check; it is not a complete next-state interface for D2’s scoreboard. See [decode:545](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:545).

**5. If locks become the leader, register D2’s lock-interest mask—not yesterday’s lock result.**

The current lock branch performs six indexed bitmap queries at [decode:615](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/arm9v2/arm9v2_decode.sv:615).

Register a 40-bit mask describing every physical register D2 currently reads or writes:

```text
needed = OR_s(used[s]   ? onehot(tag[s])  : 0)
       | OR_d(writes[d] ? onehot(dest[d]) : 0)

lock_hazard = |(needed_q & i_locked)
```

**Next values:** compute masks for admitted, block-next and held D2, selecting them with the same priority as option 1. The lock bitmap remains current, so same-edge installations and clears are not delayed.

**Expected effect:** replaces multiple variable-index muxes with a parallel AND/reduction. It may help routing, but a 40-bit reduction is not free.

**Area/cycles:** 40 flops plus candidate mask-generation logic; zero cycles. This is secondary because neither supplied path is lock-rooted.

**Risk:** assuming physical tags outside 0–39 behave like a zero mask requires validating the active-tag invariant. Preserve the used/write masks, particularly around faults and block expansion.

A registered *lock result* is harder: it must query `lock_nxt` using D2’s next owner, not `lock_ff` using its old owner. The cache already follows that pattern for W at [dcache_fsm:264](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache_fsm.sv:264). `lock_nxt` includes both return clearing and newly installed miss locks at [line 710](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache_fsm.sv:710) and [line 891](/Users/jacob/dev/fpga/mister/NGage_MiSTer-consult/rtl/cpu/zap/zap_dcache_fsm.sv:891). Pulling that cone into decode can create a worse cache-to-metadata path.

**What I would not expect to solve this alone**

Your `d2_load~SynDup` proves duplication happened. The remaining question is the location and fanout of the **last** driver, including any shared reset/enable logic after that duplicate. More `maxfan` or `keep` without examining that final distribution is a low-confidence experiment.

Likewise, spelling the hold as `d2 <= enable ? new : d2` does not ensure a different implementation: Quartus can move feedback logic onto the register enable. A narrowly scoped enable-versus-D-mux experiment may be worthwhile, but it trades the enable network for per-bit feedback muxes and still broadcasts the decision. It adds no cycles, potentially adds many muxes, and can worsen packing. [Quartus 17 documents this enable conversion](https://resources.altera.com/quartushelp/17.0/comp/comp/comp_tab_fitting.htm).

**If a registered hazard stage becomes necessary**

There are two very different costs:

| Implementation | Likely cycle consequence |
|---|---|
| Keep one D2 slot; require a check clock after every new D2 instruction or block micro-op | An otherwise unstalled stream issues at most every other clock. Roughly one extra non-overlapped clock per micro-op, plus possible delayed hazard release. Existing stalls can hide some check clocks. |
| Add a separate elastic checked-instruction slot | Adds one stage of latency, but can retain one instruction per clock for independent work. Pipeline fills, recovery paths and delayed hazard releases can cost clocks. The extra slot must participate in pending-writer detection. |

A bare `hazard_q <= o_hazard` is not a correct implementation of either. The registered answer can belong to the previous D2 owner or miss changed producer/lock state. A held checked record needs an explicit freshness/interlock scheme; a new stage also introduces an older producer that the current scoreboard does not represent.

I would not estimate a suite percentage from the available data. For the single-slot version, measure the number of otherwise issuable micro-ops whose additional check clock is exposed; that is the first-order cycle cost, not the rare-event +0.24% measured for REG_DONE.

My next experiments would be **the two-bit WAW exemption, registered producer classes with flatter common control, then the immutable-payload banks**, independently parameterized. The banks offer the clearest structural way to remove the measured wide-enable problem without adding cycles. Full next-owner conflict registration comes afterward if the smaller D2 header remains critical.

I checked the WAW substitution algebra, flattened `d2_load` identity, and abstract two-bank transition invariant separately. These are not RTL or fitting results. The checkout remains unchanged; each implementation still needs its old-form assertions, cycle comparison and matched-seed timing results.


