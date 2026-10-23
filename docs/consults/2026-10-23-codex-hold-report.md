# D-cache fill hold report

Implemented on `codex/hold`, against baseline `8831aa6`. The report uses the
requested 2026-10-23 filename; the work was performed on 2026-10-22.

A younger data access now waits for the current line fill and is served from
IDLE, without a writeback replay. The original miss still acknowledges early;
loads still lock their destination and write it through UNLOCK_WR. The
separate IDLE/TLB-busy replay is unchanged.

## Why deleting the four responses failed

There are three independent correctness requirements, plus replacement-state
bookkeeping:

1. **The cache lookup pipeline must be restored, not just delayed.** The tag
   comparison uses the memory request's `i_address`, but the three-stage tag
   and data RAMs read `i_address_nxt`, which comes from the ALU, three stages
   earlier. The D-cache's external `i_stall` is tied to zero in `zap_top`.
   Consequently, withholding acknowledgment holds the CPU's post-ALU stages
   while the RAMs keep reading the stationary, younger ALU address. They lose
   the held lookup and both younger lookups. A settle state that keeps reading
   that address cannot repair this. Separately, a pre-fill snapshot can contain
   the old victim tag/data or an invalid tag for the newly filled line.
2. **The TLB must stay aligned too.** Its RAMs and registered permission check
   otherwise advance on the younger address while the CPU waits. Holding only
   the cache request does not preserve the translation/cacheability/fault that
   belongs to it.
3. **UNLOCK_REG contains a fifth acknowledgment.** Its store-miss branch sets
   `o_ack = 1`, even though the original store was already acknowledged in
   IDLE. After removing the replay responses, this acknowledges the younger
   waiting operation without performing it. That acknowledgment is removed.
4. **Stale comparisons must not update LRU.** The wrapper now qualifies the
   tag RAM's `i_access` with the FSM's registered `idle`; a held access becomes
   a use only when it is actually served with a valid lookup.

For a negative control, a temporary source copy under `/tmp/hold-naive` was
regenerated with exactly the four-response deletion, leaving the extra store
acknowledgment intact. `dcache_rtl` failed at all three latencies (check 2), and
`icache_rtl`, `ctrand1`, and `crand1` did not reach a successful result before
the diagnostic five-million-cycle limit. The new `dhold_rtl` failed at check
878 at every latency. No diagnostic RTL was retained in this worktree.

The `zap_hit_under_miss` macro in `zap_defines.svh` already sets both hits to
zero. Its comment explains that upstream's cache-disabled condition could
never hit a valid line. This change removes the dead D-cache call sites and
`rhit`/`whit` variables; it does not re-enable hit-under-miss.

## Implementation and cycle alignment

Only `zap_dcache_fsm.sv` and `zap_dcache.sv` change in the RTL sources.
`zap_cache_tag_ram.sv`, the I-cache FSM, issue/memory stages, bus merger and
all of `sys/` are unchanged.

- CLEAN_SINGLE, FETCH_SINGLE, UNLOCK_REG and UNLOCK_WR leave acknowledgment
  and replay deasserted for younger operations. The existing fill write,
  dirty-victim writeback, original store merge and background-register write
  run normally.
- The wrapper saves the set indices of the two younger post-ALU lookups.
  These advance with the CPU, on cycles without a pending unacknowledged
  access. The current held address already lives in the CPU and needs no
  duplicate request buffer.
- If an access is present when the fill completes, the FSM enters three
  one-hot states, RELOOKUP0/1/2. They feed the cache RAMs the held request's
  set, the nearest younger set, then the next younger set. No tag/data write,
  acknowledgment, replay or LRU hit update occurs in these states.
- When IDLE is reached, the held lookup is at the RAM output and the younger
  two are in flight in their original order. Normal reads from the ALU resume
  immediately. A hit can acknowledge normally; a miss captures the correct
  victim and starts the next fill.
- The TLB's existing hold input additionally asserts during fill/relookup
  states when a CPU data request is present. The tag/data RAMs remain enabled
  so writes and recovery reads can complete. The TLB's existing uncached hold
  behavior and IDLE busy response remain in place.
- Without a younger access at completion, the FSM returns directly to IDLE.
  There was no data stall to disturb the RAM pipeline, so recovery is skipped.

The three recovery edges are:

| Edge ending state | Cache RAM stage 1 | Stage 2 | Output used next cycle |
|---|---|---|---|
| RELOOKUP0 | held request | irrelevant | irrelevant |
| RELOOKUP1 | nearest younger | held request | irrelevant |
| RELOOKUP2 | next younger | nearest younger | held request |

All fill writes precede RELOOKUP0, including the existing UNLOCK_REG store
write. This avoids depending on old read snapshots or a particular collision
forwarding case. Keeping `idle` low until recovery completes also preserves
`wr_sel`: fills write the captured way, whereas a held store serviced in IDLE
writes only the newly determined hit way.

## Cases considered

