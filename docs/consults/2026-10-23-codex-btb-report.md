# Early registered BTB lookup

Implemented on `codex/btb`, starting from `8831aa6`. A trained taken branch
now loses **one fetch-address slot instead of three**. The RAM read and the
prediction decision each retain their clock boundary. No issue, shifter,
ALU, cache, core-wrapper, or `sys/` source was changed.

## Design

`zap_writeback` supplies `pc_nxt` to the BTB RAM, in parallel with loading
`pc_ff`. The following cycle's tag comparison uses `pc_ff`; the registered
decision therefore belongs to `pc_del_ff`. A taken decision replaces the
next PC, invalidates only the younger `pc_ff` as it advances into `pc_del`,
and preserves the branch and older instructions advancing into `pc_del2`
and `pc_del3`. It does not call the full-recovery `zap_pc_shelve` macro.

For an ARM branch B to target T, with an otherwise advancing frontend:

| Edge | `pc_ff` | `pc_del` | `pc_del2` | `pc_del3` / fetch |
| --- | --- | --- | --- | --- |
| 0: RAM has read B | B | older | older | older |
| 1: decision registered | B+4 | B | older | older |
| 2: redirect accepted | T | invalid | B | older |
| 3 | T+4 | T | invalid | B, prediction T |
| 4 | T+8 | T+4 | T | invalid |
| 5 | T+12 | T+8 | T+4 | T |

Two 33-bit registers carry the **accepted** prediction alongside the branch
through `pc_del2` and `pc_del3`. Two 2-bit registers carry its predictor
state. They share the fetch pipeline's `!i_code_stall` enable. The fetch
and predecode interfaces are unchanged: `o_pred` describes where fetch
actually redirected for this instruction, and `o_taken` is its state for
predecode and ALU feedback. There are 70 additional metadata bits, no new
RAM, no larger table, and no pipeline stage added between issue and memory.

`zap_btb` also clears its registered decision on `i_clear`, including under
stall. Its valid-bit reset already had this priority. The state output
continues advancing when the address pipeline advances, even during clear.
Writeback suppresses accepting a new prediction during `i_clear_btb`.
Already accepted prediction metadata is retained: erasing it after fetch
has redirected would misdescribe the fetched stream to predecode.

Zero lost slots would require an earlier decision or a later combinational
redirect point. This implementation deliberately keeps both BTB registers
and uses the permitted one-slot result.

## Cases and coverage

| Case | Handling and verification |
| --- | --- |
| Correct taken branch | Preserve the branch and all older slots; invalidate exactly one younger slot. The directed frontend bench checks the exact valid/PC/target/state sequence. |
| Branch at the target of another branch | The target gets its own normal lookup and can redirect again. ARM and Thumb branch chains are checked in both the frontend bench and `btb_early.S`. |
| Trained branch on the discarded sequential path | The invalid `pc_del` cannot accept its prediction. The frontend bench trains a poison destination for that slot. |
| Not-taken branch, cold entry, or tag alias | No target redirect without the existing valid/tag/taken checks. Raw counter-state behavior on an alias is retained. The frontend alias case, `bpred`, random tests, and QEMU traces cover recovery. |
| Wrong target or direction | ALU `clear_from_alu`, target, confirmation and state-feedback connections are unchanged. The new assembly test alternates indirect targets; existing conditional/random tests compare against QEMU. |
| Returns and calls | RAS push/pop, pending-write forwarding, return recognition, and ALU validation are unchanged. Existing `bpred`, ARM/Thumb and random tests plus calls in `btb_early` cover these paths. |
| Thumb halfword addressing | The BTB still indexes at two-byte granularity; bit 1 is preserved. The frontend bench checks a target at word+2 and two-byte sequential steps; the assembly test enters and exits Thumb through BX. |
| T-bit changes | The BTB does not change T. Existing ALU/writeback recovery and `i_mode16` stepping remain authoritative. The complete suite includes interworking, exceptions and the Thumb-BL interrupt case. |
| Fetch wait or FIFO backpressure | RAM, decision and address/metadata stages hold under `i_code_stall`. The frontend bench stalls each of ten phases in each instruction mode, including the bubble, and checks every exposed address and metadata signal. The CPU tests run at all three bus latencies. |
| ALU/decode redirect while stalled | Full-recovery priority and shelving are unchanged. The frontend bench checks both redirect sources, stalled and unstalled, against a simultaneous BTB decision. |
| Exception, data retry, load to PC | Existing writeback priority and full three-slot invalidation remain in use. The suite covers interrupts, faults, MMU replay and PC loads. No speculative BTB request overrides these cases. |
| Older I-cache retry | Retry has priority over a younger prediction and restarts the current fetch through full recovery. The directed bench retries an older slot after a younger redirect; cache/MMU tests exercise the real interface. |
| Outstanding wrong-path fetch | No bus transaction is canceled or reinterpreted. The address pipeline stays frozen until the existing fetch handshake completes; full recovery uses the existing shelve mechanism. A one-slot BTB redirect changes only the youngest address-valid bit. |
| Invalidation | `i_clear_btb` cancels unaccepted decisions even under stall, while accepted metadata stays attached to its instruction. The frontend bench checks both cases. Existing CP15 drain/refetch behavior is untouched; in this checkout the writeback clear input is wired to `predecode_clear_btb`. |
| Stale branch prediction for ordinary code | Predecode still detects `skid_pred[32]` for an unsupported/nonbranch instruction, redirects to fall-through, and clears the BTB. `btb_early` trains a branch, overwrites it with ADD, invalidates I-cache and verifies both ADD and fall-through execute. |
| Reset, FCSE and table updates | Reset invalidates metadata; the existing FCSE mapping and bit-zero masking of `pc_nxt` are unchanged. Feedback writes, the RAM wrapper's collision policy, and the a8ca165 valid-bit behavior are unchanged. |

