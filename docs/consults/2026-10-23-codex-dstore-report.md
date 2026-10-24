# D-cache store completion and deferred eviction — 2026-10-23

Started on `codex/dstore` from master `f12bb8a`. The completed timing-round-5
branch `codex/timing2` is preserved at `c188fe5`; none of its unmerged CPU
changes are included. The build uses master's stripped default, with no
debug macro. No firmware boot bench, board deployment, `sys/` changes or
ARM9 changes.

## 1. Store-miss completion: already implemented on master

The premise in the Pocket-core consult does not match this ZAP revision.
In both valid-victim and invalid-victim miss branches, `zap_dcache_fsm`
already acknowledges a checked, cacheable write-back store in IDLE. The
payload, byte enables, VA, PA and victim context are captured on that edge.
It does so **before** even launching the bus fill, and before a dirty
victim's write-back. There is no destination register to lock for a store.
`data_stall` only holds the CPU for a subsequent unacknowledged access;
it is not driven by the fill's occupancy. Hit-under-miss already permits
unrelated hit loads/stores during this transaction.

No RTL optimization is needed for item 1. Delaying its acknowledgement to
bus launch would lose cycles. The bytes merge into the registered fill
buffer; installation is exclusive. Filling/victim-line accesses, another
miss, uncached/WT operations and maintenance retain their existing ordering.
Alignment and translation faults are decided before acceptance. Cacheable
bus ERR already completes a beat without a late data abort; this task does
not change that contract. Uncached errors still fault precisely.

Added `dstore_rtl.S` and bench-only observations. The test repeats cold and
warm instruction passes, with a fixed 24-clock beat delay. It covers clean
and dirty victims, an independent 32-instruction arithmetic stream, a
load from the filling line, victim loads/stores, another miss, line clean,
line invalidate, line clean/invalidate, whole-cache clean and invalidate.
It checks merged and untouched bytes and all four victim words. Whole-cache
invalidate intentionally discards the dirty new line after the accepted
victim eviction completes. It requires at least eight instructions to
retire during the background store transaction on the warm independent
pass. A bench assertion checks every eligible store miss is acknowledged
without hold, fault or replay. Bus-event observations separately count
whether a dirty transaction begins with a fill or a write-back.

On unchanged master the directed test passes at all three latencies and
observes 188 instructions retiring during background stores at 0:0; all
18 dirty transactions begin with write-back. This verifies early completion
rather than claiming a new cycle gain. The 225 original runs pass and
57 QEMU signatures/traces agree. Only the new RTL-only test binary is built;
existing binaries and QEMU results are reused.

Item-1 verification: **228/228** runs pass (225 original plus three new),
all cycles and instruction counts unchanged by bench instrumentation;
**57 QEMU comparisons agree, 0 differ**. Generated-RTL check and stripped
lint pass; generated `input reg` count remains 10. The initial new test
uses 172,772 / 198,824 / 264,911 cycles and 15,119 instructions.

## 2. Deferred dirty write-back

The miss-accept edge already captures the entire victim data line and its
physical tag. These existing registers now serve as the write-back buffer;
no extra line RAM or 128-bit data register is added. For a dirty victim at
a different physical line, IDLE enters FETCH_SINGLE directly. The critical
load beat still writes/unlocks its destination through the registered
background path. Store bytes still merge into the fill buffer. UNLOCK_REG
installs the new line exclusively and launches beat zero of the victim
write-back from the saved registers on that same edge. CLEAN_SINGLE drains
the remaining beats. There is still exactly one outstanding cache miss;
the saved context cannot be overwritten before the drain finishes.

The write-back uses the victim's saved PA, never a new translation. A
same-physical-line synonym is an important exception: if a miss replaces
a dirty virtual tag whose saved PA equals the requested PA, reading first
would retrieve stale memory. That case retains CLEAN_SINGLE then
FETCH_SINGLE. A directed alias case verifies both directions, including
partial stores. This is not general synonym coherence: software's existing
VIVT ownership/maintenance responsibilities are unchanged.

The installed line may hit while its former victim drains. The next-slot
exclusion calculation now saves the victim-only comparison separately.
A three-edge installation visibility guard lets the existing tag/data
forwarding pipeline absorb the new line before that line becomes eligible.
The ordinary lookup-alignment repair remains a separate requirement. Both
checks feed registered `hum_slot_ff`; the ACK expression is unchanged.
Until installation the complete filling and victim lines stay excluded.
During drain, the victim/buffered line stays excluded; misses and uncached
accesses still wait for IDLE. No forwarding from the write-back buffer is
introduced. A victim load or store therefore waits for memory write-back,
then misses and refills normally. The other way of the same set remains
available throughout, as do unrelated hits in either way. Dirty/LRU updates
and byte-enable writes use the existing hit path.

