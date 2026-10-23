# D-cache critical word first and early register write

Implemented on `codex/cwf`, starting at `4abbbcd` (the merged BTB,
late-pickup, I-cache early-restart and D-cache hold changes). The filename
uses the requested 2026-10-23 date; work began on 2026-10-22 local time.

## Design

Both requested parts are implemented. A 16-byte D-cache fill starts at the
requested word and wraps within the line. The requested load value is written
to its physical register on the clock edge after its beat is accepted. The
remaining fill continues, and the cache line/tag become visible at the same
end-of-burst point as before. Younger data accesses still wait for IDLE and
the hold change's fresh cache lookups.

### Beat order and bus path

`adr_ctr_ff` still counts completed beats, from zero through four. Two small
word-position expressions add the saved request's word offset to the current
and next beat counts, modulo four. They produce both the bus address and the
index in `buf_nxt`. Thus a request for word 2 reads **2, 3, 0, 1**, but the
assembled cache line is still laid out **0, 1, 2, 3**. CTI follows the beat
count: three incrementing beats, then EOB. The next-address candidates are
formed from registers before the existing acknowledge-controlled selection.

The D-cache FSM supplies BTE `01` for these fills. `zap_dcache` selects it
only for the fill manager, `zap_wb_merger` registers it alongside address/CTI,
`zap_top` exports it, and `arm925t.bus_bte` carries it through `NGage.sv` to
`ngage_mem`. The existing `wb_arb2` already forwards the CPU's BTE and
`upp_bus.nxt/nxt2` already implement wrap-four. SDRAM already requests the
selected column first and collects its naturally wrapping burst by word
index. Flash's halfword prefetch sequencing uses the same BTE-aware next
addresses; `ddram_flash` requires no change.

Only D-cache fills use wrap-four. Dirty-victim CLEAN_SINGLE writeback,
maintenance writeback, table walks, uncached accesses and all I-cache traffic
retain BTE `00`. `zap_cache_fsm.sv` is untouched. Other cache-line sizes keep
linear fills; this work targets and verifies the configured 16-byte lines.
No changes were needed in `rtl/upp`, `rtl/mem`, or `sys/`.

### Value, write and lock timing

At a completed requested beat, the existing `ld_transform` consumes
`i_wb_dat` into the existing 32-bit `reg_dat_ff`. Selecting that beat replaces
the old `adapt_cache_data` word selection from the assembled line; it does
not change byte/halfword extraction, sign extension or unaligned rotation.
A new one-bit `reg_wr_ff` produces a single-cycle background-write pulse.

| Edge / interval | Action |
|---|---|
| Requested beat's accepting edge | Capture the formatted value and set the write pulse; destination remains locked. |
| Following interval | Drive `o_reg_dat/o_reg_idx` from saved value/index; `o_lock` still has the destination bit. |
| Following edge | Register file writes the value; FSM clears that lock bit. Existing late-pickup logic may capture this same background-write port. |
| After that edge | Register-file readers can use the unlocked value. Later beats cannot overwrite the destination. |
| Final fill edge | Publish the assembled line and tag, as before. |

UNLOCK_REG and UNLOCK_WR remain in the completion path to preserve the
existing fill/lookup recovery schedule. UNLOCK_WR no longer writes or clears
a load register. There is therefore no late duplicate write that could
clobber a subsequent instruction's result. A last-beat completion in a
non-16-byte linear configuration would write during UNLOCK_REG instead.

The issue/shifter/ALU files are unchanged. In particular the memory forwarding
value remains qualified by `!i_dc_lock`; the lock does not disappear before
the register write. No new stage is inserted between issue and memory.

## Errors and other cases

The existing cacheable-fill error behavior is unusual but explicit in the
baseline: `take` accepts ACK **or ERR**, FETCH_SINGLE stores the returned
word for either, then publishes the line and completes the load without a
data abort. CLEAN_SINGLE likewise advances on an error. This change preserves
that behavior rather than introducing an imprecise abort on a younger
instruction. An ERR on the requested beat writes that beat's returned value;
an ERR later in the line cannot retract or repeat the earlier register write.
The errored beat's returned data still occupies its own position in the final
line. This is preservation of this port's contract, not a claim that precise
ARM cacheable external aborts are implemented. Adding those would require a
separate retirement/exception design.

