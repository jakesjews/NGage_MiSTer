# ARM9 replacement: session 4 continuation report

## Status and exact stopping point

**Partial. Scalar loads/stores now overlap younger arithmetic with ordered
retirement, but memory requests still serialize. ZAP remains the default.**
The first checkpoint is `f49d81c`; the second removes scalar admission and
completion bubbles. ARM9 still loses to ZAP on cache, dcache_rtl, ctrand1 and
crand1 at every latency. It wins both GBA tests at every latency.

Session 4 stopped within task step 1: the next change is independently valid
M1/M2/M3 request records. One-request-per-cycle stores, streaming LDM/STM and
the target one/two-cycle load-use schedule are **not implemented**. SWP is still
a blocking ordered pair. Task step 3 was not reached: no Quartus trial was run
this session, and no current timing-closure claim is made. The last integrated
measurement remains session 3's **-2.623 ns**, with both cache/Thumb-translation
and execute-to-flags families failing. That is historical evidence, not the
slack of this changed netlist.

The [session-3 report](arm9/session3-report.md) is archived unchanged. This report
and `docs/ARM9.md` describe the new boundary; they do not claim the requested full
memory pipeline is finished. No push, branch switch, `sys/` change or firmware
boot was performed.

## Design as implemented

E has its own valid bit and register-shift wait bit, independent of the slow
controller. A slow E handoff captures `slow`: PC, PC+8/+4, raw/decoded instruction,
CPSR, instruction kind and physical base/destination tags. Post-E memory, fault,
CP15, block continuation and W read that record. Address, store data, format,
load destination and writeback controls retain their existing held registers.
The bench data-PC tap uses `data_pc8`, independently of the younger E PC.

Non-PC DP can execute behind a scalar memory operation. Two elastic result
records hold younger results; another instruction can wait in E. The older
memory instruction must retire before those younger results. No younger memory
access, branch, state change, or exception is issued while that memory context
is occupied. This bounds speculation to register/flag results that can be discarded.

Scalar memory can now enter immediately after a fast E instruction, without
first draining both result records. On the memory E handoff, only one older
result can remain in M. `older_pending` lets that result retire from W during
the memory lookup. It then clears, leaving younger results blocked. A skipped
memory instruction also waits for that older W: otherwise two architectural
instructions would compete for the single retirement port. This collision was
found during review and fixed before the second checkpoint was committed.

When no younger result is queued, D can admit the next scalar memory instruction
on the previous memory retirement edge. It does not issue a new cache request
on that edge; the next instruction must still execute and traverse the lookup.

A successful load response is captured in `m_read_data`. The next edge must
still observe the cache's newly registered miss lock. If no lock exists, that
classification edge now serves as W; a hit no longer incurs another W bubble.
A miss still waits for its critical-word completion, captures it, and retires
on the subsequent W edge. Stores do not classify a load lock and go directly
to W after acknowledgement. This also removes one cycle from the SWP write half
and one per completed LDM/STM transfer. No cache RAM/tag/bus path was changed.

## Cases considered

- **Operands and forwarding:** physical tags select fast M, fast W, pending
  memory load, then pending memory base. Scalar memory enables forwarding for
  the base, register offset and store data; a post-indexed raw base uses the same
  forwarded value as the execute adder. Immediate and PC values retain D's
  construction. Other slow instructions still drain before capturing operands.
- **Pending load and base writes:** both are unready until precise memory W.
  Load wins a same-register base alias, matching the retained writeback ports.
  A younger ready writer shadows an older unready load. A held E captures each
  bypass before its producer disappears, including while queue space or another
  source is unavailable. Only used operands cause a dependency wait.
- **Conditions and flags:** E selects the newest M/W flags. Scalar memory
  snapshots those flags rather than D's potentially stale CPSR. A false condition
  neither accesses memory nor waits for an unused load; it still retires once.
  A register-controlled shift takes its existing extra cycle only after the
  operands are ready and the condition passes.
- **Load formats and addresses:** byte, signed byte, halfword, signed halfword,
  unaligned word rotation, alignment faults, FCSE, pre/post indexing and user
  translation retain the existing cache formatting and architectural rules.
  The access's own mode comes from `slow.flags`, not a younger E instruction.
- **Misses and replay:** the three native RAM edges and the existing retry/hold
  sequence remain intact. Early acknowledgement alone cannot retire victim
  data. Critical-word completion is captured before W and checked by the bench.
  A write miss still follows the cache's existing acknowledged-store semantics.
- **Abort precision:** an older fault discards E and both younger result entries.
  Their flags and register values never reach the register file. A younger store
  cannot have issued. The fault PC and mode come from the held context; failed
  scalar base writeback is suppressed by the retained exception logic.
