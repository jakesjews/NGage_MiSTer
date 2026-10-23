# ARM9 integer pipeline replacement

Status: session-6 two-edge cache schedule, 2026-10-23 deliverable.
ZAP remains the production default. ARM9 launches its one-edge cache RAM and
TLB together from registered next-PC (fetch) or E's effective address (data).
The next edge captures tag/way/word selection and load formatting alongside
the unchanged registered permission check. Fetch hits enter D from a registered
F2 packet, taking four clocks for an unpredicted branch; load-use remains two.
Prediction is optional and defaults on for ARM9. Block and multiply drains are
removed for normal encodings. The seven-workload cycle gate passes at all three
bus latencies. The final integrated seed-2 fit is -8.332 ns and 16,755 ALMs
against ZAP's 15,917; timing and area remain open. The session-6
sections supersede the historical native schedule.
Starting revision: `75cce2e`, branch `codex/arm9`.

## Contract and sources

Replace only the integer pipeline, retaining ARMv4T/TI925T semantics, CP15,
MMU, caches, merger, wrapper ports and retirement/debug meaning. Keep ZAP
selectable until ARM9 passes the complete suite. No changes under `sys/`.
Architectural authority is the existing patched TI925T QEMU reference, including
its treatment of architecturally unpredictable cases already in the tests.

