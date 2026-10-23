# D-cache write allocation and event counters — 2026-10-23

Starting tree: `a52560b`, branch `codex/timing2`, after the size experiment
was merged. That work remains first: 8 KB/two-way is the default and
`NGAGE_DCACHE_16K` remains an opt-in for the separate board build. This
change adds measurement, not a new allocation policy. No whole-core build,
boot bench, hardware deployment, `NGage.sv`, `sys/` or ARM9 edits.

## What the phone does

TI's **SPRU671, Table 1 / section 4.1**, specifies read allocation for the
TI925T: copy-back read misses load a line, while store misses access memory
without updating the cache. Hits remain write-back. Write-through misses
also bypass allocation. **Section 5 / Table 2** describes a **17-word,
32-bit write buffer**, controlled by CP15 W, MMU enable and page attributes.
Clearing W lets queued writes finish; unbuffered writes stall. Buffered
external aborts are ignored, so fault-capable regions must be unbuffered.
Copy-back evictions use the buffer even with W clear. These rules come from
the [TI reference guide](https://www.ti.com/lit/ug/spru671/spru671.pdf),
printed pages 19–21, read from its local PDF/text copy in
`research/arm925t/downloads/OMAP5910_MPU_Subsystem_spru671.*` in the main
checkout. `research/arm925t/CP15.md` sections 2–3 agree. The web tool could
not fetch the PDF during this task; the archived primary text was available.

The phone firmware actually enables these facilities. In
`research/firmware/analysis/boot-0000-a000.arm.txt`, the boot helper at
`0x2E04–0x2E08` loads literal **0x127F** from `0x2E20` and writes c1:
M, C and W are set, along with I. Its earlier setup at `0x2DC4–0x2DC8`
uses **0x1272**, before enabling MMU/D-cache/write-buffer. The kernel
disassembly `ekern.arm.txt` contains buffer drains at `0x503224B4`,
`0x50323408`, and during descriptor changes at `0x503241C4`,
`0x5032420C`, `0x50324288`, `0x503242D4`. These are firmware evidence,
not a new boot run. Individual framebuffer/blit mappings still depend on
their C/B attributes; this does not establish that every graphics surface
uses copy-back memory.

ZAP differs: `zap_dcache_fsm` accepts a write-back store miss, saves its
data/byte enables, cleans a dirty victim if necessary, reads the complete
line, merges the store bytes, then installs a dirty line. It can retire
the initiating store before the fill ends. There is **no posted write
buffer**. Its write-through store path already does no allocation: it uses
`UNCACHEABLE_PREPARE → UNCACHEABLE → UNC_DONE`, and updates a hit only after
a successful bus response. Noncacheable data and cache-disabled accesses
also use the blocking single-word path. CP15 W is stored/readable, but is
not exported to the cache as a write-buffer enable. CP15 drain currently
goes straight to DONE.

## Implemented event interface

Commit `b275664` adds **`arm925t.dbg_dcache[3:0]`**. Each bit is a one-clock
event for the existing `dbg_counters` per-second accumulator, **not a
32-bit count or an occupancy level**. The owner of `NGage.sv` can pack
these four bits into `dbg_ev` and name the resulting overlay rows:

| Bit | Suggested row name | Exactly what increments it |
| --- | --- | --- |
| 0 | D load fills | Last accepted beat of a D-cache line fill initiated by a load |
| 1 | D store fills | Last accepted beat of a D-cache line fill initiated by a write-back store |
| 2 | D write-backs | Last accepted beat of a dirty-line write-back: replacement eviction **or** whole-cache/by-VA/by-index cleaning |
| 3 | D uncached | Completion of one uncached data read/write, including D-cache-disabled accesses; **excludes write-through stores**, TLB walks and instruction traffic |

Fill/victim/uncached events are registered in `zap_dcache_fsm`. A second
registered event in `zap_dcache` watches the tag manager's final write
beat for explicit cleaning, and is ORed into bit 2. There is one shared
data bus, so the two sources cannot complete two write-backs on one clock.
`zap_top` exports the vector and ties it to zero for `ONLY_CORE`.
The cache is instantiated beside `zap_core`, not inside it, so the actual
route is **D-cache → zap_top → arm925t**; routing it through the CPU
pipeline would add no information. The existing `dbg_stall` route remains
unchanged.

Cases and limits:

- Count **completed line transactions**, not four beats, clocks spent
  waiting, miss retries, or the early critical-word register write.
  A fill crossing a one-second boundary belongs to its completion second.
- Dirty replacement produces one write-back event and later one fill
  event, classified by the original saved load/store direction. A younger
  hit under that miss cannot change the classification.
- Clean invalid/clean lines and invalidate-only operations produce no
  write-back event. By-index operations covering two physical set colours
  can produce two events when both lines are dirty, as intended.
- ACK or ERR completes a beat under the existing bus contract. Cacheable
  burst errors still consume returned data without a late abort; the
  counter describes that completed transaction, not successful memory.
  An uncached external-abort response also counts as an access. Alignment,
  permission and translation faults before a data transaction do not.
- WT stores produce none of these four events; a later WT-page read miss
  produces a load fill. They can be given a fifth counter later if useful.
- Reset clears the pulses. No new input ports or port defaults were added.
  Six source state bits are added (four event flops, one saved uncached
  classifier, one tag-clean event), plus small decoding logic. There is no
  counter RAM or 32-bit accumulator inside the CPU. No debug result feeds
  the ACK, live tag compare, operand or bus-address control paths.

`NGage.sv` is deliberately untouched. `lint/exclusions.vlt` has a single
pin-specific PINMISSING exception for that file's new `dbg_dcache` output;
remove it when the parallel overlay change connects the vector. Other
missing ports remain errors. The unused debug logic may be optimized away
until connected. No fitted area or timing claim is made.

## Streaming-store measurement and counter checks

New RTL-only test **`sim/cpu/tests/walloc_rtl.S`** writes an initially cold
1 KB region with **64 iterations of `STMIA {r4-r7}`**, 16 bytes each. It
checks the merged last word, then explicitly cleans the cache. It reads
the actual exported vector through bench counters at `0xF0000030..3C`.
QEMU cannot model these bench registers/cache events, so the test is tagged
`@@ qemu: no`; existing QEMU binaries and references were reused.

All three bus latencies, at both tested capacities, give exactly:

| Phase | Load fills | Store fills | Line write-backs |
| --- | ---: | ---: | ---: |
| Cold 64 × 16-byte store loop, before cleaning | 0 | **64** | 0 |
| Cumulative after cleaning that loop | 0 | **64** | **64** |
| Read the 64 cold lines, including a second hit word per line | **64** | 0 | 0 |
| Rewrite those warm lines and clean | 0 | 0 | **64** |
| Three dirty stores to one two-way set, before cleaning | 0 | 3 | **1** |
| Cumulative after two by-VA cleans of the remaining lines | 0 | 3 | **3** |
| Dirty hit followed by invalidate-only | 0 | 0 | 0 |
| Four cold write-through stores | 0 | 0 | 0 |
| Then a WT read miss, WT hit store/read, clean | **1** | 0 | 0 |

The test also checks that WT stores do not increment the uncached counter,
and that an uncached scratch write/read increment it exactly twice (plus
the initial counter read itself). It validates actual stored values as
well as event counts. Existing `dhum_rtl`, `dcwf`, fault and maintenance
tests run with the new taps too.

An independent **external bus-log count** of the first streaming phase
confirms **256 read beats and 256 later clean write beats**, with every
word address in the 1 KB range seen exactly once in each direction. This
holds at all three latencies. The loop's elapsed counter interval, including
its final dependent load/check and measurement-read overhead but excluding
the subsequent clean, is:

| Bus latency | 0:0 | 0:3 | 2:9 |
| --- | ---: | ---: | ---: |
| 8 KB cold store-loop interval, clocks | 1614 | 2172 | 4025 |

These are bench timings, not the UPP SDRAM's 12–15-clock fill latency.
The reported 20–25% board SDRAM wait cannot yet be attributed to stores
from this loop or these synthetic tests.

For context, the new **0:0** counters on existing tests are:

| Test | Load fills | Store fills | Write-backs | Uncached accesses |
| --- | ---: | ---: | ---: | ---: |
| cache | 4130 | 4142 | 4153 | 20563 |
| ctrand1 | 77 | 229 | 230 | 4167 |
| crand1 | 171 | 232 | 249 | 4167 |
| dhum_rtl | 1255 | 21 | 316 | 5988 |

Those include initialization and maintenance; they are not game miss rates.

## No-write-allocate: gain, cost and scope decision

For the cold full-line overwrite above, no-write-allocate would require
**zero fill reads and 256 store write beats**, with no later write-back of
those lines. It saves 64 fills and halves the data words transferred for
this particular write-then-clean pattern (512 → 256). It also avoids
polluting the cache or evicting unrelated useful dirty lines. At the given
12–15 clocks per fill, eliminating 64 such fills removes **768–960 clocks
of fill service**, not necessarily that many CPU stall clocks: overlap,
queue pressure and bus arbitration determine the instruction-rate gain.

The gain is workload-dependent. Repeated stores to a warm line already
need no read fill, and write-back can combine repeated updates. A sparse
write followed by a read loses the early allocation and still needs a read
fill under no-write-allocate. Stores bypassing allocation need byte enables,
and four separate writes can have different bus overhead from a four-beat
line write-back. Buffering alone does not imply combining or bursts. The
existing UPP bridge already posts some SDRAM writes; this task did not
alter or benchmark that bridge. Do not convert the board's full SDRAM wait
percentage into an expected gain without the new event measurements.

**No `DCACHE_WRITE_ALLOCATE` parameter is added in this change.** The
requested posted path is not contained within the permitted cache files.
Here is the implementation boundary, rather than a claim that a bypass
itself is difficult:

| Area | What a correct implementation needs |
| --- | --- |
| Store miss | After alignment/MMU permission checks, capture translated PA, data and byte enables into an available queue entry; acknowledge only after capture. Do not reserve/clean a victim or install a tag. A full queue must hold the access without repeating it. |
| Queue and bus | A separate drain engine must keep payload stable until ACK/ERR and arbitrate against fills, write-backs and TLB walks. Even four entries need roughly 4 × (32 PA + 32 data + 4 byte enables + valid) = 276 state bits, plus control; combining needs masks, matches and more logic. No precise ALM cost is claimed. |
| Later loads | A younger read/fill to the same **physical bytes/line** must not read old memory ahead of a queued write. Simplest first implementation drains before all later data reads/misses; more concurrency needs registered physical-address matching and byte forwarding/merging. Virtual-only matching would miss aliases. |
| Hit under miss | Preserve the filling/victim exclusions and fault ordering. A store to an in-flight fill must wait and then hit the installed line, or explicitly merge in age order; it cannot bypass and then be overwritten by stale fill data. Existing HUM is for unrelated cache hits, not a second queued miss. |
| Lookup repair | The existing blocking uncached path holds the lookup/TLB pipeline; fill/HUM holds use the three-set repair sequence. Queue-full holds, delayed requests and resumed hits need the same alignment proof. Capture and drain queued writes independently of live lookup addresses. |
| Precise faults | Permission/alignment faults must precede enqueue. A posted store cannot later take the existing precise `UNC_DONE` abort. TI ignores buffered external aborts, whereas ZAP reports uncached/WT bus errors; preserve unbuffered/device behavior and make the new buffered contract explicit. |
| CP15 and maintenance | Export W and a real drain request/done handshake; drain cannot remain a no-op. Order queued writes before subsequent clean/invalidate, remap/TLB changes, cache/MMU disable and DMA/device handoff as required. A pipeline drain alone is not proof that a separate write queue is empty. |
| Existing WT/uncached paths | Keep their current blocking/error behavior unless deliberately implementing TI buffering for them too. Full TI behavior also needs the page B attribute (including C=0,B=1), which the present cache interface reduces to cacheable/WT flags, and the SWP/device rules. |

The required W/drain interface changes touch `zap_cp15_cb`, `zap_core`
and `zap_top`; full bufferability requires TLB interface work as well.
That is outside the allowed three-file policy scope and deserves its own
ordering/abort test plan.

A **blocking** no-write-allocate experiment could reuse the existing
uncached path locally: on a WB store miss, hold the CPU, bypass the
fill/victim, and acknowledge after the bus response. It would keep later
loads ordered and need no posted queue. However, it would pay the
prepare/bus/registered-completion path for each of the four words, change
cacheable-store external-abort handling unless explicitly preserved, and
would not implement the phone's enabled write buffer. It also brings the
live miss decision into store ACK selection, which needs timing review.
It is left as a separately measurable experiment, not shipped as a
misleading substitute for the requested buffered policy. No variant speed
or equivalence result is claimed.

## Verification and cycles

Before edits on the merged tree: **222 RTL passes, 57 QEMU agreements**.
After the counter addition:

| Configuration | RTL suite | QEMU comparisons |
| --- | --- | --- |
| Default 8 KB / two ways | **225 passed, 0 failed** | **57 agree, 0 differ** |
| Existing 16 KB / two ways | **225 passed, 0 failed** | **57 agree, 0 differ** |

There is no new policy variant. The second run checks that the event logic
also works with the already-merged size option. Commands were
`make -C sim/cpu run` / `diff`, and the same with a separate `MODEL_DIR`
and `VEXTRA='-GDCACHE_SIZE=16384 -GDCACHE_WAYS=2'`. Only the new
`walloc_rtl` binary was built. No existing binary or QEMU reference was
rebuilt or rerun.

**Every one of the 222 pre-existing default runs has identical cycles and
instructions before/after**: 20,292,342 cycles in total. There are no moved
tests to list. All 222 runs at 16 KB also exactly match the archived
size-task results. Representative before = after counts, latency order
**0:0 / 0:3 / 2:9**:

| Test | Default cycles, before = after | Instructions |
| --- | --- | ---: |
| cache | 789362 / 917207 / 1251084 | 293427 |
| dcache_rtl | 58214 / 85278 / 154102 | 12771 |
| dhold_rtl | 273742 / 343931 / 521056 | 41081 |
| dhum_rtl | 483093 / 509201 / 575433 | 24632 |
| dcwf | 74403 / 105986 / 188165 | 15336 |
| ctrand1 | 72413 / 102215 / 178927 | 16159 |
| crand1 | 72922 / 104399 / 187183 | 15982 |
| gba_arm | 8183 / 10785 / 17742 | 1192 |
| gba_thumb | 4917 / 6509 / 10831 | 774 |

New `walloc_rtl` (no pre-edit equivalent):

| Geometry | Cycles, 0:0 / 0:3 / 2:9 | Instructions |
| --- | --- | ---: |
| 8 KB / two ways | 67402 / 97006 / 173816 | 13777 |
| 16 KB / two ways | 67692 / 97193 / 174135 | 13777 |

`make lint` passes, as does top-level `-Wall` lint with
`-DNGAGE_DCACHE_16K=1`. `tools/gen_cpu.sh` regenerated the committed netlist;
`make cpu-gen-check` passes and `grep -c 'input reg'
rtl/cpu/arm925t_gen.v` stays **10**. Local artifacts are under
`sim/cpu/build/walloc/{baseline,default,variant16,stream}`: logs, per-run
counts, baseline generated netlist, bus logs and interval dumps.

## Stopping point

Counter implementation, tests and allocation analysis are complete.
Allocation policy and existing cycle behavior remain unchanged. The next
owner should connect the named bits to the per-second overlay, measure the
same game scenes with 8 KB and 16 KB, and distinguish store fills from load
fills and line write-backs before choosing a larger cache or a write-buffer
project. The counters count lines, not SDRAM wait clocks, and write-backs
include maintenance; they cannot alone assign all SDRAM wait time to a
particular cause. No whole-core fit, boot or board result is claimed here.