- **Interrupts, fetch faults and redirects:** admission waits for older work.
  Already admitted younger DP retires before the next interrupt boundary, unless
  the older memory operation faults. Branches cannot redirect ahead of pending
  memory. Loaded PC and other slow redirects cancel younger fetch work as before.
- **LDM/STM:** the retained sequencer still commits transfers in order, preserves
  completed transfers on abort and restores the original base when required.
  User-bank selection and exception-return flags are unchanged. It benefits
  from the shorter completion path but does not stream requests.
- **SWP:** the held read completes before the held write; source data is retained
  across both. The load side still classifies/captures a miss. The write side
  skips the irrelevant load-classification cycle. No younger instruction enters.
- **Multiply, PSR and CP15:** these remain barriers and use the held context after
  E. CP15's existing maintenance/drain semantics and the execute stage length
  are unchanged. The forwarding leaf adds a producer-count parameter; its
  standalone default remains three producers, while this core uses four.

## Cycle comparison

Both cores passed all 27 requested pre-edit runs. The complete nine-test records
are [baseline](arm9/session4-baseline.json),
[first checkpoint](arm9/session4-context.json), and
[final checkpoint](arm9/session4-admission.json). Every instruction count in
those nine tests is identical to baseline. Every ZAP cycle count is unchanged.
Columns within a cell are **0:0 / 0:3 / 2:9**.

| Test | ZAP | ARM9 session 3 | ARM9 session 4 |
| --- | --- | --- | --- |
| cache | 760787 / 888787 / 1222550 | 1237634 / 1317526 / 1652590 | 1028308 / 1131577 / 1480523 |
| dcache_rtl | 58301 / 85328 / 154143 | 99427 / 124688 / 201580 | 99158 / 118893 / 201381 |
| icache_rtl | 58201 / 85393 / 154521 | 99490 / 124951 / 202315 | 99293 / 119107 / 202090 |
| ctrand1 | 72594 / 102419 / 179154 | 125032 / 152984 / 237636 | 121214 / 143720 / 234066 |
| crand1 | 73608 / 105167 / 187620 | 124960 / 154055 / 243949 | 121181 / 145424 / 241635 |
| gba_arm | 8291 / 10887 / 17749 | 7439 / 9468 / 15551 | 7205 / 9389 / 15517 |
| gba_thumb | 4913 / 6523 / 10877 | 4515 / 5780 / 9696 | 4376 / 5751 / 9651 |
| mmu_page | 77102 / 112796 / 203209 | 132146 / 165272 / 266134 | 131532 / 157140 / 265373 |
| align | 5427 / 7001 / 11223 | 6175 / 7430 / 11117 | 5869 / 7049 / 10589 |

The four required losses versus ZAP remain **267521/242790/257973** clocks on
cache, **40857/33565/47238** on dcache_rtl, **48620/41301/54912** on ctrand1,
and **47573/40257/54015** on crand1. The outstanding mechanism is serialized
memory admission plus the retained block sequencer. Cache-enabled tests also
spend considerable time initializing their page tables with uncached stores;
this change does not eliminate the memory controller's per-request bubbles.
These are aggregate measured losses, not a claim that every lost clock has
been attributed to a single cause.

The state schedule still permits consecutive scalar hit requests only every
six clocks. For a word load with an immediate ALU consumer, relative to the
load's E cycle:

| Clock | Memory instruction | Dependent successor |
| ---: | --- | --- |
| 0 | E captures address | D cannot yet admit successor |
| 1 | M1 / RAM edge 1 | D admits successor |
| 2 | M2 / RAM edge 2 | E waits |
| 3 | M3 / RAM edge 3 | E waits |
| 4 | response captured | E waits |
| 5 | classify and retire hit | E receives W bypass |
| 6 | completed | result M |
| 7 | completed | result W |

An independent successor can execute at clock 2 and wait in the result queue.
Thus the native hit schedule still has an admission bubble plus three dependent
E wait clocks, **not** the requested one/two-cycle interlock. The one-clock
retirement-window difference between independent and dependent successors does
not prove a one-clock execute interlock. Register shift adds its separately
specified cycle. Byte/halfword formatting shares this schedule; no new claim of
TRM-exact narrow-load timing is made.

LDM/STM still cost seven clocks per additional register: the three-register
window is 25 versus 11 for one register, a 14-clock difference. This is still
six clocks per extra register worse than streaming at one per clock.

## TRM windows and architectural coverage

