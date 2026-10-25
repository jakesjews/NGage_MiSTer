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

## Follow-up: exception entries and returns (`72e50e5`)

On the board, the fixed core (`694252b`, 78 MHz) boots and plays. One
boot of three still died in the logo phase, with the kernel record
`00250030 503b27c0 10000000`:

- The PC was `0x00250030`.
- r14 was `0x503B27C0`, the return address of the executive-call stub
  `svc 0xC000BF`.
- The type word is a prefetch abort.

The kernel's prefetch-abort handler stores the aborted mode's r14 (for
USR, `stm lr, {sp, lr}^` at `0x50322124`). So the PC went wrong in a mode
whose lr was the caller's, most plausibly on the way back to user. The
candidates are:

- `movs pc,lr` followed by `bx lr` at `0x50321618`-`0x50321620`;
- the fast path at `0x503214c0`;
- the context-switch resume at `0x50321660`-`0x50321670`.

### The sweep

`sim/cpu/tests/arm9_swi_lock_rtl.S` repeats the window shapes behind
every other flush V2 takes, 584 cases:

- **Flush:** SWI from SVC or USR; IRQ from SVC or USR; `movs pc,lr` to
  SVC or USR; `ldmfd sp!,{r0,pc}^`; `subs pc,lr,#4`.
- **Window:**
  - the WAW pair, and the kernel's store-through-ip shape;
  - `ldr pc,[r1,r2,lsl #2]` through the loaded table base;
  - `bx` through the loaded register;
  - each with and without a younger writer;
  - a younger writer of the new mode's banked lr and sp;
  - copies of the executive-call return and of the SWI entry.
- **Lit1:** its line departs under a store miss beside a dirty or a
  clean line, optionally after a TLB flush, or it is a cold miss behind
  a TLB flush.
- **Gap:** 0 or 2 instructions between the store miss and the flush.

Each case runs cold and warm in three configurations: sections at the
bench latency, small pages at 24, sections at 12.

| RTL | 0:0 | 0:3 | 2:9 |
|---|---:|---:|---:|
| V2 before `137f6b8` (failing cases of 1,752) | 318 | 357 | 407 |
| V2 at `137f6b8`, predictor on and off | 0 | 0 | 0 |
| ZAP | 0 | 0 | 0 |

Before the fix, every flush kind except `ldm ^` failed. So did every
younger-writer window, including the banked lr and sp ones. The two
kernel-shaped windows never failed: the SPSR `msr` flush, or the cold
miss on the SVC word, separates the load from the departing line.

On the fixed core, a counting probe confirms that the hazard is hit:

- 822-1,166 unaccepted first-clock short hits per run;
- 16-79 first-clock short hits on the fill-end clock;
- at least one of each in every flush kind and every window kind.

**No variant fails after the fix.**