CP15 clean, invalidate and line operations still enter only at actual
cache IDLE, so the buffer drains before any of them can complete. This
includes invalidate-only: an eviction already accepted by the CPU must
finish writing its old line, even when the subsequently installed line is
discarded. The explicit `c7,c10,4` drain operation now waits on a registered
`o_writeback_busy` flag, passed through the D-cache wrapper, top and core to
CP15. It adds no cycle when the flag is clear and does not clean unrelated
cache lines. All other CP15 decoding and the uncached/WT paths are unchanged.
The flag remains high from dirty-miss acceptance through the final accepted
victim write beat, including the physical-synonym fallback.

### Timing and resources by construction

There is no new pipeline stage, cache RAM, live cache-data forwarding, hit
comparison term, or operand-register data cone. The live ACK expression
and the normal hit data selection are unchanged. Added state is six bits:
a saved defer decision, write-back ownership, victim-only exclusion, a
two-bit installation delay and its sticky visibility bit. New combinational
work is the 28-bit physical-line equality at miss selection (for 16-byte
lines), a short registered HUM eligibility choice, and the installation
state's selection of saved beat-zero bus payload. The bus request adds a
registered-state/registered-ownership term. These can affect the existing
FSM-to-merger and HUM-control timing families; only the whole-core fit
below can establish their placed cost. CP15's drain consumes one registered
control flag, without adding a normal CPU stall-input term.

### Verification

The final implementation passes **228/228** default-cache runs and
**57 QEMU comparisons, 0 differences**. Every test's instruction count is
identical at each latency. Stripped lint, debug-top lint, generation and
`make cpu-gen-check` pass; generated `input reg` count is **10**.
Existing binaries/QEMU references were reused. Only the two RTL-only
directed binaries were assembled after their sources changed; no new
QEMU reference is required for their bench MMIO.

`dstore_rtl` was extended with explicit drain and same-PA synonym cases,
then rerun against the archived master netlist to obtain its matching
baseline (15,454 instructions, not the smaller item-1 program). The HUM
test's expected count for the installed filling line changes from zero to
one: it now hits during victim drain. The instruction sequence length is
unchanged. No architectural check was relaxed.

A two-state Yosys induction/equivalence check on the actual old/new FSMs
with `i_cache_tag_dirty=0` proves all 1,394 output/common-state
equivalence points agree
cycle for cycle. The no-CLEAN_SINGLE/no-pending-buffer reachability
invariants used by that comparison are proved separately from reset on
both modules, with arbitrary remaining inputs. This proof covers the
non-dirty path; it is not a whole-cache refinement proof for reordered
transactions or an X-propagation proof.

The independent bench scoreboard captures the victim PA and every byte at
miss acceptance, checks every write-back beat against that snapshot, checks
fill/install-before-write-back for distinct physical lines and the opposite
order for synonyms, prevents a second miss from replacing a pending victim,
and checks maintenance and explicit drain cannot complete early. Existing
lookup-alignment, registered/live hit equality, fault eligibility, load
lock/write/unlock and bus stability/burst checks remain enabled. The new
line is permitted only after observed installation; the victim stays
excluded. The final directed test observes 20 fill-first dirty evictions
and two write-first physical-synonym evictions.

The six directed cache tests (`dstore_rtl`, `dhold_rtl`, `dhum_rtl`,
`dcsize_rtl`, `walloc_rtl`, `dcwf`) also pass all **18/18** runs with a
16 KB two-way D-cache. This tests the changed exclusion and maintenance
behavior at the board variant's geometry. No board test or firmware boot
bench is claimed. Another **27/27** runs pass with bus latency 2:31 and
random seeds 2, 7 and 19 (`cache`, `dhold_rtl`, `dhum_rtl`, `dstore_rtl`,
`walloc_rtl`, `dcwf`, `dcwf_rtl`, `crand1`, `ctrand1`), including
`dcwf_rtl`'s existing read-error injections.

### Cycles

Latencies are 0:0 / 0:3 / 2:9. Cells are master → deferred write-back.
This table includes **every test whose count moves**, plus the unchanged
GBA proxies. All unlisted tests are cycle-identical at all three latencies.
The original 225 runs use 20,630,566 → 20,404,172 cycles (−226,394, −1.10%).
The result is a suite measurement, not a gameplay prediction.

