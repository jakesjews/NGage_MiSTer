# ARM9 replacement: session 5 continuation report

## Status and exact stopping point

**Partial. Scalar requests and block transfers now stream at one hit access per
clock. ZAP remains the default: the required performance and timing gates have
not been met.** Three native cache read edges plus registered W still give a
three-clock immediate load-use interlock, one more than the requested FPGA
allowance. Block transfers have fixed setup/drain overhead; SWP remains an
ordered, drained pair. The integrated ARM9 Quartus trial is running; its result
will be appended before the session ends.

Checkpoints: `78c9aeb` adds ordered scalar requests, `51a60de` admits ready slow
operands before the last older retirement, and `8e83709` streams blocks and PC
loads. The final refinement lets independent arithmetic proceed after a miss's
critical word and removes three lookup clocks from a non-missing SWP write half.
The unchanged [session-4 report](arm9/session4-report.md) records the starting point.

No push, branch switch, `sys/` edit or firmware boot was performed. Build-server
jobs use the task-specific `dev/mister/ngage-arm9-session5-final` directory and
the supplied script's four-container limit.

## Final design

Arithmetic, branches and scalar memory share four ordered records: three
records tracking the **existing** cache RAM read edges, followed by W. E launches
the first RAM read on its handoff edge. Each record retains valid/condition,
PC, result flags, load/base physical destinations, address, store data, format,
byte enables and access mode. The second record supplies the MMU check and its
own mode; the third supplies the cache request. W alone changes architectural
state. The shared cache RAM/tag hit path, bus merger, register file and execute
arithmetic are unchanged. No new RAM or extra execute stage was introduced.

Every stage exposes separate load and base/ALU producers, youngest first. A
load wins its own base alias, while a younger writer shadows an older unready
load. Base values can forward immediately but retire only after the access
succeeds. Load data forwards only from registered W, never directly from the
cache into E. Held E operands capture bypasses before producers disappear.
Failed conditions neither access memory nor wait on unused load dependencies.

The cache's existing registered fill-state indication is exported through the
wrapper. An uncached request holds the pipeline until its response. An early
load-miss acknowledgement enters W with provisional data, but the newly
registered lock prevents retirement. The critical-word pulse replaces the
provisional value before W may retire. Independent arithmetic can then advance
while the rest of the fill completes; another memory record at the request
stage stops it. No new data request issues while the cache owns a fill.

After a fill or TLB retry, three reload clocks reconstruct the held request
and its two younger lookup records, including gaps. Fill writes retain their
RAM clocks; core-owned holds alone drive the new external stall connection.
ZAP still drives that stall to zero and retains its previous cache behavior.
The three reload clocks remain an optimization opportunity, especially when
there is no useful pending memory lookup.

Slow operations can read ready operands before the pipeline finishes draining.
They wait in E until all older records have retired (the last W may retire on
the handoff edge), and until fill/reload activity is done. They use the newest
flags, including MRS/MSR. Ready-at-admission is necessary because multiply, SWP
and block setup use captured D values. An older fault or loaded-PC redirect
cancels this handoff.

LDM/STM capture the instruction, original physical base, final base, original
mode and SPSR once. A register-list selector, one RF read and an address counter
then feed one transfer per enabled clock into the same pipeline. Only the last
packet writes back the base or restores flags. Access mode is separate from
result flags: an exception-return load must check permissions in its original
mode, not the mode it will return to.

Ordinary PC-relative memory and loads to PC use the scalar pipeline. A loaded-PC
W redirect suppresses younger requests and clears their records before they
can write. Unpredictable memory forms with base writeback to PC retain the old
slow path. SWP retains its source data across an ordered read/write pair. On a
non-missing read, the classification edge also checks **write** permission, then
the write uses the unchanged lookup directly. A read miss keeps the conservative
reload path. The read result commits only after the write succeeds.

## Cases and coverage

- **Order and faults:** a memory error is retained in W. Its retirement edge
  suppresses younger requests and discards younger E/results. Thus a younger
  store cannot escape an older fault, even when adjacent. Speculative register,
  base and flag results never enter the RF after that fault.
- **Block aborts:** earlier completed transfers survive. For a writeback-enabled
  block, an internal non-final micro-op restores the original physical base
  before abort entry, even if an earlier LDM transfer loaded that base. This
  ordering also preserves exception-link priority if the base is the abort
  bank's LR. LDM with the base in its list suppresses successful final writeback.
