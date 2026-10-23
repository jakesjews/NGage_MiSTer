# SDRAM open-page policy — 2026-10-23

Worktree: `NGage_MiSTer-cx-sdram`, branch `codex/sdram`, starting commit `4abbbcd`.

## Result and status

Implemented open rows independently for all four SDRAM banks. A row-hit read now returns its first word in **5 rather than 8 clocks**. A line-hit read accepts the next request after **12 rather than 15 clocks**; word/line-hit writes take **3/9 rather than 9/15 clocks**. Reads that conflict with an open row cost three extra clocks versus the old closed-page controller. The address mapping, timing parameters, mode register, capture pipeline, and external port are unchanged. No `rtl/cpu` or `sys/` files were modified.

Staging/committing is blocked by the execution sandbox, not a test failure: `git add` cannot create `/Users/jacob/dev/fpga/mister/NGage_MiSTer/.git/worktrees/NGage_MiSTer-cx-sdram/index.lock` (`Operation not permitted`). No branch switch or push was attempted. The implementation and this report are left in the worktree for a commit by an environment allowed to write the worktree's Git metadata.

## Implemented design and cases

The controller stores a valid bit, 13-bit row address and saturating ACTIVE age for each bank. Age saturates at `max(tRAS,tRC)`; READs and WRITEs do not reset it. At the defaults this is 72 bits of row state. One latched row address retains the pending request through a conflict.