| Test | 0:0 | 0:3 | 2:9 |
| --- | ---: | ---: | ---: |
| cache | 789,362 → 752,437 | 917,207 → 861,284 | 1,251,084 → 1,130,306 |
| crand1 | 72,922 → 72,636 | 104,399 → 104,148 | 187,183 → 186,981 |
| crand2 | 73,323 → 73,017 | 104,839 → 104,579 | 187,740 → 187,546 |
| crand3 | 73,501 → 73,082 | 105,353 → 104,977 | 188,579 → 188,125 |
| crand4 | 73,970 → 73,636 | 105,359 → 105,132 | 188,441 → 188,177 |
| crand5 | 73,371 → 73,100 | 104,835 → 104,619 | 187,959 → 187,644 |
| crand6 | 73,524 → 73,195 | 105,368 → 105,036 | 188,888 → 188,616 |
| crand7 | 73,142 → 72,768 | 104,536 → 104,251 | 187,414 → 187,058 |
| crand8 | 73,351 → 73,034 | 104,956 → 104,700 | 187,916 → 187,656 |
| ctrand1 | 72,413 → 72,379 | 102,215 → 102,177 | 178,927 → 178,836 |
| ctrand2 | 72,472 → 72,442 | 102,244 → 102,204 | 179,116 → 179,025 |
| ctrand3 | 72,444 → 72,410 | 102,238 → 102,200 | 178,962 → 178,873 |
| ctrand4 | 72,460 → 72,429 | 102,594 → 102,555 | 179,435 → 179,355 |
| ctrand5 | 72,397 → 72,363 | 102,234 → 102,181 | 178,967 → 178,877 |
| ctrand6 | 72,413 → 72,382 | 102,204 → 102,158 | 178,984 → 178,893 |
| ctrand7 | 72,261 → 72,223 | 102,055 → 102,027 | 178,832 → 178,754 |
| ctrand8 | 72,381 → 72,347 | 102,172 → 102,122 | 178,933 → 178,849 |
| dcache_rtl | 58,214 → 58,193 | 85,278 → 85,271 | 154,102 → 154,102 |
| dcsize_rtl | 111,795 → 111,795 | 145,322 → 145,327 | 237,264 → 237,271 |
| dhold_rtl | 273,742 → 273,120 | 343,931 → 342,784 | 521,056 → 518,764 |
| dhum_rtl | 483,093 → 483,052 | 509,201 → 509,160 | 575,433 → 575,392 |
| dstore_rtl | 188,428 → 188,465 | 214,528 → 214,565 | 280,595 → 280,632 |
| gba_arm | 8,183 → 8,183 | 10,785 → 10,785 | 17,742 → 17,742 |
| gba_thumb | 4,917 → 4,917 | 6,509 → 6,509 | 10,831 → 10,831 |
| icache_rtl | 58,072 → 58,050 | 85,258 → 85,236 | 154,412 → 154,390 |
| iprefetch_rtl | 73,140 → 73,127 | 104,194 → 104,171 | 184,182 → 184,176 |
| walloc_rtl | 67,402 → 67,392 | 97,006 → 97,004 | 173,816 → 173,816 |

The store-only allocation policy is unchanged: `walloc_rtl` still performs
64 cold store fills and 64 subsequent line write-backs. Its gain is tiny
because each next store uses the just-filling line. `cache` gains much more
because useful load work now starts before dirty victims drain. HUM and
hold tests still intentionally wait on blocked addresses and maintenance.
Two tests have small regressions: `dcsize_rtl` adds 5/7 clocks at variable
latencies, and `dstore_rtl` adds 37 clocks at each setting. The latter now
includes a real explicit drain instead of the old no-op; the delta also
includes the changed transaction scheduling. These are retained
and reported; neither changes instruction count or memory results.

### Limits and remaining risks

This remains a one-entry miss/eviction engine. A second miss, an uncached
access, a WT store or a TLB walk cannot overlap the pending drain. Buffered
victim accesses wait rather than forwarding from the buffer. General VIVT
synonym coherence still depends on firmware maintenance; the same-PA
replacement exception only preserves the old behavior of that replacement.
DMA visibility still requires firmware cache clean/drain; there is no snooping.
Cacheable fill/write-back ERR is still treated as completion, without a
late abort; adding precise external aborts would require another design.
Reset cancels in-flight cache work as before. The new ordering has extensive
CPU simulation coverage, but no firmware boot or gameplay validation here.
The main timing risks are the saved-victim launch mux and HUM phase control,
not a widened cache tag compare. One fit is a sanity check, not evidence
that a family improves across placement seeds.