The test also stopped ZAP on a bench assertion ("Registered HUM tag
match differs from live lookup"). It fired on idle clocks of a long
deferred write-back, where ZAP's early compare follows the next check
address. Only a presented access consumes that match: the HUM ACK,
`live_write` and the accepted-hit LRU update all require `i_rd` or
`i_wr`. The assertion now requires one too. With that change ZAP's
results are all correct.

Verification:
- 294/294 runs in all three configurations.
- All 291 earlier runs are cycle-identical.
- QEMU: 73/73 agree.

### Audit: consumers of the first-clock W short hit

| Consumer | Trusts completion? | Verdict |
|---|---|---|
| D2 WAW exception, `arm9v2_decode.sv:535` | yes | the hole; fixed in `137f6b8` (`arm9v2_core.sv:838`) |
| D2 S-entry pending bit `o_pending`, `arm9v2_decode.sv:599` | for data only | safe; gated by the same `i_w_load_hit`, and S re-evaluates live producers |
| S/A waits and grants, `i_load_hit`, `arm9v2_execute.sv:144,147,162,228`; W forwarded word `mw_value[1]`, `arm9v2_core.sv:465` | for data only | safe by argument (below) |
| `fast_pc_hit`, `defer_load`, `load_data`, `arm9v2_core.sv:695-697` | no | used only with `request_done` (an ACK); the assertion at 699 checks the word |
| `d_return_match`, `return_a_match` (execute 126/130), `quick_reload`, `return_ready` | no | built from completion (`return_next_valid`) or registered locks, not from the short hit |

The S/A argument: a reader that takes an unaccepted or stale short-hit
word takes the departing line's current contents, which equal memory.
The later background return writes the same value into the register
file.

### Ranked remaining candidates (none reproduced here)

1. **A stale memory word through the short port's store-to-load
   handling.** The context-save and resume code stores the thread's
   saved PC and SPSR (`str r0,[ip,#0x3c]`, `str lr,[ip,#0x40]` at
   `0x50321638`) and reloads them a few instructions later (`ldr
   r0,[lr,#0x40]`, `ldm{ne} lr,{...pc}^`, `ldr lr,[lr,#0x3c]; movs pc,lr`
   at `0x5032164c`-`0x50321670`). A stale read there gives a garbage PC
   with lr_usr intact.
   - It would be V2-only: the short port and its S11 captured-descriptor
     forwarding live in `zap_dcache.sv` and `zap_cache_tag_ram.sv` under
     `SHORT_READ`.
   - It fits panics spread across contexts.
   - Neither test covers same-word store-then-load at distances 2-8
     under a fill.
2. **The reader-side premise, if the short data can come from a line
   that is half installed.** Readers trust that an unaccepted or stale
   short hit carries the departing line's data. If the short data
   register can capture the new line's bytes at the old tag on the
   `UNLOCK_REG` edge (S11 post-edge forwarding), a reader's operand would
   be wrong for good. That is `mw_value[1]` (core 465) and `i_load_hit`
   (execute 144-228). The 16-79 fill-end events pass, so this is less
   likely.
3. **V2's fetch queue across a redirect into a filling I-line.** Entries
   pushed as `pending` are released by any `i_fill_done`
   (`arm9v2_fetch.sv:151-154`). A wrong word after an exception-entry
   redirect would be executed. The sweep does not cover it.
4. **A latent priority, not a cause under the D2 invariant.** When an
   older background return (port 1, `i_dc_reg_dat`) and a younger normal
   completion (port 0) match the same tag on one clock, port 1 wins the
   S/A repair loops (`arm9v2_execute.sv:374`, `383` and `459`). Register-file
   port C also beats B. Both are safe only while D2 never admits that
   younger writer.
5. **Low.** Banked tags on the mode switch: D1 maps tags with the live
   CPSR (`arm9v2_decode.sv:298`), every mode change flushes, and the
   banked windows pass. The RAS/BTB after the flush: BX and DP/LDM PC
   writes are validated at A/W.

The hardware trace of the fixed source should separate candidate 1
(wrong word on a store-to-load pair in the save/resume code) from
candidate 3 (a wrong instruction word on the refetch).

## Follow-up 2: candidates 1-3 as directed tests (`34ccaaf`)

None of the three fails. Each test passes on V2 (both predictor modes)
and on ZAP, at 0:0/0:3/2:9, D8 and D16. Expected values are computed in
the tests, independently of either core. The full suites run 303/303 per
configuration, and the 294 earlier runs are cycle-identical. There is no
RTL change.

### Candidate 1: `arm9_store_reload_rtl.S`, store then reload

- **Stores:** str, strh, strb, stmia of three words.
- **Reloads:** the same word, another word of the line, another width;
  0, 1, 2, 4 or 6 instructions after the store.
- **Line states:**
  - present, or present and dirty;
  - absent: the store allocates and is merged byte-wise into its own
    fill buffer (`zap_dcache_fsm.sv:467`);
  - departing under a store miss;
  - dirty and departing under a load miss, so its write-back is deferred
    behind the fill (`CLEAN_SINGLE` after `UNLOCK_REG`);
  - being filled by a load miss;
  - write-through (the store completes on the bus and updates the line
    at `UNC_DONE`).
- **Modes:** SVC, USR, and a store in SVC with the reload in UND after a
  mode-change flush.
- **Kernel case:** the context save/resume copied literally, in UND, for
  a USR and a SYS thread. It does `stm ^`, stores the PC and SPSR words,
  reloads them into `msr spsr_fc`, then `ldm{ne} {..pc}^` or `ldm ^` plus
  `ldr lr,[lr,#0x3c]; movs pc,lr` into `bx lr`. The save area's lines are
  present, dirty, absent or departing.

1,688 cases, each cold and warm, at the bench latency and at 24. Every
reload value, final PC, mode and restored register is correct. The
same-set store/lookup collision window is covered by the gap-0..2 hits.
Only 0-12 unaccepted short hits occur: W is in order, so a reload can't
reach W before its store has been handled.

### Candidate 2: `arm9_install_edge_rtl.S`, readers around installation

- **First access:** a load or an allocating store misses word c (0-3).
  The fill returns that word first and wraps (linear for c = 0).
- **Then:** after 0-6 instructions, a load of word k, read at once by an
  ALU operand (A) and a shifted operand (S), and a third load summed
  with it.
- **Set:** empty, or both ways dirty (deferred victim drain).

448 cases, at the bench latency and at fixed 8 and 24.

What the probe saw at each of the 2,688 installations per run:
- W held the second load on the line: 2,420-2,670.
- A held its pending reader: 2,260-2,452.
- S held the pending shifted reader: 2,274-2,562.
- The new line took background hits during the drain: 2,480-2,688.

Measured from the install edge (the `UNLOCK_REG` clock), the second load
completed at:

| Latency | Completion clock: count |
|---|---|
| 0:0 | +3: 32, +4: 302, +5: 426, +6: 346, +7: 994, +8: 570 |
| 0:3 | +4: 282, +5: 409, +6: 308, +7: 1011, +8: 660 |
| 2:9 | +4: 287, +5: 380, +6: 331, +7: 1009, +8: 663 |

A few cases at each latency complete later. None completes before +3:
the FSM admits the installed line only three edges after `UNLOCK_REG`
(`install_delay_ff`, `fill_visible_ff`), and a held access is
re-looked-up. A half-installed line is therefore never readable in this
design; all values were correct.

### Candidate 3: `arm9_fetch_redirect_rtl.S`, fetch queue across a redirect

The bench runs this test with `--icache-quarantine`, which makes every
I-fill provisional.

- **Entry:** after invalidating the I-cache, each case enters a cold
  line at word e (each critical word).
- **Redirect:** taken from that word, or after one plain instruction: b,
  beq, bx, mov pc, ldr pc, or svc.
- **Target:** a cold line two lines on, or far away, so that a second
  fill follows.
- **Poison:** every other word of both lines.

120 cases, untrained and trained BTB, at three latencies. Per run:
19,856-20,150 provisional pushes, 173-221 redirects that discarded
pending entries, about 9,900 fill completions. No poison retired and no
target word was wrong. The test passes with guaranteed fills too.

By the RTL, the hazard can't occur:
- During `FETCH_SINGLE` only the filling line's arrived words acknowledge
  (`fill_ready_ff`), so a pending entry always belongs to the current
  fill.
- Its `fill_done` (`FILL_COMPLETE`) precedes any next fill.
- A redirect clears the queue and bumps the epoch.
- A pending entry's word has already arrived; "pending" only defers a
  late bus error. An early release could at worst lose a prefetch abort,
  never deliver a wrong instruction word.

### Where that leaves the second death

The directed sweeps now cover, without a failure:
- the first loads after every flush kind;
- the WAW, RAW, banked and dispatch shapes;
- store-to-reload in every cache state, including the kernel's
  context-switch code;
- readers around line installation;
- the fetch queue across redirects.

The remaining explanations are outside these single-CPU, single-master
shapes. In order of likelihood:
1. An interaction with the other bus masters (DMA, LCD, the MMC host)
   and with the board's real latencies and early-ACK behaviour, which
   the bench's RAM does not model: `bus_no_late_error`, the merger's
   arbitration, ROM wait states.
2. Timing at 78 MHz on the trace build's specific paths.
3. A V2 path not yet shaped, such as Thumb, multiply, SWP or CP15.

The trace of the fixed source is the next evidence.

## The second death (`5c652ee` test, `6a85407` fix)

A 16 KB trace core of the fixed source caught a user-mode data abort at
25.25 s (the "App. closed" panics). The thread runs Thumb code: it calls
`0x503CBDD8`, which calls `0x503CBDC0`, which calls through an import
stub into Symbian's handle lookup at `0x503A320C` (ARM). The lookup
returned NULL, and the caller's `ldr r0,[r4,#28]; ldr r0,[r0,#56]`
aborted at `0x503CBDF4`.

### Every load returned memory's word

Each value below is checked against the data ring and the bus ring.
Where a load missed, the data tap shows the victim's word, the known
artifact; the bus gives the delivered word.

| PC | Load | Address | Value | How |
|---|---|---|---|---|
| `0x503CBDE6` | `ldr r1,[r5,#60]` | `0x80629DF0` | `0x00080000` (the handle) | hit; stored there earlier in the window |
| `0x503CBDC2` | `ldr r0,[r0,#36]` | `0x80629DD8` | `0x8062A274` | miss; bus line `0x0A1D4DD0`, critical word first |
| `0x503A320C` | count | `0x8062A27C` | 1 | hit |
| `0x503A3210` | array base | `0x8062A288` | `0x8062A358` | hit |
| `0x503A3228` | entry id | `0x8062A358` | `0x00030008` | hit |
| `0x503CBDC4` | `ldr r2,[pc,#12]` | `0x503CBDD4` | `0x801009D0` | miss; ROM line `0x003CBDD0`, critical word first |
| `0x503CBDC6` | `ldr r2,[r2]` | `0x801009D0` | `0x80602148` | hit |
| `0x503CBDC8` | `ldr r2,[r2,#4]` | `0x8060214C` | 3 | hit |

From these, r1 = 8 | (3 << 16) = `0x00030008`, equal to the entry id.
**But the `cmp r1,r3` at `0x503A3238` cleared Z.** The first wrong value
is therefore the CPU's r2: the value consistent with the result is the
literal `0x801009D0`, which gives r1 = `0x09D00008`.

### Pipeline situation

1. `ldr r0,[r0,#36]` missed. Its fill (line `0x80629DD0`, set `0x1DD`)
   began evicting the literal line `0x503CBDD0`, the set's LRU way.
2. The literal load reached W on the next clock and hit the departing
   line: a short hit the cache never acknowledges.
3. After installation it missed. Its fill evicted the set's other, dirty
   way (`0x0A2FFDD0`, written back after the fill), and its word returned
   in the background.
4. `ldr r2,[r2]` and `ldr r2,[r2,#4]` read r2 and also write it. D2
   passes such a writer behind an older pending load of its source,
   reasoning that it must wait for that load's data. But S/A trusted the
   unaccepted first-clock short hit and took the departing line's word
   (the right value). Its data-port address `0x801009D0` precedes the
   literal's bus beat, as in the first death.
5. Both younger loads hit and retired first. The literal's background
   return then wrote r2 = `0x801009D0`.

The first fix had covered only D2's independent-writer exception, not
this self-dependent one.

### Test and fix

`sim/cpu/tests/arm9_dep_waw_rtl.S` copies the shape:
- **ISA:** ARM and Thumb.
- **Eviction:** by a load miss (the board's) or by a store miss to the
  literal's set.
- **Gap:** 0-2 instructions.
- **Younger writer:** two dependent loads, one, an add, a shift.
- **Other way:** clean or dirty.
- **Check:** r2 read from the register file after a call.

At `36a4544`, V2 fails 128/142/144 of 192 at 0:0/0:3/2:9, at D8 and
D16, in both predictor modes, every time with r2 = the literal. ZAP
passes.

The fix:
- D2 registers, with the S-entry record, whether the instruction writes
  a register it reads (`o_self_dep`).
- For such an instruction, S and A accept W's first-clock short hit only
  if `o_short_live` holds and it is not the fill-end clock
  (`arm9v2_execute.sv`, `s_load_hit` and `a_load_hit`).
- Other readers keep taking the word.

### Verification

- **Suites:** 306/306 runs in all three configurations, plus V2 at D16.
- **ZAP:** all 306 cycle-identical.
- **V2, earlier runs moved by the fix** (out of 303):
  - predictor on: 17 runs; crand/ctrand −2..+9 clocks, `cache.0-3` +182,
    `cache.2-9` +6, `store_reload` +4, `psr_irq.0-3` +3 (timer-driven);
  - predictor off: 18 runs, up to `cache.0-3` +1,500 (0.15 %);
  - D16, predictor on: 14 runs.
  - The 3/4/5 windows are unchanged.
- **Why counts moved:** in those runs a self-dependent writer used to
  rely on a short hit that later proved to be a hit anyway. At the first
  W clock the schedule can't tell, short of a new victim-exact
  comparator in the shared cache. Gating every reader instead moved 33
  runs, so it was rejected.
- **QEMU:** 73/73 agree in all three. The four lint configurations are
  clean, and `cpu-gen-check` passes with `LC_ALL=C` (23 `input reg`,
  unchanged).
- **Not done:** no fit and no board run of the change.

## The third death, Kern::Fault("PLAT", 0x1005B) (trace v2t16b, dumps 1-3)

### Dump 3, 21.1 s: where the fault is raised

The kernel server (UND mode) takes a message from `0x80006C00`, with
handle `0xFFFF8001` (the requesting thread itself) at +4 and reason 0 at
+8. It dispatches it as a panic request:
1. The event dispatch at `0x5033A390`, then `0x50338F6C`; the
   category descriptor is copied by `0x5033B948`.
2. The handle `0xFFFF8001` is translated to `0xFFFF0003`, then to the
   thread `0x8040E370` (via `0x5033791C` and `0x50324714`).
3. The virtual panic `ldr pc,[ip,#60]` goes to `0x5032D9DC`. A check at
   `0x50325AE4` returns −2, and the call continues with `mov r1,#2`
   (exit type panic) and `ldr pc,[ip,#52]` to `DThread::Exit` at
   `0x5032D7C8`.
4. There, `[thread+36]` = 3 is rewritten to 2. `[thread+32]` = 4 is the
   critical flag, so `movne r0,#0x5B; blne 0x5032DD9C` raises
   Kern::Fault("PLAT", 0x5B | 0x10000).

So a system-critical thread panicked itself (User::Panic, reason 0); its
category string was copied before the data ring's start. The kernel's
reaction is correct.

### Consistency

All 128 data-ring accesses of dump 3 are consistent with the
instruction stream. The 25 ROM reads whose tap differs from cs0.bin are
explained:
- misses whose bus fill delivers the ROM word, or whose fill precedes
  the bus ring's start;
- halfword loads of the UTF-16 "PLAT" string.

No register value in the window is inconsistent.

### Dumps 1 and 2, the user aborts

Both dereference zeros that memory delivered:
- **Dump 1, 17.9 s:** `ldr r0,[r0]` at `0x5094EA3E` missed on
  `0x8540BEA4`. The bus filled line `0x0A1D4EA0` with zeros, and the
  tap's `0x8040F840` is the victim's word. That null then flows into
  `ldr r0,[r0,#28]` and on to the fault at `0x5044A72A`.
- **Dump 2, 20.6 s:** `[0x0040C7A8]` = 0, a hit.

All three events are consequences of earlier wrong data, outside the
windows.

### Relation to the second fix

The second fix's precondition is common in these windows:
- `ldr rX,[pc,#n]` followed within three instructions by
  `ldr rX,[rX,...]` occurs 11, 5 and 7 times per 512 instructions in
  dumps 1-3. These are the global-access and import-stub idioms (for
  example `0x5095590C`, `0x50AD0BA4`, `0x5033C9F0`).
- Several of those literal loads missed (tap ≠ ROM, with bus fills).
- The fault's frequency follows the conflict rate: 3/3 boots at D8,
  about 1/8 at D16. That is consistent with the departing-line
  precondition.

The corruption itself (a register replaced by its literal, then stored
or used as a pointer) happens earlier than any of these windows. The
evidence supports the second mechanism but does not prove it. No third
mechanism is visible, so there is no test or RTL change here. The board
run of the D8 build of `7dd5509` is the discriminating experiment.

### What should have written the two null words

Neither word is ever written in the failing boot. Both objects are being
destroyed after a Leave, before their construction reached the store;
each field still holds the allocator's zero fill.

**Dump 1, `0x8540BEA4` = `this+0xC0` of the object at `0x8540BDE4`:**
1. A nested `NewL` at `0x5045E548` allocates 0x40 bytes and constructs
   them (`0x5045E5E0`, vtable `0x504699DC`).
2. It calls the object's virtual +0x10 (`0x5045EDB1`), which opens the
   comms database: `RFs`, `c:\System\Data\Cdbv2.dat`, falling back to
   `z:\System\Data\DefaultCdbv2.dat`.
3. That returns −20 (`KErrCorrupt`), at `0x5045E56A`. `NewL` deletes the
   object and calls `User::Leave(-20)`, the code being r5 at
   `0x5045E580`.
4. `CleanupStack::PopAndDestroy` then runs the outer object's destructor
   (`0x5094EA28`, vtables `0x5095A9B8`/`E4`/`AA24`). It dereferences
   +0xC0 without a NULL check.

**Dump 2, `0x0040C7A8` = `this+4` of the object at `0x0040C7A4`:**
- It is built by `NewL` at `0x50AD03F8` (0x1C bytes, constructor
  `0x50AD0428`, vtable `0x50AD1E6C`) and then ConstructL at `0x50AD0450`.
- ConstructL retries `0x50531CFD` on member +0x18 three times with
  `User::After(50000)`, then calls `User::LeaveIfError`.
- **+4 is written only at `0x50AD0490`** (`str r0,[r5,#4]`), from
  `bl 0x50AD1494`, after those steps.
- The destructor path (`0x50AD0530` to `0x50394CF0`) dereferences +4
  unguarded.

The earliest anomaly visible is therefore the `KErrCorrupt` from opening
`c:\System\Data\Cdbv2.dat`. The later aborts and the critical
self-panic are plausibly its consequences.

For the store-triggered capture: these words are written only by the
allocator's zero fill, so that capture will show heap code.
Discriminating triggers would be:
- `User::Leave` with r0 = −20 (svc 0x73 at `0x503A785C`);
- `0x5045E56A` with r0 = −20;
- or a comparison of the board's `Cdbv2.dat` on C: against ROM's
  `DefaultCdbv2.dat`. A corrupted copy points at the copy and write
  path; an intact one points at the DBMS read and validation.

### Audit of the panicking threads' less-covered paths

None of these has a first-clock trust or a lock-free window after the
two fixes:
- **Thumb literal plus `ldr rX,[rX]`:** the self-dependent case is gated
  (`arm9v2_execute.sv` `s_load_hit`/`a_load_hit`, `arm9v2_decode.sv`
  `d2_self_dep`). The I-cache and D-cache share no state for a line both
  touch, only bus arbitration.
- **`bx r3` after `ldr r3,[r3]` in import stubs:** bx writes no register,
  so it may take the departing line's word, which is the current data.
  The target is validated at A against that operand.
- **`pop {r0}; bx r0`:** the same reader argument for the LDM final-word
  pickup. LDM/LDR to PC retires its short word only with the cache's
  ACK (`arm9v2_core.sv` `fast_pc_hit`/`defer_load`/`load_data`).
- **Thumb SWI:** EKA1 user code calls ARM exec stubs. Exception entry is
  ISA-independent at W.

### Uncached and long-latency runs (`arm9_unc_chain_rtl.S`)

The new test covers an older load that is uncached (a word, or an LDM's
last word) or a cached literal, followed by self-dependent chains, an
independent younger writer, or a reader then the writer. The chain's
cached line is present, departing or absent. ARM and Thumb.

- **Before fix 2** (`5c652ee`): it fails 30 of 540, all of them
  departing-line self-dependent chains, including both uncached older
  kinds.
- **At `3c492f8`:** it passes on V2 and ZAP at 0:0, 8:12 and 16:40,
  D8 and D16.
- **The other directed tests:** `msr_lock`, `dep_waw`, `store_reload`,
  `swi_lock` and `install_edge`, plus copies of `msr_lock`, `dep_waw`
  and `store_reload` with their data section mapped uncached and the
  code cached. All 64 runs pass at 8:12 and 16:40, D8 and D16, V2 and
  ZAP.

### Where the Cdbv2.dat check runs (static ROM analysis by a subagent)

**Verified by disassembly:**
- The C: file exists, so the client calls `RDbs::Connect`, then
  `RDbNamedDatabase::Open(RDbs&, c:\System\Data\Cdbv2.dat, "[10004e1d]")`
  (stub `0x50465A68`, called from `0x5045EF00`). The store checks
  therefore run in the DBMS server thread. The client only receives the
  −20 and leaves.
- `0x50465AC0` is Create; it runs only if `RFs::Att` fails.
- The ESTOR −20 sites, with the correct values for the C: file:
  - header check at `0x508B53D0` (leave at `0x508B5470`): iBackup
    `0x4F58`, iHandle 0, iRef `0x239D`, iCrc `0x0955`;
  - frame type and length at `0x508AF8F2` and `0x508AF91C`: descriptors
    `0x8043`, `0x80E8`, `0x5534`;
  - TOC and delta-TOC checks from `0x508B4494` to `0x508B4668`;
  - `RFile::Read` and `LeaveIfError` at `0x508ACC86`/`0x508ACC8A`.
- A CRC mismatch would give −5, not −20.

**Inferred:**
- The C: file was rebuilt from the LFFS log by taking the newest record
  per 512-byte sector. It passes every check, and it differs from
  `Z:\System\Data\cdbv2.dat` from offset `0x1A27` on, so it is not a
  plain copy.
- Several of its sectors start at flash addresses that are 2 mod 4. A
  misaligned copy out of the uncached flash window, in the file server
  or the media driver, is a plausible place for V2 to differ.

**For the capture:** a trigger on the client's Leave will show only the
IPC return. Triggers on ESTOR's `User::Leave` stub (`0x508B625C` with
r0 = −20, in EDbsrv) or on the file server's read path would show the
check itself.

Scratch notes, the reconstructed files and a validator are in the
session scratchpad (`cdb/`).

## The flash copy itself (`arm9_unc_copy_rtl.S`)

### The routine (verified by disassembly)

medint.pdd copies the sector at `0x50381864`:
- dest = the request descriptor's pointer plus its offset (`[[this+0x350]]`
  and `+8`);