- **Formats and modes:** byte, halfword, signed and unaligned scalar loads retain
  the cache formatter; LDM reads aligned words. Alignment/FAR inputs retain the
  raw address. FCSE, user-translated accesses, banked/user registers, loaded PC,
  exception return and condition failures retain their existing behavior.
- **Misses and retries:** both hits and early-ack misses are tested at all three
  bus latencies. W lock classification and critical-word capture remain checked
  by the bench. Native cache collision forwarding handles adjacent stores/loads;
  saved address records handle different sets and invalid gaps.
- **Interrupts and state:** IRQ/FIQ admission waits for an architectural boundary;
  blocks remain one interruptible instruction. CP15, PSR changes and other slow
  operations drain older work. Already fetched younger instructions are canceled
  on faults/redirects using the existing fetch epochs. Debug retirement/data-PC
  taps and stall bits include the new pipeline paths.
- **SWP permissions:** the write half performs a fresh permission check. A write
  abort commits neither its held read result nor the store. The new directed
  test checks this with uncached and warm cached read-only user mappings.

Three new shared tests were added. `arm9_stream` covers adjacent same-word and
different-set accesses, byte-lane collisions, post-index chains, gaps and aborts
with younger stores. `arm9_stream_timing` checks seven eight-access windows.
`arm9_swp_perm` checks read-permitted/write-forbidden SWP and SWPB. Only these new
tests' binaries and QEMU references were built; existing binaries/references
were not rebuilt. The 69 original timing windows still use versioned exact
expectations, with no tolerances or disabled comparisons.

A new unaligned SWPB permission-fault experiment exposed an existing issue in
**both** cores: FAR was 0x00400000 rather than QEMU's 0x00400001. Both cores align
the address sent to the TLB check. This session did not change that shared MMU
behavior; the committed SWPB permission test uses an aligned byte address and
still verifies write permission, destination suppression and store suppression.
Low FAR bits on byte permission faults need a separate fix and test.

## Cycle comparison

Both cores passed all 27 pre-edit runs. All nine tests retain their own baseline
instruction counts, and every ZAP cycle count is unchanged. Values in each cell
are **0:0 / 0:3 / 2:9**. These are complete-test measurements, including setup.

| Test | ZAP | ARM9 session 4 | ARM9 session 5 |
| --- | --- | --- | --- |
| cache | 760787 / 888787 / 1222550 | 1028308 / 1131577 / 1480523 | 994118 / 1117965 / 1463092 |
| dcache_rtl | 58301 / 85328 / 154143 | 99158 / 118893 / 201381 | 82060 / 115410 / 200299 |
| icache_rtl | 58201 / 85393 / 154521 | 99293 / 119107 / 202090 | 82314 / 115760 / 201212 |
| ctrand1 | 72594 / 102419 / 179154 | 121214 / 143720 / 234066 | 97715 / 133902 / 226865 |
| crand1 | 73608 / 105167 / 187620 | 121181 / 145424 / 241635 | 98994 / 137221 / 236697 |
| gba_arm | 8291 / 10887 / 17749 | 7205 / 9389 / 15517 | 6874 / 9175 / 15435 |
| gba_thumb | 4913 / 6523 / 10877 | 4376 / 5751 / 9651 | 4197 / 5624 / 9568 |
| mmu_page | 77102 / 112796 / 203209 | 131532 / 157140 / 265373 | 108082 / 152125 / 263633 |
| align | 5427 / 7001 / 11223 | 5869 / 7049 / 10589 | 4419 / 5917 / 9949 |

ARM9 wins both GBA tests at every latency, but **does not beat ZAP** on cache,
dcache_rtl, ctrand1, crand1 or mmu_page. The required all-workload gate fails.
The remaining measured deficits against ZAP are:

| Test | Extra ARM9 clocks, 0:0 / 0:3 / 2:9 |
| --- | --- |
| cache | 233331 / 229178 / 240542 |
| dcache_rtl | 23759 / 30082 / 46156 |
| ctrand1 | 25121 / 31483 / 47711 |
| crand1 | 25386 / 32054 / 49077 |
| mmu_page | 30980 / 39329 / 60424 |

The complete machine-readable checkpoints are [baseline](arm9/session5-baseline.json),
[scalar](arm9/session5-scalar.json), [admission](arm9/session5-admission.json),
[block](arm9/session5-block.json), and [final](arm9/session5-final.json). The first
scalar version regressed cache by imposing whole-fill stalls and deeper drains.
Critical-word continuation removes 65,570 / 73,838 / 77,880 clocks from the block
checkpoint's cache run. This is a measured revision delta, not additive stall
attribution. The final cache is faster than session 4 at all three latencies.

