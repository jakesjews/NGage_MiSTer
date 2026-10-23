# ARM9 replacement: session 1 continuation report

The ARM9 CPU is **not integrated or selected**. Milestone 1 (design) and
milestone 2 (tested execute datapath and a passing 104 MHz trial) are complete.
ZAP remains active and passes the existing suite. This is a multi-session implementation, starting at `75cce2e`
on `codex/arm9`. No branch changes, pushes, `sys/` edits, existing test-binary
rebuilds, QEMU reruns or firmware boots were performed.

## Done and verified

- Design milestone committed as `4c9fbfb`: `docs/ARM9.md` records stages, cycle
  model, forwarding/interlocks, CP15/cache boundaries, exceptions, tests and risks.
- New GPL-3.0-or-later datapath leaves under `rtl/cpu/arm9/`: physical-tag
  forwarding with youngest-pending-write priority, complete ARM barrel-shift
  edge cases, all 16 data-processing operations/NZCV, conditions, store-data
  forwarding and a branch-target adder. No multiplier or instruction controller.
- `arm9_execute.PRE_SHIFTED` supports a captured D-stage shift result; the default
  performs the shift in E. Both are tested. Callers must supply current flags,
  banked tags and correct PC/immediate values, and gate side effects on readiness.
- Source and sv2v output each pass 145,568 independent C++ reference checks in
  both modes: 582,272 checks total. Run `make -C sim/cpu arm9-execute`.
- Added ARM9 sources to `tools/gen_cpu.sh` and the SV bench source list. The
  regenerated production file still contains only ZAP. All 40 generated module
  bodies are byte-identical to baseline; sv2v reordered some modules after its
  input list changed. This explains the large generated diff without a CPU change.
- Top-level `make lint` passed; `make cpu-gen-check` passed. New leaves and both
  timing harness configurations also lint with warnings fatal. ShellCheck passes
  excluding its informational SC2029 for deliberate client-side SSH expansion.

The complete required regression sequence ran: baseline focused **27/27**;
baseline full **198/198**, QEMU **52 agree / 0 differ**; after-change focused
**27/27**, full QEMU **52/0**, full suite **198/198**, full QEMU **52/0** again.
This checkout has 66 tests and 52 QEMU references, more than the brief's 59/49.
No failures or changed architectural instruction counts were observed.

## Cycle measurements

ZAP before -> after; no ARM9 execution or speedup is claimed. Each cell is the
same before and after, at bus latencies 0:0, 0:3, 2:9 respectively.

| Test | 0:0 cycles | 0:3 cycles | 2:9 cycles | Instructions (each latency) |
| --- | ---: | ---: | ---: | ---: |
| cache | 760787 | 888787 | 1222550 | 293427 |
| dcache_rtl | 58301 | 85328 | 154143 | 12771 |
| icache_rtl | 58201 | 85393 | 154521 | 12771 |
| ctrand1 | 72594 | 102419 | 179154 | 16159 |
| crand1 | 73608 | 105167 | 187620 | 15982 |
| gba_arm | 8291 | 10887 | 17749 | 1192 |
| gba_thumb | 4913 | 6523 | 10877 | 774 |
| mmu_page | 77102 | 112796 | 203209 | 16887 |
| align | 5427 | 7001 | 11223 | 549 |

Machine-readable evidence: `arm9/session1-baseline.json`,
`arm9/session1-after.json`, `arm9/session1-validation.txt` alongside this report.
The future `arm9_cycles.S` is not added: no new core can execute it yet. Existing
assembly tests cannot exercise unconnected leaves, so the new behavior is tested
at the leaf boundary instead. Add timed architectural sequences at integration.

## Implemented design and timing decision

Use **one execute stage**, with registered D operands and registered M/W
forwarding sources. The retained shifter uses parallel direction networks;
left shifts no longer pass through input/output bit-reversal muxes. Arithmetic
N/Z comes directly from the adder sum, bypassing the logical-result mux. Keep
the simpler original priority forwarding mux. All changes preserve the leaf
truth table and add no pipeline stage. ARM9's register-shift extra cycle belongs
to the future controller; it has not been implemented by pretending the leaf is
an instruction-executing CPU.