- src = `[this+0x128]` (the CS1 window at `0x59200000` / `0x59600000`)
  plus `[this+0x354]`;
- length `[this+0x358]` (0x200);
- through the stub `0x503830B4` to EUser `Mem::Copy` (`0x503A1D38`).

This branch is taken when the descriptor is local (`r4 != 0` at
`0x50381820`). Otherwise `0x50381884` hands a TPtrC8 of the flash to the
kernel's thread write.

Mem::Copy, for a source 2 mod 4 and a word-aligned dest (ascending,
src > dst):
1. `bic r1,r1,#3; ldr fp,[r1],#4`.
2. At `0x503A1F70`, sixteen 32-byte blocks: `lsr r3,fp,#16`,
   `ldm r1!,{r4-fp}`, an `orr ..,lsl #16` / `lsr #16` chain, then
   `stmia r0!,{r3-sl}`.
3. `msr CPSR_f`-chosen 16/8/4-byte tails, then up to two `ldrb`/`strb`.

So the flash is read as aligned words, eight at a time (an uncached
8-word LDM). There are no rotated or unaligned loads. The other paths:
- **Aligned source:** eight unrolled `ldm`/`stm` pairs per 256 bytes.
- **n ≤ 15:** `add ip,pc,#120; sub pc,ip,r2,lsl #3` jumps into an
  `ldrb`/`strb` run.
