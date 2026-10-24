# Shared memory side 2: merger-owned dirty victim

Date: 2026-10-24. Branch: `codex/memside`. Implementation commit: `64b8f33`. Baseline: `eeb1e47`
(memside1); no merge from master and no changes to parked `codex/timing2`.

## Result and measurement boundary

The D-cache now transfers a distinct-physical-line dirty victim to a one-line
buffer in `zap_wb_merger` on the same edge that installs the replacement.
The cache resumes through its existing unlock/lookup-repair path, independently
of the write burst. Clean misses, unrelated hits, and nonconflicting TLB/I-cache
reads can proceed while that buffer is occupied. A second dirty miss waits for
space. Uncached/write-through accesses and maintenance retain drain ordering.

The original 231 runs pass with identical instruction counts and **57 QEMU
agreements, zero differences**. Their aggregate cycles change from 21,385,393
to 21,367,361: **18,032 fewer (0.084%)**. The gain is small in these workloads;
`walloc_rtl` is unchanged. This is a bench result, not a gameplay prediction.
The board measurement is the next decision point; no Quartus fit, deployment,
firmware boot bench, or gameplay measurement was performed here.

The user's memside1 board capture reported Sonic at 31.2–31.7 M instructions/s,
42.5% FIFO-full clocks, 6.5% true fetch wait, 438 K I-demand fills/s, 1.2% fill
wait behind DATA ownership, and 257 K/164 K I/D TLB beats/s. Those are supplied
hardware observations, not measurements repeated in this worktree. The two
speed consults motivate this experiment, but their larger write-buffer speed
estimates are not validation of this particular victim buffer.

## Ownership and ordering

1. **Acceptance and reservation.** Existing alignment/MMU permission checks
   precede cacheable miss acceptance. The FSM still captures the victim in
   its existing `cache_line` and `cache_tag` registers. A dirty miss is accepted
   only while the merger buffer is empty. There is one producer, so this
   reserves that buffer until the installation handoff without another
   reservation register. The initiating store's early ACK and the load's
   register lock/critical-beat write are unchanged.
2. **Atomic handoff.** `UNLOCK_REG` writes the new RAM line/tag and pulses
   `o_victim_valid` with the complete saved line and aligned physical address.
   The merger captures both and sets its valid bit on that edge; the cache's
   own write-back-busy bit clears on the same edge. Their OR is continuously
   busy, with no gap for CP15 to observe. The producer may reuse its saved
   context afterwards. The buffer's line and physical tag remain immutable
   through its final ACK/ERR.
3. **Lookup repair.** Loads leave installation through `UNLOCK_WR`; stores go
   through `RELOOKUP0..2` when an access is held, otherwise directly to IDLE.
   No new RAM port or live tag/data comparator is involved. Hits can complete
   in IDLE during a merger drain. The old post-install `CLEAN_SINGLE` visibility
   delay is unnecessary and removed. A dirty miss or uncached access held in
   IDLE asserts `o_hold`: both cache and TLB lookup results must stay frozen.
   An initial test caught omission of that hold; it is fixed and the complete
   suite was rerun.
4. **Read priority.** CODE and DATA retain their normal arbitration when the
   buffer is empty. While it is occupied, pending reads have priority over a
   discretionary victim drain. An admitted transaction retains ownership
   through its terminal beat, including ACK latency and burst beats. There
   is no mid-burst preemption. The victim starts at word zero and drains four
   beats with BTE=wrap-4 and terminal CTI on beat three for a 16-byte line.
   Other supported line lengths retain a linear burst.
5. **Physical conflicts.** Reads of the buffered physical line **wait for its
   drain**, with no forwarding. Both CODE and DATA addresses are checked,
   including D-TLB walks. During buffer overlap only, a new request is held
   for a registered PA comparison before admission; a new transaction after
   EOB cannot reuse its predecessor's check. A conflict requests the victim
   at the next free burst boundary. A buffered-line store normally misses
   and waits for capacity or for the conflicting allocation read. No new
   snooping/coherence guarantee for arbitrary simultaneously resident VIVT
   synonyms is introduced; software maintenance remains required as before.
