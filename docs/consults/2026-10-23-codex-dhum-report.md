# ZAP D-cache hit-under-miss — 2026-10-23

Implemented on `codex/timing2`, starting at `8f267c2` (the merged stall
session and flash line-wide fetch). No firmware boot bench was run.
No changes to `sys/` or `rtl/cpu/arm9`.

## Design implemented

The single background miss retains its saved address, physical address,
victim tag, way, dirty line, store bytes and load destination. Independent
cache hits use the ordinary registered tag/data lookup and hit-way write
selection while that transaction runs. A hit never overwrites the saved
miss context or starts another bus transaction.

`hum_slot_ff` is a registered eligibility predicate for CLEAN_SINGLE,
FETCH_SINGLE and UNLOCK_WR. Its input combines the next FSM state, lookup
alignment and line exclusions. The address comparisons run one stage ahead
on `i_address_check`, with their result held when the CPU stalls. On miss
acceptance they use the live miss/victim; subsequently they use the saved
context. They exclude the complete filling line and the valid victim line,
not their whole set: the other way in the same set remains accessible.

The background-hit tag match is registered alongside the RAM's third
lookup stage, using the second-stage forwarded tag and the pending valid
bit update. Both the next CPU address and the held address are compared
before the one-bit stall selection. This removes the live tag compare
from the high-fanout CPU data-stall path. The normal live compare still
selects load data and the write way. A bench assertion checks equality of
the registered and live matches in every eligible background slot.

This early comparison deliberately needs no forwarding of the **current**
RAM write into its tag check: a current hit write preserves tag identity
and validity; a fill can change only the filling/victim lines, both
excluded from background hits; maintenance has no eligible slot. Prior
writes are covered by the RAM's stage-two forwarding and the pending-valid
bypass. A store is enabled only if the registered hit is acknowledged.
The shared I-cache instance leaves this new result unused.

The TLB check now also registers `o_hit_ok` beside its existing outputs.
It means translation present, no permission/domain/translation fault,
cacheable, and not a write-through store. It is independent of the TLB
walker's cache-IDLE qualification. That distinction is essential: the
existing walker suppresses `o_fault` when the cache is not IDLE. Testing
only that fault output would let a cached tag bypass a permission fault.
The walker still waits for actual cache IDLE. TLB reads/checks advance with
an acknowledged background hit and freeze with a held access.

The cache RAMs have three lookup stages and continue running during fills.
After a CPU hold, their output no longer describes the held request.
A three-bit repair sequence reloads the held set, then the two saved younger
sets. A registered alignment flag prevents acknowledgements during that
repair. This can run while the bus fill is still active. The existing
end-of-fill restore has priority. Its selection, and the live/background
RAM payload selection, are registered from their next-state values with
retiming disabled. They have the same cycle behavior as the decoded states
without putting another control mux ahead of the RAM set-address mux. UNLOCK_WR returns directly to IDLE when
it acknowledges a hit; otherwise a restore could incorrectly treat an
advancing pipeline slot as a held request. The first implementation exposed
that bug in `dhold_rtl` at latency 0:3; the corrected transition passes the
suite and the additional bus-delay seeds.

The full line and tag are installed in UNLOCK_REG, using the registered
fill buffer, one edge after the final beat. That state owns the cache RAM
write port and withholds younger accesses. Stores allocated on a miss are
already merged byte by byte into that buffer; the former repeated store
write is unnecessary. The intermediate write that cleared the victim's
dirty bit at the end of CLEAN_SINGLE is also unnecessary: the victim is
reserved until replacement and maintenance cannot inspect it meanwhile.
Removing those two bus-completion-qualified writes makes RAM ownership a
registered-state decision. Bus ACK does not choose between a hit write and
a fill write.

The unchanged tag RAM updates dirty state and LRU for acknowledged hits.
The wrapper selects hit ways in a live slot and the saved way for fill/WT
completion. A store miss cannot accidentally write the victim: live store
enables are still qualified per way by the tag RAM's hit. Fill installation
updates replacement state in the same way as an ordinary completed fill.
The background load's critical-beat write and register lock/unlock timing
are unchanged. The register file already has a separate background write
port; the existing issue locks protect RAW/WAW dependencies.

## Cases and ordering

| Case | Handling |
| --- | --- |
| Load hit in either way, different line | Acknowledge from the registered lookup; normal load formatting and memory-stage register. |
| Write-back store hit, including partial stores | Normal byte enables, hit-way write, dirty and LRU update. |
| Other way in the filling set | Allowed; the saved victim way is reserved, not the entire set. |
| Filling line, including another word | Held until installation and lookup restoration. No partial-line hit or second fill. |
| Victim line, clean or dirty | Held; it cannot be read or modified while being replaced or written back. |
| Another miss | Held; still one outstanding allocation. |
| Uncached access or write-through store | Held until IDLE, then the existing uncached/`wt_hit` completion path. |
| TLB miss, cached permission/domain fault, alignment fault | Held until IDLE; existing replay/walk or precise abort handling then applies. |
| Fill's line/tag write | UNLOCK_REG has exclusive ownership; the hit waits and lookups are repaired. |
| Fill's critical load-register write | Independent RF port; original mask, formatted value and lock protocol retained. |
| CP15 clean/invalidate/line operation | Existing request remains pending until actual IDLE; HUM does not acknowledge maintenance. |
| Interrupted/flushed pipeline or younger blocked access | CPU request gating and fault squash remain unchanged; the fill continues and saved context survives. |