- **src < dst:** the descending copy (`0x503A2104`, `ldmdb`/`stmdb`).

**Not determined:**
- whether the window is cached (its C/B bits);
- whether the dest lies below `0x59200000` (ascending) or at a kernel
  address (descending).

The test covers both cases of each.

### Coverage

278 cases, each run cold and then warm:
- **Mem::Copy's own sequence** (a functional copy of `0x503A1D38`),
  ascending and descending: k 0-3; n 512, 1024 (crosses 1 KB) and 511
  (every tail); an uncached or a cached source; the dest's first line
  present, departing or absent;
- **dest offsets 1-3** (the head bytes), with k 0 and 2;
- **small copies:** n 1, 2, 3, 7 and 15 (the computed jump), with dest
  offset 0 and 3;
- **an LFFS header then the body:** a 2-byte copy, then the 510-byte
  rest;
- **two simpler loops:** a word-at-a-time shift-merge and a plain
  `ldm`/`stm` loop.

Each case is compared with a byte-loop reference copy, and a consumer
sums both. Rotated unaligned `ldr`/`ldrh` copies were dropped: the ROM
never issues them, and `ldrh` at an odd address is unpredictable.

### Result

- **Passes** on ZAP and V2 at 0:0, 0:3, 2:9, 8:12 and 16:40, in four V2
  builds: D8, D16, predictor off, and the netlist before fix 2
  (`5c652ee`).