6. **Same-PA dirty replacement.** When the victim and new miss have the same
   physical line but distinct VAs, `CLEAN_SINGLE` still drains the old dirty
   bytes **before** `FETCH_SINGLE`. This path never hands off a victim. It
   also waits for an older merger victim before accepting the dirty miss.
7. **Backpressure and maintenance.** A full buffer prevents another dirty
   miss from being acknowledged, while allowing clean misses. All cache
   clean/invalidate operations (line or whole cache) wait for an empty buffer
   before starting their tag-manager operation. Invalidation has no path to
   clear the buffer. A registered FSM drain request gives a blocked dirty
   miss, uncached/WT access, or maintenance operation priority at the next
   burst boundary. CP15 c7,c10,4 exports its own registered drain request;
   continuous instruction reads cannot starve it. It still has no added
   CP15 cycle when neither cache nor merger owns a dirty victim.
8. **Device/DMA publication.** Uncached reads/writes, cache-disabled accesses,
   and write-through stores wait for the buffer, including an unrelated
   device address. Thus a device doorbell cannot overtake an older eviction.
   Maintenance/drain completion still implies every victim bus beat has
   completed. This is the same bus-ACK visibility contract as before; the
   UPP bridge's existing posted-SDRAM-write behavior is unchanged. No DMA
   snooping is added.
9. **Faults and reset.** Cacheable fill/write-back ERR continues to consume a
   beat without a late architectural abort, exactly as the previous FSM did.
   Uncached/WT errors retain their precise response path. Reset discards
   volatile cache/buffer ownership, as it did for an in-flight old FSM drain;
   cache invalidation and ordinary maintenance cannot do so.

`zap_dcache_fsm.sv` carries this contract in its header. The cache still
serializes a second fill behind the first fill/install; this is not multiple
outstanding fills or a posted uncached-store queue.

## Interface handoff for ARM9 v2

| Module | Addition / changed contract |
|---|---|
| `zap_dcache_fsm`, `zap_dcache` | Input `i_victim_busy`; outputs `o_victim_valid`, `o_victim_line[CACHE_LINE*8-1:0]`, `o_victim_addr[31:0]`, `o_victim_drain`. Valid is an installation-edge pulse and must only be asserted with busy low; assertions check overflow. Address is line aligned. |
| `zap_wb_merger` | New `CACHE_LINE` parameter, set to `DATA_CACHE_LINE` by the cached top. Inputs `i_victim_valid`, `i_victim_line`, `i_victim_addr`, `i_victim_drain`; outputs `o_victim_busy`, `o_victim_done`. The latter pulses after the final accepted write beat. No invalidate input exists. |
| `zap_dcache.o_writeback_busy` | OR of its FSM's dirty-victim ownership and merger busy; connect this combined status to CP15. |
| `zap_cp15_cb`, `zap_core` | New registered CP15 `o_dcache_drain`, carried unchanged through the core port. No pipeline/interlock/operand logic changed. |
| `zap_top` | Connects the handoff, ORs the FSM and CP15 forced-drain requests, and adds merger completion to existing D-cache event bit 2. ONLY_CORE ties the enqueue/drain inputs low. |
| Merger debug | `o_dbg_data_owner` now includes VICTIM ownership, so the existing I-fill-behind-DATA counter also counts this drain. |

The ARM9 v2 integration must connect these interfaces explicitly, including a
forced CP15 drain request and the combined busy fence. A consumer without this
producer must tie the new inputs low with the appropriate line width. There
are no input-port default values. No ARM9/v2 file was edited or tested here.

Eviction event bit 2 is now counted at merger drain completion, while same-PA
clean-before-fill and tag-manager maintenance still count at their existing
terminal beats. Handoff itself is not a write-back event. The top-level counter
layout and `mister_dbg.py` require no change.

## State and timing review

Every newly declared synthesized register is listed here (widths for the
16-byte-line configuration). No new cache RAM or pipeline stage is added.