## Verification

Before editing, the required nine tests passed at all three latencies:
**27 passed, 0 failed**. Their cycle/instruction totals were saved before
the logs were overwritten. No existing test binary or QEMU reference was
rebuilt or rerun.

The first implementation passed the same 27 runs, then the original full
suite: **177 passed, 0 failed; RTL vs QEMU: 49 agree, 0 differ**. An initial
attempt to diff after just the nine tests encountered missing RTL traces
for other tests in this fresh worktree. Running the full suite supplied
them; the subsequent comparison covered all 49 references.

Added `sim/cpu/tests/btb_early.S`; only that new test was assembled and run
on QEMU. Its four checkpoints and 13,778 compared trace instructions agree.
The bench's PASS total is 13,779 instructions, identical before and after.

Final verification after the clear/state alignment adjustment:

- `make -C sim/cpu run T="cache dcache_rtl icache_rtl ctrand1 crand1 gba_arm gba_thumb mmu_page align"`: 27 passed.
- `make -C sim/cpu diff` after the focused run: **50 agree, 0 differ**
  (the original 49 references plus the new test).
- `make -C sim/cpu run`: **180 passed, 0 failed** (177 original runs plus
  three new runs); the following `make -C sim/cpu diff`: **50 agree, 0 differ**.
- `make -C sim/cpu RTL=sv run`, using an isolated build/output directory:
  **180 passed, 0 failed**; its QEMU comparison: **50 agree, 0 differ**.
- `tools/test_btb.sh`: passes the one-slot and recovery assertions. Against
  the original generated RTL it fails at the expected extra fetch bubble.
- `make lint`: passes (warnings are errors).
- `make cpu-gen-check`: passes.
- `git diff --check`: passes.

The large textual regenerated-netlist diff includes module reordering by
sv2v. Comparing modules by name shows that **only `zap_btb` and
`zap_writeback` changed**; all other generated module bodies are identical
to the starting commit.

The default source-RTL and generated-RTL runs are architecturally consistent,
but do not have identical cycle totals. This is also true before this
change: at 0:0, baseline source `crand1` is 90,676 versus generated 90,706,
and source `ctrand1` is 89,103 versus generated 89,133. The corresponding
changed totals retain exactly that 30-clock difference. Baseline `cache`
is 903,928 in source versus 903,967 generated. Tests with cycle-scheduled
FIQs can also retire different numbers of polling instructions between
the two simulation forms. These differences were not treated as a new
BTB regression or silently combined with the required generated baseline.
Setting both Verilator X options to zero, or using the generation script's
port modules and `SYNTHESIS` with source RTL, did not remove the differences.
Their pre-existing cause was not pursued further in this task.

## Cycle counts

Positive percentages mean fewer cycles. Every listed before/after pair has
the same instruction count. These are complete test totals, not a claimed
per-branch or hardware game speedup.