- **The checks bite:** mutants of the ascending byte tail, the
  descending 16-byte tail and both small paths fail on both cores, at
  the expected first case.
- **Suites:** 312/312 in all three configurations. The 306 runs shared
  with the fix-2 baseline are cycle-identical in all three.

**Ruled out on the way:**
- **Cache maintenance during a fill:** every MCR waits at W until there
  is no lock and no fill (`arm9v2_core.sv:689`), and it is serialising
  (`:684`, `:760`).
- **The kernel's DACR writes:** those at `0x50321588`, `0x50321A84` and
  the others (ahead of `ldm {..,pc}^`) are such MCRs.

### Next suspect: the board's CS1 path

The CPU bench replaces this path with flat memory. On the board, each
uncached CS1 word goes through:
1. `wb_arb2` (CPU against DMA, `ngage_mem.sv:151`);
2. upp_bus's split into two 16-bit `nor_flash` reads (`upp_bus.sv:309`
   and `:310`);
3. `ddram_flash`:
   - a beat buffer that answers in the same clock (`ddram_flash.sv:172`
     to `:180`, gated by `!ack_q`);
   - the want/arbitration logic (`:193` to `:195`);
   - write-through updates of the buffer (`:409` and `:410`) and of
     the read cache (`:422` to `:471`).

