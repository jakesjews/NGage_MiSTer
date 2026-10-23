# D-cache capacity experiment — 2026-10-23

Starting tree: `e0e91bc`, branch `codex/timing2`. I-cache prefetch is off.
The withdrawn prefetch timing changes are not part of this work. No boot
bench, whole-core build, hardware deployment, `sys/` or ARM9 edits.

## Design decision, before implementation

Recommend **16 KB, two ways**, selectable for a board experiment, with the
phone's **8 KB, two-way default unchanged**. Preserve the two parallel tag
comparisons and the final two-input load-data select. Expanding the number
of sets adds one bit to registered set indices and makes the valid/dirty/
LRU arrays larger; it does not add a way or widen the live hit-selection
logic. The crucial prerequisite is extending the firmware's **8 KB index
maintenance** to cover all physical sets of the enlarged cache.

### Aliases and the phone's moving memory model

The current cache is virtually indexed **and virtually tagged** (VIVT).
The saved physical tag is for writeback, not for detecting a CPU hit or
cohering aliases. The proposed geometries are:

| Geometry | Sets/way | VA index | Index bits above a 4 KB page | Replacement |
| --- | ---: | --- | --- | --- |
| 8 KB / 2 ways (default) | 256 | [11:4] | none | existing LRU |
| 16 KB / 2 ways (recommended) | 512 | [12:4] | bit 12 | existing LRU |
| 32 KB / 2 ways | 1024 | [13:4] | bits 13:12 | existing LRU |
| 16 KB / 4 ways | 256 | [11:4] | none | would need tree pseudo-LRU |
| 32 KB / 4 ways | 512 | [12:4] | bit 12 | would need tree pseudo-LRU |

A 16 KB four-way cache removes **cross-set page colouring**, but it is
not synonym-free in this implementation. Two VAs mapping one PA can still
have different virtual tags and occupy different ways of the same set.
That is already possible in the default 8 KB two-way VIVT cache. The
"no synonyms when a way fits in a page" argument applies to a physically
tagged VIPT cache, not to ZAP's virtual hit tags. Tiny 1 KB mappings also
have fewer page-offset index bits than any of these geometries.

The firmware already needs a maintenance discipline for both synonyms
(different VAs, same PA) and homonyms (the same run VA reused for another
process). Enlarging the cache must preserve that discipline; four ways
would not replace it with hardware coherence.

Evidence read for this decision:

- `docs/CPU.md`, Architecture / Memory system: VIVT, saved writeback PA,
  TI way bit 31, index operations, DMA range maintenance, fixed CP15 cache
  type and pipeline drain around CP15.
- `model/tools/kstacks.py`: observed EKA1 process data at run address
  `0x00400000`, chunk/current-home metadata at DChunk `+0x28`, and the
  PhoneServer home-region example `0x85000000`. Kernel inspection/copies
  locate a non-running process's memory through its chunk mapping.
