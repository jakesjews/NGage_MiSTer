# CPU: the ARM925T

The N-Gage QD's processor is the TI ARM925T inside Nokia's UPP_WD2 ASIC: an
ARM9TDMI integer core (ARMv4T: ARM and Thumb), TI's CP15 with an MMU, a
16 KB instruction cache and an 8 KB data cache (2-way, 16-byte lines). The
core's CPU is ZAP (Revanth Kamaraj, GPL-3.0-or-later), changed so that it
behaves as an ARM925T. This document covers the design, every known
difference from a real ARM925T, how it is tested, and the FPGA numbers.

## Files

- `rtl/cpu/zap/`: ZAP at commit fc7bd75, with `NOTICE` and `LICENSE`.
  Every change is tagged `ARM925T:` in the source. The new behaviour is
  switched on by parameters (`V4T`, `TI925T`, `CP15_ID`, `CP15_CTYPE`,
  `HIVECS`); the upstream behaviour stays the default where that is
  possible. Bug fixes that apply to every configuration are unconditional.
- `rtl/cpu/port/`: two replacement modules for Quartus 17 (a byte-lane RAM
  that infers M10K, and a stub for the simulation-only decompiler).
- `rtl/cpu/arm925t.sv`: the wrapper the rest of the core uses.
- `rtl/cpu/arm925t_gen.v`: the Verilog-2005 netlist Quartus compiles,
  made by `tools/gen_cpu.sh` (sv2v 0.0.13, `-DSYNTHESIS`, plus the Quartus
  fixes described in the script). `make cpu-gen` regenerates it and
  `make cpu-gen-check` fails when it is out of date, so regenerate after
  any change under `rtl/cpu/`.
- `sim/cpu/`: the Verilator bench, the tests, the QEMU comparison, the boot
  bench and the Quartus trial (see Verification).

## Interface

`arm925t` has one clock, a synchronous active-high reset, two interrupt
inputs and one memory bus master.

Parameters:

- `HIVECS` (0): reset value of control bit V, the ARM925T's HIVECS pin. 1
  puts the vectors and the reset address at 0xFFFF0000. The N-Gage boots
  from CS0 at 0, so the core uses 0.
- `ICACHE_SIZE` (16384), `DCACHE_SIZE` (8192), `CACHE_LINE` (16): cache
  geometry in bytes. `ICACHE_SIZE` 32768 is a 1,024-set I-cache (16 M10K
  more); the cache type register still reports 16 KB.
  `NGAGE_DCACHE_16K` in `NGage.qsf` selects an experimental 16 KB two-way
  D-cache (512 sets, VA[12:4]); the default remains 8 KB. CP15 still
  reports 8 KB, so a D-cache by-index operation visits both physical set
  colours for the named architectural set/way. By-VA operations stay
  targeted. The live two-way compare/select and hit-under-miss protocol
  are unchanged. This VIVT cache still relies on firmware alias/DMA
  maintenance; see [the capacity analysis](consults/2026-10-23-codex-dcache-report.md)
  for the recommendation, projected cost and validation limits.
- `ICACHE_PREFETCH` (0): a one-line sequential I-cache prefetch. After a
  line fill, the next line (within the same 1 KB) is read into a line buffer
  while the bus is free; a later miss on that line is answered from it and
  installs it. Off by default: the ARM925T has none, the games measured no
  gain from it on the board (2026-10-23) and it costs about 1 ns of slack;
  NGAGE_ICACHE_PREFETCH in NGage.qsf turns it on.
  docs/consults/2026-10-23-agy-iprefetch-report.md.

Ports:

- `clk`, `reset`: reset is synchronous; drive it from a flip-flop.
- `irq`, `fiq`: level-sensitive, active high (the inverse of nIRQ/nFIQ).
  They pass a two-flop synchroniser inside ZAP.
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

- Reset: a flip-flop holds the CPU in reset with the memory system, while
  the memory test runs, and until both flash images are in DDR3: CS0
  loaded through the OSD (F1) and CS1 loaded (F2) or mounted as the save
  file (S1, once its copy is in). It then boots from CS0 at 0 and runs
  until the next core reset (OSD reset, the user button, a new image).
- The OSD's "Memory test" gives the port to `wb_selftest` instead, with
  the CPU in reset; switching it on or off resets the board. The port's
  multiplexer select is a register (`test_sel`).