- **Open-row hit:** issue the first READ/WRITE on the request acceptance edge. Start the existing access counter at the virtual ACTIVE age `RCD+1`, removing exactly the three activation clocks. The first column/data operands come from the request; following beats use the latched operands.
- **Closed bank:** issue ACTIVE on acceptance, then wait tRCD. Also retain the same-bank tRC check, including after refresh. No precharge is needed at the end.
- **Row conflict:** latch the request; wait for that bank's original ACTIVE to satisfy tRAS; precharge only that bank; wait both tRP and the original ACTIVE's tRC before activating the replacement. Other open banks retain their rows. A request arriving while busy remains the requester's responsibility until the ordinary acceptance handshake.
- **Word read:** BURST TERMINATE exactly two clocks after READ stops the burst after two halfwords while leaving the row open. This command has a CAS-latency delay, so it preserves the existing capture edges. The model now implements it with bank/address ignored. See the [Alliance AS4C16M16SA datasheet, Burst Stop command and Figure 16](https://www.alliancememory.com/wp-content/uploads/256M-AS4C16M16SA-Automotive_v2.0_March-2015.pdf#page=16).
- **Line read:** the BL8 burst completes naturally. Requested-word-first ordering and wrapping within the 16-byte block are unchanged; returns remain two clocks apart. No extra rvalid is emitted after a word read.
- **Writes:** single-location WRITE commands still transfer two/eight halfwords. A line write starts at the block base regardless of the requested word. A word write uses only its addressed word's data and enables. All-zero and partial enables are preserved, including masks on A12:A11 and the dedicated DQM pins.
- **Read/write direction changes:** retain the read capture/drain schedule before permitting another request. After a write, hold the controller through tWR from its final halfword even when the next operation is another write or a hit read. At CL2 this also leaves enough time for old write DQM to clear before read data, and for the FPGA/chip to release DQ before the other drives it. No overlapping accesses or speculative commands are introduced.
- **Short-lived rows and parameter changes:** per-bank ACTIVE ages are checked independently of the access counter. The extended-timing test (tRAS=120 ns, tRC=180 ns) requires real additional precharge/activate waits: its word-write conflict takes 16 clocks instead of the default 9. This exercises both age guards, rather than relying only on default access lengths accidentally satisfying them.
- **Refresh:** once due, stop accepting requests, finish the current access and write recovery, wait for every open bank to satisfy tRAS, then PRECHARGE ALL. Wait tRP, issue AUTO REFRESH, invalidate all row state, and wait tRFC before accepting again. PRECHARGE ALL is issued even if every bank is already closed. Refresh has priority over a new request. A request accepted on the edge that raises the due flag completes before refresh.
- **Initialization:** the existing NOP/power-up, PRECHARGE ALL, initialization refreshes, mode-register and tMRD sequence is retained. `init` clears row-valid state, initializes the age counters and cancels the access state. Resetting during an in-flight transaction still abandons it; no new transaction-completion guarantee is introduced for reset.

All command/address/data decisions still end in the internal `p_*` registers. The subsequent physical I/O register stage and the DQ input/capture registers are untouched. The added row lookup and first-write operand muxes are in the SDRAM controller, not in a CPU forwarding or load-data path.

## Clock counts

Measured from request acceptance to rvalid and to the next possible request acceptance, excluding a concurrent refresh stall. Commands in the source schedule reach the pins one clock later. In the old controller every request starts with a closed bank; the hit/miss rows below mean the same address sequences, not an old row-state optimization.

| Access / bank state | Before: read return clocks | After: read return clocks | Before: next request | After: next request |
|---|---|---|---:|---:|
| Word read, hit | 8 | 5 | 9 | 6 |
| Word read, closed | 8 | 8 | 9 | 9 |
| Word read, conflict | 8 | 11 | 9 | 12 |
| Line read, hit | 8,10,12,14 | 5,7,9,11 | 15 | 12 |
| Line read, closed | 8,10,12,14 | 8,10,12,14 | 15 | 15 |
| Line read, conflict | 8,10,12,14 | 11,13,15,17 | 15 | 18 |
| Word write, hit | — | — | 9 | 3 |
| Word write, closed | — | — | 9 | 6 |
| Word write, conflict | — | — | 9 | 9 |
| Line write, hit | — | — | 15 | 9 |
| Line write, closed | — | — | 15 | 12 |
| Line write, conflict | — | — | 15 | 15 |

After the first column command, writes occupy clocks 0–1 or 0–7, with readiness at 3 or 9; a closed bank adds 3 and a conflict adds 6 at default timings. Longer tRAS/tRC settings can add further waits, as tested.

Refresh previously occupied 8 clocks (AUTO REFRESH through tRFC); it now normally occupies 11 (PRECHARGE ALL, 3 clocks tRP, AUTO REFRESH, 8 clocks tRFC). Any remaining tRAS must elapse first. The timing parameters themselves remain RCD=3, RP=3, RAS=5, RC=8, RFC=8, WR=2 clocks at 104 MHz.

The actual old `REFRESH_CLKS` expression evaluates to 773, despite its header saying 780. The new expression evaluates to 755. It reserves a conservative 23-clock access bound, 8-clock close bound, 2 clocks for due-flag/control latency, 8 clocks RFC and 16 clocks slack from the 812-clock tREFI budget. Thus even `755+2+23+8=788` clocks between refreshes is under tREFI. The longest observed new gap is **777 clocks / 7471 ns**, versus **789 clocks / 7587 ns** in the original random bench; both are under 7812.5 ns. The enhanced model also checks the gap from the final initialization refresh to the first runtime refresh, and no longer conceals missed deadlines by overwriting the last-refresh timestamp.

## Bank mapping and locality

Retained byte-address bank bits **24:23**, row **22:10**, column **9:1**. The phone's first 16 MB therefore remains in physical banks 0 and 1 as before; byte addresses and all 32 MB remain compatible with the existing model and memory system.

For the new bench's seed-1 random phase (8,438 accepted requests), actual row state records **447 hits, 825 closed-bank accesses, 7,166 conflicts: 5.30% hits**. Identical accepted addresses and refresh events fed through independent shadow mappings produce:

| Mapping | Hits | Hit rate |
|---|---:|---:|
| Current, bank bits 24:23 | 447 | 5.30% |
| 1 KB interleaving, bits 11:10 | 676 | 8.01% |
| 4 KB interleaving, bits 13:12 | 273 | 3.24% |

This bench deliberately jumps among hot rows and random addresses. Its address generator's high hot-region bits are at byte bit 22, so these numbers are not a CPU/game trace. Three more random runs give current-mapping hit rates 5.44%, 5.16% and 5.19%. The separate sustained one-row line workload gives **1,009/1,024 hits (98.54%)**, with refresh still closing the row periodically.

1 KB interleaving can keep adjacent rows open simultaneously and helps this artificial random stream modestly; 4 KB interleaving hurts it. Neither establishes the best mapping for game instruction/data/translation traffic. Remapping also changes the physical bank footprint of the first 16 MB. Keeping the current mapping isolates the page-policy change; choose a remapping only from representative accepted bus-address traces and hardware measurements. In particular, this change is not evidence of a game frame-rate improvement: conflict-heavy read traffic can slow down.

## Verification

- Baseline before RTL edits: all 27 requested CPU runs passed; original SDRAM random bench, all four fault injections, both UPP configurations and the top-level bench passed. The timing probe was then run against the original controller to capture the table's before values.
- `make -C sim sdram`: passed. Includes command counts and exact default access latency assertions for all twelve hit/closed/conflict cases, four simultaneously open banks, every word/line/read/write transition on a hit/bank switch/conflict, all word offsets and 16 byte-mask patterns, zero enables, row/bank/16 MB/32 MB boundaries, 800 refresh phases and sustained row hits. Data comparisons remain against independent byte-addressed memory.
- `make -C sim sdram-faults`: all four injected faults caught (capture, tRCD, tRFC and refresh interval).
- Seven model-only negative controls each produce exactly one expected error: tRAS minimum across repeated column commands, tRAS maximum, tRC independent of tRP, final-write tWR, refresh with an open bank, tRP after PRECHARGE ALL on idle banks, and the first runtime refresh deadline.
- Additional seeds 2, 3 and 9, each with 2,000,000 random-phase clocks plus directed cases: passed with zero model/data errors.
- A separately compiled `-GT_RAS_NS=120 -GT_RC_NS=180` controller, with matching bench arguments `--ras-ns 120 --rc-ns 180 --cycles 1000000`: passed. Other timing and capture parameters remained at defaults.
- `make -C sim upp`: both the default and 256 KB on-chip-memory configurations passed with the enhanced chip model.
- `make -C sim top`: passed (`emu: all checks passed`, 119,463,677 clocks). Its small CPU program completed its stores 7,768 clocks after the CS1 download (baseline 7,771); its first memory-test pass took 99,639 clocks (baseline 126,782). The enhanced SDRAM model reported no errors.
- `make lint`: passed, including every configured top; warnings remain errors.
- `LC_ALL=en_US.UTF-8 make cpu-gen-check`: passed. The default `C.UTF-8` and `C` locales sort `*.sv` differently from the committed generator output. Generating into a temporary file showed all 40 module bodies byte-identical, only reordered. Matching the original collation makes the whole file identical; no CPU source or generated file was changed.
- CPU subset rerun: 27/27 passed, full suite: **192/192 passed**, full signatures/traces: **52 agree, 0 differ**. This branch contains more tests than the prompt's 177 runs / 49 comparisons. The first full `diff` attempt after only the nine-test subset had missing RTL traces for other tests in this fresh worktree; running the full suite populated those traces, and both subsequent full diffs passed. Existing binaries and QEMU references were used throughout; neither was rebuilt or rerun.

The fresh worktree also lacked the ignored top-level `build_id.v`. `make lint-prepare` followed by `cp lint/gen/build_id.v build_id.v` supplied a local simulation build identifier before running the top bench; no tracked build/framework file changed.

### CPU cycles and instructions

Every entry below is **before = after**; all three latencies preserve identical instruction counts. These counts cannot improve from this task because the CPU-only bench does not instantiate this SDRAM controller.

| Test | Cycles, 0:0 | Cycles, 0:3 | Cycles, 2:9 | Instructions at each latency |
|---|---:|---:|---:|---:|
| cache | 789,484 | 914,969 | 1,247,123 | 293,427 |
| dcache_rtl | 58,399 | 85,366 | 154,163 | 12,771 |
| icache_rtl | 58,225 | 85,393 | 154,521 | 12,771 |
| ctrand1 | 72,756 | 102,568 | 179,303 | 16,159 |
| crand1 | 74,121 | 105,544 | 187,828 | 15,982 |
| gba_arm | 8,291 | 10,887 | 17,749 | 1,192 |
| gba_thumb | 4,913 | 6,523 | 10,877 | 774 |
| mmu_page | 77,102 | 112,796 | 203,209 | 16,887 |
| align | 5,427 | 7,001 | 11,223 | 549 |

## Area, timing risks, limits and next work

A generic Yosys `synth -top sdram` comparison after sv2v yields 318→406 one-bit flip-flops (**+88**), and 1,449→2,232 total generic cells, with **no memory cells**. These are technology-independent gate counts, not Cyclone V ALMs or a Quartus timing result. The row state is small, but the row comparator/bank mux, age checks, acceptance control and request-to-first-WRITE path add combinational logic and routing. The physical I/O register stage stays unchanged; fitting must still check its existing hold-sensitive register pairs and any new internal setup path at 104 MHz.

No Quartus placement/timing run, board memory test, physical boot, real firmware device-access comparison or game performance measurement was performed. The top bench runs its own small CPU program and memory test, not the firmware's 76,975-access boot comparison. Mid-transaction reset, unsupported SDRAM geometries, and alternative CL/board-delay combinations were not newly characterized; the port and operating assumptions remain those of this controller. The model is a timing/data model, not the vendor's analog device or a board signal-integrity measurement.

Next: commit these four files from an environment with writable Git metadata, fit at 104 MHz, then run the OSD memory test and boot on hardware as planned. Capture real row-hit/conflict counts and game timing before deciding whether to retain this policy, interleave banks lower, or make a separate adaptive policy. Read conflict cost and the extra refresh precharge overhead must be weighed against the measured locality, rather than extrapolating from the one-row best case.