An acknowledged cacheable miss has already passed alignment and MMU
checks. The pre-existing cacheable bus-error contract consumes returned
data on ERR and does **not** generate a late abort, even after critical-word
restart. Consequently it is safe, under that existing contract, to let a
younger store hit proceed behind it. This change does not introduce precise
cacheable external aborts. Uncached accesses and TLB walks can still fault;
they are never background-hit slots. A younger fault behind a fill waits,
and the existing post-ALU fault squash kills a following store before its
memory request. The directed test deliberately skips that store on exception
return and verifies that it never changed memory.

## Verification and cycles

Before editing, the six requested tests passed at all three latencies
(18/18). Baseline logs, counts, generated RTL and executable are retained
locally under `sim/cpu/build/dhum/baseline/`. Existing test binaries and QEMU
references were not rebuilt or rerun.

Cycles are before → after; each of these six tests has the same instruction
count before and after, at all three latencies.

| Test | Instructions | 0:0 | 0:3 | 2:9 |
| --- | ---: | ---: | ---: | ---: |
| cache | 293,427 | 789,368 → 789,362 | 917,253 → 917,207 | 1,251,084 → 1,251,084 |
| dcache_rtl | 12,771 | 58,226 → 58,214 | 85,307 → 85,278 | 154,102 → 154,102 |
| dhold_rtl | 41,081 | 275,005 → 273,742 | 346,608 → 343,931 | 529,669 → 521,056 |
| dcwf | 15,336 | 74,408 → 74,403 | 105,986 → 105,986 | 188,165 → 188,165 |
| ctrand1 | 16,159 | 73,043 → 72,413 | 102,937 → 102,215 | 179,631 → 178,927 |
| crand1 | 15,982 | 73,935 → 72,922 | 105,359 → 104,399 | 187,907 → 187,183 |

`cache` is almost unchanged because its accesses largely use the filling
line or otherwise serialize. The compiled proxies improve by 0.39–1.37%;
`dhold_rtl` improves by 0.46–1.63%. These are simulation results, not measured
game CPI or frame rates.

The observed background hit counts are loads/stores. They count actual
request acknowledgements during the background states, not eligibility.

| Test | 0:0 | 0:3 | 2:9 |
| --- | ---: | ---: | ---: |
| cache | 5/0 | 5/1 | 5/1 |
| dcache_rtl | 3/0 | 3/0 | 3/0 |
| dhold_rtl | 290/30 | 385/438 | 807/819 |
| dcwf | 1/0 | 1/0 | 1/0 |
| ctrand1 | 64/0 | 65/64 | 65/64 |
| crand1 | 126/6 | 137/92 | 151/103 |

`dhum_rtl.S` is RTL-only because it uses bench cycle, latency and observed-hit
counters. The same test binary, run on the archived baseline netlist with
the new bench instrumentation, fails check 2: zero observed background hits
where one is required. It uses fixed 24-clock bus latency during its directed region,
with the requested three latency presets still covering setup/teardown.
Each distance 1–6 is tested for loads and stores to: the other way in the
filling set, both ways of a second set, the filling line, and the victim.
Every warm allowed case must produce exactly one observed background hit;
every excluded case must produce zero. Values are checked exactly, including
writeback through uncached aliases; the interval has a loose 768-cycle
upper bound. It also tests a partial store allocation with a stream of byte
and halfword hit stores/reads across fill completion, a cached domain abort
with a younger store, an unmapped TLB miss, an uncached external abort and
a write-through hit.

Measured warm request-to-acknowledge **wait clocks** in the directed trace
at preset 0:0 (loads and stores give the same rows):

| Instruction distance | Other way, same set | Other set, way 0 | Other set, way 1 | Filling line | Victim |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 0 | 0 | 0 | 207 | 207 |
| 2 | 0 | 0 | 0 | 74 | 74 |
| 3 | 0 | 0 | 0 | 73 | 73 |
| 4 | 0 | 0 | 0 | 72 | 72 |
| 5 | 0 | 0 | 0 | 71 | 71 |
| 6 | 0 | 0 | 0 | 70 | 70 |

These are clocks after the request reaches the cache, not a promise about
instruction issue spacing: fetch availability and the remaining burst beats
change how much of the fill is left when it arrives.

New directed-test totals: 0:0: 483,093 cycles, 0:3: 509,201 cycles, 2:9: 575,433 cycles; 24,632 instructions at each preset.