All 69 existing windows are retained. Their assembled instruction binary and
QEMU reference were not rebuilt. `sim/cpu/arm9/cycles.txt` supplies versioned
expectations through the source's bench tag. The bench rejects missing, duplicate,
unknown or zero entries, visits each window five times, and compares both hot
0:0 visits exactly. It does not turn mismatches into tolerances. First/final
window values are also preserved as JSON beside this report.

| Window | Session 3 | First checkpoint | Final |
| --- | ---: | ---: | ---: |
| load, independent successor | 13 | 10 | 6 |
| load, ALU / shifted-value consumer | 13 | 11 | 7 |
| load, base or store-data consumer | 20 | 17 | 11 |
| load, register shift-count consumer | 14 | 12 | 8 |
| load byte/halfword/signed/unaligned | 13 | 11 | 7 |
| load PC | 17 | 17 | 13 |
| store | 12 | 9 | 5 |
| LDM1 / STM1 | 12 | 12 | 11 |
| LDM3 / STM3 | 28 | 28 | 25 |
| LDM including PC | 33 | 33 | 30 |
| SWP / SWPB | 17 / 18 | 17 / 18 | 16 / 17 |
| load with 1 / 2 / 3 intervening DP | 14 / 15 / 16 | 11 / 12 / 13 | 7 / 8 / 9 |

Counts include the end marker and pipeline admission/retirement effects. The
exception windows improve by one clock because their vector LDR-PC completes
sooner. DP, branch, PSR, CP15 and multiply windows retain their prior values.
They are regression expectations for this implementation, not completion of
the target TRM cycle model.

The new `arm9_memory.S` runs uncached, cached, then warm-cached cases. It covers
pending load/base consumers, WAW shadowing, queue backpressure, held bypasses,
loaded shift counts, failed conditions, and abort cancellation of younger
registers, flags and a store. Its handler checks original register/base state,
SPSR and abort PC. Signature and full trace agree with QEMU on both cores.
Only this new test binary and QEMU reference were built.

## Verification

The first checkpoint passes both cores' **210/210** generated runs and **56/56**
QEMU signature/trace comparisons, 0 differ. ARM9 source smoke passes 18/18 runs
and six comparisons. The execute leaf passes 582,272 reference checks over
source/generated RTL and both shift configurations. Top-level `make lint` and
`make cpu-gen-check` pass. Its [ledger](arm9/session4-context-verification.txt)
records the input hash and checks. A wrong DP expectation (10 rather than 9)
produces both expected cycle errors.

The final checkpoint passes the focused 33 runs, then **210/210** full generated
runs and **56/56** QEMU comparisons on ARM9. ZAP also passes **210/210** and
**56/56**, with unchanged baseline cycles. ARM9 source smoke passes **18/18**
and six comparisons. All **69** timing windows pass both hot checks. Required
`make lint` and `make cpu-gen-check` pass. Additional source ARM9 lint passes
with inherited interface/style/unused waivers and D-cache-only width waivers;
no ARM9 width diagnostic is waived. The final [verification ledger](arm9/session4-admission-verification.txt)
records the exact generated-input hash and results.

## Risks, limits and next work

The new four-source forwarding and elastic result control add fanout to the
already marginal execute boundary. No execute stage was lengthened in cycles,
no new E-to-memory stage was added, and no cache RAM was added. There is no new
area/slack measurement. The cached-load data path remains registered before W.
Session 3's standalone leaf timing result cannot establish integrated closure.

The next implementation must replace the single `m_address/m_dst/m_load` context
with independently valid request records through the three cache read edges,
while retaining the ordered retirement and distinct load/base producer rules.
It must handle gaps as well as back-to-back memory operations. The cache's
`i_stall` is still tied to zero at the shared top: freezing only CPU metadata is
unsafe. Coordinate RAM advances, internal fill hold, MMU retry and cache relookup;
verify older faults kill all younger memory side effects. Do not generalize the
single-bit `older_pending` proof to multiple outstanding memory instructions.

Then stream block transfers, retaining the original base until every fault
boundary is handled; keep SWP's pair ordered. Repeat both complete suites and
QEMU comparisons at each step. Only after that, pursue the saved cache-select /
Thumb-translation and execute-to-flags paths with an integrated ARM9 trial at
104 MHz. The performance and timing gates are both still unmet.

Coverage limits retained from session 3: no firmware boot, full-system fit or
hardware game measurement; no exhaustive unpredictable alias/empty-list or
negative multiplier-boundary coverage. The new directed test is ARM state;
Thumb memory semantics remain covered by the shared suite. Multiple outstanding
memory requests and one-register-per-clock block transfers are not tested as
implemented behaviour because they do not exist yet.

No server/container was started this session. Local verification processes exit
on completion; other engineers' worktrees, jobs and files were left alone.
