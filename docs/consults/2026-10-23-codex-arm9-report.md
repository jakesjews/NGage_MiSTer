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
