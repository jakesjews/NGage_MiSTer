# CPU: the ARM925T

The N-Gage QD's processor is the TI ARM925T inside Nokia's UPP_WD2 ASIC: an
ARM9TDMI integer core (ARMv4T: ARM and Thumb), TI's CP15 with an MMU, a
16 KB instruction cache and an 8 KB data cache (2-way, 16-byte lines).

The core's CPU is this project's own implementation of it, `arm925t`:

- an eight-stage integer pipeline written for this project
  (`arm925t_core` and its stage files);
- caches, an MMU, CP15, a register file, a writeback stage and a bus
  merger derived from the ZAP processor (Revanth Kamaraj,
  GPL-3.0-or-later) and changed to behave as the ARM925T's. ZAP's own
  pipeline is not part of it.

Every module and file is named `arm925t_*`. `rtl/cpu/NOTICE` lists which
files come from ZAP and what was changed in them.

Earlier names, for reading docs/PROGRESS-LOG.md and the reports in
docs/consults: until 2026-11-18 the pipeline was called "V2" or "ARM9V2"
(`arm9v2_*` in `rtl/cpu/arm9v2/`), the ZAP-derived files were `zap_*` in
`rtl/cpu/zap/`, and the module below the top was `zap_top`. Two other
pipelines existed in October 2026 and are gone: ZAP's own 17 stages, and a
first replacement called "ARM9" (`rtl/cpu/arm9/`, of which only the ALU
remains, as `arm925t_alu`). "ARM9" in a test's name means the architecture.

This document covers the design, every known difference from a real
ARM925T, how it is tested, and the FPGA numbers.

## Files

- `rtl/cpu/arm925t.sv`: the top, which the rest of the core instantiates.
  It holds the core's configuration: constants, the two cache sizes as
  its only parameters, and `real_caches`, its one setting.
- `rtl/cpu/arm925t_top.sv`: the pipeline, the two caches with their MMUs,
  the interrupt synchroniser and the bus merger.
- `arm925t_core.sv` with `arm925t_fetch`, `arm925t_front_decode`,
  `arm925t_decode`, `arm925t_execute`, `arm925t_forward`, `arm925t_rotate`,
  `arm925t_alu` and `arm925t_predict`: the pipeline. `arm925t_writeback`
  and `arm925t_register_file`: retirement and the banked registers.
  `arm925t_cp15`: the coprocessor.
- `arm925t_icache` and `arm925t_dcache` (each with its `_fsm`),
  `arm925t_cache_tag_ram`, `arm925t_store_queue`: the caches.
  `arm925t_tlb`, `arm925t_tlb_check`, `arm925t_tlb_fsm`,
  `arm925t_tlb_buffer`: the MMU.
- `rtl/cpu/NOTICE` and `rtl/cpu/LICENSE`: provenance and licence. Changes
  to the ZAP-derived files are tagged `ARM925T:` in the source.
- Every parameter's default in these files is the value the core is built
  with.
- The sources are the one design the core is built from. They have no
  feature switches: the timing work's one-bit parameters were folded in on
  2026-11-18, each at the value the core was built with, and the forms
  they chose between are gone (git history has them). Seven one-bit
  parameters remain, each because two instances of a module differ in it
  (the instruction side and the data side, or two RAMs). Names such as
  `FREE_SELECT` or `REG_DONE` in comments and in docs/PROGRESS-LOG.md
  label parts of the design; the head of the file that holds a part says
  what it is.
- Nothing in the sources exists only for simulation: no behavioural RAMs,
  no reference models, no assertions (two checks of the cache parameters'
  ranges are all that is left). The RAMs are Altera's megafunctions,
  which the benches model (`sim/stubs`), and the checks are the benches'.
- `rtl/cpu/arm925t_gen.v`: the Verilog-2005 netlist Quartus compiles,
  made by `tools/gen_cpu.sh` (sv2v, plus the Quartus fix described in
  the script). `make cpu-gen` regenerates it and
  `make cpu-gen-check` fails when it is out of date, so regenerate after
  any change under `rtl/cpu/`.
- `sim/cpu/`: the Verilator bench, the tests, the unit benches of the
  pipeline's parts (`sim/cpu/units`), the QEMU comparison, the boot bench
  (see Verification), and standalone Quartus trials of the CPU and its
  parts (`sim/cpu/quartus`).

## Interface

`arm925t` has one clock, a synchronous active-high reset, two interrupt
inputs and one memory bus master.

Configuration. `arm925t` has two parameters, the cache sizes in bytes as
they are built (`ICACHE_SIZE`, `DCACHE_SIZE`, 32 KB each; `emu` in
`NGage.sv` and the CPU bench pass them on), kept for speed tests with other
sizes: a bench takes `VEXTRA=-GDCACHE_SIZE=16384`, a Quartus build a
changed default in `NGage.sv`. It has one setting, the input `real_caches`:
high, the caches are the phone's sizes; low, the sizes built (the menu's
"CPU caches", below). Everything else is one configuration, constants in
`arm925t.sv`, so that no build and no test runs with another:

- The reset value of control bit V, the ARM925T's HIVECS pin, is 0
  (vectors and reset address at 0; the N-Gage boots from CS0 at 0).
