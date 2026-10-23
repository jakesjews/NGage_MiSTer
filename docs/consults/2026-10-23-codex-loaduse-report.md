# Load-use late operand pickup — 2026-10-23

Implemented on `codex/loaduse`, based on `8831aa6`. No changes under `sys/`,
no changes to the cache FSM, register file, post-ALU stages, or bus merger.
The generated `rtl/cpu/arm925t_gen.v` is regenerated with `tools/gen_cpu.sh`.

## Design implemented

This is a bounded late-pickup path. It removes **two issue wait clocks for
eligible plain operands**, and **one for operands needed by the shifter**.
It deliberately retains the early part of the load-use interlock:

* A plain ALU source (`rn`) or unshifted/LSL-immediate-zero `rm` can leave
  issue when its load is in postalu1 or postalu2.
* A shifted source, register shift amount, or store-data source can leave
  issue when its load is in postalu2. These operands must be ready in shifter.
* Earlier producers remain interlocked. Only loads whose condition has
  already passed in ALU can create a pending operand.

Issue carries four pending bits, using the existing physical register tags
for rn, rm and store data and adding a six-bit shift-amount tag. Shifter
carries two pending bits and two six-bit tags for plain ALU operands.
There are **24 additional metadata bits**, no additional data array, no
register-file ports, and no pipeline stage. Existing operand registers hold
captured results. The extra control/mux logic has not been placed and routed;
24 bits is a source-level metadata count, not an ALM estimate.

The load-completion qualification is `memory_dav_ff && memory_mem_load_ff &&
!i_dc_lock[memory_mem_srcdest_index_ff]`. The data comes from the memory
stage's registered, formatted `memory_mem_rd_data`. ALU rn and rm each gain
one 2:1 mux between their existing input register and this registered value.
No new candidate or mux is added to `get_register_value` or
`o_alu_source_value_nxt`.

When an early operand is unavailable, shifter holds the issue output and
sends bubbles downstream. When a plain operand is unavailable, ALU holds
the shifter output, propagates backpressure through shifter to issue and
the frontend, and sends bubbles to postalu0. The rest of the pipeline keeps
draining unless the existing data-bus stall requires a global hold.
ALU bubbles suppress result validity, flags, retirement, exceptions, branch
confirmation and bus requests. A late wait is not ORed into the global `data_stall` signal.

While a slot is held, completion data is captured into its existing operand
registers and the corresponding pending bits are cleared. This happens even
during a data stall: memory-stage completion is transient and cannot be
expected to reappear. Ordinary shifter forwarding is retained in the held
issue operands too, so an older ALU writer can drain without losing its
value. Multiplies explicitly retain their original raw operands throughout
their FSM, rather than using this operand refresh.

## Cases and their handling

| Case | Implemented behavior |
| --- | --- |
| Cache hit / uncached successful load | Qualified registered memory data resolves a tag. Global data waits keep stages aligned; transient completion is captured even on a hold. |
| Cache miss already locked at issue | Existing xlock interlock remains; no new pending operand is issued against a locked register. |
| Admitted load subsequently misses | The early acknowledged memory response is rejected because its xlock bit is set. The pending consumer waits. In `UNLOCK_WR`, the existing one-hot `i_dc_reg_idx` and registered `i_dc_reg_dat` feed the same operand registers that would otherwise capture a memory hit. This is the exact value and edge used by the register-file background write. The pending flag clears at that edge; execution resumes with a registered operand after the lock clears. No speculative use of fill data and no new RF read port. |
| Replay / abort / writeback redirect | Writeback clear has priority over capture and clears both stages' pending flags with their instruction-valid state. Old tags cannot resolve a new instruction. Existing fault sleep/drain and return behavior remains. |
| ALU redirect | Existing ALU-clear priority and data-stall qualification are preserved; pending flags clear in the same branches as their instruction slots. |
| Conditional load fails | No pending tag is admitted before condition resolution. A failed load ceases to be a producer; the existing forwarding/RF path supplies the old register value. |
| Base writeback | `mem_srcdest_index` names the loaded value; `destination_index` names the base/ALU result. Any matching ALU destination makes late admission conservative, including the producer's base. The undefined overlapping base/destination case is not newly optimized. |
| LDM/STM and temporaries | Ordinary transferred registers may use late pickup. Physical dummy registers 33/34, SPSRs and other special registers retain their old locks. Uop ordering, uop-last, temporary forwarding, and abort recovery are unchanged. |
| Load to PC | PC cannot become a pending operand; the existing load-to-PC sleep and writeback redirect remain authoritative. |
| Byte / halfword / signed loads | Both completion paths already contain the final formatted value. No rotation or sign extension is duplicated in the new mux. |
| Thumb | Uses the same decoded physical operands and shifter paths. Instructions with `force32align` retain the old interlock, preserving PC-relative alignment behavior. |
| Two pending operands | Independent tags and bits. Each result is consumed or captured separately; executing requires every operand needed at that stage to be ready. A ready first operand is retained while the second waits. Same-register duplicates are also supported. |
| Store data | The store-data bit can defer only an actual store's source, and it resolves before the shifter output register. Byte replication and store bus generation remain in ALU. |
| Shift lock | The original shift and flag locks remain intact. This change does not attempt the separate shift-lock optimization. |
| Multiply / long multiply / MAC | No late admission. Raw operands stay stable through multiply busy, including the second long-multiply uop and accumulator inputs. SMULL/UMLAL regressions are included in the new test. |
| Younger writer to same register | Existing load WAW checks on the destination and memory source/destination remain. They prevent such a writer from passing an unresolved load. Late admission additionally rejects matching ALU writers in issue through postalu2. Thus tag-only matching cannot substitute an older load for a younger result. The existing forwarding priority is preserved, but the design does not rely on that priority alone. |
| Flag-setting producers / consumers | Original flag interlock is retained. ALU flags are frozen while waiting, and updated once on execution. Carry-sensitive ADC/RRX and the long-multiply sequence are tested. |
| Interrupt while pending | Exception-carrying issue entries do not use late admission. An asynchronous IRQ can arrive during a pending wait; the pipeline resumes/drains in order, and a writeback exception flush clears pending state. The IRQ sweep checks preserved results, one interrupt per iteration, and normal return. |

