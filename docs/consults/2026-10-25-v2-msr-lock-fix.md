# V2: the kernel's clobbered ip (a younger writer past D2 on an unaccepted short hit)

Branch `codex/arm9v2`, from `ab84e82`. Commits: `17094db` (test), `137f6b8`
(fix and regenerated netlist). No Quartus run, no board run, no push.

## Reproduction

`sim/cpu/tests/arm9_msr_lock_rtl.S` (`@@ qemu: no`) copies the system-call
window at `0x50321564` from the session-11 board trace. Each case runs
twice (cold and warm I-cache). The first pass maps the code as sections
at the bench's latency. The second maps it as small pages at a fixed
latency of 24. The cases vary five things:

- the PSR write: none, SVC to UND, UND mask-only (the kernel's), SVC
  mask-only, UND to SVC;
- the TLB flush: none, D-TLB, both;
- the victim layout: the set empty, both ways dirty, one dirty way plus
  a store miss just before the window, and **lit1's own line cached as
  the LRU way and evicted by that store miss** (beside a dirty or a
  clean line);
- the gap between the miss and the younger writer: 0 to 3
  instructions, with or without a `str` through ip.

Each case checks r0, the final ip, the reader's store and the old ip's
word. It records error bits in a table. The test fails at the end with
the first failure.

Failing cases before the fix (of 1,050):

| RTL | 0:0 | 0:3 | 2:9 |
|---|---:|---:|---:|
| V2 at `ab84e82`, D8 | 106 | 130 | 136 |
| V2 at `7ed5190` (session 11, the board build), D8 | 106 | 133 | 135 |
| V2 at `ab84e82`, D16 | fails | fails | fails |
| ZAP | 0 | 0 | 0 |

Every failure has the same pattern:

- No TLB flush. A TLB miss at that clock clears the short hit, and those
  cases pass.
- Victim kinds 3/4 only: lit1's line is departing.
- With or without an MSR. A mode-change MSR adds the fill-end variant
  below.
- Error bits 1+2 only: ip and r0 hold lit1's value (`0x00410E90`,
  `[A1+4]`), the board's symptom. The reader's store was never wrong.

## Mechanism

D2's WAW check (`arm9v2_decode.sv`, `load_hazard`) lets a younger writer
of W's load destination pass on a first-clock short hit,
`i_w_load_hit = w.memory && short_hit && !w_waited`. The premise is that
the load completes now. Two short hits do not:

1. **A fill's departing victim.** The store miss allocates over lit1's
   line. That line keeps its tag until `UNLOCK_REG` and still compares
   equal (short hit 1), but it gets no background-hit slot. The FSM
   withholds the ACK, the load waits, and after installation it misses.
   Only then does the FSM install the lock on ip.
2. **The fill-end clock.** The response predates installation, and W
   re-reads it (`RETRY0`). After a W flush (the mode-change MSR), the
   refetched first load often lands exactly on this clock (the FSM is
   IDLE there).

Bench trace, case "no MSR, victim 3, gap 0", 0:0, cold pass:

| Clock | Event |
|---|---|
| 78048 | The store miss is accepted; the write-allocate fill starts. |
| 78049 | `ldr ip,lit1` is in W: short hit 1, no ACK. D2's hazard drops, and `ldr ip,lit2` enters S. |
| 78066 | The fill ends; RETRY0/RETRY1. |
| 78069 | lit1 completes as a miss. The lock on ip is visible from 78070. |
| 78073 | `ldr ip,lit2` hits in W and writes ip (RF port B). On the same edge, lit1's critical word writes ip through port C, which has priority. |
| 78078 | `ldr r0,[ip,#4]` reads `A1+4`. |

On the board, the same race fits the trace:

- The set held lit1's line from the −38 miss.
- The `stmfd` store miss allocated the stack line over it.
- The `str` used the departing line's word: the right value, two clocks
  before the bus data.

**One part of the trace is not explained.** The trace shows a walk for
lit1's page after the fill. In the test, a TLB miss at that clock
prevents the failure. The walk's cause is not established.

## Fix

The D-cache exports `o_short_live` (`zap_dcache.sv`). It is
`live_lookup`, the FSM's registered `state_ff[IDLE] || hum_slot_ff`, the
only states with a hit ACK. `zap_top` wires it to the V2 core, and only
V2 uses it. In `arm9v2_core.sv`:

```
.i_w_load_hit(w.memory&&i_data_short_hit&&i_data_short_live&&!w_waited&&!fill_ended)
```

Such a load is treated as a pending owner. The younger writer waits in
D2, then for the miss's lock to clear. Readers are unchanged: the word
they may take in S/A is the departing line's current data, and the
background return rewrites the same value.

Both terms are needed:

- The live-lookup gate alone leaves 16/1/0 failures, all in the
  mode-change cases (the fill-end clock). This was measured as a gate on
  `o_short_hit` itself.
- Gating `o_short_hit` itself (readers too) plus `!fill_ended` also fixes
  the test. It moves 8 predictor-on and 15 predictor-off runs, by −51 to
  +332 clocks, so it was rejected.

The new D2 terms are three registers (`live_lookup`, `fill_was_busy`,
`i_data_fill_busy`) in the existing hit qualifier. Timing is not measured.

## Verification

- **New test after the fix:** passes on V2 (predictor on and off) and on
  ZAP at 0:0/0:3/2:9, D8 and D16. V2 clocks at D8: 3,420,433 /
  3,632,600 / 4,132,944 with the predictor on, 3,464,023 / 3,669,542 /
  4,183,322 with it off. ZAP: 3,480,529 / 3,612,873 / 3,989,321.
  217,006 instructions on both cores.
- **Full suites:** 291/291 in all three configurations (ZAP, V2 on, V2
  off), on the regenerated netlist.
- **Counts against pre-fix runs of the same 288:**
  - ZAP: 288/288 identical (D16: 288/288).
  - V2 predictor on: 288/288 identical (D16: 288/288).
  - V2 predictor off: ctrand3.0-3 134,369 → 134,374 and ctrand7.0-3
    134,323 → 134,328 (+5 each). D16 off moves ctrand3/4/7 at 0:3 by +5.
    Instruction counts are unchanged.
  - The 3/4/5 hit windows are unchanged (their exact checks pass).
- **QEMU** (`make qemu`, then `diff` for each result directory): 73
  agree, 0 differ in all three configurations.
- **Netlist:** `tools/gen_cpu.sh` regenerated it and `make cpu-gen-check`
  passes, both under `LC_ALL=C`. Without it this Mac's glob orders
  `zap_cache_fsm.sv` before `zap_cache.sv`, and the check falsely fails
  on module order. `grep -c 'input reg'` is 23 before and after: 10 in
  ZAP modules and 13 V2 function arguments, as the session-7 report
  explains.
- **Lint:** `make lint` passes, as does `-Wall` on `emu` with
  `NGAGE_DEBUG=1`, with `NGAGE_CORE_ARM9=1` and with both. No warnings.

**Not done:** a fit of the new D2 term, and a board or whole-core run.
The per-clock debug probe (a `bind` module) is in the session
scratchpad, not committed.
