# ARM9 replacement: session 3 continuation report

## Status and exact stopping point

**Partial overlap is implemented; the requested full ARM9 pipeline is not
finished. ZAP remains the default.** Ordinary non-PC data processing and B/BL
now overlap D/E/M/W behind an independent streaming fetch queue. Memory,
LDM/STM, multiply, PSR operations, other PC writes and exceptions still use
the conservative blocking controller. ARM9 remains slower than ZAP in the
requested whole-test comparisons. Do not switch the default or claim the
performance acceptance gate has passed.

This report supersedes session 2, archived as [arm9/session2-report.md](arm9/session2-report.md).
The first checkpoint, `78c0cd2`, introduced the independent fetch pipeline and
passed both cores' 201-run/53-reference suites. Commit `e47c566` adds the
arithmetic overlap, captured transfer controls, and real cycle-window checks
(204 runs / 54 references). The following timing fix registers Thumb translation
in the existing fetch queue and adds `arm9_queue`, taking the suite to 207 runs
and 55 references. The final timing result is recorded below.

## Design implemented

`arm9_fetch.sv` owns launch PC, three cache-latency records and an eight-entry
queue. Each record carries its PC, instruction state and two-bit epoch. Queue
entries add raw and translated instruction, Thumb undefined/alignment metadata,
precise prefetch-abort state and the provisional fill bit. It can fetch each clock on hits, independently of the backend.
`arm9_core.sv` decodes the queue head, captures instruction/PC/physical operand
tags in E and produces independent `fast_m` and `fast_w` result records for
non-PC DP and B/BL. Those records carry validity, condition result, value,
destination, flags and PC+8/+4. The reused writeback block commits W once.
The unchanged execute leaf receives real registered producer inputs now.

Specific overlap cases:

- **Register dependencies:** youngest M before W; D bypasses both as well so
  a same-edge RF write cannot leave a stale captured operand. Only used E
  operands participate. Immediate and PC values are constructed after the
  D bypass. Slow instructions drain both producers before capture, covering
  their additional operands, banked SPSRs, separate base/load destinations
  and direct multiplier inputs without pretending they have a load bypass.
- **Flags and conditions:** E selects M, W, then committed CPSR. RRX,
  ADC/SBC/RSC, preserved V and zero-rotation carry see the newest flags.
  Failed instructions still retire exactly once with no register or flag
  changes. A register-controlled shift holds E one extra clock only when
  its condition passes; the decision uses E's forwarded flags.
- **Branches:** B/BL redirect from E without prediction and kill the younger
  queue. BL preserves flags and writes its return address through M/W.
  No older fault-capable instruction can coexist with that branch: memory
  and state operations are still barriers. DP-to-PC, BX, loaded PC, exception
  returns and Thumb BL halves retain the previous precise serialized path.
- **Fetch cancellation:** redirect invalidates the queue immediately, but
  an outstanding untagged cache response drains before the new target uses
  the lookup pipe. Each RAM-advancing edge advances matching metadata, even
  when it is invalid. An early implementation froze metadata on one clear
  edge; `cache` caught a wrong-set instruction and this was fixed before
  checkpoint 1. Epoch wrap cannot resurrect a queue entry because every
  redirect clears occupancy and outstanding work drains before reuse.
- **Fetch faults and retry:** provisional entries cannot decode until the
  fill finishes. Completion/fault updates reach even a full, held queue.
  Retry preserves older queued instructions and restarts the failed lookup
  plus younger addresses. A killed result never inserts into the queue.
- **Stores, load misses, aborts and interrupts:** the previous blocking
  completion/lock protocol remains. No younger store or CP15 action can
  precede an older fault. IRQ/FIQ admission and state-changing instructions
  drain older result records. LDM base restoration, partial transfers,
  user-bank permissions and completion-to-W assertions remain intact.
- **Block address timing:** D captures count, register/list and a signed
  eight-bit start offset. E adds that offset to the base once; final base
  arithmetic is separate. This removes the previous unregistered Thumb
  decode/popcount and chained adders from the address endpoint. No execute
  leaf or cache RAM/tag/bus logic was changed and no E-to-memory stage added.
- **Debug/trace:** W supplies its own PC and flags. Data-access taps retain
  the blocking operation's PC. Cache completion remains distinct from
  architectural retirement. Stall bits now describe fetch occupancy,
  drains, shift/multiply busy and early versus retirement redirects.

Architectural cases not changed by overlap (multiply forms, SWP capture,
alignment, CP15, modes and banked state) are detailed in the session-2 report.

## Cycle measurements and regressions