### Whole-core timing sanity check and stopping point

The one completed whole-core fit is **−0.956 ns at slow 100C**, versus
b26's **−0.395 ns** at the same seed 2: **0.561 ns worse**. This is a timing
regression in the requested sanity check, not timing closure or a demonstrated
zero-cost change. The worst path is `zap_wb_merger.o_wb_cyc` →
`upp_bus.ack_q` (−0.956 ns; its duplicate is −0.950 ns). Other leading paths
are Thumb-valid → predecode undefined classification (−0.872 ns), D-cache
data forwarding → memory-stage load data (−0.843 ns), and D-cache FSM
`state_ff[3]` → post-ALU valid/clear control (−0.728 ns). The last path still
passes through the baseline FSM's priority logic; the separately parked
round-5 changes are not included in this branch.

| Fit metric | b26, seed 2 | dstore, seed 2 |
| --- | ---: | ---: |
| Slow 100C setup | −0.395 ns | −0.956 ns |
| Slow 100C hold | +0.249 ns | +0.250 ns |
| ALMs | 35,898 | 36,665 (+767) |
| Registers | 43,775 | 43,308 (−467) |
| M10K blocks | 487 | 487 |
| Block memory bits | 3,563,340 | 3,563,340 |
| DSP blocks | 43 | 43 |

Other setup corners: slow −40C **−0.927 ns**, fast 100C **+3.188 ns**,
fast −40C **+3.693 ns**. All four hold, recovery and removal checks are
positive; minimum hold across corners is **+0.080 ns**. The physical ALM
increase is the observed whole-fit cost, not an estimate of the six source
flip-flops and comparator. With one placement, source cost and changed
packing/routing cannot be separated. No extra M10K is consumed.

The added targeted slow-100C queries use the same fitted database:

| Family (worst matching path) | Slack |
| --- | ---: |
| Inputs to FSM state / defer / write-back ownership | 0.000 ns |
| Inputs to HUM slot / victim exclusion / visibility registers | −0.292 ns |
| Registered HUM slot → CPU pipeline | +0.786 ns |
| FSM state / write-back ownership → bus merger | −0.271 ns |
| Saved victim data/tag → bus merger | +1.777 ns |
| Write-back ownership → CP15 | +3.162 ns |
| Background load index → shifter/ALU | −0.577 ns |
| Cache tag/data RAM → memory stage | −0.843 ns |

The HUM-input query starts at the victim LRU register and ends at
`hum_slot_ff`; the bus-control query starts at IDLE's state bit and ends
at the merger's write enable. Thus the new snapshot and CP15 drain do not
create the worst paths in this placement, but the existing cache-control
and cache-data timing families still need attention. This is not a paired
seed comparison, and no timing improvement is claimed.

Build: `BUILD_DIR=dev/mister/NGage_MiSTer-dstore ./build.sh remote compile`
from isolated worktree `NGage_MiSTer-dstore-fit`, source **`d94d4b2`**, on
Ubuntu only. QSF seed is 2; `NGAGE_DEBUG` remains commented, with no obsolete
`NGAGE_NO_DEBUG` override. All **153** audited HDL/project inputs match the
source commit, allowing only Quartus's version metadata rewrite in QSF.
The final build ID is `261023`, matching b26. An initial synthesis was
stopped before fitting because the server's UTC date generated `261024`;
its generated database was removed and the same source/seed restarted with
`TZ=America/Detroit`. No completed fit or seed was discarded. A lane check
preceded each container phase; only one task-owned Quartus container ran at
a time, and the total stayed below four. All task-owned containers exited.
The report script's negative-timing exit was expected and the reports/RBF
were copied back successfully.

Local evidence: `build/dstore/baseline`, `final`, `d16`, `stress`, `proof`,
`b26-timing`, and `fit`; the fit directory contains the full critical paths,
corner checks, targeted families, fit summary/report and `NGage.rbf`.
RBF SHA-256:
`2bddf0018c0cf6cec2db15315ecc1ac2ce7c126484d78ca199032e3800577eed`.

**Exact stopping point:** item 1 is verified as already present; item 2 is
implemented and committed, with all functional verification above complete.
Stopped after the single requested fit, retaining the functional change
and reporting its worse timing. No closure sweep, board deployment or
firmware boot bench was run. `codex/timing2` remains exactly at `c188fe5`;
all this task's work is on `codex/dstore`. The next steps belong to the
integration/board work: measure gameplay, then revalidate the combined tree
when the parked timing changes are merged. The 0.561 ns sanity-check
regression must remain visible in that decision.
