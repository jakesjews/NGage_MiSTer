# The plasticbugs N-Gage core for the Analogue Pocket, read on 2026-10-23

https://github.com/plasticbugs/n-gage (SystemVerilog, started 2026-10-17,
v1.0.0 on 2026-10-23, no licence file). Read for insights; nothing copied.

## What it is

Not a reconstruction of the phone. "NGVM": a custom ARMv4T CPU in
gateware (eight stages, a 256-entry BTB answering in the fetch cycle,
64 KB instruction and data caches, 80 MHz on its own PLL, about 5,000
ALMs on its own), a page table, an LCD, a timer, keys and an audio FIFO,
and a small C kernel (`sw/kernel`) that replaces EKA1 and every driver:
only the firmware's user side runs (the Symbian exec calls are
implemented by the kernel, `docs/eka1_exec.md`). The firmware is the
retrobios `SYM.ROM` (18,612,224 bytes, md5 64a95a4a884cf4cc15a566b856603193,
"the ROM as linked at 0x50000000"), the games are 32 MB FAT drive images
built from a game's files (`mkdrive.py`). Verified in lockstep with
Unicorn instruction by instruction; the whole machine simulated on the
Pocket's memory glue. Not implemented: saving, sleep, the link port,
pausing; the phone's own kernel, drivers, flash, modem and file system
are not there at all (loads come from a drive in CRAM).

## Their measurements worth having

- The phone's own speed: an ARM9TDMI-class core at 104 MHz with no
  branch prediction (taken branches 3 cycles, load-use 1, LDM/STM a
  register a cycle) delivers "roughly 45-50 MIPS, not 100" once cache
  misses are counted. Our core runs the games at 29-31 M instructions/s
  (CPI 3.4 at 104 MHz): about 60-65 % of the phone, which matches our
  frame rates (Asphalt 13-14 of 21).
- Busy MIPS the games want, at a 100 MIPS reference: Puzzle Bobble 12.6,
  Bomberman 16.9, Snakes 20, Puyo Pop 33, Super Monkey Ball 33, Sonic N
  60 (peak 97), Virtua Cop 68-93. The 3D games render as fast as the CPU
  allows. X-Men Legends II panics (ViewSrv 11) below about 45 MIPS: its
  frame object outruns the view server; Puyo Pop's sound needs more than
  about 29 MIPS. Both are tests for our core (x-men-legends is on the
  MiSTer).
- Their CPI in play with memory: 1.68-1.9 (Virtua Cop, Tony Hawk) at
  80 MHz, with a line costing 36 CPU clocks and the first word at 13
  (their memory path is slower than ours: 12-15 clocks a line). The
  difference to our 3.4 is the pipeline and the caches, not the bus.
- Their cache model on gameplay traces: I-cache 16 -> 32 KB -5.8 % cycles
  (Virtua Cop) / -2.5 % (Tony Hawk); a store miss completing once its fill
  is on the bus a further -3.7 % / -5.3 %; D-cache 16 -> 32 KB -2.7 % /
  -3.6 %; four ways -0.8 %; a next-line D prefetch +3.7 to +6.5 % (loses:
  45 % of prefetched lines unused, each holding the bus); write-validate
  -0.5 % (not worth it). On the RTL: I 64 KB +5.2 % / +2.4 %, BTB 512
  +1.2 % / +0.6 %, D 64 KB +1.7 % / +3.7 %. Our own board numbers agree
  in shape (the I-cache 32 KB +1 %, the D-cache 16 KB +1-3 %, the I
  prefetch nothing).
- Branch prediction on their pipeline: no BTB 0.63-0.83 cycles lost per
  instruction; a 256-entry BTB answering in the fetch cycle 0.15-0.20; the
  same BTB one cycle late 0.26-0.34; 1,024 entries 0.11-0.14. The cost of
  the late answer, 0.1-0.14 CPI, is the slot our predicted taken branches
  still lose.
- Their timing closure: the CPU alone synthesised first (as ZAP was),
  six stages 61 MHz, eight stages 90 -> 96 MHz through seven rounds
  ("one rotator for every shift" met 96 at one seed; three other seeds
  -0.66 to -0.98: "one seed is not a measurement"); they settled at
  80 MHz for the whole core.
- Firmware needs they found (`docs/hardware.md` 8): NOSDRIVER's energy
  management replies (charger not connected, battery 7 bars) are needed
  by Xanadu Next and System Rush; our stand-in answers both
  (model/nos-stub/nos_isi_replies.h, resource 0x17 messages 0x08 and
  0x0A). The file server's priority 750 and a start-a-server race they
  worked around in their kernel; ours runs the real kernel.

## What we can use

1. **A store miss completes once its fill is launched** (the data is
   already merged into ZAP's fill buffer): -4 to -5 % cycles in their
   model, a contained D-cache FSM change with hit-under-miss's exclusions
   already there. And the dirty victim's write-back overlapped with or
   deferred behind the fill (a write-back buffer) instead of before it:
   about 300 K dirty misses a second at about 10 clocks each on our
   board, 2-3 %. Both for the Codex D-cache thread after timing round 5.
2. **The BTB's remaining lost slot** on a predicted taken branch: their
   numbers put it at 0.1 CPI; it conflicts with the predecode cone that
   is our critical family, so it is a timing-round decision.
3. **The firmware input**: the retrobios `SYM.ROM` is the file the
   community has (their users and EKA2L1's). If it is the ROM region as
   linked (CS0 and the CS1 firmware half in ROM order), our in-core
   loader or mkimage's flat mode can accept it as a third input beside
   the Phoenix files; to be checked against our own ROM-order image
   (research/firmware/images/nor/rh29-4.60-symrom-from-fls.bin,
   18,284,544 bytes: 320 KB shorter, so not identical as a file).
4. **Tests**: X-Men Legends (the panic below 45 MIPS) and Puyo Pop's
   sound on our core; Virtua Cop as a benchmark game if a dump exists.
5. **The big picture**: their custom pipeline reaches CPI 1.7 at 80 MHz,
   about 47 M instructions/s, against ZAP's 30 at 104. Our ARM9-style
   core (paused at -7 ns at 104 MHz) is the same road; their data says
   a deeper pipeline with a same-cycle BTB at 80-90 MHz beats ZAP at
   104, which is a reason to revisit the ARM9 at a lower clock once the
   release is out.

## What they lack that we have

The phone itself: its kernel, drivers, flash, the modem stand-in, the
file system and saves, the MMC controller and a card model with writes;
so the first boot, C: persistence, the real load path, the real timing
of everything the kernel does. "Memory card support" on their side is
the game image; ours is the same image on a modelled card, writable.