Before RTL edits, both selected cores passed the 27 requested focused runs;
`arm9/session3-baseline.json` records their cycles and instruction counts.
The nine tests' instruction counts remain identical. ZAP cycles are unchanged
in every cell. Bus-latency columns in each cell are **0:0 / 0:3 / 2:9**.

| Test | ZAP before and after | ARM9 session-2 baseline | ARM9 partial overlap | Instructions |
| --- | --- | --- | --- | ---: |
| cache | 760787 / 888787 / 1222550 | 2553475 / 2613823 / 2803925 | 1237634 / 1317526 / 1652590 | 293427 |
| dcache_rtl | 58301 / 85328 / 154143 | 163476 / 189557 / 259170 | 99427 / 124688 / 201580 | 12771 |
| icache_rtl | 58201 / 85393 / 154521 | 163204 / 189350 / 259203 | 99490 / 124951 / 202315 | 12771 |
| ctrand1 | 72594 / 102419 / 179154 | 202854 / 231634 / 309047 | 125032 / 152984 / 237636 | 16159 |
| crand1 | 73608 / 105167 / 187620 | 203684 / 234675 / 318037 | 124960 / 154055 / 243949 | 15982 |
| gba_arm | 8291 / 10887 / 17749 | 13315 / 15305 / 20663 | 7439 / 9468 / 15551 | 1192 |
| gba_thumb | 4913 / 6523 / 10877 | 8538 / 9804 / 13270 | 4515 / 5780 / 9696 | 774 |
| mmu_page | 77102 / 112796 / 203209 | 216632 / 250908 / 341968 | 132146 / 165272 / 266134 | 16887 |
| align | 5427 / 7001 / 11223 | 8847 / 10171 / 13817 | 6175 / 7430 / 11117 | 549 |

`arm9/session3-fetch.json` preserves the intermediate fetch-only checkpoint;
`arm9/session3-overlap.json` preserves the arithmetic checkpoint. ARM9 does
**not** beat ZAP on any of the required six test families at any latency.
The major remaining cost is still serial memory/sequencer admission, with
extra cost for serialized state operations and native fetch refills.

`arm9_cycles.S` adds 69 named retirement windows spanning every TRM Table 7-2
instruction row, representative LDM/STM lengths, load operand roles and
positive multiplier values for each m=1..4. Three calls warm each path; the
last two are exact checks at ARM9 0:0. All core/latency combinations check
that every window was reached five times. Timers are not read inside the
measured sequence. Unknown/zero expectations are rejected. No architectural
trace comparison is disabled.

The DP, dependency and flags chains demonstrate one clock per instruction;
executed register shifts demonstrate two and skipped shifts one. Every other
measured value, and its deviation from the target, is in the new measured-model
section of `docs/ARM9.md` and `arm9/session3-cycle-windows.json`. Those values
are regression expectations for this partial implementation, **not a claim
that slow operations meet the TRM**. B/BL cost six clocks including refill
(the native-cache target was five), before the end-marker clock. Loads still
block independent and dependent successors alike. Exception windows include
the vector's actual LDR-PC trampoline and must not be compared directly with
the TRM's core-entry count.

Two test-design findings matter for continuation:

1. The patched QEMU and existing RTL differ on the selected unaligned word
   pattern; this timing-only case uses equal bytes in adjacent words so both
   conventions produce the same value. Existing alignment/rotation tests
   remain unchanged. This is not a proposed change to load semantics.
2. An initial MRC-PC case changed flags to the CPU ID's top nibble: ARM9
   matched QEMU, while ZAP left flags unchanged. The shared timing case now
   starts with those same flags, so it remains usable by both selections.
   The existing ZAP omission was not fixed in this ARM9 worktree. The committed
   case does not test an MRC-PC flag transition; preserve that distinction.

## Verification

The two new binaries and QEMU references (`arm9_cycles`, `arm9_queue`) were
built locally using installed ARM binutils and patched `qemu-system-arm`.
No existing test binary or QEMU result was rebuilt. Only new-test references
were regenerated while their sources were being completed. The original
suite was 201 runs / 53 references; the final total is 207 / 55.

Final generated-netlist results after the queue translation change: ARM9
**207/207 runs, 55 QEMU comparisons agree, 0 differ**; ZAP **207/207,
55 agree, 0 differ**. The nine focused tests plus `arm9_cycles` and
`arm9_state` pass 33/33 on ARM9; `arm9_queue` independently passes all three
latencies on both selections. The full suites include all of them. Every
original cycle/instruction record is unchanged by the timing-only refinement.

