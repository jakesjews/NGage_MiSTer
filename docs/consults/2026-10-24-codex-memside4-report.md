# memside4: cache metadata in synchronous block RAM

Work is on `codex/memside4`, based on `codex/memside3` at `df29e89`.
The inherited early-execution gate and one-bit fetch handshake are unchanged.
No ZAP pipeline, ARM9, `sys/`, board RTL or cache-capacity default is changed.

The default fit saves **3,272 ALMs** but worsens setup slack by **0.456 ns**.
The 16 KB D-cache fit saves **6,878 ALMs** and improves slack by **0.639 ns**.
Both retain a negative-slack dirty-RAM write-control path. The final design
preserves single-cycle whole-cache invalidation; it does not use the initially
tried invalidate sweep. CPU cycle and instruction equality is checked against
fresh runs of the parent, separately for each cache-size configuration.

## Design

The implementation is in `zap_cache_tag_ram.sv`. Each way still has its original
tag and data RAMs. Metadata is read synchronously at the same lookup address,
with the existing three-edge timing for ZAP or the first RAM edge for
`SHORT_READ=1`. The normal hit comparator still receives `valid_q`, `dirty_q`
and `lru_q` from the same final register boundary. No request, ACK, fill,
lookup-repair or maintenance completion stage is added.

### Valid: four RAM banks and one live flag per four sets

Each way's valid bits occupy four interleaved one-bit RAM banks, indexed by
`set >> 2`; `set[1:0]` selects the bank. A `valid_live` flip-flop per four-set
group says whether that group's RAM bits belong to the current cache contents.
Reset, whole invalidate and cache disable clear the live flags in the same
clock that the old implementation cleared the per-line valid array.

An install into a dead group writes all four banks at that group address:
only the installed line becomes valid. Subsequent installs update their own
bank. Thus clearing the group flags cannot resurrect stale RAM bits, however
many invalidations occur. There is no finite epoch counter and no rollover
sweep. A line invalidate writes zero only to the addressed bank, preserving
its neighbours. Pending installs and read/write collisions are forwarded.

The live flag is sampled alongside the RAM read. In ZAP the four-way bit
selection and flag qualification precede the existing metadata pipeline
registers; they do not add a serial term to the live hit comparison. The short
port uses only the first read and its registered collision/current-write
qualifiers, with the small bank selection parallel to the tag comparison at
the caller's existing compare/capture boundary. No extra read cycle is added.
Its integration still needs the ARM9 branch's own physical timing check.

This retains some flip-flops deliberately: one quarter of the old valid-array
bits. Four banks, rather than sixteen, balance ALM savings against actual
M10K availability. The cited 63% usage is **memory bits**, not RAM blocks:
the archived b26 fit uses 487 of 553 blocks (88%). Counting spare bits as
independently allocatable blocks would over-budget this device.

The optional prefetch tag copy uses the same four-bank validity scheme and
registered read/write bypass. It remains off by default. Both settings are
covered by the metadata unit bench.

### Dirty: sixteen banks retain the clean scanner's throughput

The existing whole-cache clean operation searches sixteen dirty lines per
clock. Serializing that search through a one-bit RAM would change maintenance
cycles. Instead, each way has sixteen one-bit banks indexed by `set >> 4`.
Normal lookup reads that group and selects `set[3:0]`; the clean scanner reads
all sixteen bits of its current group. At clean entry, group zero is read on
the request edge. When an empty group advances the block counter, the next
group is read on that same edge. The scanner retains its priority order,
existing wait states and four-beat write-back protocol.

A `dirty_initialized` flag per sixteen-set group provides logical zero after
reset without resetting the RAM contents. The first update initializes all
sixteen bank entries, with only the addressed line allowed to be dirty.
Later updates change just their bank. Maintenance clears have their original
priority over pending updates. Whole invalidation and cache disable **do not
clear dirty bits**, matching the parent; reset does. Whole clean can therefore
still visit invalidated dirty lines exactly as in the parent implementation.
Single-line checks use the registered valid/dirty read after the existing
maintenance wait states, instead of asynchronously indexing a full array.

`get_tag_ram_rd_addr` and `baggage`, including their cache-wide dirty-vector
shifts, are removed. The existing 16-bit priority encoder and block/beat
counters remain. The block counter now addresses synchronous RAM banks.

### LRU: one read port, one update port, bounded fill deferral

