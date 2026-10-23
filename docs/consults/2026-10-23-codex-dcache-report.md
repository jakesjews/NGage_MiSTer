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

The intended implementation expands each by-index maintenance request to
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

## Baseline and execution status

Before edits: **219 RTL runs pass; 57 QEMU references agree, 0 differ**.
The baseline is archived under `sim/cpu/build/dcache-size/baseline/`,
including generated RTL, logs and per-run counts. Existing binaries and
QEMU references were not rebuilt or rerun. Baseline aggregate:
**19,797,961 cycles**.

This first commit records the design decision before implementation.
Variant implementation, directed maintenance coverage, complete cycle
tables and final verification will follow in the next commit. No
whole-core build is authorized for this task; another engineer owns the
fit and board measurements.
