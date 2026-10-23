# ARM9 session 6: short cache RAM and partial short schedule

## Status and exact stopping point

**Partial. The one-edge cache RAM and its collision forwarding pass. The CPU
now has a two-clock immediate load-use interlock, but the complete F1/F2 and
M1/M2 schedule requested for this session is not finished.** Fetch still has
three edges through response/Thumb capture; unpredicted B/BL costs five clocks,
not four. The cache launches from the registered check address, one edge after
E/next-PC launches the TLB. ZAP remains the default.

`d765618` is the independently verified cache milestone. The subsequent
schedule change removes one TLB read delay and one CPU/fetch record, preserves
the registered permission check, and fixes an invalid check during reload.
The final verification ledger identifies the generated netlist by SHA-256.
The previous handoff is preserved as [session 5](session5-report.md).

Work stops **inside step 2**, at this verified shorter schedule. No BTB/RAS,
block setup/drain removal, or multiplier scheduling change was attempted after
that boundary. The requested all-workload cycle gate still fails, so **no
Quartus trial was run** under the session's ordered gate. There is no new slack
or ALM measurement. No firmware boot, push, branch switch, `sys/` modification,
or change to another worktree was performed.

## Design as implemented

### Cache RAM: step 1

`CORE="ARM9"` selects `SHORT_READ` in the I/D caches and tag RAM. ZAP retains
its original three-edge RAM and all defaults. In the short RAM, one enabled
edge reads block memory and captures the simultaneous write data and the
write-address/read-address match. Each data byte has its own forwarding enable.
The output chooses that registered write or the read-first RAM output. It is a
one-entry collision register; the address comparison is captured as a bit
rather than retaining the address and comparing after the register.

The caller's next edge captures tag comparison, way/word selection and load
formatting. The tag compare, victim selection, word selection and formatter
are unchanged. The first milestone deliberately used `i_address_check` to
launch this shorter RAM, retaining the old CPU/TLB schedule. The first naive
experiment also delayed the TLB address and broke translation; it was corrected
before the cache milestone, with both full suites and QEMU passing.

Valid/dirty/LRU reads now use that same RAM edge and set. They forward the
current write and pending write-behind update; a current hit wins over the
pending fill LRU update. The ZAP chains are unchanged. D-cache restoration
reads the held request during relookup; it does not reinsert two obsolete
cache-only lookup stages. Global and line maintenance keep their conservative
wait states. Both the source byte RAM and the generated per-byte M10K wrapper
implement the same option.

### Shorter schedule: partial step 2

The TLB also uses a one-edge RAM through `zap_mem_inv_block.SHORT_READ`, then
the existing `zap_tlb_check` permission/translation register. Page walk logic,
CP15, permissions and fault priorities were not rewritten.

Relative to E's handoff, edge 1 stores `fast_1` and reads the TLB; edge 2 stores
`fast_m`, registers its permissions and reads the cache; edge 3 captures the
formatted cache result in `fast_w`. W then retires. An immediate consumer waits
while the producer is in `fast_1` and `fast_m`, and uses registered W data.
There is no combinational cache-data-to-E bypass. One result record is removed,
so six load/base producer slots replace eight. Data/base alias priorities,
held operands, flags, miss locks and ordered retirement are preserved.

Fetch similarly removes one lookup record but retains registered Thumb
translation in the queue. Next-PC remains registered. Three fetch edges still
exist: TLB read, permission plus cache read, then response/Thumb capture.
The five-clock branch is measured, not relabeled as four.

Reload now takes two clocks. Only its final clock has a valid permission-check
packet. Checking the younger held address against the stale first-reload read
can launch a phantom page walk. At latency 0:0, `arm9_cache_lru_rtl` originally
retired PC `0x37c` (D-cache invalidate) and then repeatedly walked PTE `0x800010`
for the pending load at VA `0x00421e00`. It timed out at 50,000,000 cycles;
a bounded trace showed the recurring mismatch beginning around cycle 79491.
The [bounded trace](session6-reload-reproducer.txt) records that mismatch.
The final `pipe_check` gate disables checks during fill and the unaligned
reload edge. The test then passes in 80,227 cycles at 0:0. This is a retry
alignment bug caught and fixed by the new test, not an unresolved RAM collision.