Each cache has one one-bit-per-set LRU RAM. Pending hit and tag updates retain
their original registered ownership, order and forwarding. A hit wins if both
updates address the same set. If a hit and fill update different sets in the
same clock, the hit uses the write port and a single deferred-fill entry
retains the fill update. Reads forward that entry until it drains. A newer
hit to its set supersedes it. Exclusive installation and miss intervals bound
the backlog; a simulation assertion detects an unsupported second independent
collision before the entry can drain.

LRU RAM contents need no reset or invalidate sweep: invalid ways take priority
in victim selection, and installs establish the set's replacement state
before it contains two valid ways. This preserves observed replacement
choices and all suite cycles. The deferred-entry valid bit is cleared on
reset and whole invalidation.

`ACCEPTED_HIT_UPDATE` preserves the ARM9 short D-port contract: LRU ownership
comes from the accepted response's address/way, including a HUM response
while a different younger lookup is held. It does not infer acceptance from
that younger probe. The existing same-set accepted-response bypass into the
victim choice is retained.

### Holds, forwarding and reset

The metadata pipeline's original maintenance clock enables matter: valid/LRU
advance on a whole/line clear even if the tag-data port is held; dirty advances
on a clean/line clear. These enables are preserved. Same-edge RAM writes are
explicitly bypassed, so the result does not depend on device read-during-write
behaviour. Live tag writes still enter only the final normal-port forwarding
stage; earlier stages receive registered pending writes.

The first-read live/initialized flags and the short current-write qualifier
clear on reset even when the read port is held. An added soft-reset unit case
found that omitting this could briefly revive a pre-reset read in the metadata
pipeline. It is fixed and tested with both held and running ports. A synthesis
attempt was stopped before fitting when this check found the issue; it is not
reported as a fit result. The completed fit uses the corrected snapshot.
A second mapping attempt showed that Quartus 17 ignored the RAM-style hint on the nested generated
scalar arrays: the sixteen-bit D-cache banks remained logic, while other
banks were inferred as AUTO. That attempt was stopped before completing a
fit. The arrays now sit inside the plain `zap_cache_metadata_ram` module,
which carries the M10K directive directly on its memory declaration. Its
registered read is unchanged. The read-only I-cache explicitly selects
`TRACK_DIRTY=0`, avoiding useless dirty RAMs; the D-cache keeps tracking.

## Registers and RAM inventory

Removed storage:

- `valid[LINES_ALL-1:0]`: replaced by valid RAM banks and quarter-size group flags.
- `dirty[LINES_ALL-1:0]`: replaced by dirty RAM banks and sixteenth-size initialization flags.
- `lru[LINES-1:0]`: replaced by the LRU RAM.
- The old first-stage metadata flip-flops `valid_s1`, `dirty_s1`, `lru_s1`
  become wires from synchronous RAM reads/bypasses.
- In `SHORT_READ`, `valid_s2`, `dirty_s2`, `lru_s2` and the normal final-stage
  metadata registers are absent; corresponding unused outputs are constant
  or directly connected to the first read. Unused normal delayed-set logic
  is eliminated. The RAM primitives' entire `g_three_edge` branch is absent.

New register names (per generated instance, not per individual bit):

| Scope | Registers |
|---|---|
| Tag manager | `dirty_read_bit_ff` |
| `g_metadata[w]` valid side | `valid_live`, `valid_live_q`, `valid_read_bit` |
| `g_metadata[w].g_valid_bank[b]` | `valid_ram.o_data`, `collision`, `forward_bit` |
| `g_metadata[w].g_dirty` | `dirty_initialized`, `dirty_initialized_q` |
| `g_metadata[w].g_dirty.g_bank[b]` | `dirty_ram.o_data`, `collision`, `forward_bit` |
| `g_metadata[w].g_short` | `current_write`, `current_dirty` |
| `g_lru` | `lru_read`, `lru_read_fwd`, `lru_read_value`, `defer_en`, `defer_val`, `defer_set` |
| `g_lru.g_short` | `now_fwd`, `now_value` |
| Optional `g_prefetch.g_pf_way[w]` | `pf_live`, `pf_live_q`, `pf_bit_q` |
| Optional prefetch `g_valid[b]` | `valid_ram.o_data`, `collision`, `forward_bit` |

Existing `pend_*`, `hit_pend_*`, maintenance counters/state, normal second/final
metadata registers and RAM forwarding registers keep their roles. Names such
as `dirty_group_q`, `valid_group_q`, `valid_s1_raw`, `dirty_s1_raw`, `pf_valid_q`
`read_bit` connections and the write selectors are wires, not additional storage.