| Case | Handling / evidence |
|---|---|
| Clean or invalid victim | Start the requested-word fill immediately; normal final tag publication. |
| Dirty victim | Finish the unchanged linear CLEAN_SINGLE writeback before starting the wrapped read. `cache`, `dcache_rtl`, and `dhold_rtl` cover eviction/writeback. |
| Store miss / write allocation | Same wrapped fill order, but no load pulse or lock. Existing byte-enable merge and UNLOCK_REG store/tag write are preserved. `dcwf` verifies byte/halfword store misses at every word and legal lane, including untouched words; `cache`, random tests and `dhold_rtl` also cover writes and accesses behind store misses. |
| Held access to new line, old victim, surviving way, another set, or another miss | No early CPU acknowledgment or replay in fill/completion/relookup states. The unchanged three RELOOKUP states restore held and younger RAM addresses, TLB holding and idle-qualified LRU remain intact. All three `dhold_rtl` runs pass. |
| Word, byte, signed byte, halfword, signed halfword | Same transform, now applied before the early write register. `dcwf` tests every word and byte lane, both aligned halfwords, immediate add/shift/store consumers and a subsequent overwrite. |
| Unaligned word | Same ARMv4 rotation. `dcwf_rtl` tests offsets 1, 2 and 3 in every word of the line. |
| Uncached access / write-through | Existing registered UNC_DONE and its abort FSR/FAR are unchanged. BTE remains linear. Existing alias/WT tests and the new uncached abort check pass. |
| Requested-beat or later-beat ERR | Same data-consumption/no-cacheable-abort rule; `dcwf_rtl` injects DEADBEEF at each word position, as the requested beat and at every later beat. It also reads that word from the completed cache line. The saved baseline model passes the same test. |
| IRQ, FIQ, abort or branch during the remaining fill | The destination is already architecturally usable once unlocked; saved physical register index, load format, address and fill way are not changed by a pipeline redirect. Fill continues independently. Any handler data access still waits. Existing exception/IRQ/FIQ tests pass; there is no interrupt-at-every-beat sweep. |
| CP15 maintenance | A command can reach CP15 sooner after the early unlock, but the D-cache FSM only accepts maintenance in IDLE and then passes it to the tag RAM. Held command/done handshakes are unchanged. Existing maintenance tests pass. |
| Cache/MMU disable or translation changes | The fill uses its saved address, physical address, way and format. New accesses remain held. Disabling the cache still clears valid bits through the tag RAM's existing logic. No new translation is used for an old fill. |
| Reset | Clears the new write pulse together with the existing locks, bus strobe and FSM state. No stale background write survives reset. |
| Big-endian configuration | Cacheable data uses the same raw-word transform as before; no new byte swap is introduced. The configured little-endian ARM925T is tested, not a new BE configuration. |

## Verification

All original binaries and QEMU references were reused. Only the new `dcwf`
and `dcwf_rtl` binaries were assembled (`bins T="dcwf dcwf_rtl"`). The installed
patched QEMU ran only `qemu T=dcwf`; `dcwf_rtl` is tagged `qemu: no` because its
cacheable ERR and unaligned-rotation expectations do not apply to QEMU.

The CPU bench now checks BTE stability while stalled and the wrapped next
address across a burst. It also checks every cycle that the background write
comes exactly one edge after the requested beat, that the destination is still
locked immediately before the write, that lock clearing coincides with it,
and that the unlocked register contains the written value immediately after
it. Missing, early, late and duplicate pulses fail these checks. This observes
the bus and register interfaces, not the new pending-pulse register.

- Before edits: requested nine tests, **27 passed, 0 failed**; additional
  `dhold_rtl` baseline, **3 passed, 0 failed**.
- Changed RTL: requested nine tests, **27 passed, 0 failed**.
- First whole-set diff was discarded: **6 agree, 46 incomplete comparisons**
  (45 absent output sets and a partially rewritten `dhold_rtl` trace, because
  the initial full run overlapped that comparison). This was not an
  architectural pass. The final comparison runs after all RTL outputs finish.
- Existing whole suite: **192 passed, 0 failed**. The merged starting branch
  has 64 tests, more than the older 177-run count in the task.
- Final whole suite with both new tests and interface checks: **198 passed,
  0 failed**.
- Whole-set QEMU comparison after the full run, and repeated after final
  suite: **53 agree, 0 differ**, including the original references and `dcwf`.
- New tests also pass on the saved, unmodified baseline executable at all
  three latencies, confirming their expected values preserve old behavior.
- `make lint`: passed with warnings treated as errors.
- `tools/gen_cpu.sh` and `make cpu-gen-check`: generated netlist is current.
  Comparing generated modules by name finds changes only in `arm925t`,
  `zap_dcache`, `zap_dcache_fsm`, `zap_top`, and `zap_wb_merger`. sv2v also
  rearranges module order, accounting for the large textual netlist diff.
- `make -C sim upp`: both default and 256 KB on-chip configurations pass,
  including existing linear and wrap-four SDRAM/flash tests.
- `make -C sim top`: passed, **119,463,680 clocks**, including CPU smoke,
  memory self-test, save loading and SDRAM/DDR protocol checks. The first
  invocation lacked the ignored `build_id.v`; supplying a local date define
  resolved that build-input issue.
- Firmware/device-order comparison is still running in the isolated
  `sim/cpu/build/cwf-boot` directory; its final result will be recorded here.

The final cache run records **4,130 background writes, all during FETCH_SINGLE**
at every latency; `dhold_rtl` records **2,672**, `ctrand1` **77**, `crand1`
**171**, and `dcwf` **137**, all during the fill. Thus these tests exercise the
early write, not merely the eventual final value.

## Cycles

Each cell is baseline → CWF. Latencies are the CPU bench's per-beat `0:0`,
`0:3`, and `2:9`. Every saved-baseline instruction count is identical after
the change. These are simulated CPU cycles, not measured MiSTer game speeds.