| Register | Bits | Purpose |
|---|---:|---|
| Merger `victim_line_ff` | 128 | Immutable saved victim bytes |
| Merger `victim_pa_ff` | 28 | Physical line number |
| Merger `victim_valid_ff` | 1 | Buffer ownership / backpressure |
| Merger `victim_beat_ff` | 2 | Current write word |
| Merger `c_checked_ff`, `d_checked_ff` | 2 total | Request address has crossed the comparison register |
| Merger `c_conflict_ff`, `d_conflict_ff` | 2 total | Physical-line conflicts |
| Merger `o_victim_done` | 1 | Registered debug completion event |
| Merger `l_genblk1.victim_data_ff` | 32 | Next victim word in the existing speculative write-data bank arrangement |
| FSM `o_victim_drain` | 1 | Registered forced drain for a blocked cache/device/maintenance operation |
| CP15 `o_dcache_drain` | 1 | Registered forced drain for c7,c10,4 |

The existing merger `state_ff` and `l_genblk1.data_owner_ff` enums widen from
one to two source bits to represent VICTIM. Source-level additions therefore
total 200 bits including those two widened bits. Five obsolete FSM bits are
removed: `defer_writeback`, `victim_safe_ff`, `install_delay_ff[1:0]`, and
`fill_visible_ff`. Net source-level increase: **195 bits**, before synthesis
optimization/encoding (the debug-only completion pulse can disappear in the
stripped build). This is not a fitter ALM/register estimate.

The physical-address compares end in registers; they do not enter the live
cache-hit compare or the merger's address selection directly. Normal requests
when the buffer is empty acquire no admission delay. Buffer-overlap requests
can pay an admission clock, and physical conflicts/forced drains intentionally
change arbitration. The common bus address remains registered after selection;
there is no new address mux after that register. The data output bank gains a
third registered word selection. Buffer-valid, owner, checked/conflict flags,
and registered drain requests feed arbitration, so this family is still a
placement/timing risk even though address arithmetic and live comparisons are
kept out of it.

The cache's new admission input is the merger's registered valid bit. It
qualifies existing uncached/WT controls and the dirty-victim selection (a short
mux of registered valid/dirty/LRU values) on a miss. Hit tag matching is
unchanged; the HUM ACK predicate is unchanged. The per-slot live cache data
path, issue forwarding and operand clock enables are untouched. CP15 busy
adds a two-input ownership OR. No timing/slack claim is made without a fit.

## Verification

- Baseline: all 77 existing CPU tests at 0:0 / 0:3 / 2:9, 231/231 passing;
  QEMU 57 agree. Binaries and QEMU references were reused.
- Changed core: all existing tests plus `wbuffer_rtl`, 234/234 passing; QEMU
  57 agree, zero differences. Every existing instruction count is identical.
- `wbuffer_rtl.S`: exact values for store miss followed by independent work,
  victim read/write, clean second miss, dirty second miss, new-line clean,
  buffered-line invalidate/clean-invalidate, whole clean/invalidate, explicit
  drain, uncached victim read, and a cold generated-code I miss. The final
  section checks the same-PA dirty VIVT replacement in both directions.
  It uses the bench's programmable latency and runs cold/warm passes.
- CPU assertions capture the victim independently at accepted dirty misses,
  verify handoff and every actual bus write's PA/data/mask/order, permit clean
  misses without overwriting that scoreboard, and check maintenance/drain
  completion. Added common-bus assertions reject physical reads ahead of the
  buffered line and bound a required drain under the bench's response model.
- `dhum_rtl` keeps its exact expected overlap counts. Its bench observation
  now also recognizes an actual IDLE cache hit while the merger owns a victim;
  counting only the old FSM states would incorrectly call these hits absent.
  No instruction or expected architectural value in that test changed.