The short RAM primitives are the already-used ARM9 branch implementation:
`zap_ram_simple.g_short` has `read_data`, `write_data`, `forward_write`;
the byte-enable primitive has the corresponding per-byte qualifier vector.
These branches are absent in the shipping ZAP configuration.

New logical block RAMs, all explicitly marked `ramstyle="M10K"`:

| Instance | Organization per way/cache |
|---|---|
| `g_metadata[w].g_valid_bank[0..3].valid_ram.mem` | Four banks of `LINES/4 × 1` per way |
| `g_metadata[w].g_dirty.g_bank[0..15].dirty_ram.mem` | Sixteen banks of `LINES/16 × 1` per way; absent for the read-only I-cache |
| `g_lru.lru_mem` | One `LINES × 1` RAM per two-way cache |
| Optional `g_prefetch.g_pf_way[w].g_valid[0..3].valid_ram.mem` | Four validity-copy banks per way; absent with prefetch off |

For the usual I=16 KB / D=8 KB configuration, logical array storage before
optimization is 1,536 valid bits, 768 LRU bits and 512 meaningful D-dirty bits.
The replacement group flags are 384 valid and 32 dirty-initialized bits:
**2,400 fewer array flip-flops**, before counting the small read/bypass and
LRU queue registers. For I=32 KB / D=16 KB, the corresponding reduction is
**4,800 array flip-flops**. These are source-level counts, not measured ALMs.
Synthesis confirms **50 metadata M10Ks**: eight valid banks and one LRU
RAM for each cache, plus 32 D-cache dirty banks. No I-cache dirty banks remain.
The physical fit's whole-core totals and timing belong below.

## Verification and cycle comparison

The original 79 binaries and 57 QEMU references are reused. No assembly test
or reference was rebuilt. The new directed test is the standalone RTL bench
`sim/cpu/tb/tb_cache_metadata.sv`, run by
`sim/cpu/tools/check_cache_metadata.sh`.

It covers same-edge install/read, immediate dirty visibility, consecutive
clean/dirty tag updates followed by eviction selection, first-write neighbour
initialization, normal hit LRU, accepted short-port HUM LRU with a different
held probe, simultaneous independent fill/hit updates and deferred drain,
line clean/invalidate, whole clean and exact burst data/counts, single-cycle
whole invalidate followed by lookup/install, repeated invalidations without
stale-group resurrection, disable/re-enable, and soft reset with running and
held lookup ports. Sizes 8/16/32 KB run with both normal and short reads;
16 KB also runs with the optional prefetch tag copy: eight configurations.

An additional scratch lockstep checker instantiated the original tag manager
beside the replacement while running the I-cache CPU test. It exposed the
maintenance clock-enable difference described above; preserving those enables
restored cycle equality. The temporary reference/checker is evidence under
`build/memside4/check/`, not a second production implementation.

The verification totals and cycle table below use the saved logs. Stale logs for tests from older branches are excluded: the manifest is
the current Makefile's 79 tests at exactly `0:0`, `0:3`, `2:9`.

All **948 CPU runs pass** (237 per configuration), with **zero cycle changes** and
**zero instruction-count changes** against their matching parent configurations.
Every QEMU comparison reports **57 agree, 0 differ**. There are no IRQ/FIQ
count exceptions in this task. All existing binaries/references are unchanged.

| I / D cache | Runs | Total cycles before = after | Instruction-count changes |
|---|---:|---:|---:|
| i16-d8 KB | 237 | 21,804,321 | 0 |
| i16-d16 KB | 237 | 21,909,584 | 0 |
| i32-d8 KB | 237 | 21,804,297 | 0 |
| i32-d16 KB | 237 | 21,909,566 | 0 |

Complete default-configuration table. Every number is **before = after**;
there is no moving-test list because no test moves. The other configurations
have the same equality, recorded per test in their saved count JSONs.

