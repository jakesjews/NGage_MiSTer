# I-cache early restart, 2026-10-23

Implemented on `codex/icache`, starting from `8831aa6`. Linear instruction-line
fills now return available words through a registered bypass, without waiting
for installation and a new tag lookup. Following fetches in that virtual line
use the same buffer, including the two Thumb instructions in a word.

To preserve precise prefetch aborts on **any** beat, these early responses are
provisional: they can enter the fetch register and FIFO, but cannot leave the
FIFO until the entire fill succeeds. This overlaps front-end delivery with the
remaining bus beats; it does **not** execute instructions before the last beat.
The required error semantics prevent unrestricted execution before completion
without a much larger rollback mechanism or a bus guarantee that later errors
are impossible. The implementation does not assume such a guarantee.

At `2:9`, `ctrand1` improves 192,788 -> 187,013 cycles (3.00%) and `crand1`
202,059 -> 197,091 (2.46%). `cache` is effectively unchanged, 1,346,786 ->
1,346,715. Its lower-latency runs regress by 110 and 521 cycles (0.012% and
0.051%). These are simulation measurements, not game or hardware results.

## Implementation and scope

- `zap_cache_fsm.sv`: hold a miss instead of repeatedly replaying its PC. Track
  valid words and a sticky error while retaining the four-beat, word-zero-first
  linear bus sequence. Select the current lookup while stalled or the next
  lookup while advancing, and register its buffer word and availability. Reuse
  the old uncacheable-response data register, so the hit data path still has
  one selection between the registered slow response and the hit ways' word.
- After the last beat, `FILL_COMPLETE` resolves provisional responses. A
  successful line is installed in the originally selected way when the RAM
  clock enable permits it. A ready current word can still be answered directly;
  otherwise only the current unanswered lookup is replayed to refresh the
  pipelined RAM/TLB lookup. Faulted lines are never installed.
- `zap_fetch_main.sv` carries a provisional bit with its held output. A late
  error is retained even if FIFO backpressure holds that output during
  completion.
- `zap_fifo.sv` uses a pending bit and a fault bit per existing FIFO slot, with
  small pointers following the payload FIFO's accepted reads/writes. Older
  validated instructions continue to drain. A pending head produces no valid
  output until completion. Success clears pending bits; failure converts them
  to abort metadata. No payload RAM was added or enlarged.
- `zap_cache.sv`, `zap_top.sv`, and `zap_core.sv` carry the three internal
  pending/done/fault signals. The core merges the registered FIFO fault into
  the existing instruction-abort flag. Faulted payloads are changed to harmless
  ARM/Thumb encodings at the Thumb decoder input, preserving PC and abort.
  Otherwise arbitrary failed-bus data can cause an UNDEFINED/SWI/CP15 decode
  before the prefetch abort reaches writeback. This was observed in the new
  Thumb fault test; the architectural exception must be the prefetch abort.
- `arm925t_gen.v` was regenerated with `tools/gen_cpu.sh`. Its large textual
  diff includes sv2v-generated declaration/name reordering.
- Added `icache_restart.S`, a repeatable read-error injection option in the CPU
  harness, and a separate cycle-level testbench/runner.

The fetch/FIFO interface extension is necessary for precise late errors. No
issue, shifter, ALU, post-ALU, memory, writeback, D-cache FSM, tag RAM, external
bus, or `sys/` source was edited. There are no added pipeline stages between
issue and memory. `instr_valid`, `code_stall`, and the existing FIFO write
inhibit equations are unchanged.

## Cases and rules

| Case | Handling |
| --- | --- |
| Requested beat has not arrived | No fetch acknowledgement; hold the lookup. |
| Requested beat arrives | Data and availability are registered; answer in the following cycle. |
| Following sequential ARM word | Select its own valid bit; hold until its beat arrives. |
| Consecutive Thumb halfwords | Reuse the same buffered 32-bit word; the fetch stage selects its halfword as before. |
| Requested word is the last beat | Answer in `FILL_COMPLETE`; no pre-completion response is possible. |
| Word zero or any later beat errors | Sticky OR across the entire fill, even when earlier words have been delivered. Continue/drain the four-beat bus transaction and do not install the line. |
| Early word queued before a later error | Pending FIFO entries become prefetch aborts before they can execute. The oldest surviving entry determines the architectural fault PC. |
| Error before any early word is delivered | Answer the held same-line fetch with the normal ACK+ERR contract at completion. |
| Error while fetch output is held | Preserve its fault until it is queued or a redirect clears it. |
| Error payload looks like another instruction/exception | Sanitize the aborting decoder input; PC and prefetch-abort metadata are preserved. |
| Two fills while older words remain queued | Completion clears pending metadata in place; a later failure cannot poison already validated entries from the preceding fill. |
| FIFO full | The bus continues. Completion releases pending entries even if installation must wait for the RAM clock enable. |
| CP15 invalidate/clean while FIFO full | Discard this clean incoming I-line and return to IDLE to service the fence. Waiting for FIFO space here deadlocks because decode is waiting for CP15. An invalidate would discard the incoming line anyway; dropping a clean read allocation on clean is also harmless. |
| Redirect within current line | Serve the new lookup only when its own beat is available and the live MMU check permits it. |
| Redirect outside current line | Finish the bus fill in the background, then replay/service the unanswered new lookup normally. Never return the old line's word for the new address. |
| Redirect discards provisional words | Normal clear priority discards payload and provisional/error metadata together. An error in a discarded wrong-path fill does not abort unrelated new-path code. |
| MMU fault, busy, permission/mode change, cache disabled | No early bypass unless the live lookup is cacheable, enabled, not busy and not faulted. Normal IDLE handling follows completion/replay. |
| Invalidate/clean arrives during fill | Stop early replies, drain the bus, resolve provisional entries, service the operation. Existing CP15 serialization and pipeline-clear behavior remain in place. |
| Reset during fill | Reset bus/state, clear valid/error/provisional metadata. |
| Uncacheable access | Existing registered `UNC_DONE` response and error handling, with its data register shared with the fill bypass. |
| Generic cache write inputs | Never early-ack a write; retain buffered byte merging. The instantiated instruction cache ties writes and dirty victims off. |