- The caches are 2-way with 16-byte lines. With `real_caches` their sizes
  are the phone's own, 16 KB for instructions (512 sets) and 8 KB for data
  (256 sets, VA[11:4]). They were 32 KB each from 2026-11-09 to
  NGage_20261114, which put SPMark04's 3D tests 18 to 38 % above a real
  phone, and 16 KB each in the first release of 2026-11-16, because the
  8 KB D-cache was then 4 % short of the phone in the fill-rate test; the
  shorter end of a line fill (below) closed that, and with the phone's
  sizes nothing is below it (docs/PROGRESS-LOG.md, 2026-11-16).
- "CPU caches" in the core's menu (2026-11-27) chooses between the phone's
  sizes (Real, the default) and 32 KB each. The RAMs are built for 32 KB,
  1024 sets a way. For the phone's sizes the set index is cut to the
  smaller cache's (`set_mask` in `arm925t_cache_tag_ram.sv`, and the
  D-cache's own same-set compare), the sets above it are never read or
  written, the whole-cache clean counts the smaller cache's lines, and an
  operation by index visits one set. The tag is the smaller cache's in
  either setting: at 32 KB its lowest bits repeat index bits and are left
  out of the lookup's compare. So Real does in every clock what a cache
  built small does, and 32 KB what one built at 32 KB does (Verification).
  A cache cannot change its size with lines in it: `emu` takes the menu's
  choice only while the CPU is in reset. Built large, the caches cost the
  core about 1,100 ALMs, 46 M10Ks and 0.3 ns of mean setup slack in either
  setting (FPGA resources and timing).
- The cache type register reports 16 KB and 8 KB in either setting; at
  32 KB an operation by index then visits the four sets of the D-cache
  that share the reported index. The caches are VIVT and rely on the firmware's
  alias and DMA maintenance, as the phone's do; the
  [capacity analysis](consults/2026-10-23-codex-dcache-report.md) of
  2026-10-23 has what a larger D-cache would cost and need.
- The small-page TLBs have two ways of 256 entries; the section, large-page
  and tiny-page buffers are 64, 32 and 64 entries, one way.

Ports:

- `clk`, `reset`: reset is synchronous; drive it from a flip-flop.
- `irq`, `fiq`: level-sensitive, active high (the inverse of nIRQ/nFIQ).
  They pass a two-flop synchroniser (`arm925t_sync2`).
- `bus_req`, `bus_we`, `bus_addr[31:0]`, `bus_be[3:0]`, `bus_wdata[31:0]`,
  `bus_burst`: the request, straight from flip-flops.
- `bus_rdata[31:0]`, `bus_ack`, `bus_err`: the response.

Bus protocol:

- A request is held, unchanged, until the cycle in which `bus_ack` or
  `bus_err` is high. That cycle completes it and carries the read data. The
  next request can start in the following cycle, so a responder must not
  take `bus_req` in its ack cycle as a new request.
- `bus_addr` is a byte address with bits 1:0 zero. `bus_be` selects the
  bytes (`bus_be[0]` = bits 7:0) for writes and for uncached reads; reads
  return the whole word.
- `bus_burst = 1` marks a beat of a cache-line burst that is followed by
  the next word. Line fills and write-backs are `CACHE_LINE / 4` beats from
  the line's first word, with `bus_burst` high on all but the last. Uncached
  accesses, table walks and fetches with the I-cache off are single beats.
- `bus_err` ends the request with an external abort: a data abort for a
  data access or a table walk, a prefetch abort for a fetch.
- On the core's Wishbone port (the memory system): `wb_cyc = wb_stb =
  bus_req`, `wb_cti = bus_burst ? 3'b010 : 3'b111`, `wb_bte = 2'b00`.

## In the core

`NGage.sv` instantiates `arm925t` as the master of the memory system's
Wishbone port (`ngage_mem`, CPU side of its arbiter; the DMA controller is
the other master), with `irq`/`fiq` from the UPP interrupt controller
(`upp_periph`).

- Reset: a flip-flop holds the CPU in reset with the memory system and
  until both flash arrays are in DDR3 and any active C: restore has finished
  (`NGage.sv`). It then boots from CS0 at 0 and runs
  until the next core reset (OSD reset, the user button, new firmware).
- The picture is black until the firmware wakes the panel through the
  UPP's LCD interface. (A memory test and a test picture shared the bus and
  the panel until 2026-11-10.)

## Architecture

### The pipeline

Eight stages, single issue, in order (`arm925t_core.sv`):

| Stage | Work |
|---|---|
| F1 | The PC is a register; the predictor's, the I-cache's and the I-TLB's reads start from it. |
| F2 | Cache compare, way selection and permission; the raw instruction word goes into the fetch queue with its PC, state and prediction. |
| D1 | The Thumb expander; instruction class and register tags; the sequencing of LDM/STM. |
| D2 | The register file read, hazards against pending destinations, unconditional direct branches. |
| S | Operand selection (forwarding) and the rotator; the multiplier's first stage. |
| A | ALU, condition and flags, the effective address, the end of a multiply. Redirects are registered here. |
| M | The D-cache RAMs' read, launched by A; the D-TLB lookup and the cache compare from M's address register. |
| W | The cache's registered response, register writes, faults and retirement. |

It has a branch predictor with a four-entry return stack (the ARM925T has
none) and a fetch queue between F2 and D1. A correctly predicted branch
loses no fetch slot. CP15 operations are carried out in order while the
pipeline waits.