The execute-leaf reference tests pass 582,272 checks across source, generated
and both shift configurations. Source ARM9 smoke passes 30 runs and ten
QEMU comparisons, including both new tests. Source ARM9 `-Wall` lint passes
with legacy ZAP warnings, empty integration output pins and unused bits of
the retained full-width `d_raw` encoding waived; no datapath warning is waived.
Required top-level `make lint` and `make cpu-gen-check` also pass.

A scratch cycle-test binary with DP expectation changed from 9 to 10 fails
with two cycle errors and exit 3, proving both measured invocations are
checked. A scratch netlist without the LDM/younger-Thumb metadata gate fails
`arm9_queue` at all three bus latencies. Neither mutation is in the repository.
`arm9/session3-verification.txt` preserves the concise verification ledger.

## Timing

The first integrated seed-2 trial of `e47c566` completed at 104 MHz and
**failed setup**. The D-captured block offset/count fix removed the old
Thumb-to-`m_address` endpoint from the worst paths, but the newly active
fetch/decode-to-operand path became limiting.

| Corner | Setup slack ns | Hold slack ns |
| --- | ---: | ---: |
| Slow 1100mV 100C | -3.753 | +0.306 |
| Slow 1100mV -40C | -3.750 | +0.283 |
| Fast 1100mV 100C | +2.188 | +0.155 |
| Fast 1100mV -40C | +3.361 | +0.140 |

Area: 13,996 ALMs, 16,049 registers, 305,568 memory bits, 69 RAM blocks,
3 DSP blocks. This is the whole CPU/trial harness, not incremental core area.
Worst path: retimed `u_thumb|WideNor14~0_OTERM7927DUPLICATE` to
`value_e[34]~_Duplicate_1`, 13.009 ns data delay, eleven logic levels. It passes
through Thumb decode, `kind_d`, `read_tag`, D forwarding and operand capture.
Other reported paths include redirect/fetch control into retimed Thumb logic.
It is not the fitted shift/ALU leaf. Detailed evidence and the exact generated
input hash are in `arm9/session3-first-fit-seed2/`.

A second trial moves Thumb translation and its undefined/alignment metadata
before the existing fetch FIFO register. D reads the registered translation;
no instruction stage or clock is added. The raw word is retained for Thumb BL
halves. LDM continuation explicitly uses its held instruction and ignores
metadata of the younger queue head. `arm9_queue.S` covers this boundary and
a branch killing a queued exception. Removing that gate in a scratch netlist
makes the directed test fail its second-transfer check at all three latencies;
the correct netlist and QEMU agree. The second trial uses seed 2 and
`BUILD_DIR=dev/mister/ngage-codex-arm9-session3-predecode-s2`; its final results
will be recorded below when fitting finishes. No execute-leaf change was made.

## Remaining work / next session

Continue with the current separate fetch/E/result records; do not reintroduce
shared decode/execute instruction state. The largest missing piece is an
in-order memory pipeline with held metadata and separate unready base/load
producer tags. Replace the all-or-nothing slow-operation drain only after
precise abort, older-store ordering and completion capture are preserved.
Then pipeline LDM/STM transfers, reduce PSR/CP15/multiply drain overhead, and
move remaining redirects earlier without lengthening the execute cone.

Concretely, the next edit must extract a held slow-operation context at the
E-to-M1 handoff: `pc`, `ins`, `kind_e`, `flags_e`, base/destination tags and
sequence state are still live inputs to M/W today. Overwriting them with a
younger E instruction is unsafe. Add ordered retirement and unready producer
entries for both load and base writes, then permit independent younger DP
results to wait behind that entry. A fault must discard those younger results.
Only after that works should M1/M2/M3 become independently valid memory
records. The D-cache currently advances RAMs with `i_stall=0`; do not freeze
just metadata on a miss and expect the RAM phase to remain aligned. Younger
stores must wait for every older fault-capable access. Commit and rerun the
full dual-core/reference suite after each of these steps.


The three-edge native RAM contract is still unchanged. B/BL refill has one
additional queue/decode admission edge beyond the native-cache target. A
proven early launch or carefully timed queue-to-D handoff is required; simply
relabelling a stage does not remove that edge. Load-use target timing cannot
be established until the blocking memory controller is replaced.

Risk and coverage boundaries: no firmware boot, full-system timing, real game
or physical-hardware measurement was performed. Empty register lists remain
undefined; unpredictable aliases and every negative multiplier termination
boundary are not exhaustively tested; all new cycle windows are ARM state,
with Thumb semantics covered by the shared suite. Integrated timing and area
must be measured again after memory overlap. Keep ZAP default until the full
performance and timing gates both pass.

No push, branch switch, `sys/` edit or firmware boot was performed. Only this
worktree's task-related CPU, test and documentation files are included.