The starting checkout did **not** implement the stated fill-error contract:
`FETCH_SINGLE` treated ERR as a returned beat, never raised `o_err`, and could
install the failed data. This change implements the requested precise contract
rather than preserving that defect. All 49 existing QEMU comparisons still agree.

## Wrapped bursts: deliberately not implemented

`rtl/mem/sdram.sv` already returns the requested word first within a 16-byte
block. `rtl/upp/upp_bus.sv` already implements wrap-four in `nxt`/`nxt2`; both
its SDRAM buffer indexing and flash read-ahead use addresses consistent with
that BTE. The obstacle is the path above it:

- Cache and internal merger interfaces carry CTI, but no BTE.
- `zap_top.sv` drives `o_wb_bte = 2'b00`.
- `rtl/cpu/arm925t.sv` discards BTE and exports only `bus_burst`, which says
  another beat follows. Its documented address contract is linear.
- `NGage.sv` recreates CTI from `cpu_burst` and ties the CPU's BTE to zero.
- CPU harness burst checking also assumes `previous_address + 4`.

A correct wrap implementation therefore needs a new propagated burst-type
signal through cache arbitration, the shared I/D merger, CPU wrapper, top-level
integration, and test harness, with matching beat-index placement and checks.
It cannot be enabled just by changing the I-cache address counter. The lower
memory controllers appear to support it already, but that complete integration
was not modified or tested here. Keeping linear order avoids changes to the
shared bus work and remains within option (a) of the task.

## Verification

Before edits, the requested nine tests passed **27/27** using the existing
binaries. Their logs and parsed cycle/instruction counts were saved in
`sim/cpu/build/icache-baseline/`. Existing test binaries and QEMU references
were not rebuilt or rerun.

After the final RTL change:

- Required nine tests: **27 passed, 0 failed**.
- Full generated-netlist suite: **180 passed, 0 failed** (all 177 existing runs
  plus the new test at the same three latencies).
- `make -C sim/cpu diff`: **RTL vs QEMU: 49 agree, 0 differ**, including
  instruction traces wherever a reference trace exists.
- `make lint`: passed, warnings remain errors.
- `make cpu-gen-check`: passed, generated file is current.
- `bash sim/cpu/tools/check_icache_restart.sh`: passed. It directly checks
  early response timing for all four word offsets, sequential beat waits,
  final line contents, a late error with backpressure, unrelated redirect,
  reset, pending-head blocking, successful/failed completion, two fills,
  completion simultaneous with enqueue, FIFO wrap, and redirect clearing.
- `make -C sim/cpu bins T=icache_restart`: built only the new test.
  `make -C sim/cpu qemu T=icache_restart`: **0 run, 1 skipped, 0 failed**;
  the test is explicitly RTL-only because arbitrary per-beat error injection
  and the bench latency register have no QEMU equivalent. Its ARM/Thumb
  success and error checks passed at all three latencies: 88,712 / 111,008 /
  176,759 cycles, **13,680 instructions** each.

The first requested full diff immediately after the nine-test run could not
compare 44 cases because this worktree initially had no corresponding RTL
signatures/traces. It reported 5 agree and 44 missing-output failures. Running
the whole suite supplied those outputs; the final full diff above passes.
Intermediate versions also exposed and fixed the CP15/full-FIFO deadlock and
Thumb error-payload exception priority described above.

### Cycle counts

Positive delta is slower. Instruction counts are identical before and after
for every row, not merely for the three headline workloads.