## Cases considered and coverage

- **Same-edge read/write:** the registered collision match overrides the
  read-first RAM value. Without a collision, the RAM output is used directly.
- **Partial writes:** forwarding is per byte, so consecutive STRB/STRH stores
  preserve other lanes. Multiple stores to one word need no deeper history:
  older completed writes are already in RAM; only the simultaneous write
  can be absent from the read-first output.
- **Different words, sets and ways:** address matching is at the RAM row, while
  the lane enables select the written word/bytes; each way has its own write
  enable. New tests cover all four words, other sets and both ways.
- **Hold:** read value, collision bit and captured write data all use the same
  enable. A held output cannot acquire a new write-enable/data mismatch.
- **Fill and critical word:** the existing FSM owns RAM clocks during fills;
  the core keeps its request/lock and captures critical-word completion before
  architectural retirement. Held lookups are rebuilt after fill or retry.
- **Valid, dirty and LRU:** forwarding includes current and pending updates;
  adjacent hit/miss tests observe the evicted dirty bytes through uncached
  aliases. Existing `dcache_rtl` also checks per-way/index maintenance.
- **TLB write/read/invalidate:** same-edge fills bypass read-first RAM; valid
  state clears on invalidate even with the read clock held. A reload check is
  enabled only with an aligned packet. Normal own-mode permission checks,
  user translations, FCSE and faults retain their original logic.
- **Architectural order:** load/base destinations, condition failures, older
  faults suppressing younger stores, PC redirects, block base restoration,
  IRQ/FIQ, SWP write permission and CP15 drains retain the session-5 behavior
  and are exercised by the shared suite.
- **Fetch:** invalid metadata still advances with the RAM, redirects retain
  epoch cancellation, and provisional I-cache fills resolve before issue.
  No prediction behavior exists yet.

`arm9_cache_edge.S` adds store/load distance 0/1/2, masked writes, offsets,
fill/refetch and dirty eviction; its new QEMU reference agrees on signature
and trace. `arm9_cache_lru_rtl.S` observes real cache backing memory, which
QEMU cannot model. The existing `cache`, `dcache_rtl`, `icache_rtl`, `dhold_rtl`,
`dcwf`, `dcwf_rtl`, stream, MMU and fault tests remain enabled. Only the two
new binaries were assembled, and only the new QEMU-capable test ran QEMU.

## Cycle comparison

Each cell is **0:0 / 0:3 / 2:9**, full-test cycles including setup. All nine
baseline instruction counts are identical after the change. Every ZAP cycle
count is identical to its baseline. ARM9 improves on its own baseline in every
cell, but still loses to ZAP on the cache/MMU/random workloads.

| Test | ZAP (unchanged) | ARM9 session 5 | ARM9 session 6 |
| --- | --- | --- | --- |
| cache | 760787 / 888787 / 1222550 | 994118 / 1117965 / 1463092 | 906731 / 1027432 / 1375538 |
| dcache_rtl | 58301 / 85328 / 154143 | 82060 / 115410 / 200299 | 81940 / 111104 / 196038 |
| icache_rtl | 58201 / 85393 / 154521 | 82314 / 115760 / 201212 | 82077 / 111408 / 196851 |
| ctrand1 | 72594 / 102419 / 179154 | 97715 / 133902 / 226865 | 96199 / 128266 / 221271 |
| crand1 | 73608 / 105167 / 187620 | 98994 / 137221 / 236697 | 97504 / 131692 / 231254 |
| gba_arm | 8291 / 10887 / 17749 | 6874 / 9175 / 15435 | 6599 / 8877 / 15170 |
| gba_thumb | 4913 / 6523 / 10877 | 4197 / 5624 / 9568 | 4075 / 5482 / 9433 |
| mmu_page | 77102 / 112796 / 203209 | 108082 / 152125 / 263633 | 107779 / 146238 / 258175 |
| align | 5427 / 7001 / 11223 | 4419 / 5917 / 9949 | 4157 / 5591 / 9759 |