| Test | 0:0 cycles | 0:3 cycles | 2:9 cycles |
|---|---:|---:|---:|
| align | 5,076 | 6,433 | 10,287 |
| alu | 2,842 | 3,811 | 6,277 |
| blslot | 1,256 | 1,601 | 2,572 |
| bpred | 1,544 | 1,962 | 3,137 |
| bresolve | 2,830 | 3,707 | 5,902 |
| btb_early | 59,403 | 85,262 | 151,147 |
| cache | 752,357 | 860,838 | 1,127,776 |
| cache_rtl | 60,163 | 87,242 | 156,381 |
| cp15 | 3,633 | 4,482 | 6,721 |
| crand1 | 72,510 | 103,452 | 184,617 |
| crand2 | 72,835 | 103,807 | 185,198 |
| crand3 | 72,909 | 104,187 | 185,805 |
| crand4 | 73,534 | 104,273 | 185,824 |
| crand5 | 72,885 | 103,912 | 185,332 |
| crand6 | 73,056 | 104,375 | 186,302 |
| crand7 | 72,642 | 103,471 | 184,677 |
| crand8 | 72,916 | 103,917 | 185,364 |
| ctrand1 | 72,299 | 101,341 | 176,329 |
| ctrand2 | 72,370 | 101,400 | 176,434 |
| ctrand3 | 72,289 | 101,432 | 176,304 |
| ctrand4 | 72,345 | 101,684 | 176,773 |
| ctrand5 | 72,297 | 101,356 | 176,285 |
| ctrand6 | 72,320 | 101,324 | 176,264 |
| ctrand7 | 72,128 | 101,247 | 176,208 |
| ctrand8 | 72,282 | 101,264 | 176,167 |
| dcache_rtl | 58,061 | 84,294 | 151,324 |
| dcsize_rtl | 111,540 | 142,206 | 226,456 |
| dcwf | 74,203 | 105,346 | 185,682 |
| dcwf_rtl | 59,667 | 87,013 | 156,785 |
| dhold_rtl | 272,454 | 341,238 | 514,826 |
| dhum_rtl | 481,506 | 507,077 | 571,724 |
| dstore_rtl | 184,654 | 210,110 | 274,639 |
| exc | 4,072 | 5,329 | 9,122 |
| fiq_movs | 16,921 | 18,496 | 22,613 |
| fiq_perm | 102,702 | 135,727 | 226,587 |
| gba_arm | 7,912 | 9,781 | 15,543 |
| gba_arm_q | 7,743 | 9,529 | 14,986 |
| gba_thumb | 4,803 | 5,967 | 9,687 |
| gba_thumb_q | 4,484 | 5,561 | 8,994 |
| icache_restart | 73,922 | 100,107 | 166,404 |
| icache_rtl | 57,996 | 84,457 | 151,764 |
| icexec_rtl | 67,151 | 92,781 | 157,845 |
| icwf_rtl | 60,671 | 87,488 | 155,910 |
| ifetch_rtl | 92,112 | 117,726 | 182,738 |
| iprefetch_rtl | 72,923 | 103,177 | 181,396 |
| irq | 76,691 | 109,805 | 207,287 |
| ldm | 3,980 | 5,233 | 8,753 |
| ldmfold | 2,249 | 2,923 | 4,829 |
| ldst | 3,504 | 4,655 | 7,833 |
| loadpipe | 82,329 | 108,383 | 175,028 |
| loaduse | 60,511 | 87,221 | 155,543 |
| loaduse_irq | 119,624 | 148,787 | 223,365 |
| mmu_page | 76,793 | 111,327 | 199,161 |
| mmu_sect | 71,867 | 102,346 | 180,799 |
| modes | 2,888 | 3,712 | 5,973 |
| mul | 2,143 | 2,759 | 4,497 |
| rand1 | 19,933 | 27,443 | 50,471 |
| rand2 | 20,119 | 27,579 | 50,715 |
| rand3 | 20,288 | 27,900 | 51,237 |
| rand4 | 20,178 | 27,653 | 50,792 |
| rand5 | 20,274 | 27,844 | 51,231 |
| rand6 | 20,460 | 28,216 | 51,874 |
| rand7 | 20,324 | 27,945 | 51,524 |
| rand8 | 20,284 | 27,878 | 51,040 |
| rtl_misc | 7,917 | 8,687 | 10,864 |
| shift | 2,360 | 3,107 | 4,972 |
| tbl_irq | 106,020 | 123,283 | 174,879 |
| tcallpipe | 94,947 | 123,944 | 202,054 |
| thumb | 2,916 | 3,772 | 6,291 |
| trand1 | 21,841 | 30,034 | 54,769 |
| trand2 | 21,904 | 30,137 | 55,056 |
| trand3 | 21,965 | 30,208 | 55,267 |
| trand4 | 22,016 | 30,346 | 55,606 |
| trand5 | 21,986 | 30,327 | 55,248 |
| trand6 | 21,694 | 29,889 | 54,728 |
| trand7 | 21,739 | 29,920 | 54,534 |
| trand8 | 21,735 | 29,951 | 54,579 |
| v5und | 4,060 | 4,993 | 7,827 |
| walloc_rtl | 66,775 | 95,873 | 170,785 |