The Quartus harness includes the unchanged 40-register file with four reads and
three writes, D capture, three registered result producers, flags feedback,
branch target, output registers and stage enables. It is a datapath feasibility
trial, not a core. `TRIAL=arm9_decode_shift` also exercises D shifting with a
real E-to-D result/flag path and all older writer ages. The final harness has
an unshifted-Rm E bypass; the rejected early D fits predate that addition.

All fits use Quartus Lite 17.0.2, Cyclone V 5CSEBA6U23I7, 9.615 ns, the existing
CPU trial QSF/SDC and optimization/retiming settings. All are CPU-only trials.

| Trial | Seed | Worst setup ns | Minimum hold ns | ALMs | Registers |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original shared barrel in E | 1 | -1.838 | 0.142 | 2427 | 2061 |
| Shared barrel in D, E-to-D bypass | 1 | -0.535 | 0.158 | 2443 | 2199 |
| Parallel barrel/direct NZ, shift in D | 1 | -0.826 | 0.162 | 2529 | 2185 |
| Shared barrel in D, one-hot forwarding | 1 | -1.352 | 0.107 | 2513 | 2223 |
| Parallel barrel/direct NZ in E | 1 | -0.045 | 0.118 | 2549 | 2190 |
| Parallel barrel/direct NZ in E, one-hot forwarding | 1 | -0.134 | 0.110 | 2579 | 2192 |
| **Retained single E, simple priority mux, final harness** | **2** | **+0.018** | **+0.159** | **2556** | **2185** |

All have zero RAM and DSP blocks. Area includes the register file and trial
stimulus/observation registers; these are not incremental ALMs over ZAP. The
one-hot candidate resolved age into one-hot grants and OR-selected data; it
passed the same reference tests but did not improve the overall fit. It was
reverted. Do not infer that an RTL mux-depth reduction guarantees a faster fit.

Accepted seed-2 corners:

| Corner | Setup slack ns | Hold slack ns |
| --- | ---: | ---: |
| Slow 1100mV 100C | +0.113 | +0.362 |
| Slow 1100mV -40C | +0.018 | +0.304 |
| Fast 1100mV 100C | +4.309 | +0.180 |
| Fast 1100mV -40C | +5.168 | +0.159 |

Worst path: `u_execute|comb~12_OTERM717DUPLICATE` to
`status_out[6]~reg0` (Z flag), seven logic levels, 9.316 ns data delay at
Slow 1100mV -40C. The original E path ran through shift, arithmetic, result
selection and zero detection (11.157 ns, ten levels at Slow 100C). Original
D shifting was limited by register tag selection/forwarding plus the barrel.
Node names include Quartus retiming artifacts. Retiming adds no CPU cycles.

**The 18 ps margin is tiny.** Seed 1 missed, so this establishes feasibility
only, not a robust 104 MHz integrated CPU. Control, additional forwarding ages,
reset/enable fanout and placement can invalidate it. Do not advertise full-core
timing closure. Repeat the trial during integration and require milestone 5's
integrated CPU-only trial before changing the default implementation.

Reproduce the accepted fit from the worktree root:

```
SEED=2 TRIAL=arm9_execute BUILD_DIR=dev/mister/ngage-codex-arm9-execute-parallel-s2 sim/cpu/quartus/run.sh
```

Current SystemVerilog was regenerated separately with sv2v and compared
byte-for-byte with `sim/cpu/build/quartus-arm9-execute-2-104/arm925t_gen.v`, the
accepted trial input. Evidence directories beside this report under `arm9/`:
`single-stage`, `decode-shift-shared`, `decode-shift-parallel`,
`decode-shift-onehot`, `execute-parallel`, `execute-combined`, and
`execute-retained-seed2`. Each retains fit/STA summaries, the worst-corner full
path and an input SHA-256. Full generated inputs and logs remain in the ignored
`sim/cpu/build/quartus-*` directories and isolated server build directories.
The earlier incomplete D trial missing W bypass was canceled, not counted.