- Standalone `make -C sim merger`: independent NXT masters check delayed ACKs,
  read priority, same-PA I/D requests, back-to-back transaction PA changes,
  forced drain against continuous reads, immutable copied bytes, full-buffer
  ownership and ERR completion at 0/3/9/31-clock delays. Its bus monitor checks
  request stability, wrap order, terminal beats and uninterrupted ownership.
- `make lint`, debug `verilator --lint-only -Wall --top-module emu
  -DNGAGE_DEBUG=1 -f lint/rtl.f`, generation and `make cpu-gen-check` pass.
  Generated `input reg` count remains **10**.

- `make -C sim sdram ddrflash upp periph top` passes, including both 64 KB
  and 256 KB UPP board configurations. The top bench completes at
  **150,622,764 clocks**. The bus-protocol monitors pass; this is simulation,
  not a live-board bus-monitor capture.
- 27 focused runs at `DCACHE_SIZE=16384` pass: cache, dhold, dhum, dstore,
  wbuffer, dcsize, walloc, crand1 and ctrand1 at all three normal latencies.
- 18 additional default-cache runs pass at latency 2:31, RNG seeds 2, 7
  and 19: cache, dhum, dstore, wbuffer, crand1 and ctrand1. They run with the
  same ownership/physical-conflict/burst assertions.
- The new directed binary also passes on the archived baseline model at
  all three latencies, with the same 17,245 instruction count. No existing
  binary or QEMU reference was rebuilt/rerun to produce a new reference.

In each normal-latency `wbuffer_rtl` run the bench observes 30 handoffs,
7 DATA beats and 68 CODE beats while a victim remains pending, 580 physical
conflict clocks, 294 full-buffer dirty-miss hold clocks, 128 uncached hold
clocks, 1,500 maintenance-pending clocks and 101 explicit-drain-pending clocks.
These overlap and are not additive. The test fixes its data-phase bus latency
at 24 clocks; this explains the repeated coverage figures across configurations.
Its two same-PA dirty evictions take clean-before-fill, independently checked
by the saved-victim scoreboard. Test-only probes/counters add no core state.

Only one local simulator ran at a time. The archived baseline model/netlist,
cycle manifests and command logs are in ignored `build/memside2/`; the new
source tests and the table below are committed. No Docker/server job was
started, and all task-owned test processes have exited.

## Cycle table

All existing tests whose cycle count changes are listed; an unchanged latency
is shown alongside the other two for that test. All 54 omitted existing tests
are cycle-identical at all three latencies. The table compares the same test
binaries on baseline and changed RTL, with instruction counts checked too.
| Test | 0:0 before → after | 0:3 before → after | 2:9 before → after |
|---|---:|---:|---:|
| cache | 752,424 → 752,424 | 861,289 → 854,349 | 1,130,292 → 1,124,728 |
| crand1 | 72,638 → 72,652 | 104,142 → 104,140 | 186,951 → 186,831 |
| crand2 | 73,007 → 72,965 | 104,577 → 104,424 | 187,513 → 187,397 |
| crand3 | 73,104 → 73,056 | 104,971 → 104,842 | 188,103 → 188,022 |
| crand4 | 73,629 → 73,616 | 105,141 → 104,922 | 188,139 → 187,942 |
| crand5 | 73,083 → 73,021 | 104,607 → 104,487 | 187,616 → 187,476 |
| crand6 | 73,192 → 73,159 | 105,031 → 104,907 | 188,592 → 188,424 |
| crand7 | 72,763 → 72,749 | 104,243 → 104,133 | 187,027 → 186,846 |
| crand8 | 73,032 → 72,934 | 104,705 → 104,569 | 187,620 → 187,435 |
| ctrand1 | 72,370 → 72,360 | 102,170 → 102,149 | 178,801 → 178,783 |
| ctrand2 | 72,438 → 72,425 | 102,198 → 102,174 | 178,988 → 179,005 |
| ctrand3 | 72,377 → 72,367 | 102,189 → 102,168 | 178,843 → 178,821 |
| ctrand4 | 72,420 → 72,407 | 102,550 → 102,513 | 179,325 → 179,319 |
| ctrand5 | 72,357 → 72,347 | 102,171 → 102,155 | 178,842 → 178,824 |
| ctrand6 | 72,377 → 72,367 | 102,140 → 102,116 | 178,864 → 178,842 |
| ctrand7 | 72,222 → 72,217 | 102,024 → 102,001 | 178,726 → 178,676 |
| ctrand8 | 72,346 → 72,336 | 102,104 → 102,081 | 178,820 → 178,800 |
| dcsize_rtl | 111,795 → 111,800 | 145,327 → 145,331 | 237,271 → 237,266 |
| dhold_rtl | 273,080 → 272,449 | 342,690 → 342,153 | 518,563 → 518,098 |
| dhum_rtl | 483,070 → 482,763 | 509,170 → 508,863 | 575,387 → 575,080 |
| dstore_rtl | 187,563 → 187,533 | 213,658 → 213,628 | 279,703 → 279,673 |
| icache_rtl | 58,035 → 58,035 | 85,224 → 85,225 | 154,361 → 154,361 |
| iprefetch_rtl | 73,120 → 73,117 | 104,171 → 104,171 | 184,164 → 184,164 |