| Test | Bus latency | Before | After | Saved | Instructions |
| --- | --- | ---: | ---: | ---: | ---: |
| cache | 0:0 | 903,967 | 888,019 | 1.76% | 293,427 |
| cache | 0:3 | 1,021,476 | 1,009,806 | 1.14% | 293,427 |
| cache | 2:9 | 1,346,786 | 1,337,975 | 0.65% | 293,427 |
| dcache_rtl | 0:0 | 71,448 | 59,091 | 17.30% | 12,771 |
| dcache_rtl | 0:3 | 93,933 | 86,288 | 8.14% | 12,771 |
| dcache_rtl | 2:9 | 160,178 | 155,462 | 2.94% | 12,771 |
| icache_rtl | 0:0 | 71,090 | 58,733 | 17.38% | 12,771 |
| icache_rtl | 0:3 | 93,587 | 85,942 | 8.17% | 12,771 |
| icache_rtl | 2:9 | 160,385 | 155,669 | 2.94% | 12,771 |
| ctrand1 | 0:0 | 89,133 | 76,785 | 13.85% | 16,159 |
| ctrand1 | 0:3 | 114,728 | 107,074 | 6.67% | 16,159 |
| ctrand1 | 2:9 | 192,788 | 188,077 | 2.44% | 16,159 |
| crand1 | 0:0 | 90,706 | 78,356 | 13.62% | 15,982 |
| crand1 | 0:3 | 118,251 | 110,613 | 6.46% | 15,982 |
| crand1 | 2:9 | 202,059 | 197,350 | 2.33% | 15,982 |
| gba_arm | 0:0 | 8,334 | 8,332 | 0.02% | 1,192 |
| gba_arm | 0:3 | 10,955 | 10,952 | 0.03% | 1,192 |
| gba_arm | 2:9 | 17,752 | 17,752 | 0.00% | 1,192 |
| gba_thumb | 0:0 | 4,935 | 4,935 | 0.00% | 774 |
| gba_thumb | 0:3 | 6,552 | 6,552 | 0.00% | 774 |
| gba_thumb | 2:9 | 10,900 | 10,900 | 0.00% | 774 |
| mmu_page | 0:0 | 93,545 | 77,345 | 17.32% | 16,887 |
| mmu_page | 0:3 | 123,102 | 113,001 | 8.21% | 16,887 |
| mmu_page | 2:9 | 209,451 | 203,191 | 2.99% | 16,887 |
| align | 0:0 | 5,543 | 5,525 | 0.32% | 549 |
| align | 0:3 | 7,064 | 7,054 | 0.14% | 549 |
| align | 2:9 | 11,440 | 11,419 | 0.18% | 549 |

The new directed assembly test, run on both the original and changed
generated CPU using the same binary:

| Latency | Before | After | Instructions |
| --- | ---: | ---: | ---: |
| 0:0 | 72,947 | 59,655 | 13,779 |
| 0:3 | 94,882 | 86,301 | 13,779 |
| 2:9 | 159,669 | 154,022 | 13,779 |

`gba_arm` changes by only two clocks at 0:0, and `gba_thumb` is unchanged.
The larger gains in cache-enabled random tests also include their setup
loops. The one-slot contract is demonstrated separately by the frontend
bench, so these aggregate totals need not be interpreted as branch counts.

## Limits, risks and next steps

The functional risk is misaligning prediction metadata, accepting a
discarded slot's prediction, or losing an older instruction at a redirect.
The directed tests cover these boundaries; the instruction-by-instruction
QEMU comparisons cover the resulting architectural stream. They are not
formal proofs or exhaustive tests of arbitrary simultaneous interrupts,
table updates and bus errors.

The PC selection still uses a registered BTB decision and registered
target. There is no RAM read or tag comparator in its combinational path.
However, `pc_nxt` now also drives the RAM read index and the valid-bit read,
so fanout and placement change. The metadata registers and one-slot valid
control also affect placement. **104 MHz timing and fitted area have not
been measured**: no Quartus compile, seed sweep, hardware deployment or
game-performance measurement was performed. Lint and simulation do not
establish timing closure. Next, screen CPU timing, then compare matched
whole-core seeds at both slow corners, including the PC-to-BTB-valid path
and the existing I-cache, issue, load-data and Wishbone critical paths.

The supplementary firmware run used the existing main checkout's boot
images and reference device trace, with separate output under
`sim/cpu/build/btb-boot`. It was stopped after its last reported checkpoint
of **110,000,000 cycles / 70,583,561 retired instructions**. The comparator
reported **279 device accesses, all matching the reference prefix**, out
of the reference's 76,975 accesses. This is only an early-boot check, **not
full boot validation**. The 2.7-billion-cycle run remains to be completed;
at the observed local simulation rate it is a substantially longer run
than the numbered CPU regression. The simulation was stopped rather than
left running after the task.

After timing and full boot validation, measure identical game segments on
hardware with FIFO-empty and ALU-clear counters; do not add these cycle
savings to the other engineers' improvements without measuring the merged
result.

## Commit status

The implementation is ready in this worktree, but the sandbox prevented
staging, so **no commit was created**. The actual error was:

```text
fatal: Unable to create '/Users/jacob/dev/fpga/mister/NGage_MiSTer/.git/worktrees/NGage_MiSTer-cx-btb/index.lock': Operation not permitted
```

The shared Git metadata is outside the permitted writable paths. The
branch was not switched, nothing was pushed, and no workaround modified
the shared Git directory. Once Git metadata is writable, commit the seven
changed/new files with this message:

```text
BTB: predict from next PC and discard only one younger fetch slot

Read pc_nxt into the clocked BTB, retain the registered tag decision,
and redirect at pc_del. Carry accepted target/state through the two
remaining fetch registers; preserve older slots, stalls and recovery.
Clear unaccepted decisions on invalidation. Add directed ARM/Thumb,
stale-code and frontend timing regressions; regenerate the CPU netlist.

Cycles before -> after, latencies 0:0 / 0:3 / 2:9:
cache:   903967 -> 888019 / 1021476 -> 1009806 / 1346786 -> 1337975
ctrand1:  89133 ->  76785 /  114728 ->  107074 /  192788 ->  188077
crand1:   90706 ->  78356 /  118251 ->  110613 /  202059 ->  197350
Instruction counts are unchanged.
```