V2 times its requests differently from ZAP:
- 8-word uncached LDMs back to back;
- D-side reads while its own I-side line fills are in flight.

The block benches (`sim/Makefile` targets `ddrflash` and `upp`) drive
this path with random traffic, not with a CPU.

**Next step:** replay V2's CS1 request stream from this test through the
`upp` bench.

## The CS1 stream through the real memory side (`make -C sim flashcopy`)

### What was replayed

The replay is closed-loop, not scripted. A V2 run in the CPU bench shows
why a script would mislead: V2 times each request from the previous ack,
and at a fixed latency of 3 it issues an uncached source word every 10
clocks, against ZAP's 8. The replay therefore runs the real CPU on the
whole core (`coreboot_main.cpp`).

The CS0 image `sim/harness/flashcopy.S`:
- maps C: as the kernel does (CS1 + 4 MB, uncached at `0x59200000` and
  `0x59600000`);
- runs Mem::Copy's sequence (`sim/cpu/tests/mem_copy.inc`) through
  `ngage_mem`, `upp_bus`, `nor_flash`, `ddram_flash` and the DDRAM
  model.

That covers:
- **uncached LDM words**, each split into two 16-bit flash reads;
- **V2's own I-fetch line reads** from CS0 (the I-cache is invalidated
  before the copy);