The cycle shapes are pinned by tests with exact counts (`arm9_cycles`,
`arm9_slots`, `arm9_branch_slots`, `arm9_predict`, `arm9_stream_timing`,
`arm9_tail`; the counts are the `*-cycles.txt` files in `sim/cpu/units`),
and the stages have unit benches there (`make -C sim/cpu units`).

How the pipeline came to this shape, with the measurements behind each
boundary, is in docs/consults/2026-10-pipeline-design-record.md. That
record was written during the work under the name ARM9V2 and compares
against the ZAP pipeline it replaced; it is history, not a description
of the code.

### The memory system

Derived from ZAP's (rtl/cpu/NOTICE):

- Caches: the ARM925T's geometry, 2-way set-associative with its LRU
  replacement, virtually indexed and tagged, write-back with write
  allocate (and write-through per page, below), 16-byte lines. Each way
  is a tag RAM and a data RAM read at the same set (I: 512 sets, VA[12:4];
  D: 256 sets, VA[11:4]); one LRU bit per set names the way to fill next,
  updated on hits and fills, an invalid way filled first; a dirty victim
  is written back before the fill. The D-cache keeps each line's physical
  address, so cleaning needs no table walk.
- MMU: ARMv4 sections, coarse and fine tables with large, small and tiny
  pages, domains, access permissions with S and R, FCSE PID. Separate I and
  D TLBs, each four buffers, one per page size: 64 sections, 32 large and
  64 tiny pages, direct-mapped, and the small pages in two ways of 256
  entries (a set's ways are replaced in turn). A hardware table walker on the bus.
- CP15 (`arm925t_cp15.sv`): carries out MCR/MRC while the pipeline waits.

### ARM925T behaviour

Identity and CP15:

- c0 reads the main ID 0x54029252 and cache type 0x05109149 (2-way,
  16-byte lines, 16 KB I, 8 KB D). With TI configuration bit O set the ID
  reads part 0x915, as on QEMU's ti925t. Writes to c0 are ignored.
- c1 control: M, A, C, W, S, R, I and V are writable; bits 6:4 read 1, B
  (bit 7) and the rest read 0. Reset value 0x70 (V is 0 at reset).
- c2 TTB, c3 DACR, c5 FSR, c6 FAR: as ARMv4. FSR and FAR change only on
  data aborts (ZAP also wrote them on uncached accesses); an external
  abort reports status 0b1000. A prefetch abort does not change them.
- c7: the ARM925T operations: c7,c7,0 (flush I+D), c7,c5,0 and c7,c5,1
  (flush I; the entry form flushes the whole I-cache), c7,c6,0 (flush D),
  c7,c10,0 (clean D), the single-line D operations by address (c7,c6,1,
  c7,c10,1, c7,c14,1) and by index (c7,c6,2, c7,c10,2, c7,c14,2, TI operand:
  set from bit 4, way in bit 31), c7,c10,4 (drain write buffer) and
  c7,c13,1 (prefetch I line) as no-ops, c7,c0,4 wait for interrupt. Any
  other c7 operation cleans and flushes both caches. Cache operations reset
  I_max/I_min, as QEMU does.
- c8: flush I, D or both TLBs; the entry forms flush the whole TLB.
- c10 TLB lockdown: stored and read back, no effect.
- c13 FCSE PID: bits 31:25.
- c15 (TI): configuration (c15,c1,0, bits 7:5 and 2:0), I_max (c15,c2,0),
  I_min (c15,c3,0), thread ID (c15,c4,0), wait for interrupt (c15,c8,2,
  and c15,c8,0 as on QEMU). Status (c15,c8,0 read) and everything else in
  c4, c9, c11, c12, c14 and c15 read 0 and ignore writes.
- MCR/MRC from User mode, to a coprocessor other than CP15, CDP, LDC and STC
  are UNDEFINED. A CP15 operation starts only after every older instruction
  has retired, and the instruction stream is fetched again after it, so
  code after a cache, TLB or MMU change runs with the new state.

Exceptions and modes:

- Control bit V moves the vectors to 0xFFFF0000.
- Alignment faults with bit A: word accesses (LDR, STR, LDM, STM, SWP,
  Thumb loads and stores) not on a word boundary and halfword accesses not
  on a halfword boundary abort with FSR 0b0001 and FAR = the address;
  nothing is transferred and the base is not written back. With A clear,
  unaligned LDR and SWP rotate (ARMv4), STR and LDM/STM ignore the low bits.
- The Thumb SWI and undefined-instruction exceptions return to the next
  instruction.

Instruction set:

- ARMv5 instructions are UNDEFINED: CLZ, BLX (both), BKPT, QADD and
  friends, the 16-bit multiplies, LDRD/STRD, PLD, the "2" coprocessor
  forms, anything with condition NV; Thumb BLX and BKPT.
- An UNDEFINED instruction traps only if its condition passes.
- PSRs have only NZCV, I, F, T and the mode; Q and the reserved bits read 0.
- Interworking as ARMv4T: only BX changes state (POP {pc} and LDR pc do
  not).
- The Thumb BL pair is executed as two instructions, as on the ARM9TDMI
  (each half can be interrupted; a lone second half works).

Memory system:

- Write-through pages (C=1, B=0): stores go to memory at once (through the
  store queue when control bit W is set) and update a
  line that hits; no allocation on a store miss (ZAP treated every
  cacheable page as write-back).
- Single-line D-cache operations (above), used by the Symbian kernel's
  index loops and by drivers for DMA buffers.
- With the MMU on and a cache off, uncached accesses use the physical
  address (ZAP put the virtual address on the bus).
- With the MMU off and the I-cache on, instruction fetches are cacheable,
  as on the ARM920T family (ZAP cached nothing with the MMU off); data
  accesses stay uncached. The firmware's bootstrap runs this way (control
  0x1272 from its first instructions). Uncached, its flash code took about
  20 clocks an instruction, and its delay loops, which count instructions,
  ran about 15 times longer than on the phone.

