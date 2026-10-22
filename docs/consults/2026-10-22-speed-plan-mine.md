# My own speed plan, 2026-10-22 (written before the Codex consultation)

Drafted before the counters ran and revised after the trace; kept out of the Codex brief so the two plans are independent.

# The speed question: my own plan (drafted before any Codex consultation)

Written 2026-10-22 before the counters have produced numbers; to be refined
with them, and kept out of the Codex brief.

## What I think is going on

1. The 150 s boot is mostly waiting, not computing. The firmware's start-up
   talks to the cellular side through the stand-in, which answers a fixed
   set of requests and leaves a dozen unanswered; EKA1 servers time out on
   those, and the Bluetooth driver's retries are the visible part. If the
   idle counter reads high during the boot, this is confirmed and the boot
   time says nothing about CPU speed.
2. In games the CPU-side loss is ZAP's pipeline, not the memory: the
   load-use lock of several cycles (the ARM9TDMI's is 1-2), the 12-cycle
   mispredict, the uncached store that waits for the acknowledge (the
   ARM925T has a write buffer, we have none). Expect 1.6-2.0 cycles an
   instruction on game code against the ARM9TDMI's 1.3-1.5.
3. The memory side may be roughly even. Our flash path has an 8 KB
   second-level cache in DDR3's front (ddram_flash) and answers a line in
   36-53 clocks; the phone's NOR chips run asynchronous or burst reads at
   the 34.67 MHz flash clock, which is 7-9 CPU clocks a halfword or a
   burst of 8 in about 45. Unknown until the bootstrap's EMIF writes at
   0x08000000 are decoded.

## Measurement protocol

- Scenes: idle screen; the Sonic N title and Neo Green Hill; Alien Front's
  Mufthasa Base; Asphalt's first race; Tony Hawk's Warehouse; Shadowkey's
  first room. Ten seconds each, captures every two seconds, overlay on.
- From the rows: frames/s and pixels/s (compare with the model's logged
  rates: Sonic 30, Rayman 21.3, Sega Rally 12.8, Alien Front 16.8, Tony
  Hawk's 27.8, Asphalt 20.5); cycles an instruction = (104 M - idle) /
  retired; wait fraction by target; average wait a beat = waits / beats.
- Same scenes with a capture every two seconds and with none for twenty
  seconds (one capture at the end) for the Zaparoo question.
- Boot: idle % per second from the Nokia logo to the dialogs.

## Reference without a phone

- Decode the bootstrap's memory-controller writes (the EMIF block at
  0x08000000 is plain storage in the core; dump it after boot from the
  model or the trace) and the flash burst configuration (555/C0) against
  the OMAP5910 EMIFS/EMIFF register layout, which the UPP_WD2 appears to
  share: wait states, burst mode, SDRAM CAS latency and clock divider.
  That gives the phone's memory timing to compare with ours.
- The ARM9TDMI cycle table from the TRM for the pipeline side.
- The model at icount shifts 4, 5, 6 (62.5, 31, 15.6 MIPS) to find each
  game's frame-step thresholds, so a measured instruction rate maps to a
  frame rate without a phone.

## Candidate changes, cheapest first, all behaviour-neutral

1. A write buffer at the D-cache's uncached and write-through path (4-8
   entries, drained in order; the ARM925T has one): removes the store
   stall. Also accuracy-positive, since the real part has it. Verification:
   the CPU benches (same instruction traces, fewer cycles), the boot bench.
2. A read-array fast path for flash line fills: when the chip is in
   read-array mode, upp_bus fetches the 16-byte line as beats straight
   from ddram_flash's cache instead of one halfword a chip access. Expect
   a line in 10-20 clocks instead of 36-53. The chip's command decode
   stays for everything else.
3. SDRAM open page: keep the row open across consecutive accesses to the
   same row and bank (closed-page today); a line read's first word in 5
   clocks instead of 8 on a row hit. Bank interleave later if waits remain.
4. MOV PC, LR through the return-address stack (the docs note it is
   predicted from the BTB): cheaper returns; small, timing risk in the
   pre-decoder.
5. Load-use forwarding in ZAP's issue stage: the big lever and the risky
   one, in a worst timing path; only with a measured CPI above 1.8 and the
   memory side clean.

Decision gates: if 3D games show idle under 5 % and frame rates below the
model's, the core is CPU-bound and items 1-3 go in order of the wait
fractions; if idle is high, games pace themselves and nothing is needed
for speed. If the phone's decoded memory timing is slower than ours, the
pipeline side is the whole gap and only 1, 4 and 5 matter.

## Revision after the counters and the trace (2026-10-22, before Codex)

The measurements overturned the draft: the memory is not slow, the
caches are not off, and the pipeline's base CPI is not the problem. The
boot's 93-second phase is exception-heavy kernel traffic where every
system call pays for two page-table walks (the vectors page at VA 0 and
the kernel code page at 0x50320000 share small-page TLB slot 0, 16
entries indexed by VA[15:12]) and the kernel's cache-flush loop pays a
38-clock pipeline drain per CP15 operation. The 48-second phase is the
idle thread spinning in the stand-in's service 13 while something times
out (the Bluetooth stack's CBUS, -33).

Plan, in order of gain per effort, all behaviour-neutral:

1. TLBs: 256-entry small-page and 64-entry section TLBs (both sides),
   indexed by VA[19:12] and VA[25:20], in M10K instead of registers; one
   RAM read and one compare as now, so timing-neutral. Removes the walks
   from the exception path entirely; expect the kernel phase's SDRAM
   traffic to fall by an order of magnitude. Verify: the walk pairs gone
   from the bus ring, bus wait % down, the CPU benches and boot bench
   unchanged in results.
2. CP15 without the drain for the operations that do not change the
   MMU's view: c7 cache maintenance by index/address, c3 DACR reads,
   c13 PID reads, c0 reads. Keep the drain for c1, c2, c3 writes, c8,
   c13 writes. A clean-by-index then costs its own cache cycle. Verify
   on the CPU benches (the cache tests) and the boot bench.
3. The idle service: make the stand-in's service 13 execute a real WFI
   (c7, c0, 4) so the idle thread sleeps; then the idle counter means
   something, and find what the 48 s waits for by the kernel text with
   timestamps (add a wall-clock tag to each STI line in dbg_sti). If it
   is the Bluetooth stack's CBUS timeouts, make the stand-in refuse the
   HCI open at once instead of letting it time out.
4. The I-cache's conflict between VA 0 and the kernel's first lines: a
   victim buffer of a few lines, or 2-way for the code side only, later.
5. SWI entry/return cost (68 + 12 clocks): the exception entry's drain
   and the return's mispredict; the return-address stack for `movs pc`.
   Later, with the CPU benches, only if the kernel phase is still slow
   after 1-2.