## Verification and measurements

The pre-edit baseline was the requested nine tests at `0:0`, `0:3`, `2:9`:
**27 passed, 0 failed**. The executable and logs were saved under
`sim/cpu/build/loaduse-baseline/`. Existing test binaries and QEMU references
were not rebuilt or rerun.

Final validation:

* The same nine tests: **27 passed, 0 failed**, with identical instruction
  counts in every baseline comparison below.
* Requested original-test acceptance sequence: focused 27 runs, QEMU diff
  **49 agree, 0 differ**, full **177 passed, 0 failed**, and another QEMU diff
  **49 agree, 0 differ**.
* The two new tests on the generated RTL: **6 passed, 0 failed**.
  `loaduse` also has **1 agree, 0 differ**, including both signature and
  instruction trace. Together this is **183 passing runs and 50 agreeing
  QEMU references**. An earlier full run including `loaduse` also reported
  180 passes and a full 50-reference comparison with zero differences.
* `loaduse_irq` is tagged `@@ qemu: no` because it uses bench interrupt
  registers. The patched `qemu-system-arm` was available for `loaduse`.
* `make lint`: passed, with warnings treated as errors.
* `make cpu-gen-check`: passed.
* The two new tests also passed all six source-SystemVerilog runs with a
  temporary bind monitor. Separate generated-netlist monitor results are
  recorded below; ordinary generated-netlist runs supply the cycle table.

The initial post-focused `diff` did not have RTL signatures for the other
44 QEMU tests in this new worktree; the full suite populated them. Comparison
also found a real long-multiply accumulator-refresh error in the first
implementation, despite its tests reaching PASS. That error was corrected,
covered explicitly in `loaduse`, and the full suite and comparisons repeated.
Do not equate a random test reaching PASS with QEMU agreement.

The table uses **before → after** cycles, followed by **after minus before**.
Instruction counts are identical before/after and at all three latencies.

| Test | Instructions | 0:0 cycles (delta) | 0:3 cycles (delta) | 2:9 cycles (delta) |
| --- | ---: | ---: | ---: | ---: |
| cache | 293,427 | 903,967 → 838,321 (-65,646) | 1,021,476 → 955,535 (-65,941) | 1,346,786 → 1,281,211 (-65,575) |
| dcache_rtl | 12,771 | 71,448 → 71,426 (-22) | 93,933 → 93,953 (+20) | 160,178 → 160,178 (+0) |
| icache_rtl | 12,771 | 71,090 → 71,049 (-41) | 93,587 → 93,710 (+123) | 160,385 → 160,423 (+38) |
| ctrand1 | 16,159 | 89,133 → 88,348 (-785) | 114,728 → 114,080 (-648) | 192,788 → 192,107 (-681) |
| crand1 | 15,982 | 90,706 → 89,763 (-943) | 118,251 → 117,756 (-495) | 202,059 → 201,605 (-454) |
| gba_arm | 1,192 | 8,334 → 8,293 (-41) | 10,955 → 10,890 (-65) | 17,752 → 17,749 (-3) |
| gba_thumb | 774 | 4,935 → 4,913 (-22) | 6,552 → 6,523 (-29) | 10,900 → 10,877 (-23) |
| mmu_page | 16,887 | 93,545 → 93,308 (-237) | 123,102 → 122,864 (-238) | 209,451 → 209,466 (+15) |
| align | 549 | 5,543 → 5,445 (-98) | 7,064 → 7,000 (-64) | 11,440 → 11,242 (-198) |