The requested seven-workload gate fails: only `gba_arm` and `gba_thumb` beat
ZAP at every latency. No predictor-assisted speedup or hardware CPI is claimed.
Machine-readable [baseline](session6-baseline.json),
[cache-only](session6-cache.json) and [final](session6-final.json)
include the instruction counts.

All 76 exact timing windows are retained. The original 69 expectations are
retargeted in `sim/cpu/arm9/cycles.txt`; the seven eight-access windows remain
9 clocks. Each window has two checked hot visits at ARM9 0:0, and all five
visits remain required at every core/latency. [Window measurements](session6-cycle-windows.json)
and the updated TRM comparison in [ARM9.md](../../ARM9.md) record the counts.
Key marker-inclusive deltas: aligned LDR+consumer 6→5, B/BL 7→6,
LDM1/STM1 11→9, LDM3/STM3 13→11, MUL m=1..4 9..12→8..11.
Blocks still cost n+8 including the marker; seven fixed excess clocks remain
for n>1. Multiplies still drain the pipe and expose four excess clocks.

## Verification

The cache-only commit passes 225/225 runs and 60/60 QEMU comparisons on each
core, all 76 windows, 12 source-RTL runs, top-level lint, explicit ARM9 lint,
and generation consistency. The [cache ledger](session6-cache-verification.txt)
records that independent checkpoint.

The final [verification ledger](session6-final-verification.txt) records
both complete 225-run suites, both 60-reference QEMU comparisons, the nine-test
before/after runs, 18 source-RTL runs including timing windows, both lint paths,
and `make cpu-gen-check`. The suite has grown from the brief's historical
177/49 to 225 runs/60 QEMU references because of prior sessions and these tests.
No comparison was skipped to accept a failure and no timing tolerance was added.

## Risks, limits and next work

Functional risk remains at replay/fill/hold boundaries and precise faults.
The tests are not exhaustive or formal proofs. New short-path one-way cache
configurations, every unpredictable ARM encoding, all negative multiplier
boundaries and every Thumb timing permutation are not newly qualified.
The existing shared low-FAR-bit issue from session 5 was not changed.
Firmware boot and hardware gameplay remain external milestones.

Timing is **unmeasured for this revision**. The RAM bypass and tag compare
have the same output mux/compare structure; producer muxes and register counts
are structurally smaller, but that is not an ALM or timing result. Live write
controls now feed the first-edge collision/valid/LRU capture, and the short
TLB read feeds the existing permission register: both need STA. No new RAM
array, execute stage, or direct cache-to-E path was added.

The last measured integrated result is session 5's **-3.970 ns setup and
16,353 ALMs**, which is historical, not this revision's slack/area. Its worst
families were I-cache response through queue/Thumb/decode, operand capture,
and execute forwarding/shifter/ALU-to-flags. Those and the new first-edge
metadata controls are the next STA targets. The ZAP-relative area requirement
has not been demonstrated.

1. Finish step 2: launch the I/D cache read from next-PC/E alongside the TLB,
   preserve the earlier hit/word result until permission resolves, and remove
   the remaining fetch response edge without restoring the known long
   cache/Thumb/decode path. Keep per-access permission checks; do not silently
   bypass them for cache hits. Recheck collision forwarding when moving that
   capture boundary, including the new LRU/retry test.
2. Reach and measure the four-clock unpredicted branch, then add the registered
   lookup BTB option and predicted/mispredicted windows. RAS remains optional.
3. Remove block setup/drain and the multiplier barrier with precise faults and
   base restoration preserved. Re-run both suites and QEMU at each milestone.
4. Only after every required cycle row beats ZAP, run the supplied CPU-only
   Quartus script on the build server with at most four containers. Measure
   slack, critical paths and ALMs against ZAP. Keep ZAP default until it wins
   both cycles and timing/area acceptance.

All local test and debugging processes have exited; the known-failing
intermediate suite was stopped after diagnosis. No server, Docker image or Quartus container was created in session 6.
