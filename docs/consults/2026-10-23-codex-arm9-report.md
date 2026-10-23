# ARM9 replacement: session 1 continuation report

The ARM9 CPU is **not integrated or selected**. ZAP remains active and passes the
existing suite. This is a multi-session implementation, starting at `75cce2e`
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

## Timing experiment (in progress at this checkpoint)

`TRIAL=arm9_execute sim/cpu/quartus/run.sh` uses the existing CPU trial QSF/SDC,
Cyclone V 5CSEBA6U23I7, Quartus Lite 17.0.2, seed 1, 9.615 ns. It generates an
isolated `arm925t_gen.v` containing the trial and real leaves; it does not replace
the production netlist. The trial contains the unchanged 40-register file with
four reads/three writes, D capture, registered E-result forwarding, flags feedback,
branch target, output registers and stage enables. Total area includes that
register file and stimulus/observation registers; it is not incremental CPU area.

First single-stage result, server `dev/mister/ngage-codex-arm9-execute-s1`:

| Corner | Setup slack ns | Hold slack ns |
| --- | ---: | ---: |
| Slow 1100mV 100C | -1.838 | 0.364 |
| Slow 1100mV -40C | -1.678 | 0.306 |
| Fast 1100mV 100C | 3.102 | 0.183 |
| Fast 1100mV -40C | 4.159 | 0.142 |

Area: 2,427 ALMs, 2,061 registers, no RAM or DSP blocks. This fails 104 MHz.
The hot corner is **100C**, correcting the earlier progress message's 85C.
Summary files and input SHA-256 are in `arm9/single-stage/`. Detailed path
extraction is pending at this checkpoint: the compile completed but the local
launcher was edited while waiting and encountered a shell parsing error before
STA reporting. Re-run reporting on the existing successful fit, not synthesis.

The decode-stage alternative is being fitted in
`dev/mister/ngage-codex-arm9-decode-shift-s2`. It includes E-to-D forwarding,
all three older registered writers and RF-to-D shift, so it cannot hide a
shifted-operand dependency behind an unmodeled interlock. An earlier s1 trial
was canceled after finding a missing W-to-D bypass in the harness; ignore it.
At most four Quartus containers, counting the other engineers, were allowed.
No timing split is accepted yet. Do not proceed with a whole-core implementation
on the assumption that either option closes at 104 MHz.

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

At this checkpoint, milestone 1 is committed and the execute portion of
milestone 2 is implemented/verified; timing experiments are unfinished.
Milestones 3–5 have not started. There is no `CORE` selector and no fake ARM9
fallback. Do not change the default until ARM9 itself passes all comparisons.

1. Finish both timing reports, identify the worst path, optimize or choose the
   split based on measured slack. Preserve full input hashes and summary/path
   evidence; rerun leaf checks after RTL changes.
2. Resolve the cache-latency discrepancy before fixing a final cycle model.
   Measure request/ack edge alignment; do not remove RAM hazard-forwarding
   registers or change tag hit logic casually.
3. Add a selectable integer core at `zap_top`'s core instance, propagating
   `arm925t.CORE`, with ZAP default. Reuse the cache/MMU/bus wiring. Implement
   fetch epoch invalidation, retirement/debug adapter, ARM DP/branch/single
   transfers and precise exception state. Start with `alu`, `align`, `modes`,
   `exc`, then add Thumb, sequences, multiply and CP15.
4. Preserve blocking load completion even though the retained D-cache can ack
   early: consume its critical-word register-completion event before retiring;
   distinguish err2/retry from faults, and carry the access's mode and VA.
5. Continue the complete regression sequence and add `arm9_cycles.S` only with
   actual cycle-window assertions. Firmware boot/hardware remain someone else's
   milestone checks.