The bench additionally checks actual RAM lookup alignment, exclusion of the
filling and victim lines, permission/translation qualification, early/live tag-match equality, fill-write
exclusivity and the live write address. Existing critical-word-first
assertions still check exactly one correctly timed background write and
lock release. Forty extra runs used bus delays 0:16 with seeds 1–8 on
`dhold_rtl`, `dhum_rtl`, `crand1`, `ctrand1` and `loaduse_irq`; all passed.
The 24 QEMU-compatible runs also matched their existing signatures and
instruction traces.

Final full suite after the last directed-test additions: **216 passed,
0 failed**. The comparison reported **RTL vs QEMU: 57 agree, 0 differ**.
`make lint` and `make cpu-gen-check` pass. Replay counts on all six proxies
are unchanged. The 36 warm independent-hit cases complete during actual
CLEAN_SINGLE (6) or FETCH_SINGLE (30), rather than merely in the finish state.

## Whole-core timing

Whole-core builds run on `ubuntu`, isolated directory
`dev/mister/NGage_MiSTer-dhum`, using
`BUILD_DIR=dev/mister/NGage_MiSTer-dhum ./build.sh remote compile`.
Container counts were checked before each launch (one existing Quartus
container before attempt 1, none before attempt 2); the four-container
limit was respected. No local Quartus process was used. Acceptance is
slow-100C setup slack at least −0.878 ns, relative to the supplied baseline
of −0.578 ns.

| Attempt | Slow 100C setup | Worst path / response |
| --- | ---: | --- |
| 1 | −1.392 ns | D-cache `state_ff[12]` → tag RAM `valid_s1[1]`, 10.247 ns data delay and seven logic levels. Failed acceptance. Registered the lookup-repair selection and live RAM selection. Also removed the live tag compare from background ACK: it appeared in the sixth-worst path into decode's enable. |
| 2 | **−0.858 ns** | CP15 `o_mmu_en` → D-cache FSM `o_live_lookup`: 9.742 ns data delay, five logic levels, −0.431 ns clock skew. Accepted: 0.280 ns below the −0.578 ns baseline, within the allowed 0.300 ns regression. Targeted, full, QEMU and stress runs retain exactly the same cycles. |

Attempt 1 used 35,810 ALMs, 43,743 registers, 470 RAM blocks and 43 DSPs.
Its slow −40C setup slack was −1.449 ns; hold slack was positive in all
corners. Reports are retained locally under `build/dhum/attempt1/`.

The generated RTL SHA-256 for attempt 2 is
`8c7117af2dfbbf85a8bf2275e900d82005818fdca26a7df541cf8f0a403c118c`.
The server copy matches this hash. The final fit uses **35,056 ALMs,
44,006 registers, 470 RAM blocks and 43 DSPs**, with 3,429,273 block-memory
bits. Slow −40C setup is −0.608 ns; fast 100C/−40C setup is
+2.880/+3.605 ns. Hold slack is positive in all corners (+0.233/+0.195/
+0.127/+0.111 ns in slow 100C, slow −40C, fast 100C, fast −40C order).

Whole-core reports are retained locally in `build/dhum/wholecore/`, including
`critical-paths.rpt`, `timing-corners.tsv`, `NGage.fit.summary` and
`NGage.sta.summary`; the compile log is alongside them. Full compilation
completed successfully. The custom timing script exits 3 for any negative
slack: this result meets the requested regression budget, **not** positive
104 MHz setup closure. Only 0.020 ns remains inside that budget. The job's
containers were automatically removed; other engineers' jobs were left
running.

## Risks, limits and stopping point

The high-risk cases are stale lookup data after a hold, a hit modifying the
reserved victim, concurrent RAM writes, and a permission fault hidden by
walker qualification. The register boundaries, exclusive fill-write state
and directed/bench checks above address those cases. Timing risks are the
new live-slot fanout into RAM payload selection and acknowledge-controlled
TLB enables. No cache live data was added to CPU forwarding; operand clock
enables and the issue/ALU datapaths are unchanged. No extra cache RAM or
second miss buffer was added.

This remains one miss at a time. It does not merge accesses into a filling
line, support uncached-under-miss, perform a concurrent TLB walk, or change
the cacheable bus-error contract. Line exclusions use the virtual tags,
as the existing virtually tagged cache does; this does not add cacheable
synonym coherence. The exclusive install slot can still
cause the existing end-of-fill restore delay; ordinary aligned hit streams
during CLEAN_SINGLE/FETCH_SINGLE require no additional cycles. The directed
coverage is for the configured 8 KB, two-way, 16-byte-line D-cache. It is not
an exhaustive formal proof over every parameterization or asynchronous
interrupt timing.

Stopping point: hit-under-miss, its registered acknowledge/control paths,
the directed test, full verification and the whole-core timing check are
complete. No additional cache pipeline, second miss, prefetch or CPU
interlock work is included. Next hardware work is to measure the same
games' data-stall, bus-wait and CPI counters. The proxies suggest a modest
pipeline gain; they do not establish how often the games access unrelated
resident lines during a fill.