## Functional cases and remaining risks

The design document is the detailed case inventory. Implemented/tested: LSL,
LSR, ASR, ROR, RRX; zero/31/32/>32/255 shifts; carry preservation; subtract
no-borrow carry; signed overflow; logical V preservation; ADC/SBC/RSC; all
conditions including NV; no writes/wait on bubbles or failed conditions;
youngest-writer priority, unavailable writers, immediate/unused tags, store
operands and branch-target wraparound.

Not covered by this leaf: fetch, ARM/Thumb decode, banking/PC bias, pipeline
hold/flush control, real data memory, exceptions, SPSRs, LDM/STM/SWP, multiply,
CP15 operations and cache integration. Those require the core controller and
architectural tests. Passing ZAP does not prove them for ARM9. The fitted trial
also does not prove integrated timing, congestion, reset/enable fanout or cache
paths. PRE_SHIFTED users must account for earlier operand availability, including
load-to-shift dependencies and current carry for RRX/zero shifts.

A second major gate is cache latency: the retained `zap_ram_simple` has **three
registered read edges**, and tag/data/valid/dirty/LRU all match that schedule.
The brief's two-cycle assumption does not describe this checkout. A first
correct adapter must preserve the native schedule; a compliant TRM+1 design
needs a separately demonstrated solution. No cache internals were changed.

## Next session / exact stopping point

**Stopped after milestone 2.** The execute leaf is tested and has a passing
seed-2 104 MHz fit. The design choice is single E with parallel shifter and
direct arithmetic N/Z, simple priority forwarding. Milestones 3–5 have not
started: no fetch/decode/controller, no `CORE` parameter, no ARM9 probe adapter,
no architectural ARM9 run, no ARM9 cycle test. There is no fake ARM9 fallback.
Keep ZAP the default until ARM9 itself passes every comparison.

Continue in this order:

1. Resolve the cache phase contract before fixing final pipeline control. The
   retained RAM path is three edges, not two. Initially preserve native phases;
   measure exact request/ack timing and investigate honest early address launch
   if needed. Do not remove RAM hazard-forwarding registers or change tag hit
   logic casually. The requested TRM+1 ceiling is not yet achieved.
2. Add a selectable integer core at `zap_top`'s core instance, propagating
   `arm925t.CORE`, with ZAP default. Reuse cache/MMU/bus wiring. Implement fetch
   epoch invalidation, a retirement/debug adapter, ARM DP/branch/single transfers
   and precise exceptions. Start with `alu`, `align`, `modes`, `exc`, then add
   Thumb, sequences, multiply and CP15. The existing core paths are still intact.
3. Extend producer coverage for the actual pipeline: the leaf's three slots
   match M1/M2/W; native M1/M2/M3/W and simultaneous load/base writers need more
   coverage or explicit interlocks. Do not leave an older writer unaccounted for.
   Flags are selected externally; preserve age and rollback on an older fault.
4. Make load retirement blocking while keeping D-cache critical-word-first:
   consume `o_reg_idx/o_reg_dat` before retiring an early-ack miss; distinguish
   err2/retry from faults and carry the access's own mode, original VA and format.
5. Add `arm9_cycles.S` and actual retire-window assertions when the core runs.
   Check each TRM row, source-role dependency and cache wait separately. Existing
   test binaries and QEMU references remain usable; only new tests need new ones.
6. Continue the required focused/full/QEMU sequence, lint, generation checks and
   repeated CPU-only fits. Full CPU 104 MHz timing, ordered firmware boot and
   physical game measurements remain unverified; the latter two are assigned
   to the other engineer, not this session.

No build or simulation from this session is left running. Quartus containers
used `--rm`; the pre-existing shared image and other engineers' jobs were left
alone. No push was made.