Cache improves by **7.26%, 6.46%, 4.87%** at the three latencies. `ctrand1`
improves by **0.88%, 0.56%, 0.35%**; `crand1` by **1.04%, 0.42%, 0.22%**.
Some tests regress slightly: the largest shown is `icache_rtl` at 0:3,
**123 clocks / 0.13%**. These totals include interactions with cache/bus
scheduling and replay timing, so a two-clock dependency saving is not a
promise that every whole-test cycle total decreases. No game CPI or frame
rate measurement is claimed.

`loaduse.S` covers cold/hot lines, consumer distances one through three,
both plain inputs, shifted source and amount, store data, two same/different
sources, conditional/WAW cases, base writeback, LDM/STM, ADC/RRX, MUL,
SMULL/UMLAL, signed and unsigned subwords, translation abort, PC and Thumb.
It also places an independent uncached access behind a cached producer to
exercise capture of a transient memory result during a global data stall.
`loaduse_irq.S` sweeps timer delays 1 through 159 across cold-load sequences.

The final directed test (13,186 instructions at every latency) also ran on
our saved unmodified baseline executable with the same newly assembled
binary. Whole-test cycles are 73,417 → 73,269; 96,120 → 96,058; and
163,607 → 163,537. MMU setup and explicit invalidation dominate this test;
its purpose is hazard coverage, not a load-use throughput benchmark.

A temporary `bind zap_core` monitor was run against the generated RTL,
using a separate model directory (`sim/cpu/build/obj-loaduse-gen-monitor`).
These are observed **cycles**, not disjoint stall buckets or retirements:

| Test / latency | Multiple pending operands | Background write while pending | IRQ asserted while pending | Writeback clear while pending | Bus stall while pending |
| --- | ---: | ---: | ---: | ---: | ---: |
| loaduse / 0:0 | 75 | 12 | 0 | 7 | 46 |
| loaduse / 0:3 | 124 | 12 | 0 | 7 | 85 |
| loaduse / 2:9 | 332 | 12 | 0 | 8 | 195 |
| loaduse_irq / 0:0 | 1,905 | 159 | 702 | 453 | 1,459 |
| loaduse_irq / 0:3 | 2,872 | 159 | 843 | 448 | 1,970 |
| loaduse_irq / 2:9 | 5,442 | 160 | 1,327 | 431 | 3,249 |

The monitor and logs are local verification artifacts under
`sim/cpu/build/loaduse-monitor.sv` and `loaduse-monitor-results/`; they are
not part of the synthesized design. The monitor only observes state. Its
separate model is not the binary used for the before/after cycle table.
Both source and generated instrumented runs passed. The ordinary generated
model was rerun afterwards to restore its signatures and logs.

## Remaining risks and next work

The architectural suite passes, but **104 MHz timing and area are not
verified**. No Quartus fit, whole-core seed sweep, board deployment, game
measurement, or 76,975-access firmware boot comparison was run. This
worktree has no prepared `sim/cpu/build/boot` inputs/reference logs.

The principal timing risks are memory-tag/lock qualification to late-stall
fanout, the new mux before the ALU, the pickup muxes before the barrel
shifter, and the held-operand feedback into issue's operand flops. The
existing issue combinational value-selection function is unchanged, but
its destination flops now have hold/capture selection; unchanged function
text alone does not establish unchanged timing. The Wishbone merger and
two-way cache-data path have not been edited.

Integration limits: this checkout still has busy-fill `err2` replay paths
in the D-cache FSM (including `UNLOCK_WR`). A parallel change to hold those
requests must be verified together with this branch. Both stages capture
background completions independently of global `data_stall`, but the
instrumented tests here did not observe background completion and a
locked global data stall simultaneously. Nor is this an exhaustive sweep
of every possible LDM/STM abort position. The existing MMU/exception/uop
tests and new pending-clear coverage passed; the firmware trace remains
an important integration check.

This does not speculate through condition resolution, optimize dummy/SPSR
operands, remove load WAW locks, remove shift locks, or make in-place
read/modify/write consumers bypass their retained destination interlock.
Those exclusions are intentional correctness and timing bounds. It is not
an ARM9 one-cycle-load-use implementation for all instructions.

Next: run the ordered firmware-device trace, then compare whole-core fits
at 104 MHz (both slow corners, hold, area, several matched seeds), and only
then measure identical game segments on hardware. If control timing is
acceptable, use workload evidence to decide whether extending admission
one stage earlier or safely optimizing read/modify/write WAW cases is
worth the added state and verification. Keep those as separate changes.

## Commit limitation

The implementation and verification are complete to the boundaries above,
but this session could not create the requested Git commit. `git add` failed
before staging any files:

```
fatal: Unable to create '/Users/jacob/dev/fpga/mister/NGage_MiSTer/.git/worktrees/NGage_MiSTer-cx-loaduse/index.lock': Operation not permitted
```

The worktree is writable, but its Git metadata is outside the sandbox's
writable roots; permission escalation is unavailable in this session.
Changes remain uncommitted on `codex/loaduse`. The prepared commit message
is `/tmp/loaduse-commit-message.txt`, including the mechanism and all three
latencies' cache/ctrand1/crand1 cycle counts. No branch was switched or pushed.