## Remaining mechanisms and measured costs

| Hot retirement window | Session 4 | Final | Interpretation |
| --- | ---: | ---: | --- |
| Eight DP | 9 | 9 | One clock per instruction plus marker |
| LDR + independent ALU | 6 | 3 | One-clock hit throughput |
| LDR + immediate ALU/base/store consumer | 7 / 11 / 11 | 6 / 6 / 6 | Three dependent E wait clocks |
| LDR + register shift-count consumer | 8 | 7 | Three wait clocks plus the register-shift cycle |
| LDR + 1 / 2 / 3 independent DP + consumer | 7 / 8 / 9 | 6 / 6 / 6 | Those instructions hide the dependent wait |
| STR | 5 | 2 | One clock plus marker |
| LDM1 / STM1 | 11 | 11 | Fixed setup/drain still present |
| LDM3 / STM3 | 25 | 13 | One clock per additional register |
| LDM including PC | 30 | 18 | Streaming plus redirect/refill |
| LDR PC | 13 | 11 | W redirect and native fetch refill |
| SWP / SWPB | 16 / 17 | 13 / 14 | Ordered pair; three lookup clocks removed |
| B / BL | 7 | 7 | Six instruction clocks including native refill |
| MUL m=1..4 | 9..12 | 9..12 | Arithmetic plus exposed drain/restart |
| Long multiply m=1..4 | 10..13 | 10..13 | Still a slow-operation barrier |

All counts include the end marker. The seven new stream windows are each 9
clocks for eight memory instructions. All 76 windows execute five times per
configuration and check both hot ARM9 0:0 visits exactly.

Relative to load E at clock 0, RAM records occupy clocks 1, 2 and 3; W's registered
load bypass is available at clock 4. A dependent successor in E waits at clocks
1, 2 and 3. This **three-clock** wait is not relabeled a one/two-clock interlock.
Meeting two clocks needs a verified earlier address/data availability boundary;
direct cache-to-E forwarding would extend an already failing timing path.

The block formula is n+10 marker-inclusive clocks in the measured windows,
versus n+1 for an ideal n-cycle block plus marker: nine fixed excess clocks,
with no excess per additional register. Branches cost three more clocks than
the TRM's three-cycle branch plus marker. Slow multiply/state barriers and
unpredicted branches in uncached page-table initialization remain substantial.
These measured local costs are not a decomposition of the complete-test deficits:
fetch, bus waits, fills and pipeline drains overlap.

## Verification and integrated timing

Both cores pass **219/219 runs** and **59/59 QEMU signature/trace comparisons**.
ARM9 source RTL additionally passes 24/24 runs and seven comparisons. All 76
windows pass their two hot checks; `make lint`, explicit generated `CORE=ARM9`
`-Wall` lint and `make cpu-gen-check` pass. The [final ledger](arm9/session5-final-verification.txt)
and [window results](arm9/session5-cycle-windows.json) record this checkpoint.
The integrated trial uses the exact same generated SHA-256.

The integrated timing trial is still running. Prior verified milestones have dedicated [scalar](arm9/session5-scalar-verification.txt),
[admission](arm9/session5-admission-verification.txt) and
[block](arm9/session5-block-verification.txt) ledgers.

## Next session

1. Start from this branch and the final ledger/hash. Preserve the now-tested
   one-access-per-clock stream and precise abort rules while shortening load
   availability; do not add a cache-data-to-execute combinational chain blindly.
2. Remove fixed block/SWP setup and unnecessary post-fill reload clocks. Address
   the native fetch/refill and slow multiply/state barriers identified above;
   memory streaming alone has not met the required ZAP comparison.
3. Use the integrated timing results below to prioritize cache/Thumb translation
   and execute-to-flags paths. Keep ZAP default until both performance and timing
   gates pass. Re-run both full suites, QEMU comparisons and exact timing windows
   after each change.

Not covered: firmware boot, full-system fitting, hardware games, exhaustive
unpredictable/empty register-list behavior, every negative multiplier boundary,
or all Thumb timing permutations. No firmware or hardware result is inferred
from this CPU bench. No execute-stage timing closure is claimed from an old
standalone datapath fit.
