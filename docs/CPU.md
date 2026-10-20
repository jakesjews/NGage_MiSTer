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
  geometry in bytes.

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

- Caches: direct-mapped, virtually indexed and tagged, write-back with
  write allocate (and write-through per page, below), 16-byte lines here.
  The D-cache keeps each line's physical address, so cleaning needs no
  table walk.
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

Timing-only changes (no change in behaviour):

- ARMv5/UNDEFINED classification moved from the decoder to the
  pre-decoder, and the alignment check registered one stage early.
- The D-cache looks at maintenance requests only when it has no access,
  so they are not in the acknowledge-to-stall path; two terms that could
  never be true (upstream's hit-under-miss, which it enabled only with the
  cache off, and a retry for a register that cannot be locked in that
  state) were removed from the tag-compare path.

## Differences from a real ARM925T

Functional:

- Caches are direct-mapped, not 2-way set-associative, so the hit rate and
  which line an index operation touches differ. Index operations map (set,
  way) to the line with that index and way bit (index bit 8 = way): with
  TI configuration C clear they act on both lines of the set, with C set
  on the line the way bit selects. Code that cleans or flushes whole caches
  by index loops (as Symbian does) is unaffected.
- No cache lockdown (c9 reads 0, writes ignored).
- Turning a cache off invalidates it (ZAP clears the valid bits while the
  cache is disabled). Dirty D-cache lines are lost if the D-cache is turned
  off without cleaning it first; the ARM925T keeps them.
- No write buffer: stores complete in order on the bus, and drain is a
  no-op. Software cannot tell, apart from timing.
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
- `thumb`: every Thumb format, interworking, BL, SWI and UND from Thumb.
- `cp15`, `v5und`, `align`, `rtl_misc`: CP15 as the firmware uses it, the
  ARMv5 instructions that must trap, alignment faults, and ARM925T details
  QEMU does not model (control register read-as values, PID masking,
  rotated unaligned loads, high vectors, the lone Thumb BL suffix, wait for
  interrupt).
- `mmu_sect`, `mmu_page`: sections, coarse and fine tables with all page
  sizes, domains, permissions with S and R, user-mode accesses, every fault
  type with FSR and FAR, prefetch aborts, LDRT/STRT from a privileged-only
  code section.
- `cache`, `cache_rtl`: 64 KB through the 8 KB D-cache (evictions and
  write-backs), bytes and halfwords in cached lines, loads of every size
  and unaligned loads that miss, LDM/STM across lines,
  clean and flush by VA and by index with uncached aliases, write-through
  pages, self-modifying code; and what only the RTL can show (dirty data
  stays in the cache until cleaned, line operations touch only their line,
  the I-cache keeps old code until flushed).

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