| Test | 0:0 cycles | 0:3 cycles | 2:9 cycles | Instructions |
|---|---:|---:|---:|---:|
| cache | 789,484 → 760,787 | 914,969 → 888,787 | 1,247,123 → 1,222,550 | 293,427 |
| dcache_rtl | 58,399 → 58,301 | 85,366 → 85,328 | 154,163 → 154,143 | 12,771 |
| dhold_rtl | 285,043 → 273,582 | 354,573 → 345,067 | 537,858 → 528,424 | 41,081 |
| ctrand1 | 72,756 → 72,594 | 102,568 → 102,419 | 179,303 → 179,154 | 16,159 |
| crand1 | 74,121 → 73,608 | 105,544 → 105,167 | 187,828 → 187,620 | 15,982 |
| icache_rtl | 58,225 → 58,201 | 85,393 → 85,393 | 154,521 → 154,521 | 12,771 |
| gba_arm | 8,291 → 8,291 | 10,887 → 10,887 | 17,749 → 17,749 | 1,192 |
| gba_thumb | 4,913 → 4,913 | 6,523 → 6,523 | 10,877 → 10,877 | 774 |
| mmu_page | 77,102 → 77,102 | 112,796 → 112,796 | 203,209 → 203,209 | 16,887 |
| align | 5,427 → 5,427 | 7,001 → 7,001 | 11,223 → 11,223 | 549 |
| dcwf (new, both executables) | 75,033 → 74,837 | 106,750 → 106,553 | 188,505 → 188,244 | 15,336 |
| dcwf_rtl (new, both executables) | 59,990 → 59,976 | 87,830 → 87,821 | 159,307 → 159,302 | 13,256 |

Cache improves **3.63%, 2.86%, 1.97%**; dhold improves **4.02%, 2.68%, 1.75%**.
Random workloads improve less: not all dependent work can overlap a fill,
and a younger memory operation still holds the pipeline until recovery.
The new directed tests deliberately spend much of their time on setup,
maintenance and verification, so their total runtime is not a load-miss
latency microbenchmark.

For the stated SDRAM beat schedule (8, 10, 12, 14), the new register write
would occur at edge 9 instead of edge 16 relative to the same first request,
independent of the requested word. This is a schedule derivation; it excludes
arbitration, dirty writeback, pipeline placement and lookup recovery.

## Risks, remaining work and cost

No RAM, new full-width data register, or pipeline stage was added. The
32-bit load result register is reused. Added state is a one-bit write pulse
and BTE propagation registers (constant bits/unconnected outputs may optimize
away); word-order arithmetic is two bits in the configured design. The old
full-line load-word selection is removed. This is source inspection, not a
Quartus area result.

Timing risks are the bus-to-load-transform capture into `reg_dat_ff`, the
small word-offset adders ahead of the existing next-address selection, and
BTE control routing through the D-cache manager and registered merger. The
hit-data path into memory and issue's register/forwarding muxes are unchanged.
No Quartus fit or 104 MHz timing signoff, and no physical MiSTer test, has been
performed. SDRAM RTL is untouched, so no separate `sdram`/`sdram-faults` run
was needed by the task's conditional requirement.

Coverage limits: no exhaustive interruption/reset/CP15-at-every-beat sweep,
no new BE or non-16-byte geometry sweep, and no newly defined precise
cacheable external-abort behavior. The existing whole-core smoke test uses
a small CPU program; the memory-system bench supplies the substantial
SDRAM/flash wrap coverage.

Next: screen this netlist at 104 MHz and compare matched whole-core fitter
seeds, then measure the same game segments on hardware. Retain the held-access
rule. Overlapping the tail/relookup states is separate work; they were kept
intact here deliberately.

## Commit status

Git staging was attempted on `codex/cwf` and denied:

```
fatal: Unable to create '/Users/jacob/dev/fpga/mister/NGage_MiSTer/.git/worktrees/NGage_MiSTer-cx-cwf/index.lock': Operation not permitted
```

This worktree's Git metadata is outside the session's writable sandbox, and
permission escalation is disabled. No commit could be created here; no branch
was switched and nothing was pushed. The implementation and report remain in
the working tree. `sim/cpu/build/cwf-commit-message.txt` holds the prepared
message with the mechanism and all requested cache/ctrand1/crand1 counts.

From an environment allowed to write this worktree's Git metadata, complete
the commit on the current branch with:

```sh
git add NGage.sv rtl/cpu/arm925t.sv rtl/cpu/arm925t_gen.v \
  rtl/cpu/zap/zap_dcache.sv rtl/cpu/zap/zap_dcache_fsm.sv \
  rtl/cpu/zap/zap_top.sv rtl/cpu/zap/zap_wb_merger.sv \
  sim/cpu/tb/main.cpp sim/cpu/tb/tb_cpu.sv \
  sim/cpu/tests/dcwf.S sim/cpu/tests/dcwf_rtl.S \
  docs/consults/2026-10-23-codex-cwf-report.md
git commit -F sim/cpu/build/cwf-commit-message.txt
```