- The actual phone kernel disassembly, `research/firmware/analysis/
  ekern.arm.txt` (read from the main checkout's ignored research assets):
  `0x50324158–0x503242D8` moves/changes page descriptors, writes a fault
  descriptor or zero into the old location, and drains the write buffer.
  At `0x50324118–0x50324144`, accumulated change flags conditionally call
  the D-cache clean/invalidate loop, invalidate I-cache, and invalidate
  I/D TLBs. The deferred change handler at `0x5032341C–0x50323458` does
  the same flag-qualified maintenance. This is not a claim that every
  thread switch flushes: fixed mappings/domain-only switches may retain
  cache contents.
- `0x503224BC–0x50322518` reads c0 cache type and loops over
  `mcr p15,0,r1,c7,c14,2` (D clean+invalidate by index).
  `0x50323468–0x503234C4` is the corresponding clean-only index loop.
  `0x503234C8–0x50323500` cleans a VA range by line. These are concrete
  operations, not a hypothesized all-cache instruction.
- The existing trace analysis in `docs/PROGRESS-LOG.md` recorded about
  20 `c7,c14,2` operations per 1000 instructions in the kernel's flush
  loop, about 38 clocks each. No new boot trace was run here.
- The archived Symbian OS Internals memory-model chapter explains the
  moving model's alternate home/run mappings, megabyte-aligned chunk
  ranges, kernel access to non-current chunks, and cache/TLB maintenance
  on moves. It describes EKA2, so it supplies context, not proof of EKA1
  instruction sequences; the phone's disassembly above is the direct
  evidence.

Ordinary home/run moves preserve a chunk's low address offset. With
megabyte-aligned home/run regions they preserve VA[12] as well, so the
16 KB variant does not introduce a new colour for that ordinary move.
The kernel's descriptor moves remove the old mapping, and the cache flush
before subsequent use removes its old virtual tag. Kernel accesses to
another process must use its current/home mapping under the moving-model
protocol, not assume that two arbitrary cached aliases are coherent.

DMA remains noncoherent. `docs/NOS_STANDIN.md` documents the audio shared
chunk at physical `0x0A061000` (60 KB) and the physical half-buffer
addresses sent to NOS/DSP; the stand-in uses the same ownership protocol.
CPU-to-device data must be cleaned before handoff; device-to-CPU data
needs the driver's invalidate/ownership sequence. Physical addressing by
a device or the stand-in is not cache snooping. Existing per-VA operations
keep their meaning, and the all-cache index loops must cover the added
capacity. No claim is made that every driver buffer is uncached.

What can go wrong: an old dirty alias left in an unvisited added set can
later overwrite newer memory on eviction, or a stale clean alias can
return old data. An ad-hoc cached small-page alias differing in VA[12]
can now occupy another set, and per-VA maintenance of only one mapping
does not clean its other aliases. The observed moving-model maintenance
supports this experiment **provided index coverage is extended**; it is
not a proof that arbitrary simultaneous cached aliases are safe. That
pre-existing VIVT restriction and board validation remain explicit risks.

### Keep 8 KB architectural maintenance complete

CP15 continues to report `0x05109149`. The disassembled loop derives
16-byte lines, two ways and 256 sets from it, visits offsets
`0x000..0xFF0`, then way bit 31. Merely setting `DCACHE_SIZE=16384` would
leave sets with VA[12]=1 out of those loops.

The implementation expands each by-index maintenance request to
both physical set colours with the same architectural VA[11:4] and way.
It finishes both before acknowledging CP15. Clean, invalidate and combined
operations retain their respective dirty/discard semantics; by-VA
operations still target their actual VA and set. Whole-cache operations
already derive their bounds from the physical capacity. This sequencing
belongs to the tag RAM's maintenance FSM, away from the live hit path.
The default cache compiles to the existing one-set operation.

### Why not four ways or 32 KB first

Four ways would add two live tag comparisons, a wider data selection,
new invalid-way/replacement selection, pseudo-LRU forwarding, and a
mapping from two reported architectural ways to four real ways for index
maintenance. It also adds 32 data M10Ks before tag storage. That is a
larger timing and verification change without eliminating VIVT aliases.
32 KB two-way keeps the narrow hit mux but quadruples the default set
arrays and adds a second page-colour bit. Start with 16 KB and measure
games before spending that additional area and timing margin.

## Storage and logic cost (computed, not a new fit)

Read the existing server b17 fitter report; a copy is archived locally at
`build/dcache-size/b17.fit.rpt`. Each D-cache way has sixteen independent
256 x 8 data RAMs, **16 M10Ks**, and one 256 x 48 tag RAM, **2 M10Ks**.
The actual default tag width is 48 bits (20 virtual tag + 28 physical
line address); it becomes 47 bits at 16 KB/two-way. Valid and dirty are
separate flip-flop arrays, not part of that RAM word.

Keeping this packing, M10K modes of 512 x 20 and 1024 x 10 give:

| Geometry | Data blocks | Tag blocks | D-cache total | Delta from default |
| --- | ---: | ---: | ---: | ---: |
| 8 KB / 2 | 32 | 4 | 36 | 0 |
| 16 KB / 2 | 32 | 6 | 38 | **+2** |
| 32 KB / 2 | 32 | 10 | 42 | +6 |
| 16 KB / 4 | 64 | 8 | 72 | +36 |
| 32 KB / 4 | 64 | 12 | 76 | +40 |

From the stated 470-block whole-core baseline, the recommended variant
projects **472 / 553 M10Ks**. The data RAM's stored bits double without
adding a byte-lane block. Packing may change in a new fit; these are
computed physical-mode counts, not a measured variant result.

Metadata grows from 512 valid + 512 dirty + 256 LRU bits to
1024 + 1024 + 512: **+1280 state bits**, plus a few pipeline index bits.
The larger arrays also need larger read muxes and write decoders.
The b17 tag-manager hierarchy uses 2937.3 attributed ALMs, of which
2268.8 are its own logic rather than child RAM/forwarding modules;
the children account for about 668.5 ALMs. These include control and
forwarding overhead that does not double with the number of sets.
An exact added ALM count cannot be derived from capacity alone without
synthesis/packing. Budget roughly **1200–2000 added ALMs**, using the
existing hierarchy and the observed approximately 2000-ALM cost of the
I-cache's larger set arrays as bounds for planning, not as a measured
result. With the stated 36,000-ALM tree this projects about 37,200–38,000
of 41,910. The subsequent fitter must establish actual cost and slack.

## Implementation and verification

Before edits: **219 RTL runs pass; 57 QEMU references agree, 0 differ**.
The baseline is archived under `sim/cpu/build/dcache-size/baseline/`,
including generated RTL, logs and per-run counts. Existing binaries and
QEMU references were not rebuilt or rerun. Baseline aggregate:
**19,797,961 cycles**.

The first commit (`b3b5a75`) recorded the design decision before RTL edits.
The implementation adds `NGAGE_DCACHE_16K` as a commented macro in
`NGage.qsf`, and passes `DCACHE_SIZE` / `DCACHE_WAYS` from `NGage.sv` to
`arm925t`. Default values remain 8192 / 2. The CPU wrapper's CP15 cache
type stays `0x05109149`.

`zap_cache_tag_ram.INDEX_SIZE` defaults to the actual capacity. Only the
enlarged two-way D-cache wrapper supplies 8192. On an index request the
maintenance FSM starts at the low reported set, retaining the selected
way, and after LINE_INV increments by 256 sets and repeats LINE_W0 through
LINE_INV until all physical colours are done. It acknowledges only the
last one. Clean-only also takes this path; invalidate-only discards dirty
data just as before. A VA request bypasses the iteration and mask.
No new input ports, live tag comparators, load-data muxes, replacement
policy or cache-hit acknowledge terms were added. The I-cache's
`INDEX_SIZE` equals its physical size, so its behavior is unchanged.

The HUM exclusion compares whole virtual lines, and its victim line is
reconstructed from parameter-derived tag/index fields. Its saved lookup
indices and repair mux use `SET_W`; these were already correctly
parameterized and needed no change. The existing bench assertions for
reserved lines, early/live tag equality, lookup alignment and write
arbitration run at both tested geometries. `dhum_rtl` passes all its
distance 1–6, both-way, filling/victim-line, store, fault and TLB cases.

Only the selected **8 KB/two-way and 16 KB/two-way** configurations are
offered and validated here. Four ways are not implemented: the existing
one/two-way assertion and two-way data select remain. The generic index
iteration also accommodates more set colours, but 32 KB is a cost/design
comparison, not an additional validated board option in this change.

Validation on the final RTL:

| Configuration | RTL suite | QEMU signatures / applicable traces |
| --- | --- | --- |
| 8 KB / 2 ways | **222 passed, 0 failed** | **57 agree, 0 differ** |
| 16 KB / 2 ways | **222 passed, 0 failed** | **57 agree, 0 differ** |

Commands: `make -C sim/cpu run`, then `make -C sim/cpu diff`; for the
variant use a separate `MODEL_DIR` and
`VEXTRA='-GDCACHE_SIZE=16384 -GDCACHE_WAYS=2'`. All runs use the generated
netlist and the three standard latency settings. `make lint` passes;
the `emu` top also passes `-Wall` with `-DNGAGE_DCACHE_16K=1`.
`tools/gen_cpu.sh` and `make cpu-gen-check` pass, and
`grep -c 'input reg' rtl/cpu/arm925t_gen.v` remains **10**.

The new `dcsize_rtl.S` is RTL-only because it intentionally inspects
memory behind dirty cache lines, which QEMU does not model. Only its
binary was assembled; all existing binaries and QEMU references were
reused. It checks:

- clean-by-index reaches the upper physical colour for each TI way,
  leaves the other way dirty, and leaves an unrelated set alone;
- invalidate-by-index discards the upper dirty line without cleaning it
  or invalidating the other way;
- TI C=0 clean+invalidate visits both ways and both colours, with an
  uncached rewrite proving the cached tag was invalidated;
- by-VA clean/invalidate still reaches the upper colour and stays targeted;
- the actual c0-derived kernel loop at `0x503224BC` cleans and invalidates
  before handing a page to a cached alias with the opposite VA[12], then
  hands it back with the updated value.

As a negative control, the same test on the archived, unmodified RTL with
`DCACHE_SIZE=16384` fails **check 3 at cycle 55,979**: the upper-set dirty
line is not cleaned by the reported index. The implemented variant and
the original 8 KB geometry both pass the new test at all three latencies.

Artifacts are under `sim/cpu/build/dcache-size/`: `baseline`, `default`,
`variant16`, per-run `counts.json`, and `negative-control.log`. No
firmware boot bench or new Quartus job was run. The withdrawn prefetch
container was already gone when checked; the remaining b18 job was not
touched.

## Cycle measurements

**The 8 KB default is cycle- and instruction-identical on all 219
pre-existing runs.** The 16 KB variant retains exactly the same instruction
count at every latency, including the cycle-triggered interrupt tests.
Its aggregate over those same 219 runs is **19,875,406 cycles**, versus
**19,797,961** at 8 KB: **+77,445 (+0.391%)**. This is not a simulated
performance win and does not predict the games' result.

The larger cache increases maintenance work: the whole-clean walker scans
64 groups of dirty bits instead of 32, even for an empty cache, and an
index operation must visit two physical sets. Startup maintenance therefore
moves even the uncached tests (about 32 clocks before bus-scheduling
effects); `dhold_rtl` and `dhum_rtl` repeat maintenance particularly often.
The compiled-test changes are small. The existing `cache` test actually
streams 64 KB (as documented in `docs/CPU.md`), so not every test working
set fits in 8 KB, but capacity alone does not remove streaming compulsory
misses or software flushes. The games' long-lived data and real bus waits
must be measured on the board.

Every test is listed below because every variant run's cycle count moves.
Triples are **0:0 / 0:3 / 2:9** bus latency. Instructions are equal between
configurations; a single instruction number means all three latencies
agree. For the new `dcsize_rtl` there is no pre-edit test baseline: its
8 KB result is the reference, with 16,999 instructions in each run.

| Test | 8 KB cycles (before = after) | 16 KB cycles | Instructions |
| --- | --- | --- | --- |
| align | 5291 / 6945 / 11373 | 5327 / 6973 / 11406 | 549 |
| alu | 2994 / 4033 / 6811 | 3030 / 4060 / 6865 | 380 |
| blslot | 1299 / 1731 / 2859 | 1335 / 1757 / 2886 | 138 |
| bpred | 1599 / 2094 / 3456 | 1635 / 2131 / 3502 | 188 |
| bresolve | 3007 / 3960 / 6376 | 3043 / 3993 / 6427 | 430 |
| btb_early | 59504 / 86073 / 153641 | 59536 / 86095 / 153642 | 13779 |
| cache | 789362 / 917207 / 1251084 | 795628 / 923304 / 1257357 | 293427 |
| cache_rtl | 60260 / 87988 / 158774 | 60491 / 88228 / 158980 | 12910 |
| cp15 | 3847 / 4930 / 7675 | 3951 / 5032 / 7762 | 311 |
| crand1 | 72922 / 104399 / 187183 | 72923 / 104353 / 187188 | 15982 |
| crand2 | 73323 / 104839 / 187740 | 73263 / 104665 / 187505 | 15986 |
| crand3 | 73501 / 105353 / 188579 | 73503 / 105236 / 188447 | 16004 |
| crand4 | 73970 / 105359 / 188441 | 73975 / 105297 / 188403 | 15996 |
| crand5 | 73371 / 104835 / 187959 | 73420 / 104897 / 188000 | 15989 |
| crand6 | 73524 / 105368 / 188888 | 73536 / 105302 / 188789 | 16027 |
| crand7 | 73142 / 104536 / 187414 | 73132 / 104491 / 187309 | 15982 |
| crand8 | 73351 / 104956 / 187916 | 73376 / 104929 / 187973 | 15988 |
| ctrand1 | 72413 / 102215 / 178927 | 72445 / 102247 / 178959 | 16159 |
| ctrand2 | 72472 / 102244 / 179116 | 72512 / 102285 / 179163 | 16177 |
| ctrand3 | 72444 / 102238 / 178962 | 72476 / 102270 / 178994 | 16179 |
| ctrand4 | 72460 / 102594 / 179435 | 72501 / 102581 / 179434 | 16198 |
| ctrand5 | 72397 / 102234 / 178967 | 72429 / 102266 / 178999 | 16179 |
| ctrand6 | 72413 / 102204 / 178984 | 72445 / 102236 / 179016 | 16161 |
| ctrand7 | 72261 / 102055 / 178832 | 72293 / 102087 / 178864 | 16153 |
| ctrand8 | 72381 / 102172 / 178933 | 72413 / 102204 / 178965 | 16157 |
| dcache_rtl | 58214 / 85278 / 154102 | 58335 / 85401 / 154196 | 12771 |
| dcsize_rtl | 111795 / 145322 / 237264 | 117239 / 151904 / 244448 | 16999 |
| dcwf | 74403 / 105986 / 188165 | 74467 / 106036 / 188235 | 15336 |
| dcwf_rtl | 59840 / 87757 / 159332 | 59902 / 87810 / 159359 | 13256 |
| dhold_rtl | 273742 / 343931 / 521056 | 286190 / 356345 / 533480 | 41081 |
| dhum_rtl | 483093 / 509201 / 575433 | 488495 / 514596 / 580838 | 24632 |
| exc | 4228 / 5663 / 9815 | 4264 / 5695 / 9826 | 498 |
| fiq_movs | 16927 / 18491 / 22902 | 16959 / 18508 / 22903 | 3583 / 3532 / 3475 |
| fiq_perm | 106828 / 141222 / 236952 | 106858 / 141248 / 236999 | 16544 / 16508 / 16436 |
| gba_arm | 8183 / 10785 / 17742 | 8219 / 10812 / 17775 | 1192 |
| gba_arm_q | 8002 / 10537 / 17217 | 8038 / 10565 / 17265 | 1145 |
| gba_thumb | 4917 / 6509 / 10831 | 4953 / 6535 / 10878 | 774 |
| gba_thumb_q | 4601 / 6092 / 10062 | 4637 / 6122 / 10096 | 715 |
| icache_restart | 76251 / 103292 / 171981 | 76283 / 103305 / 171982 | 13680 |
| icache_rtl | 58072 / 85258 / 154412 | 58022 / 85146 / 154153 | 12771 |
| iprefetch_rtl | 73140 / 104194 / 184182 | 73149 / 104135 / 184081 | 15255 |
| irq | 77438 / 111804 / 212332 | 77474 / 111824 / 212353 | 14633 / 14623 / 14612 |
| ldm | 4159 / 5587 / 9501 | 4195 / 5616 / 9542 | 451 |
| ldmfold | 2347 / 3109 / 5189 | 2383 / 3148 / 5243 | 239 |
| ldst | 3667 / 4931 / 8311 | 3703 / 4962 / 8339 | 414 |
| loadpipe | 82484 / 109276 / 177612 | 82516 / 109308 / 177643 | 24219 |
| loaduse | 60626 / 88009 / 158149 | 60658 / 88041 / 158181 | 13186 |
| loaduse_irq | 119676 / 149477 / 225624 | 119708 / 149509 / 225656 | 21387 / 21225 / 20676 |
| mmu_page | 77070 / 112738 / 203065 | 77106 / 112774 / 203108 | 16887 |
| mmu_sect | 72139 / 104442 / 185914 | 72175 / 104483 / 185944 | 14818 |
| modes | 3009 / 4028 / 6539 | 3045 / 4052 / 6589 | 341 |
| mul | 2236 / 2926 / 4911 | 2272 / 2946 / 4929 | 262 |
| rand1 | 19876 / 27914 / 50983 | 19912 / 27948 / 51009 | 3521 |
| rand2 | 20061 / 28181 / 51279 | 20097 / 28212 / 51306 | 3525 |
| rand3 | 20240 / 28411 / 51691 | 20276 / 28437 / 51726 | 3543 |
| rand4 | 20111 / 28098 / 51389 | 20147 / 28128 / 51405 | 3535 |
| rand5 | 20217 / 28395 / 51807 | 20253 / 28424 / 51826 | 3528 |
| rand6 | 20400 / 28724 / 52530 | 20436 / 28757 / 52562 | 3566 |
| rand7 | 20254 / 28488 / 52090 | 20290 / 28518 / 52126 | 3521 |
| rand8 | 20230 / 28382 / 51605 | 20266 / 28410 / 51647 | 3527 |
| rtl_misc | 8032 / 9017 / 11422 | 8068 / 9040 / 11459 | 309 |
| shift | 2530 / 3328 / 5559 | 2566 / 3365 / 5579 | 329 |
| tbl_irq | 115069 / 134865 / 205774 | 115105 / 134905 / 205810 | 9742 |
| tcallpipe | 95080 / 124702 / 204675 | 95112 / 124718 / 204676 | 18921 |
| thumb | 3026 / 4042 / 6881 | 3062 / 4066 / 6920 | 414 |
| trand1 | 21870 / 30940 / 56039 | 21906 / 30969 / 56058 | 3698 |
| trand2 | 21946 / 31190 / 56508 | 21982 / 31223 / 56530 | 3716 |
| trand3 | 22014 / 31171 / 56488 | 22050 / 31213 / 56516 | 3716 |
| trand4 | 22103 / 31290 / 56883 | 22139 / 31321 / 56925 | 3737 |
| trand5 | 22024 / 31170 / 56479 | 22060 / 31209 / 56498 | 3719 |
| trand6 | 21744 / 30769 / 55726 | 21780 / 30807 / 55734 | 3700 |
| trand7 | 21795 / 30800 / 55659 | 21831 / 30833 / 55702 | 3692 |
| trand8 | 21776 / 30750 / 55728 | 21812 / 30784 / 55765 | 3696 |
| v5und | 4188 / 5327 / 8685 | 4224 / 5358 / 8715 | 416 |

## Risks and exact stopping point

The remaining functional limit is software's existing VIVT alias and DMA
ownership discipline; this change does not snoop physical aliases. It
fixes the concrete added-set hole in the phone's index sweeps, and tests
that fix directly. A suite pass is not proof of every game's driver path.

The live two-way hit cone is unchanged, but larger valid/dirty/LRU arrays
and set-address fanout can still hurt placement and timing. The ALM range
and M10K counts above are estimates from existing packing, not a fit of
the variant. The extra maintenance clocks can offset capacity gains in
workloads that flush often. Both remain reasons to keep 8 KB the default.

Implementation and the requested default/variant verification are complete.
No whole-core build, timing-closure claim, firmware boot or gameplay run
was made. The next owner should uncomment `NGAGE_DCACHE_16K`, fit that
tree, inspect the D-cache tag/metadata paths and actual packing, then
compare instruction rate, SDRAM beats/wait, data stalls and frame rates
in the same Asphalt, Sonic and Tony Hawk scenes. If 16 KB helps without
excessive timing/area cost, a separately verified 32 KB experiment is the
next capacity step; widening to four ways is not needed for this trial.
