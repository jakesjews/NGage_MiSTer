# D-cache store completion and deferred eviction — 2026-10-23

Started on `codex/dstore` from master `f12bb8a`. The completed timing-round-5
branch `codex/timing2` is preserved at `c188fe5`; none of its unmerged CPU
changes are included. The build uses master's stripped default, with no
debug macro. No firmware boot bench, board deployment, `sys/` changes or
ARM9 changes.

## 1. Store-miss completion: already implemented on master

The premise in the Pocket-core consult does not match this ZAP revision.
In both valid-victim and invalid-victim miss branches, `zap_dcache_fsm`
already acknowledges a checked, cacheable write-back store in IDLE. The
payload, byte enables, VA, PA and victim context are captured on that edge.
It does so **before** even launching the bus fill, and before a dirty
victim's write-back. There is no destination register to lock for a store.
`data_stall` only holds the CPU for a subsequent unacknowledged access;
it is not driven by the fill's occupancy. Hit-under-miss already permits
unrelated hit loads/stores during this transaction.

No RTL optimization is needed for item 1. Delaying its acknowledgement to
bus launch would lose cycles. The bytes merge into the registered fill
buffer; installation is exclusive. Filling/victim-line accesses, another
miss, uncached/WT operations and maintenance retain their existing ordering.
Alignment and translation faults are decided before acceptance. Cacheable
bus ERR already completes a beat without a late data abort; this task does
not change that contract. Uncached errors still fault precisely.

Added `dstore_rtl.S` and bench-only observations. The test repeats cold and
warm instruction passes, with a fixed 24-clock beat delay. It covers clean
and dirty victims, an independent 32-instruction arithmetic stream, a
load from the filling line, victim loads/stores, another miss, line clean,
line invalidate, line clean/invalidate, whole-cache clean and invalidate.
It checks merged and untouched bytes and all four victim words. Whole-cache
invalidate intentionally discards the dirty new line after the accepted
victim eviction completes. It requires at least eight instructions to
retire during the background store transaction on the warm independent
pass. A bench assertion checks every eligible store miss is acknowledged
without hold, fault or replay. Bus-event observations separately count
whether a dirty transaction begins with a fill or a write-back.

On unchanged master the directed test passes at all three latencies and
observes 188 instructions retiring during background stores at 0:0; all
18 dirty transactions begin with write-back. This verifies early completion
rather than claiming a new cycle gain. The 225 original runs pass and
57 QEMU signatures/traces agree. Only the new RTL-only test binary is built;
existing binaries and QEMU results are reused.

## 2. Deferred dirty write-back

Implementation and final timing sanity check are in progress. Final cycle
comparison, risks and exact stopping point will be recorded here.

Item-1 verification: **228/228** runs pass (225 original plus three new),
all original and new-test cycles/instructions are unchanged by the bench
instrumentation. Generated-RTL check and stripped lint pass; generated
`input reg` count remains 10. At 0:0 / 0:3 / 2:9 the new test uses
172,772 / 198,824 / 264,911 cycles and 15,119 instructions each.
