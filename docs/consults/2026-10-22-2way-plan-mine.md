Kept out of the Codex brief so the two plans are independent.

# Two-way caches: my own plan (drafted 2026-10-22, before any Codex consultation)

Goal: the ARM925T's cache geometry, 16 KB I-cache and 8 KB D-cache, 2-way
set-associative, 16-byte lines, so that hit rates and the meaning of the
firmware's index operations match the part. The measured reason it matters:
the kernel at 0x50321xxx and EUser at 0x503A1xxx collide at the same
direct-mapped index (VA[13:4]) on every system call, and after the TLB fix
those refills are 71 % of the bus beats in the kernel phase.

## What ZAP has (rtl/cpu/zap/zap_cache_tag_ram.sv, zap_cache_fsm.sv)

One tag RAM (zap_ram_simple, DEPTH = lines) and one data RAM
(zap_ram_simple_ben, line-wide, byte enables) per cache, indexed by
VA[13:4] (I) / VA[12:4] (D). Valid and dirty bits are registers with a
three-deep forwarding chain against the tag RAM's write (fwd_st*). The hit
is one compare of the tag RAM's registered output with the delayed line
address; the FSM takes the data from the data RAM output by lane. The
clean/invalidate-by-index operations decode the ARM925T's (set, way)
encoding (set from bit 4, way in bit 31; with TI configuration C clear
both lines of the set) onto the single line with that index today.

## Design

1. Two ways as two tag RAMs and two data RAMs of half depth (I: 2 x 512
   lines, D: 2 x 256), both read with the same set index (VA[12:4] for I,
   VA[11:4] for D). Tags gain one bit.
2. Hit: two compares in parallel, hit = hit0 | hit1. Data: a 2:1 mux on
   the data RAM outputs selected by hit0. That is one more level on the
   data path and an OR on the hit path; everything else as now. If the
   fitter cannot close it, the fallback is to register the way-hit and
   take the data a cycle later, which costs a cycle on every hit and is
   the accuracy trade I would rather not make.
3. Replacement: per set, one round-robin bit (toggled on each fill into
   the set) when the set is full, else the invalid way. The ARM9 family's
   control register bit 14 selects round-robin (1) or random (0); the
   firmware's setting of it to be read from the trace of the CP15 c1
   write at boot and the TRM consulted for the ARM925T's default. A
   random option is a 1-bit LFSR, trivial to add if the firmware clears
   the bit.
4. Fills: the chosen way's tag and data written as today, the other way
   untouched. Valid/dirty bits and the forwarding chain per way.
5. Index operations: (set, way) from bit 4 and bit 31 map directly onto
   the two ways; with configuration C clear both ways of the set, as the
   docs describe; the whole-cache clean loops of the kernel then do what
   they do on the part.
6. D-cache: the same structure plus the dirty bit per way and the
   write-back of the victim way on a fill; the tag RAM's forwarding
   doubles. Do the I-cache first (no dirty state, the measured problem),
   then the D-cache with the same shape.
7. Resources: the same bits of M10K as now (half depth, twice the RAMs),
   one more tag bit, a few hundred ALMs for the second compare, the mux
   and the round-robin bits (512 + 256 flops, or a small RAM).

## Verification

- The CPU benches with the cache tests and the random tests (both
  cache-on and cache-off), the cache-maintenance tests: results must be
  identical to today's; cycle counts may change (fewer misses).
- The boot bench to the clock before/after.
- A Quartus trial of the CPU alone (sim/cpu/quartus) for the timing cost
  before the whole-core build.
- On hardware: the trace at 130 s after the CPU start, expecting the
  kernel/EUser flash refetches to drop by most of the 71 %.

## Order

I-cache 2-way first; measure; then the D-cache. Before either, the flash
cache enlargement (already built) tells how much the conflicts still cost
when a miss is cheap, which bounds the gain.
