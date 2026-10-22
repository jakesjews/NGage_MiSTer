# Timing at 104 MHz after the two-way caches: my own plan (2026-10-22, before the Codex consultation)

The situation: with both caches 2-way, the 128 KB flash cache and
video_freak in, the core is 0.05-0.6 ns short at the slow corners on
thirteen seeds of thirteen, and a different path family tops each
report. Three families recur (sweep 3 and 4 reports, docs/PROGRESS-LOG.md):

1. The two-way load data: D tag RAM output -> tag compare -> way select
   -> 128-bit line mux -> word select -> the FSM's uncached/cached mux ->
   the core's load/store mux -> rotate and extend (`transform`) ->
   `mem_rd_data_t`. The I-side twin ends in the fetch stage's instruction
   register. Worst -0.46 (sweep 4 seed 8), on top in 5 of 13 seeds.
2. The bus merger: the slave's acknowledge -> arbiter grant AND -> merger
   ack routing -> cache wrapper ack routing -> cache FSM (beat counter
   increment and a 32-bit address add) -> wrapper 3:1 manager mux ->
   merger 2:1 mux whose select (`state_nxt`) itself depends on the
   acknowledge -> `o_wb_adr`/`o_wb_cyc`. Worst -0.53 (seed 7), on top in
   3 of 13.
3. The issue stall: `o_stall_from_issue` -> skid mux -> four 6-bit source
   indices against seven stages' load destinations and the 64-bit
   register lock -> `lock` -> the stall register and the NV/flag
   overrides; and the operand forwarding network behind the same skid
   mux into `o_alu_source_value_ff`. Worst -0.36 (seed 2), on top in 2.

## Family 1: the load data

a. Word before way. Select the word of each way from its line by the
   address bits (registers, early) and mux the two words by the hit
   (late) last: the late select then passes one 32-bit 2:1 mux instead
   of a 128-bit mux followed by a 4:1 word mux. The tag RAM gets an
   `o_cache_word` output; `o_cache_line` becomes the victim's line
   (register-selected), which is all the FSM latches it for. Both caches.
b. Transform before way. The D-FSM already receives the load format
   (`i_ldfmt`) and owns `ld_transform` for background loads: apply it to
   each way's word before the way mux, and to the registered uncached
   data in parallel, so `o_dat` is the finished register value and the
   memory stage's `transform` passes cache data through (a parameter,
   since ZAP's core-only configuration still needs it). Takes the
   rotate/extend's two or three levels off the path and leaves: compare
   -> hit -> one 2:1 mux -> the uncached mux -> the load/store mux ->
   register. Expected gain 1-1.5 ns on the family.
c. Not this: registering the hit and selecting a cycle later costs every
   load a cycle (the load-use interlock is already ZAP's weakness).

## Family 2: the merger

a. Precomputed burst addresses. Every bus FSM (I and D fetch, the
   D-cache clean, the tag RAM's clean walk, the TLB walker) forms the
   next beat's address as `base + (adr_ctr_ff + ack) * 4`: an increment
   and a 32-bit add after the acknowledge. Keep two registered
   candidates, the current beat's and the next beat's address, and let
   the acknowledge choose (one mux level); the same for CTI (the last
   beat is `adr_ctr_ff == last && ack`). Cycle-identical.
b. Merger select after the registers. The merger registers one side's
   NXT signals through a mux whose select, `state_nxt`, depends on the
   acknowledge and both strobes. Register both sides' NXT signals
   unconditionally and mux after the registers by `state_ff`; the bus
   side then sees one mux level from registers (upp_bus and the arbiter
   already mux). Cycle-identical for the bus, since the registered
   values are the same ones chosen today, one mux later.
c. The arbiter's grant AND on the acknowledge is one level and the grant
   is a register; leave it.

## Family 3: the issue stall

a. First measure with the full-path report: whether the depth is the
   lock tree or the forwarding mux, and how much is routing fan-out from
   the skid mux (its 6-bit indices reach dozens of compares).
b. If the lock tree: the 64-bit register lock from the D-cache can be
   checked a stage earlier (the indices are known in decode) and carried
   as four registered bits; the seven-stage compares stay. If the
   forwarding network: split the skid mux (compute the forwarding and
   the lock from the skid registers and from the live inputs in parallel,
   choose the 1-bit or 32-bit results last). Both cycle-identical.
c. The timing-frontend branch (e5159ba: the FIFO's pop at the last gate,
   the TLB's idle copy, the D-cache's acknowledge cone), cycle-identical
   and unmerged, belongs to the same effort; re-measure it on top.

## Order and gates

Family 1 first (most seeds, cleanest change), a CPU trial; family 2, a
trial; family 3 only if the trial's worst path is still there. Each step:
the CPU suites cycle-exact, the boot bench, then a trial; a sweep only
after the trial clears 104 MHz with margin to spare, since the whole-core
fit loses about 0.4 ns against the trial.