- The test picture (`lcd_testgen`) shows until the UPP's LCD interface
  first drives the panel, as before.

## Architecture

ZAP is a single-issue, in-order core with a 17-stage pipeline: fetch
(address, TLB, cache, memory), instruction buffer, Thumb decoder,
pre-decoder (micro-op sequencer for LDM/STM, SWP, BL, long multiplies),
decoder, issue (register read, interlocks), shifter, ALU, two post-ALU
stages (D-TLB, D-cache), memory and writeback. It has a bimodal branch
predictor with a BTB and a 4-entry return stack, a 16-word fetch buffer,
and non-blocking cache-miss loads (the destination register is locked until
the line arrives).

The memory system is ZAP's:

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
  D TLBs, each four direct-mapped buffers (one per page size: 4 sections,
  8 large, 16 small, 32 tiny pages). A hardware table walker on the bus.
- CP15 (`zap_cp15_cb.sv`): carries out MCR/MRC while the pipeline waits.

### What was changed for the ARM925T

Identity and CP15 (`TI925T = 1`, `CP15_ID`, `CP15_CTYPE`):

- c0 reads the main ID 0x54029252 and cache type 0x05109149 (2-way,
  16-byte lines, 16 KB I, 8 KB D). With TI configuration bit O set the ID
  reads part 0x915, as on QEMU's ti925t. Writes to c0 are ignored.
- c1 control: M, A, C, W, S, R, I and V are writable; bits 6:4 read 1, B
  (bit 7) and the rest read 0. Reset value 0x70, plus V from `HIVECS`.
- c2 TTB, c3 DACR, c5 FSR, c6 FAR: as ARMv4. FSR and FAR change only on
  data aborts (upstream also wrote them on uncached accesses); an external
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
  instruction (upstream: to themselves).

Instruction set (`V4T = 1`):

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

- Write-through pages (C=1, B=0): stores go to memory at once and update a
  line that hits; no allocation on a store miss (upstream treated every
  cacheable page as write-back).
- Single-line D-cache operations (above), used by the Symbian kernel's
  index loops and by drivers for DMA buffers.
- With the MMU on and a cache off, uncached accesses use the physical
  address (upstream put the virtual address on the bus).
- With the MMU off and the I-cache on, instruction fetches are cacheable,
  as on the ARM920T family (upstream cached nothing with the MMU off); data
  accesses stay uncached. The firmware's bootstrap runs this way (control
  0x1272 from its first instructions). Uncached, its flash code took about
  20 clocks an instruction, and its delay loops, which count instructions,
  ran about 15 times longer than on the phone.

Upstream bugs fixed (found by the tests; all configurations):

- Fine page tables were walked with the coarse layout.
- Page faults reported the wrong domain.
- Thumb B with condition 1110 branched (it is UNDEFINED).
- The 011x..1 space (e.g. 0xE7F000F0) decoded as a load instead of
  UNDEFINED.