`make -C sim/cpu boot` runs the N-Gage boot code from the CS0 image on the
RTL. `sim/cpu/tb/ngage.h` gives the bench the reference model's memory
map and the devices the boot uses, ported from `model/hw`: both NOR flash
chips (AMD command set), SDRAM, on-chip RAM, the emif and upp register
blocks as storage with `model/upp-quirks.txt`, the interrupt controller and
timers, the CBUS master with the UEMK registers of `model/cbus-regs.txt`,
the LCD interface's panel ID and status reads, and the STI window, whose
kernel debug text goes to `kern.log`. `sim/cpu/boot/prep.py` patches the
images as the model does (`model/rom-patches.txt`, with the integrity
digests computed through the bootstrap's ROM map). The register blocks log the first read and write of every
register as the model's `regs.log` does, the CBUS logs every transfer as
the model's `cbus.log` does, and `sim/cpu/boot/cmp_regs.py` compares each
pair entry by entry (address, size, value, PC). `--watch ADDR` prints the
registers whenever an instruction retires at ADDR, and `--dump` writes
memory at the end.

### Results

- Default regression (`make -C sim/cpu all`): 53 tests (17 directed, 32
  random, 4 gba-tests) at 3 bus latencies, 159 RTL runs, all pass. The 48
  that QEMU can run (14 directed, 32 random, `gba_arm_q`, `gba_thumb_q`)
  agree with it in signature and instruction by instruction.
- Random seeds 1-100 of all four kinds (400 programs): all pass on the RTL
  and agree with QEMU.
- The same regression on the SystemVerilog sources (`RTL=sv`) gives the
  same results, which checks the sv2v conversion.
- gba-tests: 161 of 183 ARM and 101 of 109 Thumb tests pass on the RTL; the
  QEMU-comparable subsets match QEMU over 1144 and 712 instructions.
- Boot code (`make -C sim/cpu boot`, about 770 million cycles to the
  kernel, 20-30 minutes): the whole bootstrap matches the model: its 32
  register accesses, the CBUS traffic to the UEMK (including the battery
  ADC), the flash ID and CFI probes, and both MD5 integrity checks over
  19.6 MB of flash with the MMU and caches on. The kernel starts, enters
  the NOS stand-in, and matches the model for 23 more register accesses and
  67 CBUS transfers in all; its first debug text is the model's. Running it
  found four of the bugs listed above. Earlier differences came from the
  bench's devices (the LCD ID, the power key timing), not the CPU. At 2.5
  billion cycles the kernel is running but makes no more device accesses
  where the model goes on with CBUS device 5 and an emif read; whether it
  waits for a device or interrupt the bench lacks is not known yet. The
  next step is an instruction trace from the model around that point.

## FPGA resources and timing

Standalone trial in Quartus 17.0.2 Lite (`sim/cpu/quartus/run.sh`, on the
build server in Docker): `cpu_trial.v` registers every input and every bus
output to pins, so nothing is optimised away; same device (5CSEBA6U23I7)
and fitter settings as `NGage.qsf`; 104 MHz (9.615 ns).

- Resources (seed 1): 13,217 ALMs (32% of 41,910), 14,038 registers, 57
  M10K blocks (303,604 bits: cache data and tags, TLBs, branch predictor,
  register file), 4 DSP blocks (the multiplier). Other seeds are within
  ±1%.
- Worst setup slack at 104 MHz over four fitter seeds (slow 100C / slow
  -40C corner): seed 1 +0.317 / +0.379 ns, seed 2 -0.124 / +0.191, seed 3
  -0.239 / -0.294, seed 4 +0.049 / +0.137. The fast corners have about 4 ns
  to spare. So the CPU sits at 104 MHz give or take 0.3 ns: about 101 to
  107 MHz depending on placement. With seed 3, the worst, constrained
  for 100 MHz: +0.156 / +0.006 ns; for 96 MHz: +0.732 / +0.719 ns.
- What limits it: ZAP stalls every pipeline stage in the same cycle as the
  D-cache decides an access (hit, bus acknowledge or error on an uncached
  access, TLB walk busy). The worst paths run from the bus acknowledge or
  error input, or from the TLB walker state, through the D-cache
  acknowledge to `data_stall` and on into the pre-decoder and the micro-op
  sequencer, or through the issue-stage load interlock. They are mostly
  routing between distant parts of the core.
- History: upstream ZAP with every output observed missed by 0.448 ns
  (about 99 MHz). Moving the ARMv5/UNDEFINED classification to the
  pre-decoder, registering the alignment check, taking the cache
  maintenance requests out of the acknowledge path and removing two terms
  that could never be true kept the ARM925T changes and the bug fixes
  (which add logic to the issue interlock and the D-cache) at about the
  same speed. A write-behind for the cache valid and dirty bits was tried
  and reverted: no measurable gain over four seeds.
- Recommendation: plan for a CPU clock of 96 MHz (clk_sys at 96 MHz, or the
  CPU on its own 96 MHz clock with a crossing to the memory system) until
  the full core shows that 104 MHz closes there. Running at 104 MHz needs
  either a lucky seed or the fix below. Since ZAP retires more ARM
  instructions per clock than an ARM9TDMI on cached code, 96 MHz is not
  slower than the phone for most code, and the timing-fidelity pass
  (below) throttles it anyway.
- The fix for 104 MHz with margin: give the stall a cycle. Register the bus
  acknowledge and error inside the cache state machines (one more cycle per
  uncached access or line beat) and the TLB walker's busy flag, so that
  `data_stall` depends only on the tag compare; then duplicate the stall
  per stage. This is a pipeline change in ZAP's memory stages and needs the
  full regression and the boot bench again.

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
3. Real cache geometry: make the I and D caches 2-way with the ARM925T's
   replacement policy (to be confirmed from the TRM), so that hit rates
   (and so the time between bus accesses) match, and the index operations
   address real ways.
4. Measure against the model and known firmware timing loops (the boot's
   delay loops, the kernel's tick calibration), then tune.

## Remaining gaps

- 104 MHz closes standalone on some fitter seeds and not others (±0.3 ns);
  96 MHz is the safe CPU clock until the stall is retimed (see above).
- Direct-mapped caches; no cache or TLB lockdown; cache disable discards
  the D-cache contents; external aborts on line fills are lost.
- Stored PC is + 8 (probably + 12 on the ARM925T).
- Cycle timing is ZAP's (see the plan above).