- **the destination's SDRAM traffic.**

126 cases, each run twice; the copy under test runs first, so the first
run meets a cold `ddram_flash` read cache:
- every source offset 0-35 in a sector, ascending and descending;
- copies straddling a sector end, 511 and 1024 bytes;
- uncached, write-through and write-back dests, and a cached source;
- small copies, and a header then the body;
- a word program of the first, middle or last halfword (the beat
  buffer's) of the line just read.

**The new bench options:**
- **`--check-flash`:** compares every CPU flash read beat with the DDRAM
  image, while the chip is in read-array mode.
- **`--ddr-*`:** sets the DDRAM port's timing.

### Result

- **V2 and ZAP:** 0 mismatches over 156,785 / 156,782 CS1 beats and
  59,355 / 52,064 CS0 beats, and 0 failed cases.
- **Four DDRAM timings:** 14:16 with 5 % busy; 6:30 with 20 % busy and
  10 % gaps; 20:24 with stalls; 3:5 with 40 % busy and 30 % gaps.
- **The checks bite:** a `ddram_flash` mutant without the beat buffer's
  write-through update fails both the bus check and the program's own
  checks.

### How V2's stream differs from ZAP's

- **V2 is slower per word:** consecutive uncached CS1 words take at
  least 11 clocks ack to ack (median 16). ZAP's take at least 9 (median
  14). V2 never sends a flash read sooner after the previous answer
  than ZAP does.
- **V2 re-walks the code section:** it reads the code section's L1
  descriptor (`0x0A100000`) 193,735 times; ZAP reads the page table
  1,124 times in all.
  - The re-walk happens on nearly every iteration of loops that have
    data-side bus traffic, so V2 takes 10.76 M clocks to ZAP's 7.19 M.
  - The descriptor read is correct, so this changes timing only.
  - The CPU bench shows 416 walks.
  - The section TLB both cores share is 8 entries, direct-mapped, and
    read with `i_clken(!i_hold)` (`zap_tlb.sv:230` to `:245`). Its
    install under V2's fetch timing is the lead; the cause was not
    chased.

### Not modelled

- the HPS DDR3 controller and f2sdram bridge (real latency, refresh,
  other masters);
- `flash_save`'s block reads interleaved with CPU reads;
- DMA on `wb_arb2`'s second port;
- erases, erase-suspend and read-while-write;
- interrupts;
- the board build's timing closure.

## V2's excess D-side TLB walks (`arm9_tlb_walks_rtl.S`, `fe65a2d`)

### On the board

Per second at 78 MHz, in game:
- **V2:** 224-334 K D-TLB beats and 0.5-0.7 K I-TLB beats.
- **ZAP:** 93-197 K D-TLB beats and 165-172 K I-TLB beats.