| Case | Handling and evidence |
|---|---|
| Held load to the just-filled line | Fresh tag and data in IDLE; normal load formatting. Directed same-line case uses another word in the line. |
| Held load to the evicted victim | Fresh tag makes it miss; dirty data has already been written back. Directed B/C conflict case. |
| Held hit in the surviving way or another set | Fresh lookup selects that hit, with no refill. Directed A/D cases. |
| Held miss to another set | Starts a second normal background fill after recovery. Directed E case. |
| Held cached store | Waits without acknowledgment; hit uses IDLE hit-way selection; miss uses the existing write-allocate path. Directed stores to all five cached targets. |
| Original operation is a store miss | No second acknowledgment in UNLOCK_REG; original store data remains in the filled line. Every directed target also runs behind a store miss. |
| Uncached load or store | Translation/cacheability is held; IDLE enters the existing uncached prepare/bus/completion path. Directed aliases of victim, fill line and other line. |
| Write-through store | Preserved TLB WT attribute and fresh hit/dirty result feed the existing uncached write/update path. Existing `cache` test covers write-through; no new WT-specific overlap case. |
| Store of the locked load destination | Cannot issue while that source is locked: `determine_load_lock` checks the per-register xlock and the ordinary in-flight load hazards. UNLOCK_WR still writes before clearing the lock. Directed dependent load/store checks the new value. |
| Two younger memory operations behind the held request | Their set indices are restored, not overwritten by repeated reads of the held address. Both immediate followers in the directed pairs read different sets. |
| Translation, permission, alignment or external abort | No fabricated fault while waiting. The held TLB check and existing IDLE priority determine the result; external errors follow UNC_DONE. Directed translation and external aborts; existing `mmu_page`, `align`, and exception tests cover the broader fault rules. |
| IRQ/FIQ while waiting | Existing pipeline data-stall and exception/locked-register interlocks remain authoritative. Recovery has no architectural side effects. Existing IRQ/FIQ suite passes; there is no new exhaustive interrupt-at-every-fill-cycle sweep. |
| Pipeline cancellation/reset | No autonomous buffer of the younger request is created; IDLE acts on the live CPU request. Reset clears the FSM, locks and saved indices. Existing writeback clear invalidates younger pipeline requests before they can be acted on; harmless recovery reads do not commit them. |
| CP15 maintenance/cache disable | The existing pipeline drain, including outstanding load locks, is unchanged. Maintenance still starts only in IDLE without a CPU access. Existing cache maintenance tests pass. |
| Burst errors, load formats, endian modes | Existing fill/error handling and transforms are untouched. This work does not redefine cacheable burst-error behavior. Default little-endian ARM925T is tested; no new big-endian configuration sweep. |

## Directed test and observed overlap

`sim/cpu/tests/dhold_rtl.S` contains 192 combinations: distances 1–6,
background load/store, younger load/store, and eight cached/uncached target
choices. Each runs twice to include warm instruction lines. It also checks a
dependent store and translation/external aborts. It uses ordinary coherent
values, so the installed patched QEMU can run the same test. Eight checkpoints
and the full instruction trace agree with QEMU (41,082 trace entries; the bench
reports 41,081 retired instructions).

At latency `2:9`, the detailed `--dcdbg` trace shows 334 continuous fill-hold
episodes: 272 starting in CLEAN_SINGLE and 62 in FETCH_SINGLE. Held clocks
include 9,011 in CLEAN_SINGLE, 14,933 in FETCH_SINGLE, 334 in UNLOCK_REG,
84 in UNLOCK_WR and 334 in each recovery state. Mapping acknowledged held
accesses back to the disassembly finds target operations at every requested
distance: 64 at distance 1 and 32 each at distances 2–6. There are zero address,
read/write-direction or store-data changes while an active request waits for
acknowledgment. Every observed replay in this trace occurs in IDLE (TLB busy),
none in the fill or recovery states.

## Cycle and replay results

Latencies are the bench's `0:0`, `0:3`, `2:9`, in that order. Cells show baseline
→ hold. The original binaries and QEMU references were reused. All 27 smoke
runs have identical instruction counts before and after.

| Test | Cycles 0:0 | Cycles 0:3 | Cycles 2:9 | Instructions per run |
|---|---|---|---|---|
| cache | 903,967 → 867,422 | 1,021,476 → 988,167 | 1,346,786 → 1,317,608 | 293,427 |
| ctrand1 | 89,133 → 86,538 | 114,728 → 113,046 | 192,788 → 190,431 | 16,159 |
| crand1 | 90,706 → 87,757 | 118,251 → 115,709 | 202,059 → 198,487 | 15,982 |
| dcache_rtl | 71,448 → 70,791 | 93,933 → 93,008 | 160,178 → 158,877 | 12,771 |
| icache_rtl | 71,090 → 70,677 | 93,587 → 93,201 | 160,385 → 159,731 | 12,771 |
| gba_arm | 8,334 → 8,334 | 10,955 → 10,955 | 17,752 → 17,752 | 1,192 |
| gba_thumb | 4,935 → 4,935 | 6,552 → 6,552 | 10,900 → 10,900 | 774 |
| mmu_page | 93,545 → 93,545 | 123,102 → 123,102 | 209,451 → 209,451 | 16,887 |
| align | 5,543 → 5,543 | 7,064 → 7,064 | 11,440 → 11,440 | 549 |
| dhold_rtl (new) | 311,302 → 308,862 | 375,460 → 373,055 | 558,244 → 554,698 | 41,081 |

