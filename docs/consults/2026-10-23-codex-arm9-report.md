# ARM9 replacement: session 5 continuation report

Work in progress on `codex/arm9`. ZAP remains the default. The unchanged
[session-4 report](arm9/session4-report.md) records the starting point.

## First checkpoint: ordered scalar request pipeline

Replaced the single scalar memory slot and two younger arithmetic slots with
four ordered records: three records tracking the native cache read edges, and
W. Both arithmetic and scalar memory use these records. E starts the first RAM
read on its handoff edge. Each record retains its own address, store data,
format, byte enables, physical load/base tags, flags, PC and condition result.
No cache RAM, tag comparison, bus protocol or execute arithmetic was changed.

The first two records advance through the same enabled edges as the cache;
the third supplies the request and receives ack/error. The preceding record
supplies the MMU check's address and access mode. An uncached access holds the
pipeline until its registered response. A fill freezes it using the cache's
existing registered fill-state indication, exported through the wrapper.
After a fill or a TLB retry, three reload clocks reconstruct the held request
and its two younger lookups, including the MMU check. Fill writes run during
this hold; the core must not disable their RAM clock. `i_stall` is wired for
core-owned holds, while the cache still owns uncached/fill holds.

W captures formatted hit data. A newly asserted miss lock prevents retirement;
the critical-word pulse replaces provisional data in W before its next possible
retirement. Registered W data is the only load bypass into E. Each of four
records supplies a load tag and a base/ALU tag, youngest first. Load wins a
same-instruction base alias; a younger ready writer shadows an unready load.
Base arithmetic can forward speculatively, but only ordered W changes the RF.
Held E operands continue capturing disappearing bypasses.

A memory error becomes a fault in W. On that cycle younger data requests are
suppressed and E/all younger records are discarded. No store passes an older
fault. Conditions suppress both requests and register writes. Separate check
and access modes preserve user-translated accesses. PC loads/PC-relative memory,
block transfers, SWP, state changes and multiply initially retain the drained
slow controller. Its data-PC tap and the new pipeline tap are selected separately.

`arm9_stream.S` adds adjacent stores/loads on one word and different sets,
read-after-write byte/halfword collisions, post-index base chains, gaps, and
aborts immediately followed by younger stores. It runs uncached, cached and
warm-cached, with full signatures/traces against QEMU. Only this new test's
binary/reference was built; existing binaries and QEMU references are unchanged.

The first implementation exposes one scalar request per clock on hits, but
**does not meet the requested load-use timing**: E launch, three native RAM
edges and registered W bypass produce three dependent E wait clocks. The
independent LDR/ALU retirement window is 3 clocks, dependent is 6, and STR is 2
(including the marker). The pipeline also initially adds two drain clocks to
slow operations, regressing the multiply-heavy cache test despite improving
scalar memory throughput. These costs are explicit follow-up work.

Baseline measurements: [session5-baseline.json](arm9/session5-baseline.json).
First scalar measurements: [session5-scalar.json](arm9/session5-scalar.json).

First checkpoint verification: both cores pass 213/213 runs and 57/57 QEMU
signature/trace comparisons. All 69 timing windows pass; top-level `make lint`
and `make cpu-gen-check` pass. All nine baseline instruction counts match,
and every ZAP cycle count is unchanged. See the
[verification ledger](arm9/session5-scalar-verification.txt).

## Slow-instruction admission refinement

Slow instructions may now enter E while older records drain, provided every
D operand is ready. They execute only when the last older W can retire on the
same edge and the cache is not held. An older fault suppresses this handoff.
The ready-at-admission rule is required because multiply, SWP and block setup
use captured D operands rather than the execute leaf's bypassed result. Flags
come from the newest older record or committed CPSR, including MRS/MSR.

This removes two retirement-window clocks around most slow operations without
changing execute length. It does not materially improve the cache workload:
its loop's taken branch already hides this admission opportunity. The measured
numbers are in [session5-admission.json](arm9/session5-admission.json).

Admission refinement verification: both cores pass 213/213 runs, 57/57 QEMU
comparisons, all 69 windows, `make lint` and `make cpu-gen-check`. The
[ledger](arm9/session5-admission-verification.txt) identifies the checked netlist.

## Streaming blocks and PC loads

LDM/STM capture their immutable instruction/base/mode/SPSR context once in E.
A register-list selector, one RF read and an address counter then feed the
ordered pipeline one register per enabled clock. The final packet performs
base writeback (suppressed for LDM with its base in the list) and, for an
exception return, restores SPSR. Memory permission checks carry a separate
access mode: the final return's new mode must not authorize its own access.

An error cancels every younger transfer. Earlier completed transfers remain.
When W was requested, the fault path restores the original physical base in
an internal non-final micro-op before entering the abort, even if an earlier
LDM transfer loaded that base. Restoration precedes exception entry so an
alias with the abort bank's LR still gives the exception link priority.

Ordinary PC-relative memory and loads to PC now use the scalar pipeline.
A loaded-PC W redirect suppresses younger memory requests and clears their
records. A slow instruction waiting in E cannot execute on that redirect edge.
Unpredictable memory forms that write back to PC retain the slow path.

The one-register LDM/STM window is 11 clocks; three registers take 13. Thus each
extra register costs one clock, versus seven in session 4. Fixed setup/drain
cost remains ten marker-inclusive clocks around the stream. The loaded-PC
window is 11 clocks. Seven new `arm9_stream_timing.S` windows each execute eight
adjacent memory instructions: same word, different sets, post-indexed bases,
and mixed loads/stores. All seven take exactly 9 hot clocks including the end
marker. They use the existing independent retirement-window checker and are
also compared with QEMU; no production timing tolerance was added.

Block checkpoint verification: both cores pass 216/216 runs and 58/58 QEMU
comparisons. The 69 existing and seven new timing windows pass, as do `make
lint` and `make cpu-gen-check`. The [ledger](arm9/session5-block-verification.txt)
identifies the checked netlist.