Bugs fixed in the parts that came from ZAP (found by the tests; fixes to
ZAP's own pipeline, which is gone, are in git history):

- Fine page tables were walked with the coarse layout.
- Page faults reported the wrong domain.
- The CP15 register array had 14 entries, so writes to c14/c15 went out of
  range; the I- and D-cache line-size parameters were swapped (harmless
  while they are equal).
- A load that misses the D-cache is acknowledged at once and its register
  written when the line arrives; that write took the whole word, so byte,
  halfword, signed and unaligned loads that missed returned the wrong
  value (found by the boot bench: the bootstrap's integrity check reads
  the stored digest with LDRB from flash). The D-cache keeps the load's
  format with the miss and applies it (`arm925t_load_format.svh`).
- Instruction fetches were permission-checked as User mode whenever the
  data side's LDRT/STRT flag was set (found by the boot bench: the kernel
  took a prefetch abort in a privileged-only section). Fetches are
  checked in the current mode.
- A cache line write-back could change its address in the middle of the
  burst (found by the bench's bus checker).
- Data accesses are permission-checked in the mode carried with the
  access, not the mode at the time of the check, which a younger MOVS PC
  or MSR may already have changed (found by the full-core boot bench: the
  flash driver's FIQ handler writes through a privileged-only section and
  returns to user mode two instructions later).

Timing changes in the caches (no change in behaviour; the first two cost
cycles):

- Registered bus responses: both cache state machines latch the bus
  acknowledge, error and data of an uncacheable access and complete it in
  a new state (UNC_DONE) one cycle later, so that the bus acknowledge is
  not in the same cycle as the pipeline stall. One more cycle per
  uncacheable access.
- A load that missed the D-cache writes its register in a new state
  (UNLOCK_WR) from a latched value instead of straight from the line
  buffer. One more cycle per load miss.
- The end of a D-cache line fill (2026-11-16). A request that waits for a
  fill (the next miss, or a store to the line being filled) used to be
  looked up again twice after the line was written: by the cache in three
  restore states (RELOOKUP0-2) and then by the CPU for three more clocks
  (its RETRY states), eight clocks from the write to the request's
  acceptance. Now the cache keeps the waiting request on its lookup and
  compare addresses during the fill; when the request has waited through
  the three clocks before the first idle clock, the response in that clock
  is its own and includes the new line (the RAMs' same-edge write bypass),
  the cache says so (`o_fill_kept`) and the CPU presents the request there:
  two clocks from the write (UNLOCK_REG, UNLOCK_WR, accepted). A request
  that arrived in the last two busy clocks is held one or two clocks more
  instead of the CPU's three. A sequential walk of loads (`make -C sim
  dfill`, 16 KB D-cache) costs 19.3 clocks a line where it cost 25.3; a
  load whose word is used at once 20.3 (25.3). A walk that leaves every
  line dirty is unchanged (41.4, was 42.1): there the SDRAM decides, its
  first read word comes 23 clocks after the request when a written-back
  line went before it, 8 otherwise. Since 2026-11-19 the memory bus reads
  ahead (`rtl/upp/upp_bus.sv`): a fill of the 16 bytes behind the last one
  read comes from its read-ahead line, the first word after 2 clocks and
  one a clock, and the walk costs 17.8 clocks a line, the load whose word
  is used at once 16.8.

## Differences from a real ARM925T

Functional:

- Replacement is the TI925T's fixed LRU (TI SPRU671; the control
  register's RR bit reads zero), one bit per set. Index operations take
  the TI operand (set in bits 11:4, way in bit 31): with TI configuration
  C clear they act on both ways of the set, with C set on the named way.
- No cache lockdown (c9 reads 0, writes ignored).
- Turning a cache off invalidates it (the valid bits are cleared while the
  cache is disabled). Dirty D-cache lines are lost if the D-cache is turned
  off without cleaning it first; the ARM925T keeps them.
- Store misses and the write buffer (since 2026-11-09, `arm925t_store_queue.sv`):
  with control bit W set and the MMU on, a write-back store miss is posted
  to a four-entry queue of permission-checked physical writes and
  allocates no line, as on the TI925T (read-allocate: TI SPRU671,
  Table 1). Write-through stores (hits update their line as well) and
  bufferable uncached stores (C=0, B=1) are posted too (Table 2). The
  queue drains in order ahead of any later fill, table walk or
  maintenance write, c7,c10,4 waits for it, and a bus error on a posted
  write is dropped. Still unlike the part: four entries instead of 17
  words; an uncached SWP stays synchronous; a store miss whose victim is
  a dirty copy of the same physical line cleans and fills as before; with
  W clear a store miss allocates, as every store miss did until this
  change ([the write-allocation analysis](consults/2026-10-23-codex-walloc-report.md)).
  Tests: walloc_posted_rtl.S, buffer_modes.S; the allocation tests
  (walloc, dstore, dcsize, dhold, dhum) run with W clear.
- The TLBs are a buffer per page size instead of the ARM925T's 64-entry
  fully associative TLBs: sections, large and tiny pages direct-mapped,
  small pages set-associative (since 2026-11-15). With one way, two small
  pages 1 MB apart evicted each other at every access, a two-level walk
  each time, and EKA1's chunks start on megabyte boundaries, so pages at
  the same offset in two chunks did exactly that: the phone's 2D drawing
  ran at 60 to 85 % of a real phone's rate depending on where its buffers
  lay (test `arm9_tlb_assoc_rtl`). The other three buffers can still do
  it (two sections 64 MB apart share an entry; not measured in the
  firmware). The instruction side walks a page twice
  after a miss (the next fetch address is checked against the entry from
  before the install). TLB lockdown has no effect.
- An external abort on a cacheable line fill or write-back is ignored (the
  line is filled with the data returned). External aborts on uncached
  accesses and table walks are reported.
- The value stored by STR and STM for the PC is the instruction address +
  8 (as QEMU). This is IMPLEMENTATION DEFINED; the ARM7TDMI and, most
  likely, the ARM9TDMI store + 12.
- Other UNPREDICTABLE cases are this CPU's own, not the ARM9TDMI's: LDM/STM with an
  empty register list, STM with writeback and the base in the list but not
  first, misaligned LDRH/LDRSH with A clear (not rotated as on the
  ARM7TDMI), register-specified shifts with the PC as an operand (not
  + 12), data-processing tests with Rd = 15 (no mode change). These are the ARM7TDMI-specific
  checks of gba-tests that are skipped (Verification).
- Instruction fetch runs further ahead: along predicted paths and up to
  the fetch queue's depth, the ARM9TDMI only the next two
  instructions. With the I-cache off (or an uncached code page) these
  fetches reach the bus, so memory past the end of the executed code can
  be read. Harmless for memory; a read-sensitive device register would
  have to sit right after uncached code to be affected.
- No CP14 (debug communications channel): its MRC/MCR are UNDEFINED. No
  EmbeddedICE, JTAG or ETM.
- Big-endian mode is not available (B reads 0).

Timing (instructions take this pipeline's cycle counts, not the
ARM9TDMI's; see The pipeline above for where the exact counts are kept):

- Eight stages with a branch predictor instead of five without: a
  correctly predicted branch costs one issue slot, a mispredicted or
  unpredicted one a refill of the front end (the ARM9TDMI: three cycles
  for every taken branch).
- Multiplies take a fixed number of clocks; there is no early termination
  by operand size.
- The wait of an instruction that uses a load's value is this pipeline's,
  not the ARM9TDMI's one or two interlock cycles.
- A line is fetched in full on a miss; a store that is not posted (W
  clear, or C=0 B=0) waits until the bus acknowledges it.
- CP15 operations wait for older instructions to retire.
- Memory is the MiSTer's: SDRAM and flash-in-DDR3 timing, not the
  phone's (docs/UPP_WD2.md).

SPMark04 on the board against a real N-Gage QD is the measure of the
whole: docs/PROGRESS-LOG.md, 2026-11-16.

## Verification

`make -C sim/cpu bins run` assembles the tests and runs them on the RTL
here; `make -C sim/cpu all` runs them on the Verilator machine instead
(`remote`), runs QEMU (`qemu`) and compares (`diff`). `make -C sim/cpu
units` runs the unit benches of the pipeline's parts and three proofs (the
D-cache's lock summary, the cache metadata against its last reviewed
form, and the 32 KB cache told to be the phone's against the phone's).
Results land in `sim/cpu/build/`.

Every test and bench runs the CPU in the core's configuration: the
modules' own defaults, with nothing overridden, and the caches at the
phone's sizes (`real_caches` high). `BENCH=--big-caches` with a `RESULTS`
folder of its own runs the tests at 32 KB. The two cache-size parameters
are for speed trials on a build or a bench run of their own (`VEXTRA`),
not for tests.

The cache setting was checked against the CPU without it (2026-11-27;
119 tests at three bus latencies, every log with its clock and
instruction counts, every signature and trace): at the phone's sizes
equal to the sources before the setting, at 32 KB equal to those sources
built with 32 KB caches. `sim/cpu/units/small_cache_miter.py` holds the
first half in the unit targets: the cache unit built at 32 KB with
`i_small` against the unit built small, every output and the registered
metadata, 400,000 clocks of random requests, for the D-cache's and the
I-cache's configurations.

### Bench

`sim/cpu/tb/tb_cpu.sv` instantiates the wrapper (the generated netlist by
default, `RTL=sv` for the SystemVerilog; the RAM models of `sim/stubs`
with either) with probes into the writeback stage. `sim/cpu/tb/main.cpp` provides 16 MB of RAM at 0, 64 KB at
0xFFFF0000 (high vectors), bench registers at 0xF0000000 (console, stop,
interrupt lines and timers, cycle and instruction counters, a fixed-latency
override) and a bus error everywhere else. It answers the bus after a
random latency (`--lat MIN:MAX`; every test runs at 0:0, 0:3 and 2:9) and
checks the protocol: a request must stay unchanged until acknowledged, and
a burst must continue at the next word. It writes a retirement trace (one
line per instruction or exception with the registers after it) and the
signature area.

Each test (`sim/cpu/tests/*.S`, with `crt0.S` and `test.inc`) checks its
own results (a failed CHECK ends the test with its number) and records
checkpoints (all registers and the CPSR) in the signature.

### Directed tests

- `alu`, `shift`, `mul`: data processing, the barrel shifter, multiplies.
- `ldst`, `ldm`: loads and stores of every size and addressing mode;
  LDM/STM in every mode, user bank, exception return, base-restored data
  aborts part-way through.
- `modes`, `exc`, `irq`: PSRs and banked registers, SWI and undefined
  instructions (which coprocessor instructions trap), IRQ and FIQ entry,
  masking, nesting, interrupts in Thumb state, a long computation
  interrupted hundreds of times.
- `thumb`: every Thumb format, interworking, BL, SWI and UND from Thumb;
  SP-relative stores read back through another register and the other way
  round.
- `bpred`: a MOV PC, LR that shares a branch-predictor entry with a taken
  branch, called by a conditional BL predicted not taken.
- `tbl_irq`: Thumb BL pairs interrupted at every cycle offset (also
  between the halves), the handler returning as the Symbian kernel does
  (a CP15 write, then LDM ^ with the PC).
- `fiq_movs`, `fiq_perm`: FIQ at every point around the kernel's MOVS PC,
  LR mode switch (the FIQ bank checked), and a privileged FIQ handler
  doing the flash driver's stores to a privileged-only section followed
  by MOVEQS PC, LR back to user mode.
- `cp15`, `v5und`, `align`, `rtl_misc`: CP15 as the firmware uses it, the
  ARMv5 instructions that must trap, alignment faults, and ARM925T details
  QEMU does not model (control register read-as values, PID masking,
  rotated unaligned loads, high vectors, the lone Thumb BL suffix, wait for
  interrupt).
- `mmu_sect`, `mmu_page`: sections, coarse and fine tables with all page
  sizes, domains, permissions with S and R, user-mode accesses, every fault
  type with FSR and FAR, prefetch aborts, LDRT/STRT from a privileged-only
  code section.
- `icache_rtl`, `dcache_rtl`: three lines of one set, code run in turn
  and rewritten behind the cache, or data dirtied in turn and read back
  through an uncached alias; what the cache still holds shows the two
  ways and the LRU choice, and the D-side's index operations act on the
  named way.
- `iprefetch_rtl` (written for the removed I-cache prefetch; it still
  checks the I-cache's sequential and invalidate behaviour): sequential code over 32 lines
  (cold, warm, backward; an execution-bound variant), a branch away from a
  prefetched line, the I-cache invalidates (all and by MVA) with code
  rewritten behind the buffer, and sequential code across a 4 KB page end
  into a page mapped elsewhere (poison at the contiguous address) and up to
  an unmapped page. Exact results, loose cycle shape.
- `cache`, `cache_rtl`: 64 KB through the 8 KB D-cache (evictions and
  write-backs), bytes and halfwords in cached lines, loads of every size
  and unaligned loads that miss, LDM/STM across lines,
  clean and flush by VA and by index with uncached aliases, write-through
  pages, self-modifying code; and what only the RTL can show (dirty data
  stays in the cache until cleaned, line operations touch only their line,
  the I-cache keeps old code until flushed, also with the MMU off).

### Random tests

`sim/cpu/tools/gen_random.py --seed N` writes a seeded random ARM program
(`randN`): data processing with every opcode, condition, S bit and operand
form, multiplies, loads and stores of every size and addressing mode,
LDM/STM, SWP, MSR/MRS and short branches, with checkpoints every 20
instructions. With `--thumb` (`trandN`) it writes a Thumb program: formats
1-5 (shifts, add/subtract, 8-bit immediates, the 16 ALU operations, the
high-register forms), loads and stores of every size with immediate and
register offsets, PUSH/POP, LDMIA/STMIA, ADD Rd, PC and conditional
branches, with checkpoints through an ARM veneer. With `--cache`
(`crandN`, `ctrandN`) the program runs with the MMU on (RAM identity-mapped,
write-back) and both caches enabled, so the same mix hits and misses. The
programs check nothing themselves; the RTL and QEMU (which has no caches)
must agree. Seeds 1-8 of all four kinds run by default (`RAND_SEEDS=...`
for more).

### gba-tests

The ARM and Thumb suites of jsmolka/gba-tests (MIT; the test bodies are in
`sim/cpu/ext/gba-tests`, unmodified) are translated from FASMARM syntax by
`sim/cpu/tools/fasm2gas.py`, with a driver for this bench that records
failures and carries on. The translation was checked against upstream's
prebuilt ROMs: the same 1813 ARM words and 1052 Thumb halfwords, apart
from two padding halfwords.

161 of the 183 ARM tests and 101 of the 109 Thumb tests run; the rest test
ARM7TDMI behaviour that ARMv4 leaves UNPREDICTABLE or IMPLEMENTATION
DEFINED, or need GBA memory (`GBA_SKIP_*` in `sim/cpu/Makefile`):

- ARM 224, 225: PC as an operand with a register-specified shift.
- ARM 234, 235: CMP with Rd = 15 (QEMU makes it UNDEFINED).
- ARM 356, 510: the stored PC (+ 12 on the ARM7TDMI).
- ARM 362: a load from 0x80000000 (no memory there on the bench).
- ARM 408, 409; Thumb 211, 212, 219: misaligned halfword loads.
- ARM 513-515, 530-532; Thumb 227-229: empty register lists.
- ARM 522-529; Thumb 230, 231: STM with the base in the list, not first.

`gba_arm` and `gba_thumb` run on the RTL only. `gba_arm_q` and
`gba_thumb_q` also leave out the unaligned word accesses QEMU aborts on
(ARM 354, 355, 407, 452, 508; Thumb 204, 216, 221, 225, 233) and are
compared with QEMU. armwrestler was not used: it has no licence.

### Comparison with QEMU

`sim/cpu/qemu/run.sh` runs each binary on QEMU's ti925t (`-M none`, 16 MB
of RAM at 0, nothing else, so everything else is an external abort, as on
the bench). GDB, connected through QEMU's stub on a pipe, stops at the halt
loop and dumps the signature area. QEMU also logs every instruction with
the registers before it (`-d exec,cpu,nochain`, one instruction per
translation block). `tools/cmp_sig.py` compares the signatures word by
word; `tools/cmp_trace.py` turns both logs into (PC, registers before)
lists and compares them instruction by instruction. It folds interrupts
and prefetch aborts into the next instruction, treats a Thumb BL pair as
one instruction (QEMU runs it as one, except when the first half is the
last halfword of a 1 KB page), skips registers still waiting for a
background load, and ignores PSR bit 8 and the flags until both first
agree.

Tests tagged `@@ qemu: no` (bench registers, interrupts, high RAM,
ARM925T details) run on the RTL only. QEMU's ti925t differs from the
ARM925T in ways the compared tests avoid: every unaligned word access
aborts even with A clear; c13 adds the unmasked PID; CP14 reads return 0;
PSRs carry the ARMv6 A bit; the second half of a Thumb BLX pair executes.

### The real boot code

The N-Gage boot code from the CS0 image runs on the RTL and on the
reference model from the same flash images, and their device accesses are
compared. Three targets:

- `make -C sim/cpu boot-prep` builds the images from git HEAD's model and
  `firmware-patches` files: the NOS stand-in assembled,
  `firmware-patches/rom-patches.txt` applied as the model applies it, and the integrity digests computed through the
  bootstrap's ROM map (`sim/cpu/boot/prep.py`).
- `make -C sim/cpu boot-model` builds the model from git HEAD on the
  Verilator server (`sim/cpu/model/build_linux.sh`: the steps of
  `model/build.sh` for Linux) and runs it on those images
  (`sim/cpu/model/run_model.sh`: `-icount shift=4,sleep=off`, RTC at
  2004-06-01 12:00:00) with a QEMU plugin (`sim/cpu/model/trace_plugin.c`)
  that logs every device access and interrupt, and instructions in a
  window if asked (`MODEL_TRACE=start=N,count=M`).
- `make -C sim/cpu boot` runs the RTL on the same images and compares the
  register logs and CBUS logs (`sim/cpu/boot/cmp_regs.py`) and the whole
  sequence of device accesses (`sim/cpu/boot/cmp_dev.py`).

`sim/cpu/tb/ngage.h` gives the bench the model's memory map and the
devices the boot uses, ported from `model/hw`: both NOR flash chips (AMD
command set), SDRAM, on-chip RAM, the emif and upp register blocks as
storage with `model/upp-quirks.txt`, the interrupt controller and timers,
the CBUS master with the UEMK registers of `model/cbus-regs.txt` and the
UEMK RTC, the HLE RTC date register, the keypad ports and CTSI register
(no key pressed), the MMC host with an empty slot, the LCD interface's
panel ID and status reads, and the STI window, whose kernel debug text goes
to `kern.log`. Guest time follows executed instructions, counted as QEMU's
icount counts them (16 ns each; an SWI or undefined instruction counts, a
Thumb BL pair counts once), and skips ahead while the CPU waits for an
interrupt, as the model's `-icount shift=4,sleep=off` does, so timer and
RTC values agree with the model's to within a few instructions. `--devlog`
writes every device access in the plugin's format; `--watch ADDR` prints
the registers whenever an instruction retires at ADDR; `--trace` with
`--trace-after N` and `--trace-count M` writes an instruction window
(`--dcdbg` and `--pddbg` add the D-cache state machine and the branch
prediction every cycle), which
`sim/cpu/boot/cmp_window.py` compares with the model's (`--pc-only`: the
plugin's PCs and registers are not reliable for code reached through a
virtual alias, see the plugin's header).

### The whole core

`sim/harness/coreboot_main.cpp` (`make -C sim coreboot`, on the Verilator
server) runs `NGage.sv`'s `emu` with everything in it: the CPU, the memory
system with the SDRAM chip model and the DDRAM port model, the UPP
peripherals, the LCD and the keypad. The flash images (`tools/mkimage.py`)
go into DDR3 and are marked loaded with a one-word ioctl download each, as
the OSD's load does; an MMC image sits on SD slot 0; MiSTer's RTC is set
to 2004-06-01 12:00:00. The bench writes the LCD picture as a PNG each
time it changes, the audio output as a WAV, the kernel's STI text,
and with `--devlog` every device access and every interrupt and exception
in the plugin's format. `--keys` plays a key script (simulated seconds).

Here the peripherals run in real time (104 MHz clocks), while the model's
time follows its instruction count, so interrupts land on other
instructions. `cmp_dev.py` is exact up to the first timer interrupt that
lands elsewhere; after that `sim/cpu/boot/cmp_flow.py` compares what does
not depend on it: the synchronous exceptions (SWIs, aborts) in order, the
device accesses outside the interrupt controller, timers and CBUS in
order, and the writes per device block.

### Results

The state at the release of 2026-11-16 (docs/PROGRESS-LOG.md), and again
after the renaming of 2026-11-18, which changed no logic:

- The CPU suite: every test at three bus latencies on the generated
  netlist and on the SystemVerilog sources (which checks the sv2v
  conversion), all passing; the tests QEMU can run agree with it in
  signature and instruction by instruction.
- The unit benches and proofs of `sim/cpu/units`.
- On the whole core: `make test` (the device benches and the top),
  `make -C sim flashcopy` and `dfill` (the CPU running the flash driver's
  copy loop and a line-fill walk against the memory system; both end on a
  fixed clock count, which changes with any change in the CPU's cycle
  behaviour), and `hps-read-test`.

## FPGA resources and timing

Whole-core compiles of `NGage.qsf` in Quartus 17.0.2 Lite on the build
server (`./build.sh remote compile`; `tools/seed_sweep.sh` for several
fitter seeds at once). A given source, seed and build date fit the same
every time; the date is the core's version string, and another day's
build of the same source and seed can fit differently (0.2 ns in the one
case measured, 2026-11-20).

- The release of 2026-11-28 (seed 160, GitHub's build of bf506ab on that
  day): worst setup slack -1.600 ns at the slow 100C corner and -1.629 ns
  at slow -40C against 104 MHz. Hold slack is positive at every corner
  (0.115 ns at the least). 37,270 ALMs for the whole core (89 %), 469 of
  553 M10Ks.
- The release before, of 2026-11-20 (seed 31337, before pull request 10
  and the cache setting): -1.148 ns and -1.321 ns; sixteen seeds of its
  sources lay between that and -1.988 ns. 33,938 ALMs.
- With pull request 10 (2026-11-27, sixteen seeds): -1.621 to -2.148 ns at
  the worse corner, 36.2 k ALMs, 423 of 553 M10Ks. With the caches built
  at 32 KB for the menu's choice (the same sixteen seeds, then twenty
  more built on the 28th): -1.629 to -2.786 ns, mean -2.17 against -1.86
  for the sixteen and -2.18 for the twenty; three of the thirty-six are
  above -1.8 ns. 37.3 k ALMs (89 %), 469 M10Ks. The larger caches' own
  paths join the worst: the D-cache's valid flags (a flag for four sets,
  read through a 256:1 multiplexer from the W address) and its data RAM's
  byte enables.
- So the timing report does not show 104 MHz; the core runs on the board
  regardless. The failing paths are in the CPU: the D-cache's answer and
  the TLB result into the pipeline's hot readers. What was tried, and why
  only a deeper pipeline is left, is in docs/PROGRESS-LOG.md (the entries
  of 2026-11-09 and 2026-11-16).
- Changing any name or any logic in the CPU re-rolls the fit: the worst
  slack then has to be found again over several seeds.

## Plan for the timing-fidelity pass

The goal is ARM9TDMI cycle counts at 104 MHz, without changing behaviour.

1. Cycle-cost model: a table of ARM9TDMI cycle counts per instruction
   class from the ARM9TDMI TRM (data processing 1, +1 with a register
   shift, +2 when it writes the PC; loads 1 plus the load-use interlock;
   LDM/STM by register count; multiplies by operand size; branches 3;
   exception entry), plus the ARM925T's memory side: cache misses with
   16-byte line fills at the UPP_WD2 memory timing, and the write buffer
   (depth and drain rules from the ARM925T TRM, to be confirmed).
2. Clock-enable throttling: a cycle accountant beside the writeback stage
   adds up the ARM9TDMI cost of each retired instruction, and the core
   runs with a clock enable that holds it (all stages, and the bus
   interface's view of time) whenever it is ahead of the accumulated
   ARM9TDMI time. Where the pipeline is faster it waits; where it is
   slower (mispredicted branches) the debt is paid back later. The
   peripherals see accesses at times close to the real phone's.
3. Real cache geometry: done, both caches 2-way with LRU, so that hit
   rates (and so the time between bus accesses) match and the index
   operations address real ways. Still unlike the part: a cache turned off loses its contents (a
   store miss no longer allocates when W is set, see above).
4. Measure against the model and known firmware timing loops (the boot's
   delay loops, the kernel's tick calibration), then tune.

## Remaining gaps

- The timing report misses 104 MHz by about 1.4 ns on the best seed (see
  FPGA resources and timing).
- No cache or TLB lockdown; cache disable discards the D-cache contents;
  external aborts on line fills are lost. The section, large-page and
  tiny-page TLBs are direct-mapped; the instruction side walks twice a
  miss.
- Stored PC is + 8 (probably + 12 on the ARM925T).
- Cycle timing is this pipeline's, not the ARM9TDMI's (see the plan
  above).
