# Session 4 SHORT_READ hit-under-miss handoff

No `zap_dcache*.sv` file was changed. The current integrated V2 core uses the
existing `SHORT_READ=1` port. The open ownership question is whether the
cache owner will fix the replacement update described below, or authorize
a scoped change in this worktree. This note describes observed evidence,
not a verified patch.

`zap_dcache.sv` qualifies the short-port tag manager's `i_access` with `idle`,
and ties its `i_idle` low. Thus a lookup acknowledged under a background fill
cannot enqueue a replacement-state hit update through that input. Store
hits still update dirty/tag metadata. In `prepare` in `dhum_rtl.S`, the final
A/B stores and the final A load can overlap the E fill. If the final A load
loses its replacement update, A can be evicted instead of B by the C miss.

The V2 predictor-on run of `dhum_rtl`, zero bus latency, reaches check 26 at
cycle 92,239. The target is B (`0x00431e00`), intended to be the dirty victim.
The watched HUM load count is **1**, expected **0**: B remained resident.
The same check fails at 113,608 / 180,962 clocks for latencies 0:3 / 2:9.
This is not a value or signature mismatch at that point; it is the required
victim-exclusion/overlap assertion. Predictor-off fails the same check.

A value consequence is visible in `dhold_rtl`, predictor on, latency 2:9,
check 69 at cycle 171,415. Its uncached B alias store writes `0x55`, but a
later dirty eviction writes B's old `0xB2` over it because A, rather than B,
was the earlier victim. Bus log excerpt, simulation clocks (not bench debug
counter clocks, which include reset):

```
170499 W 00421e00 be=f 000000a2 burst  # C miss evicts A
170529..170583                       # interleaved instruction/C fills
170609 W 00431e00 be=f 00000055       # requested uncached B alias store
170641 W 00431e00 be=f 000000b2 burst # later A load evicts retained dirty B
170801 R 00431e00 be=f 000000b2       # check expects 0x55
```

The fix must align the hit's set/way/access qualification with the accepted
short-port response, including HUM, hold/relookup and fill installation.
Simply counting every live tag compare would count invalid or speculative
lookups and can change the victim for a request already in flight. Preserve
ZAP's three-edge schedule and check replacement-update priority against
concurrent fill/store metadata. Re-run both cores' cache tests, especially
`dhum_rtl`, `dhold_rtl` and `arm9_cache_lru_rtl`, at every latency.

Two independent integration bugs were fixed in the core before this handoff:
held W requests now own their load-format/check payload, and the first
request following fill-busy falling re-reads its lookup instead of accepting
a pre-installation tag result. The latter previously launched a false miss
over a freshly installed dirty store line. CP15 submission is also now a
single pulse rather than a repeated maintenance request. These fixes do not
provide the missing HUM replacement update.