The cycle specification is ARM DDI0180A, chapter 7, **Table 7-2** (Table 7-1
only defines symbols), and section 7.2's dependency examples. Read alongside
DDI0151C (ARM920T), DDI0100I (ARM ARM) and TI SPRU671. The untracked research
files are absent from this worktree; this session read the copies in
`/Users/jacob/dev/fpga/mister/NGage_MiSTer/research/arm925t/downloads/`.
[Manufacturer-hosted DDI0180A](https://ww1.microchip.com/downloads/en/DeviceDoc/ARM_9tdmi_TRM.pdf)
is an alternative source. Existing `docs/CPU.md` describes the port's exceptions
and CP15 configuration, but some pipeline descriptions there predate this branch.
Do not infer current cache latency from that prose.

## Pipeline and timing decision

Logical stages are F, D, E, M, W, single issue, in-order retirement. D resolves
banked register indices and decodes ARM or a Thumb translation into the same
control record. E evaluates the condition, shift, ALU, flags, branch target and
effective address. W is the sole architectural retirement point. ARM9 has the optional registered BTB described below; no RAS is implemented. A successful E redirect kills younger fetch/decode records;
an older W exception wins over it. Stores cannot escape ahead of an older fault.

Each record carries valid, instruction PC, instruction width/T state, pre-state
CPSR, condition-failed state, destination tags, write enables, fault metadata and
last-transfer. A valid condition-failed instruction retires once, changes no
state, accesses no data memory and never faults on the skipped operation.

**Cache-latency discrepancy is an integration gate.** The brief assumes two
clocks; the actual unchanged RAM macro has **three enabled read edges**:

1. `zap_ram_simple.mem_data_st1` reads RAM and records a write collision.
2. `mem_data_st2` and the collision bypass feed `o_rd_data_pre`.
3. `rd_data_st3`/`fwd_data_st3`/`fwd_st3` feed `o_rd_data`.

`zap_cache_tag_ram` uses `o_rd_data`, not `o_rd_data_pre`, for both ways and
pipelines valid/dirty/LRU by the same three edges. Tag comparison, word selection
and load formatting follow that output. Its comment explicitly requires the
lookup address three clocks after `i_address_nxt`. The byte-lane Quartus RAM
replacement has the same latency. Changing only the request/ack adapter cannot
make this a two-clock memory.

Therefore the first functional integration must preserve the native **F1/F2/F3
and M1/M2/M3** schedule. The two-clock target below is conditional on a separately
verified cache solution; it is not implemented or assumed. No cache RAM, tag hit
path or bus-side rewrite is part of the execute milestone. Request launch from
an already available address may overlap a stage, but load-dependent addresses
and redirect targets cannot be guessed. Do not hide those cycles in the model.
This native schedule exceeds the requested TRM+1 ceiling for branches and some
loads; resolving that discrepancy is required before calling the project done.

The execute timing trial decides whether all of forwarding/shift/ALU fit in E.
First try one E stage, with registered D operands and short late forwarding.
If it fails 104 MHz, move ordinary shifts to D with an E unshifted-operand bypass;
shifted dependencies then need a measured bypass or an explicitly counted stall.
Register-controlled shifts already have a TRM extra cycle; use that cycle to
capture the shifted operand, never to conceal an extra stage on all instructions.
Do not add stages between issue and memory just to pass timing.

## Execute milestone: measured trials

The implemented leaves are `arm9_forward`, `arm9_shift`, `arm9_alu` and
`arm9_execute`. The execute leaf is combinational between D capture and the
registered M result. It has three ordered producer slots for the intended
M1/M2/W path; a native three-cycle-cache integration must extend the producer
coverage (including separate base/load writers), not silently omit a stage.
`PRE_SHIFTED=1` accepts the D barrel result and its carry; raw Rn/store operands
still use E forwarding. The test harness also instantiates the existing
four-read/three-write register file and a real E-to-D result/flags path when
shifting in D. That trial had no controller. The session-2 bring-up controller now instantiates
the same execute leaf, as described below.

Quartus 17.0.2, 5CSEBA6U23I7, seed 1, 104 MHz (9.615 ns), same CPU-trial
optimization/retiming settings, all four operating corners:

| Initial implementation | Worst setup | Minimum hold | ALMs | Registers |
| --- | ---: | ---: | ---: | ---: |
| Shared barrel, shift in E | -1.838 ns | 0.142 ns | 2427 | 2061 |
| Shared barrel, shift in D with E-to-D bypass | -0.535 ns | 0.158 ns | 2443 | 2199 |

Both fail the timing gate. The single-stage worst path is a retimed execute
node (`u_execute|comb~0_OTERM263`) through the barrel, arithmetic, result mux
and zero-flag reduction to `status_out[6]~reg0`: ten logic levels and 11.157 ns
data delay at Slow 1100mV 100C. The D-shift trial's worst path is `control[6]`
(the Rm physical-register tag) through register selection/forwarding and the
barrel to `decoded_shift[16]~30_OTERM554`: nine levels, 9.834 ns data delay at
the same corner. Retimed node names are fitter artifacts, not extra CPU cycles.

**Selected implementation: one execute stage.** Keep parallel left/right/rotate
networks in `arm9_shift`, compute arithmetic N/Z directly from the adder sum in
`arm9_alu`, and keep the original simple priority forwarding mux. Both changes
are combinational; no pipeline stage was added. The explicit one-hot forwarding
experiment increased area and did not improve the worst-corner result, so it
was discarded.

| Final single-E trial | Slow 100C setup | Slow -40C setup | Minimum hold | ALMs | Registers |
| --- | ---: | ---: | ---: | ---: | ---: |
| Parallel barrel/direct NZ, seed 1 | -0.045 ns | +0.130 ns | +0.118 ns | 2549 | 2190 |
| Same datapath, final harness, seed 2 | +0.113 ns | +0.018 ns | +0.159 ns | 2556 | 2185 |

The final source regenerates **byte-for-byte** to the seed-2 fitted trial input.
Its worst path is the retimed execute node
`u_execute|comb~12_OTERM717DUPLICATE` to `status_out[6]~reg0` (Z flag), seven
logic levels and 9.316 ns data delay at Slow 1100mV -40C. All four setup/hold
corners pass. This is feasibility evidence, **not robust timing margin**: only
18 ps remains at the worst corner, and seed 1 missed. Integrated control,
fanout and placement can lose that margin. Repeat timing after every substantial
integration step, and require the integrated CPU-only trial at milestone 5.

Reproduce the accepted trial with:

```
SEED=2 TRIAL=arm9_execute BUILD_DIR=dev/mister/ngage-codex-arm9-execute-parallel-s2 sim/cpu/quartus/run.sh
```

Full corner summaries, rejected alternatives and path evidence are in the
continuation report. Area includes register-file and stimulus/observation
logic; it is not additional ALMs over ZAP or a whole-core fit. The D-shift
alternative remains selectable for experiments via `PRE_SHIFTED`; its caller
can enable E forwarding for unshifted Rm while shifted Rm/Rs are consumed in D.
The retained design uses the single-stage E path. Register-specified shifts must
still consume the TRM's extra cycle in the future controller even though the
leaf can calculate them in E. A separate registered shift-preparation sequence
was considered but is not implemented or measured as a CPU cycle model.

## Target cycle model (acceptance specification)

Counts are steady-state issue cost with hot memories, no external wait, no
exceptions and a filled pipe. Interlocks are additional bubbles attributed to
the producer; do not count them again in the consumer. PC costs include refill.
Let `f` be extra fetch latency over the TRM (target 1, native 2), and `d` extra
load latency (target 1, native 2). The native predictions still require an adapter
trace to establish exact request/response edge conventions and throughput.

| Case | TRM clocks | Intended FPGA cost / implementation rule |
| --- | ---: | --- |
| Condition failed | 1 | 1; no side effects, including no shift/multiply wait |
| Data processing, immediate shift, no PC | 1 | 1 if execute closes timing |
| Data processing, register shift | 2 | 2; sample Rs[7:0], including zero |
| Data processing to PC | 3 | 3+f; add 1 for register shift |
| LDR word, independent successor | 1 | 1 throughput, latency tracked separately |
| LDR aligned word, immediate ALU consumer | 2 | 2+d total; 1+d interlock bubbles |
| LDR byte/halfword/unaligned word, immediate consumer | 3 | 3+d; TRM requires a second interlock |
| LDR to PC | 5 | 5+f+d provisional upper bound; overlap must be demonstrated |
| STR | 1 | 1 hit throughput; waits and ordering charged separately |
| LDM/STM one register, no PC | 2 | 2, plus exposed memory latency |
| LDM/STM n>1, no PC | n | n with one accepted transfer per clock |
| LDM including PC | n+4 | n+4+f+d provisional bound |
| SWP | 2 | 2 transfers plus exposed memory latency; serialized read then write |
| SWPB, immediate loaded-value consumer | 3 | 3+d, plus any serialization wait |
| B / BL / BX taken | 3 | 3+f (target 4, native 5); BL also writes LR |
| SWI / undefined entry | 3 | 3+f plus older-operation drain if necessary |
| MRS | 1 | 1 |
| MSR flags only | 1 | 1 with flag forwarding |
| MSR other masks | 3 | at least 3; serialize state/banking change |
| MUL / MLA | 2+m | 2+m, same for both |
| SMULL / UMULL / SMLAL / UMLAL | 3+m | 3+m, both destination halves commit in order |
| MCR / MRC | b+1 | retained CP15 drain/handshake may add cycles; count explicitly |
| MRC followed by consumer | b+2 | dependency on returned register, no stale operand |
| MRC R15 | b+3 | updates NZCV, not a branch |
| CDP / LDC / STC | b+1 / b+n | undefined in this TI925T port; exception row applies |

`m=1..4` tests successive upper 24/16/8 bits of Rs. MUL/MLA and signed long
multiply terminate on all zeros **or all ones**; unsigned long multiply only on
zeros. Never use the multiplicand to compute m. Thumb MUL uses its encoded
multiplier register. IRQ/FIQ and abort entry are not assigned a made-up Table
7-2 cost: measure from the accepted exception boundary to first handler issue,
separating drain, vector fetch and external waits. Record both architectural
instruction counts and cycles. Total whole-test cycles also include reset,
cache initialization/fills, uncached accesses, CP15 waits and test harness exit.
They cannot be equated with the sum of the hot-loop table alone.

## Operands, forwarding and interlocks

Keep `zap_register_file` (40 physical registers, four combinational read ports,
two ordinary writes and the existing third one-hot write port). Preserve its
same-register write priority. Translate R8-R14 according to the instruction's
mode, not a younger CPSR. User-bank LDM/STM uses explicit user tags. PC operands
are values computed from the instruction PC, not dependencies on a physical PC
register: ARM +8, Thumb +4, ARM register-shift special +12 where required;
Thumb literal base aligns to a word. Store-PC behavior follows QEMU/tests.

D latches the read operands. E has youngest-first forwarding from registered
E/M results through M to W, with separate tag and ready bits. A matching newer
producer that is not ready blocks the operand: it must never fall through to an
older ready value. Forward base writeback and loaded data as separate producers;
for a load writing its own base preserve existing/QEMU priority. Ignore unused
operand fields so an immediate or a condition-failed instruction cannot falsely
interlock. Store data needs a late bypass as well as address operands.

Flags have the same age rule. RRX, ADC/SBC/RSC and condition evaluation consume
the most recent NZCV, including when a logical instruction preserves V or shift
by zero preserves C. Flag-writing PC instructions restore SPSR in W; their
ordinary ALU NZCV must not override the restored CPSR. Logical tests write flags
but no destination. Subtraction carry means no borrow. Mode/T/I/F changes are
serialized until younger records can be reconstructed with the correct state.

The execute leaf computes values and readiness, not architectural side effects.
It accepts physical tags and already selected current flags. Its caller must
turn a blocked result into a stall and must qualify branch/store/register writes
with condition, valid, older faults and downstream readiness. A held E stage
must not repeatedly redirect, retire or start a memory operation.

## Memory and CP15 integration

Reuse `zap_top`'s cache and bus wiring; a later small generate at the integer-core
instance selects ARM9 vs ZAP, propagated from `arm925t.CORE`. Default stays ZAP
until milestone 4. Do not fork or duplicate the memory system. Preserve all
`*_address_nxt`, `*_address_check`, lookup-address phases and their matching
mode/write/read metadata. Add an adapter under `rtl/cpu/arm9/` where necessary.

For initial correctness, ARM9 loads are blocking at retirement. Retain the
D-cache's bus and critical-word-first FSM unchanged: capture an early-ack miss
as pending, suppress architectural retirement, consume its `o_reg_idx/data`
completion into the pending load, then clear the pending state. A locked
register is not a completed load. An access during the remaining fill waits as
it does today. Do not write the same register again on final line installation.
`err2` restarts the memory transaction after translation, not a retired
instruction; err/align fault kills the load and base writeback. Fault, ack,
lock and completion in the same cycle need directed tests before integration.

Maintain original VA for FAR and alignment, FCSE-adjusted lookup address,
transfer size, signedness, low address bits, force-user attribute and **the
access's own mode** through all memory phases. Alignment faults occur before any
bus transfer. Retain the cacheable-fill error behavior encoded by current tests;
do not invent a later abort after a critical word has already completed.

CP15 is `zap_cp15_cb` with TI925T, V4T, ID `54029252`, CTYPE `05109149` and the
existing geometry. Start it only after older instructions and pending loads
finish; stop younger issue, supply its register operand, honor maintenance
request/done, and refetch after completion. Keep WFI wake/IRQ/FIQ semantics,
HIVECS, c1 masking, FCSE, TLB invalidation and single-line way/index operations.
Removing conservative CP15 drains is a later optimization, not this milestone.

## Multi-transfer and precise exceptions

LDM/STM sequencer tracks original base, next address, ascending register list,
final base, transfer count and original PC/CPSR. One transfer per accepted cycle;
backpressure does not advance the list. A one-register list still costs two
TRM cycles. Empty lists and base-in-list special cases follow existing tests and
QEMU; add coverage before coding a guessed behavior. Base writeback is deferred
until success, or explicitly restored on abort. Earlier transferred registers
and stores keep the ARM9 base-restored abort model's effects; a partially executed
LDM is not rolled back wholesale. PC and SPSR restoration happen only after the
last successful transfer. One architectural retirement event, last-transfer
marked, with data accesses logged in order.

SWP is serialized across the read and write and holds the original operand;
it must not accidentally use the newly loaded Rd as store data. Preserve the
existing system's bus atomicity contract; do not claim a stronger lock than the
merger exposes. An abort must not leak the suppressed phase. Thumb BL halves
remain separate instructions with an interrupt boundary and a working lone
second half. ARMv5 encodings remain undefined only when their condition passes.

At W, the oldest valid exception record wins; no younger store or CP15 operation
may already have acted. Preserve SPSRs, banked LR and CPSR masks using the
existing writeback semantics as the reference. Data abort wins over younger
redirects; prefetch abort travels with the fetched address and traps only if
that record reaches the architectural boundary. Kill stale outstanding fetches
using a generation/epoch tag across redirects and mode changes. Fetch completion
can warm a cache but must not put a stale instruction into D. IRQ/FIQ sampling
and priority must match existing `exc`, `irq`, `tbl_irq`, `loaduse_irq`,
`fiq_movs` and `fiq_perm`; interworking belongs to BX, not ARMv5 load-to-PC rules.

## Observability and verification

Keep wrapper debug ports and meanings. The bench eventually selects a probe
adapter by CORE: valid/cfail/last, PC+8 or +4, pre/post CPSR, exceptions,
40-register physical image, data VA/access PC/alignment, CP15 state and WFI.
Never fabricate retirement in the bench to make signatures pass. Preserve the
stall bit positions: [0] data wait, [1] fetch blocked, [2] fetch empty,
[3] dependency interlock, [4] multiply/execute busy, [5] sequencer/CP15 wait,
[6] execute redirect, [7] retirement exception/retry redirect. They overlap.
ZAP-only prediction probes may be zero in ARM9; architectural/data probes may not.

Acceptance sequence for each integrated change:

1. Regenerate with `tools/gen_cpu.sh`; run the nine requested tests at 0:0,
   0:3, 2:9 and compare cycles **and** instruction counts to the saved baseline.
2. `make -C sim/cpu diff`, full `run`, then full `diff`, using existing binaries
   and QEMU references. Count actual tests, not the historical 177/49 totals.
3. Run source and generated execute-leaf tests (boundary shifts, arithmetic
   carry/overflow, all conditions, forwarding and unavailable youngest values).
4. At core integration, add `arm9_cycles.S` plus bench cycle-window support:
   hot instruction/data lines, timestamp at retire PCs, subtract a matched control
   loop; each table row has a named sequence and predicted bubble count. Test
   dependencies at distances 0..3 and each register role, both modes and cache
   ways. New architectural tests alone get new binaries/QEMU references.
5. `make lint`, `make cpu-gen-check`, CPU-only Quartus at 104 MHz. Report all
   setup/hold corners, worst path and area; this is not whole-core timing proof.

Firmware boot, whole-system fitting and hardware measurements are deliberately
left to the other engineer at milestones. No boot bench is run by this session.

## Main risks and release gates

The native cache latency conflicts with the performance ceiling; cache store
throughput, replay and metadata alignment need measurement before promising a
cycle count. Decode-stage shifting risks adding dependencies and a long
E-to-D feedback path. Single-stage shifting risks the forward/shift/add/flag
path at 104 MHz. Early branch redirect must not bypass an older abort. Partial
LDM effects, same-register writes, cache background completion, flag forwarding,
and exception ordering are the largest functional risks. A standalone fitted
leaf understates placement congestion and global stall/reset fanout.

Milestone status and exact results are in
`docs/consults/2026-10-23-codex-arm9-report.md`; machine-readable baseline in
`docs/consults/arm9/session1-baseline.json`. No ARM9 speedup is claimed until an
ARM9 architectural run exists.

## Session 2: historical bring-up schedule

This section describes the prior checkpoint. The session-3 section below
supersedes its serial fetch/DP schedule.

`arm925t.CORE` selects `ZAP` (default) or `ARM9` at the integer-core instance
inside `zap_top`. Cache, MMU and merger wiring is shared. Use `make -C sim/cpu
CORE=ARM9 run T="alu align modes exc"` and the corresponding `CORE=ARM9 diff`;
the Makefile isolates ARM9 models and results from ZAP's reference results.

The first controller is deliberately non-overlapped: F1/F2/F3/F, D, E, M1/M2/M3/M,
ack classification/background wait as necessary, W. Non-memory instructions
skip M. Register-controlled shifts insert their preparation clock. This is an
architectural bring-up scaffold and does **not** satisfy the target cycle table
above. The fitted execute leaf remains unchanged; producer inputs are inactive
while only one architectural instruction is admitted. No speedup is claimed.

`zap_writeback` supplies the unchanged register file, CPSR and exception state
updates. Its old fetch/prediction outputs are disconnected. The new controller
owns the PC and gates the retirement/debug events. CP15 is serialized. The
cache miss lock is sampled after the ack edge; completion data is captured
before retirement rather than written asynchronously into architectural state.
The I-cache's provisional words wait for whole-fill fault resolution.

The continuation report records coverage, incomplete cases, exact counts and
where to replace conservative sequencing with an overlapping pipeline.

The session-2 controller also implements registered multiply/accumulate (all
ARMv4 short/long forms), using a product register followed by an accumulator
register outside the execute leaf. It counts multiplier-dependent termination
cycles from Rs, while the instruction admission remains serialized. LDM reads
aligned words without LDR's rotation, suppresses final base writeback when an
LDM loads its base, and restores the original base before entering a data abort.
This restoration is an internal non-final micro-op and preserves the old CPSR,
including when an LDM exception return faults on its PC transfer.

Four register-file reads are retained: a flag-restoring DP write to PC uses the
otherwise-unused fourth port for SPSR, so a register-specified shift can still
read Rs. `arm9_state.S` verifies this case and the aborted LDM exception return
against both cores and QEMU. Multiply, undefined ARMv5/NV encodings, SWP and the
Thumb instruction formats are exercised by the existing suite. Empty register
lists and unpredictable operand combinations outside the suite are not claimed.

The bench keeps the cache's original beat-to-completion and lock-edge assertions.
For ARM9 it additionally verifies completion capture, preservation until W and
the actual register-file write at W. ZAP retains its same-edge write assertion.
A cache completion is never substituted for architectural retirement in a trace.

See the continuation report for measured whole-test costs. An independent DP
instruction still requires the entire fetch/decode/execute/retire loop; this
implementation is a correctness baseline, not the proposed high-throughput
pipeline. The next architectural change must introduce independent stage-valid
records, fetch invalidation and a producer scoreboard without losing this test
coverage. No extra read-latency improvement is claimed from the cache adapter.

### Session-2 integrated timing gate

The serialized ARM9 core, with the real caches/MMU/CP15 and registered bus
harness, was fitted at 104 MHz, seed 2. It **fails setup**: -2.678 ns at Slow
100C and -2.704 ns at Slow -40C; minimum hold +0.108 ns. Area is 15,011 ALMs,
15,223 registers, 69 RAM blocks and 3 DSP blocks. The worst path is from a
retimed Thumb instruction bit through the unregistered register-list count and
block-transfer address arithmetic to `m_address[22]` (11.650 ns data delay).
Capture sequencer count/control at D before optimizing that address path; do
not treat the execute leaf's earlier +0.018 ns as an integrated timing result.
Details, path reports and the exact input hashes are in the continuation report.


## Session-3 implementation and measured cycle model

D is the held fetch-queue head; its decoded operands/control are captured in E.
`fast_m` and `fast_w` are independent, valid-tagged result records containing
PC+8/+4, flags, condition result, destination and value. Ordinary non-PC DP,
including executed and skipped register shifts, and B/BL use this path.
They can occupy D/E/M/W simultaneously. The unchanged execute leaf receives
registered M then W producers in youngest-first order; D also bypasses these
producers across the register-file write edge. Immediate/PC operands are
constructed after the D bypass. PC destinations and banked-state operations
remain serialized, so no physical-PC or SPSR producer can masquerade as an
ordinary register. Flags select the latest M, then W, then committed CPSR.
An immediate rotation of zero preserves that latest carry. Register shifts
hold E one additional clock only if the condition passes with those flags.

A slow instruction enters only after M/W drain. No younger operation issues
while its data access, sequencer, multiply, CP15 or exception is outstanding.
That is the current interlock: it is functionally conservative and substantially
more expensive than the target producer scoreboard. Loads still have separate
base/data destinations and preserve the original completion-capture monitor.
No forwarding from an unready load is claimed. The stage registers and early
branch redirects are real; full memory-stage overlap remains unfinished.

The first integrated fit after overlap exposed a -3.753 ns path through live
Thumb translation and D operand selection. Thumb translation, its undefined
flag and PC-alignment hint are now captured in the existing fetch queue, before
D reads operands. This adds no stage and leaves every measured cycle unchanged.
The queue also retains the raw encoding for the independent Thumb BL halves.
A continued LDM decodes its held instruction and ignores the younger queue
head's undefined/alignment bits. `arm9_queue.S` tests this exact boundary;
removing that gate in a scratch netlist fails the test at all three latencies.


The fetch unit pipelines three RAM edges with matching PC/Thumb/epoch records,
then queues eight entries. Each entry waits for any provisional fill to finish.
Late faults update held entries even when the queue is full. A taken B/BL in E
invalidates the younger queue immediately. A serialized W redirect (PC writes,
exceptions, CP15 or MSR) uses the same mechanism. An untagged outstanding cache
response drains under a killed epoch before the target restarts; retries keep
older queued instructions and restart the unanswered lookup. Invalid metadata
must advance whenever cache RAMs advance, including on the redirect edge.
`cache` caught a same-tag/different-set mislabel before this rule was fixed.

The previous Thumb-decode-to-block-address path is cut at D: register-list
count, current transfer register/list and an eight-bit signed start offset
are captured with the instruction. E computes the block start with one 32-bit
addition, not `base +/- count*4` followed by another 32-bit +/-4. The final base
is computed separately. There is no added stage and no execute-leaf change.

### Session-3 integrated timing result

The final `CORE="ARM9"` trial at 104 MHz, seed 2, Quartus 17.0.2 fails setup.
The generated input matches commit `06ed82f`; this is a CPU-only integrated
trial on 5CSEBA6U23I7, not the complete MiSTer design.

| Corner | Setup slack ns | Hold slack ns |
| --- | ---: | ---: |
| Slow 1100mV 100C | -2.581 | +0.317 |
| Slow 1100mV -40C | -2.623 | +0.307 |
| Fast 1100mV 100C | +2.715 | +0.164 |
| Fast 1100mV -40C | +3.805 | +0.126 |

There are two failing path families. The worst is cache way selection through
Thumb translation and the queue input mux to a retimed decode capture
(`list_d[1]`): -2.623 ns, 11.547 ns data delay, ten logic levels. The other is
the forwarded E operand through the barrel shift, ALU and Z reduction to
`fast_m[62]`: -2.551 ns, 11.498 ns data delay, nine logic levels. Registering
the translation before operand read improved the first session-3 fit's
-3.753 ns result, but did not close either family. The execute leaf's unchanged
source and earlier standalone +0.018 ns do **not** prove integrated E timing.

Area is 14,503 ALMs, 15,828 registers, 305,568 memory bits, 69 RAM blocks and
3 DSP blocks for the whole CPU/trial harness. The full-system area constraint
has not been checked. Detailed paths, exact input hash and reproduction
command are saved in
[`consults/arm9/session3-final-fit-seed2/`](consults/arm9/session3-final-fit-seed2/).
Closure requires shortening the cache-selection/translation boundary and
the execute producer/capture path without adding instruction cycles. Both
are open; no single-remaining-family or 104 MHz claim is made.

### Reproducible retirement windows

`sim/cpu/tests/arm9_cycles.S` includes 69 named windows. Its embedded table
contains begin/end PCs, exact expected elapsed clocks, name and invocation
count. `--arm9-cycles` in the real CPU bench measures retirement-edge differences;
it neither substitutes retirement nor uses intrusive timer loads. The first
three invocations warm instruction/data/vector paths; the final two must both
match at **CORE=ARM9, latency 0:0**. Every core/latency must visit every window
five times. The ARM9 timing checks are intentionally not applied to ZAP.

These are exact regression counts for the **current partial implementation**,
not relabelled TRM promises. `session3-cycle-windows.json` lists every window.
A window begins with one marker NOP and ends at the retirement of another.
For ordinary sequences the elapsed delta is the enclosed instruction cost
plus one marker clock. Complex operations additionally expose pipeline drain
and restart; the table below leaves those costs visible. In the exception
rows the end marker is the handler's first instruction, so the measurement
also includes the vector's `LDR PC` trampoline.

| Window / enclosed operations | Expected delta at 0:0 | Interpretation / remaining deviation |
| --- | ---: | --- |
| Eight independent DP | 9 | 1 per instruction, target met |
| Four dependent DP / four flag-dependent DP | 5 / 5 | M/W data and newest-flag bypass, target met |
| One register shift / skipped register shift | 3 / 2 | 2 / 1 instruction clocks, target met |
| DP to PC / register-shift DP to PC | 11 / 12 | serialized PC writes; target 3+f / 4+f not met |
| LDR then independent ALU / dependent ALU | 13 / 13 | all successors wait; target throughput/interlock not met |
| LDR then dependent base / store | 20 / 20 | two serialized memory operations |
| LDR then Rs / shifted Rm | 14 / 13 | Rs adds one shift clock; no early load bypass |
| Byte, halfword, signed byte/halfword, unaligned LDR + ALU | 13 each | retained cache formats value; same blocking wait |
| LDR PC | 17 | serialized load, writeback redirect and refill |
| STR / one-register LDM / one-register STM | 12 each | blocking memory transaction |
| Three-register LDM / STM | 28 each | eight exposed clocks per extra transfer |
| Three-register LDM including PC | 33 | blocking transfers plus redirect |
| SWP / SWPB + ALU | 17 / 18 | read/write phases serialized |
| B / BL | 7 / 7 | six instruction clocks including native fetch refill; target native five not met |
| BX | 11 | state-changing PC path remains serialized |
| MRS / flag-only MSR / control MSR | 7 / 11 / 11 | PSR operations still drain; flag-only target not met |
| MCR / MRC / MRC + consumer / MRC PC | 18 / 16 / 17 / 16 | conservative CP15 drain/refetch, not TRM b+1 |
| SWI / UND / unsupported CDP/LDC/STC | 24 each | exception plus actual vector trampoline to handler |
| MUL/MLA, m=1..4 | 9/10/11/12 | 2+m arithmetic schedule plus six exposed drain/marker clocks |
| All four long multiply forms, m=1..4 | 10/11/12/13 | 3+m schedule plus six exposed drain/marker clocks |
| LDR, 1/2/3 independent NOPs, ALU consumer | 14/15/16 | no hidden load-latency overlap yet |

The unaligned-load timing case uses the same byte pattern in two adjacent
words so it agrees with the patched QEMU's unaligned-read convention; existing
`align`/load tests still check the port's rotation behavior. The shared MRC-PC
window starts with NZCV already equal to the CPU ID's top nibble: ZAP does not
update those flags, while ARM9 does. The initial changing-flags experiment
agreed with QEMU on ARM9 and exposed that pre-existing ZAP omission. Fixing ZAP
is outside this worktree task; the committed shared case times the instruction
without pretending to cover that flag transition. No comparison was disabled.

The windows cover every Table 7-2 instruction row, representative n=1/3 block
sizes and all positive m=1..4 multiplier lengths. They do not exhaust every
register alias, negative early-termination boundary, dependency distance or
Thumb timing permutation. Architectural ARM/Thumb, fault, IRQ and FIQ coverage
continues to come from the full shared suite; IRQ/abort timing is not assigned
a fictitious TRM table value here. Firmware boot and hardware speed remain
external milestones.

## Session 4: held memory context and ordered younger arithmetic

E validity and its register-shift cycle are independent of the slow controller.
At a slow E handoff, `slow` captures PC, PC+8/+4, raw/decoded instruction, CPSR,
kind and physical base/destination tags. Request mode, fault PC, CP15 word,
block continuation and W use that context. Access data/format and W controls
already had their own registers. The bench's data-PC tap now reads held memory
PC, independently of the younger E PC.

Only non-PC DP may enter behind a scalar memory operation. Two result entries
hold younger work; they cannot retire until the slow operation retires. A third
instruction may wait in E. No younger memory transaction, branch, exception or
state operation is admitted. A slow redirect clears E and both younger result
entries. The retained memory engine preserves cache replay/hold, the critical
word completion capture, SWP and the base-restored block-abort implementation.

Four physical producer slots are ordered M, W, memory-load, memory-base. The
last two are unready until precise memory retirement; load wins a same-register
base alias. A younger ready result shadows an older unready load. Held E operands
capture bypasses every clock so a producer cannot disappear while E waits on a
different source or queue space. Only architecturally used sources can interlock;
failed conditions skip both dependency and register-shift delays. Forwarded
flags follow younger M/W, then committed CPSR.

The existing `arm9_cycles` instruction binary and reference stay unchanged.
`sim/cpu/arm9/cycles.txt` supplies versioned timing expectations; the bench rejects
missing, duplicate, unknown or zero entries. All 69 windows still execute five
times and check both hot 0:0 visits. The original embedded values document the
session-3 machine; the external model documents this checkpoint. The new
`arm9_memory` test covers uncached and cached execution, load/base dependencies,
WAW shadowing, queue backpressure, failed conditions, and abort cancellation of
younger flags/register/store work. It compares both signature and full trace.

The remaining gap is material: hit memory instructions still wait to enter the
single memory engine, and a load consumer waits for its native RAM lookup and
classification. Do not describe the new younger arithmetic execution as a
one/two-cycle load-use interlock or one-store-per-cycle throughput.

### Session 4 scalar admission/completion refinement

Scalar memory now follows a fast E instruction without draining M/W. At that
handoff only one older M result can remain; `older_pending` permits that W to
retire during the lookup, then prevents younger W from passing the memory op.
A skipped memory op waits for the older W rather than sharing its retirement
edge. Scalar base/offset/store sources and conditions use current forwarding.
D may admit the next scalar memory op on the previous retirement edge if no
younger result is queued.

A captured hit retires on the no-lock classification edge. A miss still captures
its critical word before a subsequent W. A store skips load classification.
This shortens scalar windows and saves one clock per block transfer or SWP write
half, but the request engine still serializes. Consecutive hit requests remain
six clocks apart, and each extra LDM/STM register still costs seven clocks.
Immediate load consumers have a successor-admission bubble plus three E wait
clocks with the native RAM, not the target one/two-clock interlock. See the
session-4 report's clock schedule and complete measured comparison.

## Session 5: ordered scalar requests

Scalar memory and arithmetic now share three native RAM-edge records and W.
E launches the address, the second record provides the MMU check, and the third
issues the cache access. Every stage retains its own metadata and advances with
the RAM. Registered W load data forwards into E; a miss lock blocks provisional
data. Each stage exposes separate physical load/base producers. Faulting W
suppresses younger requests before clearing their records.

The cache exports its existing fill-state indication. During fills the core
holds metadata but leaves RAM writes enabled; after fills/TLB retries it reloads
the three saved lookup addresses before issuing. ZAP retains its constant-zero
external RAM stall and unchanged cache behavior. See the session-5 report for
verified checkpoints and exact remaining interlock/drain costs.

Block transfers now retain one immutable base/mode/SPSR context while a list
selector and address counter feed one register per enabled clock into the
ordered pipeline. Only the final packet writes back the base/restores flags.
Earlier completed transfers survive an abort; a writeback-enabled aborted block
restores its original physical base before exception entry. Access mode is
separate from result flags so a final exception-return transfer uses its own
original permissions. Loads to PC redirect at W and suppress younger requests.
The seven new stream timing windows verify eight adjacent hit requests in nine
marker-inclusive clocks. The existing LDM1/LDM3 windows verify one extra clock
per additional register, with fixed block setup/drain overhead still exposed.


### Session-5 integrated timing gate

The final streaming-memory core (`56cb701`) fails 104 MHz setup in the CPU-only
seed-2 Quartus 17.0.2 trial: -3.970 ns at Slow 100C and -3.899 ns at Slow -40C.
Minimum hold is +0.122 ns. Area is 16,353 ALMs, 18,528 registers, 69 RAM blocks
and 3 DSPs; the increase from session 3 is 1,850 ALMs and 2,700 registers.
The worst family is I-cache tag response through fetch queue/control into
retimed decode. Execute and operand capture also fail; the explicit NZCV
query puts Z worst at -2.185 ns. The session-5 report
links the detailed paths and records the remaining cycle and area gates.
ZAP remains the default; no full-system or hardware result is implied.

## Session 6: one-edge cache RAM checkpoint

`SHORT_READ`, selected only by `CORE="ARM9"`, removes the two collision-delay
edges from the tag and data RAMs. The remaining synchronous read captures a
same-edge write and its address match; each byte lane selects that registered
write or the read-first RAM output. The next edge captures the existing tag
compare, way/word select and load formatting at the caller. This retains one
read per clock, including adjacent stores with different byte enables.

Valid, dirty and LRU outputs use the same read set/edge. Current writes have
priority over write-behind state; the hit LRU update has priority over a fill
update. The compare/select equations are unchanged. The shared three-edge
RAM implementation, including the Quartus per-byte RAM wrapper, remains the
ZAP default. Clean/invalidate walks retain their conservative waits.

This checkpoint deliberately launches the cache at `i_address_check`, one
clock before the request, while preserving the original early address for the
TLB. The TLB independently uses the same three-edge RAM primitive: its two-edge
`o_rdata_pre` feeds a registered permission check. Moving its address without
retiming that chain breaks translation. The cache can now complete in two
edges, but the CPU still retains its prior schedule pending the TLB/schedule
change. This distinction matters: the RAM change alone does not establish a
two-clock load interlock or four-clock branch.

`arm9_cache_edge.S` checks adjacent word/byte/halfword stores and loads, all
word offsets, two ways, fill/refetch, and dirty eviction against QEMU.
`arm9_cache_lru_rtl.S` checks backing memory through uncached aliases after
adjacent hit/fill LRU and dirty updates; QEMU has no cache model for that test.


## Session 6: two-edge cache schedule

The TLB's `zap_mem_inv_block.SHORT_READ` presents its first-edge read at
`o_rdata_pre`; `zap_tlb_check` still registers the original permission and
translation equations on the next edge. Page walks, CP15 semantics, own-mode
checks and fault priorities are unchanged. The first reload edge has no aligned
check packet, so its read/write-check enables remain zero.

| Edge relative to E handoff | Record / operation |
| --- | --- |
| 1 | `fast_1` / M1: parallel cache and TLB RAM reads from E; retain access metadata |
| 2 | `fast_m` / M2: register permissions and cache hit, way, word and formatted value |
| 3 | `fast_w` / W: capture the ordered response or miss lock; forward the registered load |
| 4 | Retire W |

An immediate consumer still waits two clocks. There is no combinational
cache-data-to-E path. The M2 response stays with the registered TLB permission
result; the existing FSM handles misses, uncached requests and faults before
W may retire. Six load/base producer slots preserve youngest-writer priority.
Fills and retries reconstruct both held lookup records.

The D-cache store uses the registered hit way, qualified by the registered hit,
so a younger probe cannot select its destination and a miss cannot write RAM.
The RAM collision register covers the E lookup sampled on the write edge.
A byte-enable merge also forwards that store into the older M1 lookup already
outside RAM. It updates the victim line and dirty state as well as the formatted
load, preserving a following dirty eviction. LRU follows the early probe and
its existing current/pending forwarding. The shared compare equations are
unchanged; the merge adds a timing risk before the M2 data register.

Fetch launches from registered next-PC. F1 reads cache and TLB in parallel;
F2 captures the word, Thumb translation and permission result. An empty queue
can present this **registered** hit packet directly to D. Queued instructions
retain priority, and misses/uncached responses use ordinary response capture.
No raw cache output bypasses the F2 instruction register. Redirects still kill
epochs, and fill-pending instructions cannot issue. This removes the redundant
hit enqueue edge: unpredicted B/BL costs four clocks including the branch.

### Exact hot windows against the TRM (prediction off)

All numbers below include the end marker (except the explicitly named interlock
row). The TRM column uses DDI0180A Table 7-2; `m` and `b` retain its definitions.
The instruction binaries and QEMU references are unchanged; `arm9/cycles.txt`
retargets all 69 original windows and the seven stream windows stay at 9.

| Window | TRM plus marker / enclosed consumer | Session 6 |
| --- | --- | ---: |
| Eight independent DP | 9 | 9 |
| Four dependent / flag-dependent DP | 5 | 5 |
| Register shift / skipped register shift | 3 / 2 | 3 / 2 |
| DP to PC / register-shift DP to PC | 4 / 5 | 8 / 8 |
| LDR + independent ALU | 3 | 3 |
| Aligned LDR + immediate ALU consumer | 4 | 5 |
| Immediate aligned load-use interlock (no marker) | 1 | 2 |
| Byte/halfword/signed/unaligned LDR + ALU | 5 | 5 |
| LDR + base / store / shifted-value consumer | dependency-specific | 5 / 5 / 5 |
| LDR + register shift-count consumer | load dependency plus shift cycle | 6 |
| LDR + 1 / 2 / 3 independent DP + consumer | 4 / 5 / 6 | 5 / 5 / 6 |
| LDR PC | 6 | 8 |
| STR | 2 | 2 |
| LDM1 / STM1 | 3 | 3 / 3 |
| LDM3 / STM3 | 4 | 5 / 5 |
| LDM3 including PC | 8 | 10 |
| SWP / SWPB + ALU | 3 / 5 | 11 / 12 |
| B / BL / BX | 4 | 5 / 5 / 8 |
| MRS / flags-only MSR / control MSR | 2 / 2 / 4 | 6 / 8 / 8 |
| MCR / MRC / MRC + consumer / MRC PC | b+2 / b+2 / b+4 / b+4 | 15 / 12 / 13 / 12 |
| SWI / UND / unsupported CDP/LDC/STC | 3 to vector, plus actual vector trampoline | 15 |
| MUL/MLA, m=1..4 | 4..7 | 4..7 |
| Long multiply, m=1..4 | 5..8 | 5..8 |
| Eight hit accesses in each of seven stream windows | 9 | 9 |

Normal blocks and multiplies now use the execution-slot schedule below. The
predictor and four new block/multiply windows are described in the next sections.

## Session 6: optional registered BTB

`arm925t.ARM9_PREDICTOR` defaults to 1 and applies only when `CORE="ARM9"`.
The accuracy configuration can set it to 0 without changing instruction
semantics. ZAP remains the default core and keeps its existing predictor.

ARM9 fetch instantiates the unchanged `zap_btb`. Its RAM reads the registered
launch PC (or the BTB's registered target); its second edge registers the tag
match, direction decision and target. No lookup address comes from the
next-PC incrementer. When F2 predicts taken, that registered target launches
immediately, the sequential F1 packet is killed, and older queued instructions
remain ordered. Prediction metadata travels with the instruction into E.

E compares the predicted target with the resolved next PC, including a failed
condition's sequential PC. Correct predictions do not flush. Wrong direction,
wrong target and stale predictions on ordinary instructions redirect to the
resolved address. A stale prediction on a serialized operation is corrected
when E accepts it; any architectural PC write or exception still takes its
normal later redirect. Only actual branches or stale predicted entries train
the table. A non-taken/absent entry starts from weakly not-taken because the
shared BTB does not export tag-valid for its raw state; a taken entry retains
its valid two-bit state. CP15 and MSR completions clear prediction state across
translation/context changes. No return-address stack is added in this step.

Hot B/BL now take two clocks (window delta 3), versus four with prediction off
(delta 5). The new `arm9_predict` windows measure both a correctly predicted
taken branch and a trained-taken conditional branch that falls through. The
latter takes four clocks with prediction, one without (deltas 5 and 2).
`cycles.txt` and `predict-cycles.txt` allow a third column for the prediction-off
expectation; the bench selects it from the actual elaborated core parameter.
The other existing expectations are unchanged; there are 78 windows including
the two new predictor cases. The new test also replaces a trained uncached
branch with ADD without any CP15/BTB clear, exercising stale-entry repair in E.

## Session 6: blocks and multiplies in their execution slots

A normal block transfer starts its first request directly from E. Its immutable
base, original base, mode, register list and restoration flags are captured once;
subsequent requests use the same ordered memory records as scalar accesses.
Every STM register read waits for its youngest producer, including a load
feeding a nonfirst transfer; the first transfer uses the ordinary E interlock.
The sequencer releases D after launching the last register. A separate pending
bit retains abort-restoration context until that register retires. A following
block may reuse the context on the same edge the preceding block retires; an
ordinary following instruction need not wait. Base-in-list, user-bank transfer,
PC-load and base-restored abort behavior keep their existing rules.

Hot blocks take `n+1` clocks in isolation; a dependent following block can take
`n+2` while waiting for the preceding restoration context. The new 8-register
windows measure 9 clocks plus the marker. Adjacent dependent 4-register LDM/STM
measure 11 clocks plus the marker. LDM including PC still waits for ordered W
and refills fetch: the three-register window is 10, including its marker.

MUL/MLA and long multiplies occupy E for their iteration-dependent time while
older records continue toward W. The product and accumulator are registered,
then added; the existing iteration count determines when the complete result
enters the ordinary result pipeline. Following instructions can then use the
normal forwarding paths. Long multiply marks a second register result as a
`pair`, independently of a memory load or cache lock. Both values forward and
retire together. Failed conditions take no multiply wait. The legacy serialized
path remains for PC-destination encodings; their existing tested semantics are
preserved rather than broadening this optimization to unpredictable cases.

MUL/MLA now take `2+m` clocks; long multiplies take `3+m`, matching Table 7-2.
The new test also checks long-result forwarding into MLA and cancellation of a
younger multiply or block store by an older abort. There are now 82 timing
windows. Timing risks are E's first block-address forwarding and the multiplier
input mux; no pipeline stage was added, and the existing multiplier cone is
shared with the serialized fallback.

## Session 6: fetch and branch completion

An empty fetch queue can also bypass an uncached ARM response into D: the
cache FSM has already registered that word. Thumb miss responses retain the
translation/capture edge, keeping that decoder off the D operand-read path.
Queued instructions keep priority, and provisional fill data still waits for
completion before issue.

B/BL register-use masks are empty: their encoded offsets are not Rn/Rm/Rd
operands. Thumb BL halves remain separate architectural instructions but now
run through E and the normal ordered result records. The prefix writes its
PC-relative base into LR; the suffix forwards LR through the existing E adder,
writes the return address and validates/trains the BTB. Both halfword
alignments have directed windows, and a standalone suffix with an aligned LR
has a QEMU-compared semantic check. Target alignment preserves the old path. No new adder or pipeline stage is needed.
The new load-then-branch window catches false register dependencies in the
immediate offset. These additions bring coverage to 85 timing windows.

Fetch suppresses its core-facing read on an E/W redirect or while draining a
killed lookup. This prevents a still-idle cache from starting a wrong-path bus
transaction on the redirect edge. An already active transaction remains owned
by the cache FSM and drains normally before lookup reuse. The eight-entry
queue remains: a four-entry experiment disturbed timing windows and regressed
the high-latency ARM random workload.

## Session 6: integrated timing correction

The first integrated fit after the cycle gate exposed a 26-level path from
`fast_w[228]` through E forwarding, shift/ALU, `early_redirect`, fetch data
selection, D decode/read forwarding and back to `value_e[71]`: 32.210 ns data
delay and -23.310 ns slack at Slow 100C. Using response validity to select
instruction data connected two substantial combinational datapaths.

Fetch now selects direct versus queued data solely from registered queue count.
Response, redirect, pending-fill and epoch conditions still qualify `o_valid`;
invalid data never issues. Thumb BL uses the existing branch adder with its
forwarded LR as base, avoiding the unrelated general shifter/ALU path in branch
validation. The changes preserve all cycle-window expectations. The final
integrated result and resource comparison are in the session report.

The corrected integrated fit at `2647f62` reaches -8.332 ns setup, with
16,755 ALMs versus the same-constraint ZAP baseline's 15,917. The remaining
worst families are held operand/branch validation into backend clearing, and
I-TLB fault/hit qualification into fetch data selection and D operand controls.
All 702 runs remain cycle-identical after the correction. ZAP remains default;
the [session report](consults/2026-10-23-codex-arm9-report.md) records the four
corners, full paths, area gap and exact next work.