(Logs `run-v2fix2.log` and `run-zap78d.log`.) ZAP's I-side walks are
ZAP's own behaviour and are left unchanged.

### The mechanism

The structure:
- Each cache has its own TLB (`zap_tlb`), with a 64-entry
  direct-mapped section RAM indexed by VA[25:20].
- `zap_tlb_check` registers the miss (`o_walk`) from the check address
  (`i_address_check`).
- The walker (`zap_tlb_fsm`) fetches the descriptor of the cache's
  `i_address`, captured while IDLE (`zap_tlb_fsm.sv:168` to `:175`).
- In ZAP those three addresses belong to one request.

V2 drives them from different stages (`arm9v2_core.sv:662` to `:669`):
- **The lookup** is A's address, every clock, for any instruction. For
  an ALU instruction it is a data value.
- **The check** is M's address (W's in HOLD and RETRY1).
- **`i_address`** is W's address.

The CPU bench's walk log (`--walklog`) shows three ways V2 walks where
ZAP does not:
1. **A hold freezes the TLB RAM on the read made before it** (the TLB's
   clock enable is `!i_hold`). That read is usually A's speculative
   lookup.
   - At the hold's end, W's check compares against that entry, misses,
     and the walker re-walks W's section, which the TLB already holds.
   - Fills cause it (RETRY0 walks), and so do uncached accesses (RELOAD0
     walks).
   - On `arm9_unc_copy_rtl` at 3:3 this accounted for 15,447 plus
     1,217 of V2's 29,839 D-side walks.
2. **M's real miss was walked at W's address.** W may hold a non-memory
   instruction, so this walked addresses like `0xEF8215A8` and installed
   their descriptors, fault descriptors included. The miss stayed (1,537
   walks).
   - flashcopy's 193,735 re-walks of the section-0 descriptor are this
     case and case 1: counters and sums sitting at W in tight
     store/load loops.
3. **The check registered in the install clock used the pre-install
   entry.** The walker, back in IDLE, walked the same section again
   (HOLD walks, 473).

### The fix (V2's D-cache only)

`zap_tlb` gets the parameter `CHECK_WALK`. `zap_dcache` sets it for
SHORT_READ; ZAP and both I-sides keep 0. It does three things:
- **The TLB RAMs read through holds** (`zap_mem_inv_block` READ_THROUGH).
  The registered check stays frozen as before.
- **The walk is for the registered check address**
  (`zap_tlb_check o_walk_va`).
- **After an install, no walk starts until the check has registered
  again**, and the TLB stays busy meanwhile.

A core-side variant tried first (withholding the check in the fill-end
clock) gave cycle-identical results once these were in, so it was
dropped.

### Results

- **`arm9_tlb_walks_rtl`:** two code sections and N data sections, at
  distinct TLB indexes; 16 counted passes after a warm-up.
  - ZAP and fixed V2: 0 walks in every configuration and window.
  - V2 before the fix: 35, 70, 132, 164 and 196 D walks for N = 4, 6,
    8, 10 and 12.
- **`arm9_unc_copy_rtl` at 3:3:** V2's D walks fall from 29,839 to
  11,311, exactly ZAP's count, none of them for another section.
- **Whole-core flashcopy:** V2's D-TLB beats fall from 197,989 to 825,
  and its clocks from 10.76 M to 6.71 M (ZAP: 7.19 M and 1,122,
  unchanged). That is 20.5 clocks saved per avoided walk on the real
  memory path.
- **Suites:** 315/315 in ZAP D8/D16 and V2 D8/D16/predictor off.
  - ZAP is cycle-identical: 309/309 D8 against the saved logs (the
    other three are `arm9_unc_copy_rtl`'s older version), and 312/312
    D16 against the HEAD netlist.
  - V2: 185-186 of 309 runs move. Totals fall 6.1 % (D8), 5.6 %
    (predictor off) and 6.0 % (D16).
  - The slowest moves are random tests at most +43 clocks.
  - Instruction counts move only in the interrupt-timed tests:
    `fiq_perm`, `loaduse_irq`, `psr_irq` and `wfi_irq`.
- **QEMU:** 73/73 in all five configurations. The four lint
  configurations are clean, and `cpu-gen-check` passes (23 `input reg`).

### Expected gain on the board

If fixed V2's D walks fall to ZAP's rate, as they do in both benches,
V2 saves 100-140 K walks/s. At about 20 clocks each, that is 2.1-2.9 M
of its 78 M clocks/s, roughly 3 % more game speed. The bound, if every
V2 walk were excess, is about 7 %.

### Left

- **Wrong-path walks:** walks still start from M's check. With the
  predictor off, V2 can walk for a wrong-path load: in the test, the
  load after the stub's return falls through. The test pads that path.
- **A lead for the deaths, not checked:** before this fix, V2 walked
  W's non-memory "addresses" and cached their fault descriptors. Such
  an entry stays until the next TLB flush, so a section mapped later
  without one would abort.
- **Not done:** no fit and no board run.