The new directed test, run as the same binary on both models:

| Test | Instructions (each latency) | 0:0 before → after | 0:3 before → after | 2:9 before → after |
|---|---:|---:|---:|---:|
| wbuffer_rtl | 17,245 | 291,840 → 291,785 | 317,937 → 317,882 | 383,982 → 383,927 |

For the specifically requested unchanged streaming test, `walloc_rtl` remains
67,392 / 97,004 / 173,816 cycles. It does not expose additional post-install
victim waiting in this sequence. `cache` improves by 0 / 6,940 / 5,564 clocks;
its no-latency case has no exposed drain to hide. Four existing tests contain
small increases at some settings (`crand1`, `ctrand2`, `dcsize_rtl`,
`icache_rtl`); the largest is 17 clocks. Registered overlap admission and the
resulting arbitration/latency-draw sequence can move individual schedules in
either direction. No performance counter or expected instruction was changed
to hide these increases.

## Risks, limits, and exact stopping point

The functional risk is ownership/order across handoff, a following transaction,
and maintenance; the independent saved-line scoreboard, physical-address
checks, standalone arbitration scenarios, delayed/randomized ACKs and existing
architectural comparison cover those boundaries. Bus ERR retains the inherited
cacheable no-late-abort model; this work does not provide precise write-back
aborts, general VIVT synonym coherence, or DMA cache snooping. Forced drain
priority operates at the CPU merger's next free burst boundary; it cannot
preempt an external DMA/self-test bus grant. The surrounding bridge/arbiter's
existing eventual-service contract still applies.

Only one victim can be buffered. A second dirty miss still waits, uncached/WT
accesses deliberately still fence it, and a read arriving after a write burst
has begun must wait for that entire burst. New clean misses can overlap a
pending victim, but cannot overlap an unfinished cache fill. No posted MMIO
writes, write combining, additional miss slots, I-cache execution bypass, or
change to cache allocation policy is included.

Timing and fitted area remain unmeasured, as requested. New critical-family
exposure is confined to merger arbitration/write-data selection, registered
buffer capacity into cache miss admission, and the CP15 busy OR described
above. Board throughput could differ substantially from the small suite gain;
no speed estimate is substituted for the owner's next gameplay capture.

The implementation and directed tests are committed in `64b8f33`; this report
is the final documentation commit on `codex/memside`. The task stops with a
clean worktree after all verification above. No changes were made under
`sys/`, to ARM9/v2, to the card model, or to NGage top-level debug packing.
The only `zap_core` change carries the explicit CP15 drain port; no ZAP
pipeline behavior was edited. `codex/timing2` remains at
`c188fe5cb7212b41b7b07745044f2ec4b577019e`. There was no merge/rebase from
master and no push. The next action belongs to the owner: build the measurement
core and compare matched gameplay throughput and existing D-cache/I-side
counters before selecting another memory-side change.