- An LDM that loads its own base lost the base-restored abort behaviour.
- Conditional long multiplies with S set the flags from the low half.
- SMLALxy was matched with bit 4 = 1, which took STRH Rd, [Rn, #-imm]
  for it.
- The CP15 register array had 14 entries, so writes to c14/c15 went out of
  range; the I- and D-cache line-size parameters were swapped (harmless
  while they are equal).
- A load that misses the D-cache is acknowledged at once and its register
  written when the line arrives; that write took the whole word, so byte,
  halfword, signed and unaligned loads that missed returned the wrong
  value (found by the boot bench: the bootstrap's integrity check reads
  the stored digest with LDRB from flash). The D-cache now keeps the
  load's format with the miss and applies the memory stage's transform.
- An instruction writing a register could issue while an older load to the
  same register was between issue and the D-cache; if the load then
  missed, its background write came last and the older value won. Issue
  now also stalls on a destination that an in-flight load will write
  (found by the cache-on random tests).
- Instruction fetches were permission-checked as User mode whenever the
  data side's LDRT/STRT flag was set; that flag is also undefined (`'x`)
  whenever its pipeline stage is empty. Fetches from privileged-only pages
  therefore aborted while an LDRT/STRT was in flight and at random after
  flushes (found by the boot bench: the kernel took a prefetch abort in a
  privileged-only section). Fetches are now checked in the current mode.
- A cache line write-back could change its address in the middle of the
  burst (found by the bench's bus checker).
- The ALU left its branch-target output undefined (`'x`) when nothing was
  flushed, and the BTB stores it on every confirmed prediction. Quartus
  happened to resolve it to the branch target (the netlist is the same
  after the fix), but in simulation loops mispredicted on every iteration
  and fetched from random addresses (found by the boot bench).
- Thumb LDR/STR Rd, [SP, #imm] subtracted the offset (the ARM form was
  built with U = 0). A store and a load both through SP agree with each
  other, so the tests passed; the kernel stores a local through SP and
  passes its address (ADD Rd, SP, #imm) to a function that reads it, and
  one of its threads then waited for ever (found by the boot bench, by
  comparing instruction traces with the model's).
- For MOV/ADD to PC the pre-decoder kept the predicted PC of an older
  instruction, and the ALU takes MOV/ADD PC as correctly predicted when
  the predicted PC equals the result. A MOV PC, LR whose predictor entry
  held the taken state of another address (no target, so the fetch went
  on) therefore ran the instructions after it whenever that stale value
  was LR, which is what a conditional BL predicted not taken leaves (found
  by the boot bench: a kernel helper returned into the next function).
  The predicted PC is now where the fetch goes next.
- A data-processing micro-op's Rn was decoded without its extend bit, so
  one that read DUMMY0 as Rn read r9 (upstream this hits the ARMv5 BLX
  immediate sequence). It broke the Thumb BL second half that runs alone
  after an interrupt between the halves (found by the full-core boot
  bench: an IRQ split a BL in a user thread, which then branched into
  data, and the kernel restarted). The BL link micro-op made from a Thumb
  branch no longer passes on the branch's bit 34 (its offset shift),
  which is the Rn extend bit position.
- Data accesses were permission-checked in the ALU's current mode, which
  a younger MOVS PC or MSR may already have changed while the access
  waited at the post-ALU stage. A privileged store right before a return
  to user mode was checked as user (found by the full-core boot bench: the
  flash driver's FIQ handler writes the program command through a
  privileged-only section and returns with MOVEQS PC, LR two instructions
  later; the kernel restarted after the permission fault). The check now
  uses the mode carried with the access.

Timing changes (no change in behaviour; the first two cost cycles, see
FPGA resources and timing):

- Registered bus responses: both cache state machines latch the bus
  acknowledge, error and data of an uncacheable access and complete it in
  a new state (UNC_DONE) one cycle later, so that the bus acknowledge is
  not in the same cycle as the pipeline stall. One more cycle per
  uncacheable access.
- A load that missed the D-cache writes its register in a new state
  (UNLOCK_WR) from a latched value instead of straight from the line
  buffer. One more cycle per load miss.
- The cache valid and dirty bits are written one cycle after the tag RAM
  (write-behind), with the reads in that cycle taking the pending write.
- The cache RAMs' last read stage registers the write collision check and
  the write data and chooses after the registers.
- The memory stage rotates, extends and selects load data before its
  register instead of after it.
- Return-address-stack pushes are written one cycle late (the pointer
  moves at once; a pop in that cycle takes the pending value).
- ARMv5/UNDEFINED classification moved from the decoder to the
  pre-decoder, and the alignment check registered one stage early.
- A disabled cache clears its valid bits in every cycle, held or not
  (upstream only when not held), so the late hold from the cache state
  machine no longer drives the clear of every valid flip-flop.
- The D-cache looks at maintenance requests only when it has no access,
  so they are not in the acknowledge-to-stall path; two terms that could
  never be true (upstream's hit-under-miss, which it enabled only with the
  cache off, and a retry for a register that cannot be locked in that
  state) were removed from the tag-compare path.

## Differences from a real ARM925T

Functional:

- Replacement is the TI925T's fixed LRU (TI SPRU671; the control
  register's RR bit reads zero), one bit per set. Index operations take
  the TI operand (set in bits 11:4, way in bit 31): with TI configuration
  C clear they act on both ways of the set, with C set on the named way.
- No cache lockdown (c9 reads 0, writes ignored).
- Turning a cache off invalidates it (ZAP clears the valid bits while the
  cache is disabled). Dirty D-cache lines are lost if the D-cache is turned
  off without cleaning it first; the ARM925T keeps them.
- Write-back store misses allocate in ZAP. The TI925T is read-allocate:
  store misses bypass the cache even in copy-back mode (TI SPRU671,
  Table 1). Write-through store misses already bypass allocation here.
- No posted write buffer: uncached and write-through stores wait for the
  bus response, and the CP15 drain operation is a no-op. The phone enables
  its 17-word buffer with CP15 W. A faithful posted path also needs drain,
  memory ordering and fault handling, not just a store-miss bypass; see
  [the write-allocation analysis](consults/2026-10-23-codex-walloc-report.md).
- TLBs are direct-mapped per page size instead of the ARM925T's
  associative TLBs, and TLB lockdown has no effect.
- An external abort on a cacheable line fill or write-back is ignored (the
  line is filled with the data returned). External aborts on uncached
  accesses and table walks are reported.
- The value stored by STR and STM for the PC is the instruction address +
  8 (as QEMU). This is IMPLEMENTATION DEFINED; the ARM7TDMI and, most
  likely, the ARM9TDMI store + 12.
- Other UNPREDICTABLE cases follow ZAP, not the ARM9TDMI: LDM/STM with an
  empty register list, STM with writeback and the base in the list but not
  first, misaligned LDRH/LDRSH with A clear (not rotated as on the
  ARM7TDMI), register-specified shifts with the PC as an operand (not
  + 12), data-processing tests with Rd = 15 (no mode change). These are the ARM7TDMI-specific
  checks of gba-tests that are skipped (Verification).
- Instruction fetch runs further ahead: ZAP fetches along predicted paths
  and up to its 16-word buffer, the ARM9TDMI only the next two
  instructions. With the I-cache off (or an uncached code page) these
  fetches reach the bus, so memory past the end of the executed code can
  be read. Harmless for memory; a read-sensitive device register would
  have to sit right after uncached code to be affected.
- No CP14 (debug communications channel): its MRC/MCR are UNDEFINED. No
  EmbeddedICE, JTAG or ETM.
- Big-endian mode is not available (B reads 0).

Timing (instructions take ZAP's cycle counts, not the ARM9TDMI's):

- The pipeline is 17 stages, not 5: a mispredicted or unpredicted branch
  costs 12 cycles (ARM9TDMI: 2-3), a correctly predicted taken branch 3,
  not taken 1. A state change (BX between ARM and Thumb) 12, exception
  entry and return about 18.
- Most other instructions take one cycle; multiplies 4 (+1 if the result
  is used at once; ARM9TDMI: 2-5 by operand size); LDM/STM one cycle per
  register; load-use interlocks differ.
- A load miss does not stall until the register is used; a line is
  fetched in full before the next access to the cache; an uncached store
  stalls until the bus acknowledges it (no write buffer).
- CP15 operations wait for the pipeline to empty and refetch afterwards.
- Interrupt latency is ZAP's (synchroniser + pipeline drain).

In short, with caches on ZAP runs ARM code at a similar or higher rate per
clock than an ARM9TDMI; branchy and Thumb-switching code runs slower.

## Verification

Everything runs on the Verilator machine (`ubuntu`, Verilator 5.032);
binaries are assembled on the Mac. `make -C sim/cpu all` builds the tests,
runs them on the RTL (`remote`) and on QEMU (`qemu`), and compares
(`diff`). Results land in `sim/cpu/build/`.

### Bench

`sim/cpu/tb/tb_cpu.sv` instantiates the wrapper (the generated netlist by
default, `RTL=sv` for the SystemVerilog) with probes into the writeback
stage. `sim/cpu/tb/main.cpp` provides 16 MB of RAM at 0, 64 KB at
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
  named way. Both fail on a direct-mapped build (`VEXTRA=-GICACHE_WAYS=1`,
  `-GDCACHE_WAYS=1`).
- `iprefetch_rtl`: the I-cache prefetch: sequential code over 32 lines
  (cold, warm, backward; an execution-bound variant), a branch away from a
  prefetched line, the I-cache invalidates (all and by MVA) with code
  rewritten behind the buffer, and sequential code across a 4 KB page end
  into a page mapped elsewhere (poison at the contiguous address) and up to
  an unmapped page. Exact results, loose cycle shape; passes with and
  without `-GICACHE_PREFETCH=0`.
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

- `make -C sim/cpu boot-prep` builds the images from git HEAD's model
  files: the NOS stand-in assembled, `model/rom-patches.txt` applied as the
  model applies it, and the integrity digests computed through the
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
time it changes, the HLE audio output as a WAV, the kernel's STI text,
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

- Default regression (`make -C sim/cpu all`): 57 tests (21 directed, 32
  random, 4 gba-tests) at 3 bus latencies, 171 RTL runs, all pass. The 49
  that QEMU can run (15 directed, 32 random, `gba_arm_q`, `gba_thumb_q`)
  agree with it in signature and instruction by instruction.
- Random seeds 1-100 of all four kinds (400 programs): all pass on the RTL
  and agree with QEMU (seeds 1-40 rerun after the Thumb BL and permission
  fixes).
- The same regression on the SystemVerilog sources (`RTL=sv`) gives the
  same results, which checks the sv2v conversion.
- gba-tests: 161 of 183 ARM and 101 of 109 Thumb tests pass on the RTL; the
  QEMU-comparable subsets match QEMU over 1144 and 712 instructions.
- Boot code (`make -C sim/cpu boot-prep boot-model boot`; the RTL run is
  2.7 billion cycles, about an hour on the server): from the same images
  the RTL makes every device access the model makes, in the same order and
  with the same values, 76,975 of them (only the timers' free-running
  counters read differently, by a few ticks), through the bootstrap, the
  kernel start, the NOS stand-in, the LCD and MMC driver start-up and the
  RTC, up to the model's last one at 581 million instructions; after it
  both wait (in this configuration: no card, no key presses). The register
  logs (61 entries), the CBUS logs (79 transfers), the MMC log and the
  kernel's debug text are identical, and the instruction numbers of the
  accesses stay within about 40 of the model's. Running it found six of the
  bugs listed above: the four found earlier, then the Thumb SP-relative
  offset and the predicted PC of MOV/ADD PC (each by comparing an
  instruction window with the model's around the first difference). It
  also showed what the bench lacked: the keypad ports, the RTCs of the
  current model, the MMC host, and instruction counting as QEMU's icount
  does (an SWI or undefined instruction counts, a Thumb BL pair counts
  once), without which the bench's guest time drifted from the model's.
  The cycle count says nothing about the phone's speed: the bench answers
  the bus with zero wait states.

## FPGA resources and timing

Standalone trial in Quartus 17.0.2 Lite (`sim/cpu/quartus/run.sh` for one
compile, `sim/cpu/quartus/sweep.sh` for a fitter-seed sweep, on the build
server in Docker): `cpu_trial.v` registers every input and every bus
output to pins, so nothing is optimised away; same device (5CSEBA6U23I7)
and fitter settings as `NGage.qsf`; 104 MHz (9.615 ns).

- Resources (seed 1): 12,637 ALMs (30% of 41,910), 13,978 registers, 58
  M10K blocks (303,732 bits: cache data and tags, TLBs, branch predictor),
  4 DSP blocks (the multiplier). Other seeds are within 1%.
- Worst setup slack at 104 MHz over eight fitter seeds (slow 100C / slow
  -40C corner): seed 1 +0.335 / +0.357 ns, seed 2 +0.434 / +0.580, seed 3
  +0.325 / +0.326, seed 4 +0.602 / +0.768, seed 5 +0.659 / +0.721, seed 6
  +0.250 / +0.338, seed 7 +0.200 / +0.531, seed 8 +0.371 / +0.376. Every
  seed closes at every corner, with 0.20 ns or more; the fast corners have
  about 4 ns to spare, and hold slack is at least +0.09 ns. Placement
  alone moves the worst slack by about ±0.3 ns: a netlist one constant bit
  different (before the Thumb SP fix) gave between -0.095 and +0.808 ns
  over the same seeds.
- Before the timing changes (commit 1e4010a) the same four seeds gave
  +0.317 / +0.379, -0.124 / +0.191, -0.239 / -0.294 and +0.049 / +0.137:
  ZAP stalled every pipeline stage in the same cycle as the D-cache
  decided an access, and the worst paths ran from the bus acknowledge,
  the TLB result or the cache state machine through the stall into the
  front end, or through the cache RAMs' write forwarding. Each change in
  "Timing changes" above removed the worst path family of at least one
  seed. The worst paths left (0.20-0.77 ns) are spread over the issue
  stage (the register read for the shift operand and the interlock), the
  TLB result into the front end and the D-cache RAMs, and the decoder
  (pattern match and register renaming into the operand registers). None
  dominates; more margin would take one of them each, for example
  classifying the instruction in the pre-decoder.
- Cost in cycles: one more cycle per uncacheable access and per load that
  misses the D-cache; the other changes cost nothing. On the boot bench
  (zero wait states, so the worst case): the bootstrap, which runs
  uncached from flash, takes 21% more cycles (5.8 to 7.1 cycles per
  instruction); with the MMU and caches on (the integrity checks) 6% more
  (2.39 to 2.54); the kernel with caches on the same (1.57 to 1.56 and
  2.12 to 2.12 cycles per instruction over 110-290 million instructions).
  The bench tests, mostly uncached: +12% at zero wait states, +5% at 0-3
  and +4% at 2-9 wait states (directed tests); `cache` (cached loops with
  misses) +5%, +3%, +2%.
- History: upstream ZAP with every output observed missed by 0.448 ns
  (about 99 MHz). Moving the ARMv5/UNDEFINED classification to the
  pre-decoder, registering the alignment check, taking the cache
  maintenance requests out of the acknowledge path and removing two terms
  that could never be true kept the ARM925T changes and the bug fixes at
  about the same speed; the changes above then made 104 MHz close.

### In the whole core

Full compiles of `NGage.qsf` on the build server
(`tools/quartus_seeds.sh TAG "SEEDS"`, two at a time in Docker; Quartus is
deterministic, so a seed's result repeats):

- With the CPU added and nothing else changed, two seeds missed 104 MHz by
  1.3 and 1.8 ns, mostly outside the CPU: the memory-test master select
  straight from hps_io, the NOR flash command decode, upp_bus's read data
  register packed into an audio DSP block.
- After the core-side changes (commits cd98c10, c330d6e, b9a38da, 5f2f8ad:
  a registered master select, the flash's two-clock decode, the audio
  products after local registers, the flash pop without an adder, the
  valid-bit clear without the hold, the memory system's request paths, the
  SDRAM output stage), three of four seeds closed (c12). The CPU fix for
  the data-side permission mode changed the netlist again; of seeds 1-6
  then (c13, c14), seeds 3 and 5 meet 104 MHz at every corner, and seed 5,
  with more margin, is the one in `NGage.qsf`: setup +0.074 ns (slow
  100C), +0.089 ns (slow -40C), +3.06 / +3.66 ns (fast); hold +0.089 ns or
  more; recovery and removal positive. The others missed by 0.08-0.26 ns.
  The worst paths move between families from seed to seed (the CPU's
  stall and issue paths, the D-cache tag forwarding and fill, the CPU's
  bus registers into upp_bus), each within about 0.3 ns now. The build
  date is part of the netlist (build_id.v), so a rebuild on another day
  can land elsewhere.
- Resources (seed 5): 30,578 ALMs (73% of 41,910), 38,702 registers, 314
  M10K blocks (2,265,832 bits), 43 DSP blocks, 3 PLLs. The CPU is about
  12,600 ALMs of that.
- `MISTER_DISABLE_YC` and `MISTER_DISABLE_ALSA` saved about 200 ALMs and
  did not help timing; Physical Synthesis effort Extra gave a bit-identical
  result in the Lite edition, and LogicLock regions need a subscription
  licence. None of these is used.

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
   ARM9TDMI time. ZAP is faster on most code, so it mainly waits; where it
   is slower (mispredicted branches) the debt is paid back later. The
   peripherals see accesses at times close to the real phone's.
3. Real cache geometry: done, both caches 2-way with LRU, so that hit
   rates (and so the time between bus accesses) match and the index
   operations address real ways. Still unlike the part: a store miss
   allocates a line here, and a cache turned off loses its contents.
4. Measure against the model and known firmware timing loops (the boot's
   delay loops, the kernel's tick calibration), then tune.

## Remaining gaps

- In the whole core 104 MHz closes with little margin (+0.07 ns on the
  seed in use, two seeds in six). The next changes would take the
  CPU's issue-stage register read and the D-cache's stall into the
  pipeline one stage earlier.
- Direct-mapped caches; no cache or TLB lockdown; cache disable discards
  the D-cache contents; external aborts on line fills are lost.
- Stored PC is + 8 (probably + 12 on the ARM925T).
- Cycle timing is ZAP's (see the plan above).
- The pre-decoder's return pattern for MOV PC, LR has Rm = 15 (upstream),
  so MOV PC, LR is predicted from the BTB, not the return-address stack:
  slower returns, no wrong results.
