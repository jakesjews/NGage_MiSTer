# ARM9 replacement: session 4 continuation report

## Status

**Partial: scalar memory now overlaps younger arithmetic with ordered retirement.
The streaming memory pipeline is not implemented, and ZAP remains the default.**
This report supersedes [session 3](arm9/session3-report.md); its measurements and
integrated timing evidence remain archived there. No firmware boot, push,
branch switch or `sys/` edit is part of this work.

## First checkpoint: independent memory context

The E valid bit and register-shift wait bit no longer share the slow controller's
state. A slow E handoff captures PC, PC+8/+4, raw/decoded instruction, flags,
kind and base/destination physical tags. Post-E memory, abort, CP15, block
continuation and retirement read that context. Request address, store data,
format, load destination and W controls retain their existing held registers.
The bench data-PC tap reads the held memory PC; E can now name another instruction.

Non-PC DP can execute behind a scalar load/store. Two elastic result records
hold its results and a third instruction can wait in E. Only the older memory
operation can retire while it is outstanding. A memory fault discards E and both
younger result records before exception entry; no younger store or branch is
admitted. This preserves precise flags as well as register state. Interrupts,
fetch faults, other PC writes and state operations still wait for the older work.

Forwarding has four ordered physical-tag slots: fast M, fast W, pending load,
pending base. Load and base are unready until memory retirement. Load has priority
over an aliased base write, matching the reused register file's two write ports.
A younger ready writer shadows an older unready writer. Held E operands capture
bypasses each edge so values survive producer retirement while another source or
queue space stalls E. Only used operands interlock; false conditions skip operand
and shift waits. E takes current flags from younger M/W or committed CPSR.

The memory cache protocol is unchanged: three native RAM read edges, registered
acknowledge data, a classification edge to observe the newly set miss lock,
critical-word completion capture before architectural W, and held/replayed access
rules. SWP, LDM/STM, base-restored block aborts, CP15 and multiply retain their
serialized paths. This checkpoint does not claim the TRM load-use delay or
one-store-per-cycle throughput.

`arm9_memory.S` exercises both uncached and cached operation, including warmed
repetition. Cases: unready load shadowed by a younger write, both load and
post-indexed base consumers, a loaded shift count, queue backpressure and held
operands, failed memory/consumer conditions, and an abort with speculative
register/flag results plus a younger store. Its handler verifies original state,
SPSR, fault PC and restored base. Full instruction traces and signatures compare
with QEMU; only this new binary/reference was built.

The old `arm9_cycles` binary/reference are unchanged. Its source's bench tag now
selects `sim/cpu/arm9/cycles.txt`, a versioned expectation file. The bench requires
every embedded window exactly once, rejects zero/unknown/duplicate/missing rows,
and retains the original five visits and two exact hot 0:0 checks. The 69 TRM
windows are not removed or relaxed. External expectations let cycle behaviour
change without rebuilding existing instruction streams or QEMU references.

## Cycle evidence

Both cores passed the requested pre-edit 27 runs; see
[baseline](arm9/session4-baseline.json). The first overlap checkpoint is recorded
in [context counts](arm9/session4-context.json). All nine tests retain exactly
their baseline instruction counts; ZAP cycle counts are unchanged. Each cell is
**0:0 / 0:3 / 2:9**.

| Test | ZAP | Session 3 ARM9 | Context overlap ARM9 |
| --- | --- | --- | --- |
| cache | 760787 / 888787 / 1222550 | 1237634 / 1317526 / 1652590 | 1122872 / 1214017 / 1558622 |
| dcache_rtl | 58301 / 85328 / 154143 | 99427 / 124688 / 201580 | 99352 / 121636 / 201507 |
| ctrand1 | 72594 / 102419 / 179154 | 125032 / 152984 / 237636 | 123979 / 148978 / 236545 |
| crand1 | 73608 / 105167 / 187620 | 124960 / 154055 / 243949 | 123933 / 150284 / 243069 |
| gba_arm | 8291 / 10887 / 17749 | 7439 / 9468 / 15551 | 7315 / 9466 / 15552 |
| gba_thumb | 4913 / 6523 / 10877 | 4515 / 5780 / 9696 | 4451 / 5781 / 9697 |

ARM9 still loses the four memory-heavy families at every latency. It wins both
GBA tests at every latency. The mechanism is still the single memory engine and
its admission/completion bubbles, not data-bus bandwidth. Scalar load-independent
window falls 13 to 10, immediate ALU consumer 13 to 11, loaded base/store consumer
20 to 17, loaded shift count 14 to 12, store window 12 to 9. These include the end
marker and entry/drain effects; they are not standalone instruction cycle costs.
DP chains, branches, SWP and block windows retain their session-3 expectations.
Some GBA high-latency runs vary by one cycle as the changed request phase changes
the deterministic bus-latency sequence.

## Risks, coverage and remaining work

The most important functional risk is confusing a cache completion with retirement
or losing an E operand when a producer disappears. The held context, ordered
result queue, completion-to-W bench checks and directed fault case address these.
There is still only one outstanding memory instruction, so ordered multiple
memory records, younger held requests across fills and streamed block transfers
are not covered by this implementation.

The four-source bypass and elastic queue add control/fanout to an already tight
execute boundary. No E stage has been added. Timing has not yet been rerun at this
checkpoint. Session 3's integrated -2.623 ns is historical, not a measurement of
this netlist; its cache/Thumb-translation and execute-to-flags families remain
unresolved. ZAP must remain default until all cycle and timing gates pass.

Next, reduce scalar admission/completion bubbles, then replace the single memory
engine with independently valid request records whose advances match the cache
RAM edges. Keep base and load producers separate and preserve precise abort
ordering. Only then stream block transfers and preserve the original base until
all transfers can no longer abort. Do not freeze only the CPU metadata during a
fill: the cache's relookup sequence owns the RAM phases. SWP must remain an ordered
read/write pair. The original request's timing work follows memory implementation.

No full-system fit, firmware boot or hardware game measurement has been performed.
Empty block lists/unpredictable aliases and negative multiplier termination
boundaries retain the session-3 coverage limits.

## First-checkpoint verification

ARM9 and ZAP each pass **210/210** generated-netlist runs and **56/56** QEMU
signature/trace comparisons (0 differ). The new test contributes three runs and
one comparison. ARM9 source smoke passes 18/18 runs and six comparisons.
All 69 cycle windows pass their two exact hot checks; changing the DP expectation
from 9 to 10 fails both checks. Execute leaves pass 582,272 reference checks.
`make lint` passes and `make cpu-gen-check` reports the netlist current. Extra
source lint finds only the inherited D-cache FSM index-width warnings after
waiving legacy unused/interface warnings; no new ARM9 warning is reported.
The checkpoint evidence is [recorded here](arm9/session4-context-verification.txt).