`main.cpp` now counts `p_dabt & 2` before each rising edge and prints it before
the existing PASS line. The baseline RTL was rebuilt separately with this same
instrumentation; its cycle counts match the saved, uninstrumented baseline.

| Test | Replays 0:0 | Replays 0:3 | Replays 2:9 |
|---|---|---|---|
| cache | 3,666 → 22 | 6,143 → 22 | 13,105 → 23 |
| ctrand1 | 242 → 7 | 267 → 7 | 500 → 7 |
| crand1 | 270 → 7 | 334 → 7 | 515 → 8 |
| dcache_rtl | 49 → 19 | 49 → 19 | 49 → 19 |
| dhold_rtl | 4,360 → 3,884 | 4,542 → 3,884 | 4,967 → 3,888 |

The cache workload improves by 4.04%, 3.26%, and 2.17%. Eliminated replays are
not a count of saved 14-cycle intervals: repeated retries overlap the same
fill, and holding now pays the remaining fill latency plus three recovery
cycles. The directed test deliberately repeats maintenance and conflicting
TLB aliases, so its remaining TLB replays dominate.

## Validation and limits

- Before edits: requested nine-test baseline, **27 passed, 0 failed**.
- After RTL change: same nine tests, **27 passed, 0 failed**.
- The first whole-set `diff` could not compare 44 tests because this fresh
  worktree lacked their RTL traces. The full run populated them; this was
  missing output, not a successful architectural comparison.
- Existing whole suite: **177 passed, 0 failed**.
- Final suite with the new test: **180 passed, 0 failed**.
- Final QEMU comparison: **50 agree, 0 differ**, including all original 49
  and the new test, with its full instruction trace.
- `make lint`: passed, warnings treated as errors.
- `tools/gen_cpu.sh` and `make cpu-gen-check`: generated netlist is current.
  Comparing generated modules by name finds only `zap_dcache` and
  `zap_dcache_fsm` changed; the large textual diff also contains module-order
  changes from sv2v.
- Existing test binaries were not rebuilt, and existing QEMU references
  were not rerun. Only `bins T=dhold_rtl` and `qemu T=dhold_rtl` built the new test/reference.

No firmware boot comparison, Quartus fit/timing run, or physical MiSTer run was
performed. The prepared boot images/reference logs are absent from this
worktree; the default boot recipe also writes a shared remote build directory,
which was not used while other engineers work in parallel. The 76,975-device-
access comparison is therefore still required before hardware acceptance.

The hardware cost is two 8-bit set-index registers and three one-hot FSM bits
in the configured two-way 8 KB cache, plus small control/read-address muxes.
There is no new RAM and no pipeline stage between issue and memory. The tag
compare, load-data selection/formatting, and Wishbone data paths are unchanged.
This is a source-level cost estimate, not a fitted utilization result.

Timing risks are the new mux before the RAM address register, the enable on
the 16 saved-index flops (which uses acknowledgment), TLB hold fanout, and the
LRU access qualifier. The default top ties external D-cache `i_stall` low; this
work does not claim recovery sequencing for a separately configured top that
asserts that input. Functional risks worth further testing are cancellation
at each recovery edge, arbitrary interrupt placement, and held WT/partial
stores under unusual aliasing. Three recovery cycles are intentionally used
to restore every RAM stage rather than speculating about forwarding latency.

Next: run the prepared firmware/device-order comparison in an isolated build
directory, screen Quartus at 104 MHz and compare whole-core seeds, then measure
matched game segments and separate fill replays from TLB replays on hardware.
Any attempt to overlap recovery with UNLOCK_REG/UNLOCK_WR should follow those
checks and retain restoration of both younger lookups.

## Commit handoff

The implementation and verification above are complete, but the commit could
not be created in this execution environment. `git add` was rejected with:

```
fatal: Unable to create '/Users/jacob/dev/fpga/mister/NGage_MiSTer/.git/worktrees/NGage_MiSTer-cx-hold/index.lock': Operation not permitted
```

The worktree's Git metadata is outside the sandbox's writable roots and
permission escalation is disabled. No branch was switched and nothing was
pushed. Changes remain in the working tree. The prepared commit message is
`/tmp/hold-commit-message.txt`; it includes the mechanism and all required
cache/ctrand1/crand1 cycle counts. From an environment allowed to write this
worktree's Git metadata, the remaining step is:

```sh
git add rtl/cpu/zap/zap_dcache_fsm.sv rtl/cpu/zap/zap_dcache.sv \
  rtl/cpu/arm925t_gen.v sim/cpu/tests/dhold_rtl.S sim/cpu/tb/main.cpp \
  docs/consults/2026-10-23-codex-hold-report.md
git commit -F /tmp/hold-commit-message.txt
```