| Test | Bus latency | Before cycles | After cycles | Delta | Instructions, both |
| --- | --- | ---: | ---: | ---: | ---: |
| cache | 0:0 | 903,967 | 904,077 | +110 | 293,427 |
| cache | 0:3 | 1,021,476 | 1,021,997 | +521 | 293,427 |
| cache | 2:9 | 1,346,786 | 1,346,715 | -71 | 293,427 |
| dcache_rtl | 0:0 | 71,448 | 71,448 | +0 | 12,771 |
| dcache_rtl | 0:3 | 93,933 | 93,933 | +0 | 12,771 |
| dcache_rtl | 2:9 | 160,178 | 160,178 | +0 | 12,771 |
| icache_rtl | 0:0 | 71,090 | 71,042 | -48 | 12,771 |
| icache_rtl | 0:3 | 93,587 | 93,453 | -134 | 12,771 |
| icache_rtl | 2:9 | 160,385 | 159,949 | -436 | 12,771 |
| ctrand1 | 0:0 | 89,133 | 88,410 | -723 | 16,159 |
| ctrand1 | 0:3 | 114,728 | 112,581 | -2,147 | 16,159 |
| ctrand1 | 2:9 | 192,788 | 187,013 | -5,775 | 16,159 |
| crand1 | 0:0 | 90,706 | 90,279 | -427 | 15,982 |
| crand1 | 0:3 | 118,251 | 116,285 | -1,966 | 15,982 |
| crand1 | 2:9 | 202,059 | 197,091 | -4,968 | 15,982 |
| gba_arm | 0:0 | 8,334 | 8,334 | +0 | 1,192 |
| gba_arm | 0:3 | 10,955 | 10,955 | +0 | 1,192 |
| gba_arm | 2:9 | 17,752 | 17,752 | +0 | 1,192 |
| gba_thumb | 0:0 | 4,935 | 4,935 | +0 | 774 |
| gba_thumb | 0:3 | 6,552 | 6,552 | +0 | 774 |
| gba_thumb | 2:9 | 10,900 | 10,900 | +0 | 774 |
| mmu_page | 0:0 | 93,545 | 93,545 | +0 | 16,887 |
| mmu_page | 0:3 | 123,102 | 123,102 | +0 | 16,887 |
| mmu_page | 2:9 | 209,451 | 209,451 | +0 | 16,887 |
| align | 0:0 | 5,543 | 5,543 | +0 | 549 |
| align | 0:3 | 7,064 | 7,064 | +0 | 549 |
| align | 2:9 | 11,440 | 11,440 | +0 | 549 |

## Risks, limits, and next work

**Functional:** the new behavior depends on keeping the payload FIFO and its
small metadata pointers synchronized. The unit bench covers accepted
read/write, full, wrap, completion and clear cases, and the CPU tests cover
precise errors across all requested ARM/Thumb offsets. All normal pipeline
clear priorities were retained. Cache writes/dirty-victim cleaning on this
instruction-cache module are not newly exercised: they are tied off in the
ARM925T integration. Exotic geometries beyond the existing supported cache/FIFO
configuration were not swept. External faults in a discarded wrong-path line
are intentionally discarded with that path, not delivered asynchronously.

**Timing/area:** no new large RAM or replicated payload buffer. For the current
16-entry FIFO the added bookkeeping is about 50 state bits before synthesis;
the fill response reuses the existing 32-bit uncacheable register. The tag
compare and way data select are untouched. New paths are buffer selection into
a register, completion/metadata into the FIFO register, and abort sanitizing
before the Thumb decoder. The shared Wishbone merger and issue-to-memory paths
are unchanged. These observations are not a Quartus fit/timing result.

**Not verified here:** Quartus area or 104 MHz timing closure, the ordered
76,975-device-access firmware boot comparison, SDRAM/flash integration under a
real firmware workload, and game speed on physical hardware. This worktree has
neither the firmware images nor a prepared boot-reference directory. No
hardware deployment was attempted.

Next, run the ordered firmware boot comparison, then matched whole-core
Quartus seeds at 104 MHz, checking both setup corners and hold as well as area.
Measure the same in-game scenes using the stall counters. If unrestricted
execution before fill completion is still required, first define a genuinely
non-faulting-line bus guarantee or implement a retirement-safe speculation
boundary; do not replace precise errors with a deferred abort on an unrelated
fetch. Wrap-four propagation is a separate small bus-interface project with
end-to-end SDRAM and flash tests, not an I-cache-only counter change.

## Delivery stopping point

Implementation, generated netlist, directed tests, the complete 180-run suite,
49-case QEMU diff, lint, and generated-file check are complete. The files remain
uncommitted on the original `codex/icache` branch; nothing was pushed or switched.

The requested commit could not be created. `git add` failed with:

```
fatal: Unable to create '/Users/jacob/dev/fpga/mister/NGage_MiSTer/.git/worktrees/NGage_MiSTer-cx-icache/index.lock': Operation not permitted
```

The worktree's Git metadata is in the parent checkout, outside this session's
writable roots. Its approval policy disables escalation. No workaround changed
Git metadata, permissions, or repository layout. The prepared commit message is
saved in `sim/cpu/build/icache-commit-message.txt`; staging and committing these
12 task files from a session permitted to write that Git directory is the only
remaining delivery action. Hardware and timing validation remain the follow-up
work described above.