Additional checks:

- Eight metadata unit configurations pass, including both reset cases.
- Both stripped and `NGAGE_DEBUG=1` lint pass.
- `tools/gen_cpu.sh` and `make cpu-gen-check` pass; `input reg` count is **10**.
- `make -C sim sdram ddrflash upp periph top` passes. The final top rerun
  completes **150,622,764 clocks**, first memory-test pass **92,213 clocks**,
  exactly matching the parent memside3 result. No firmware boot bench was run.


## ARM9 v2 handoff

Take the tag-manager implementation and its metadata test. The added
`SHORT_READ` / `ACCEPTED_HIT_UPDATE` parameters and inputs `i_accepted_hit`,
`i_accepted_address`, `i_accepted_way` intentionally match the current ARM9
branch. Keep that branch's real accepted-response connections in `zap_dcache`;
do **not** replace them with this ZAP wrapper's inactive tie-offs. Preserve its
short lookup-address selection, captured hit/way/word, hold/repair logic and
existing consumer boundary. No new ready/ACK/maintenance signal is required. Carry the instruction
wrapper's `.TRACK_DIRTY(1'b0)` tag-manager parameter and the new RAM helper
module (defined in the tag-manager source). D-side tracking defaults on.

The three RAM primitive files here carry the same short-mode implementation
already on that branch (`zap_ram_simple.sv`, the original byte-enable wrapper,
and the Quartus byte-lane port replacement). Their default three-edge logic is
unchanged. This task tests the short metadata port directly; it does not run
or modify the ARM9 CPU implementation or claim an ARM9 whole-core timing result.

## Whole-core fit

Requested references: stripped seed 9, 8 KB D-cache **-0.734 ns / 35,839 ALMs**;
16 KB D-cache **-1.472 ns / 39,580 ALMs**. The build here also inherits memside3,
so it is not a pure same-commit tag-RAM A/B against those supplied figures.
No measurement-core debug macro or prefetch macro is enabled.

The default build uses implementation commit `1f002ef`, with seed 9 selected
only in its isolated build copy. Generated RTL SHA-256:
`98e1e0f83a885d133cb302cfedc6db994fa9754908705f2d2b12d8ec46ea9ddd`.
The server directory is `dev/mister/NGage_MiSTer-tag-s9`.

| Configuration | ALMs before | ALMs after | ALMs saved | Slow 100C setup before | Setup after | M10Ks after |
|---|---:|---:|---:|---:|---:|---:|
| I16 / D8 | 35,839 | 32,567 | 3,272 (9.1%) | -0.734 ns | -1.190 ns | 537 / 553 |
| I16 / D16 | 39,580 | 32,702 | 6,878 (17.4%) | -1.472 ns | -0.833 ns | 539 / 553 |

The default fit uses 40,565 registers and 3,566,156 block-memory bits (63%).
The physical RAM summary confirms that each of the 50 metadata banks uses
one M10K: 50 blocks for 2,816 logical bits. The whole core leaves only
**16 M10Ks free** (97% of blocks used), despite the much lower memory-bit
percentage. The normal tag/data RAM organization is unchanged. The detailed
instance/depth/block inventory is saved as `default-fit/metadata-packing.tsv`.
Counting unique physical RAM locations, rather than summing rows for merged
logical byte lanes, gives:

| Default cache | Data M10Ks | Tag M10Ks | Metadata M10Ks | Total |
|---|---:|---:|---:|---:|
| I16 | 14 | 6 | 9 | 29 |
| D8 | 32 | 4 | 41 | 77 |

The remaining non-cache RAMs account for 431 blocks. Instruction byte lanes
share physical RAMs because their write controls agree. Data byte lanes retain
independent writes and occupy one block each. None of the 50 metadata RAMs
share a physical block in this fit.

Default slow-100C hold slack is +0.242 ns; the minimum hold slack across all
four reported corners is +0.079 ns. Recovery and removal are positive.
The build produces its RBF and reports, then exits 2 because setup timing
is not met. This is a completed fit, not a failed compilation.

The new worst family is **maintenance dirty-bank write control**:
`o_wb_cyc_ff` -> maintenance decision -> `dirty_write_set` / initialization
lookup -> dirty-bank write enable. It occupies eight of the worst 30 paths.
The worst endpoint is way 1, bank 12's M10K `porta_we_reg`: **-1.190 ns**,
six logic levels, 11.682 ns data delay (6.351 ns interconnect, 5.331 ns cells).
This is a real new control cone and is not dismissed as placement noise.
The next different cache family is tag forwarding into a data-RAM write
enable at -0.933 ns; DMA write control into the bus is -0.714 ns.

The metadata read still lands at the old hit-comparison register boundary,
but that structural property does not establish whole-core timing closure.
The default result is an area improvement and a timing regression. The
substantial area saving justifies the conditional D16 fit, where capacity
had pushed the old design to 94% ALM utilization; that run uses the identical
RTL and only enables the D16 macro in a separate seed-9 build copy.

The conditional D16 build also completes successfully and exits 2 for
negative setup slack. Its server directory is
`dev/mister/NGage_MiSTer-tag-d16-s9`. It has **41,068 registers**, **3,656,524
memory bits** (65%), and the same 50 metadata M10Ks. The D-cache's two tag
RAMs grow from two to three blocks each; its data lanes and metadata banks
use the same number of blocks. Total cache blocks are I=29 / D=79, leaving
**14 of 553 blocks free**. In these two fits the larger D-cache costs only
135 additional ALMs and two M10Ks.

D16 slow-100C setup is **-0.833 ns**, a **+0.639 ns** improvement against the
supplied -1.472 ns reference. Slow-100C hold is +0.243 ns; minimum hold across
all four corners is +0.114 ns. Recovery and removal are positive. The worst
path is again dirty-bank write control, this time starting in the D-cache
wrapper's `state_ff[1]` and ending at way 0, bank 6's `porta_we_reg`:
six levels, 11.239 ns data delay (6.288 ns interconnect, 4.951 ns cells).
Ten of its worst 30 paths end at dirty metadata write enables. The next
family is top-level `test_on_q` into merger `o_wb_adr[7]`, at -0.707 ns.

Thus D16 improves both measured area and slack, while D8 improves area at a
timing cost. These are one-seed results on the inherited memside3 tree,
not a seed sweep or a timing-closure claim. Both fits use the identical
verified RTL. Their RBFs and reports remain in the isolated build copies;
no bitstream has been deployed.

## Stopping point and risks

Stopped after implementation commit `1f002ef`, all requested simulation
checks, one completed default seed-9 fit and one completed D16 seed-9 fit.
This report is committed separately with the measured results. There are no
unverified RTL changes after the fitted snapshot. The default cache sizes
remain I16/D8; the branch is a functional and area-tested candidate, with the
remaining timing issue explicitly unresolved.

The main known limitation is the new maintenance-to-dirty-write-enable timing
path. A next timing change would separate already-initialized maintenance
clears from first-update group initialization, or register their bank/write
selection before the existing clear edge. That needs its own cycle comparison
and fit; it has not been applied after the measured snapshot. The existing
hit/ACK timing boundary is preserved, but the default whole-core result does
not meet 104 MHz.

The RAM cost is also material. This implementation intentionally spends banks
to preserve the sixteen-line dirty scan and single-cycle invalidation. A more
compact asymmetric-width RAM or a read/modify/write metadata engine would need
a separate forwarding and maintenance design. The 32 KB I-cache configurations
are functionally verified here, but not fitted. With current packing, their
larger data/tag RAMs leave little or no block headroom; the combined I32/D16
configuration may exceed the device's 553 blocks. Do not treat simulation
support as proof of physical fit.

The short-port bench covers the shared RAM interface, including accepted HUM
LRU ownership. The ARM9 branch still must integrate its real accepted-response
wires and run its own core and physical timing checks. The one-entry deferred
LRU update relies on the documented exclusive-install/miss interval; its
assertion remains to catch a future interface that violates that bound.
Board behavior and frame rates have not been measured in this task.

Evidence lives under ignored `build/memside4/`: parent generated RTL/model,
per-configuration before/after logs and count JSONs, current test manifest,
unit logs, both lints, generation check, board benches, fit source hash and
patch, and the isolated build tree/reports. No bitstream is deployed or pushed.
