# Game CPI: my own reading, 2026-10-22 (before the Codex consult)

Written after the in-play measurements and before the stall-counter build
(a91da1d) has produced numbers; kept out of the Codex brief so the two
readings are independent. The earlier speed plan
(2026-10-22-speed-plan-mine.md) guessed 1.6-2.0 clocks an instruction for
game code; the measurement is 4.9-5.3, so that guess was wrong by 3x and
this note starts over from the numbers.

## The numbers

Seed 10 of the 3a tree on the MiSTer, the overlay's per-second counters,
keys scripted (docs/PROGRESS-LOG.md, "game speed on the hardware"):

- Sonic N in Neo Green Hill: 7-12 frames/s (model 30), 19.3-20.8 M
  instructions/s, CPI 5.0-5.4, SDRAM wait 22-25 %, flash 8-9 %, idle 0.
- Asphalt in a race: 10-12 frames/s (model 20.5), 21.0-21.3 M
  instructions/s, CPI 4.9, SDRAM 22.4 %, flash 6.5 %, idle 0.

Per instruction at CPI 4.9: 1.1 clocks of SDRAM wait, 0.3 of flash wait,
3.5 in the pipeline (one of them the instruction itself).

## Where I think the 3.5 pipeline clocks go, ranked

1. **The load-use interlock, 1.0-1.5 clocks an instruction.** The pipeline
   is fetch, FIFO, Thumb decoder, predecode, decode, issue, shifter, ALU,
   postalu0, postalu1, postalu2, memory, writeback (zap_core.sv). The issue
   stage's determine_load_lock (zap_issue_main.sv:1005) holds an
   instruction whose source is the destination of a load anywhere in the
   shifter, ALU, the three post-ALU stages or the memory stage: a use
   right behind a load waits up to 6 clocks, and compiled game code has a
   load in every 4-5 instructions with the use 1-3 instructions behind.
   The ARM9TDMI's is 1-2 clocks (the data is forwarded from the memory
   stage into the execute stage). The two extra post-ALU stages are the
   ARM925T port's (the MMU and the two-way lookup spread for 104 MHz), and
   each one lengthens every load-use by a clock.
2. **Uncached stores, 0.3-0.5 and rising with the frame rate.** The LCD is
   written a byte a store over the 8080 bus: 36,608 pixels x 2 stores a
   frame, 0.7 M stores a second at 10 frames/s, 2.2 M at 30. Each one goes
   through the D-cache FSM's uncached path and waits for the bus's
   acknowledge before the pipeline moves (no write buffer; the ARM925T has
   one), 5-8 clocks a store. The "other" bus-wait counter reads 0 because
   the acknowledge itself is quick; the cost is the FSM's own clocks,
   which the new data-stall counter will show.
3. **Branch mispredicts, 0.3-0.5.** The BTB is in fetch (a predicted taken
   branch costs no bubble), a wrong prediction is found in the ALU and
   costs 12 clocks (clear_from_alu); the predictor is 512 bimodal entries
   and the return-address stack only predicts. Game code: a branch in 6
   and perhaps 10-15 % wrong.
4. **Multi-uop instructions, 0.3-0.5.** LDM/STM retire a register a clock
   (uops); C++ prologues and epilogues push and pop 4-8 registers, memcpy
   loops are LDM/STM. The ARM9 pays the same, so this is not a gap, but
   it is in the 3.5.
5. **Shifter locks, under 0.2.** A shifted operand behind a flag-setting
   instruction and multiplies (shift_lock, zap_issue_main.sv:960).
6. **The fill without early restart, in the 1.4 bus clocks.** A miss waits
   for the whole 16-byte line (SDRAM 15 clocks, flash 24) plus the tag
   write and the re-lookup before the pipeline moves; the word asked for
   arrives at clock 8 of the SDRAM's 15.

The stall counters (data, code, FIFO empty, issue, shifter, decode, the two
flush counts, uops) decide between 1-5; the bus side is already measured.

## What I would do, in order of gain for the risk

1. **Early restart on both caches**: hand the requested word to the
   pipeline as it arrives and finish the line in the background (the
   D-cache already has a background-load lock per way for the write path;
   the I-cache needs the same idea). Saves 7-10 clocks a miss: 0.3-0.5 of
   the 1.4 bus clocks. Cycle behaviour changes, architectural results do
   not; the CPU benches against QEMU and the boot bench against the
   model's device log still hold.
2. **A write buffer for uncached and write-through stores** (4-8 entries,
   drained in order, the ARM925T's own feature): the pipeline moves on at
   the store, the FSM drains behind. Removes most of item 2; also makes
   the LCD blit scale with the frame rate instead of eating it. Risk:
   ordering against uncached loads (drain before a load to the same
   device) and against CP15 (drain on the fence); verified by the
   device-order check of the boot bench.
3. **Load-use: forward from the memory stage into the issue stage** when
   the cache has hit (the data is in the memory stage's register a clock
   before writeback): one clock off every load-use. Then the larger step,
   stalling the dependent instruction in the shifter or ALU instead of at
   issue, two more clocks; that is a change to ZAP's forwarding network,
   which is on the worst timing path family (the register file read mux
   and the operand forwarding), so it needs the timing sweep afterwards.
4. **Mispredict penalty**: resolve conditional branches whose condition
   is already known at the shifter stage there instead of in the ALU
   (saves 1 clock of 12), and let the return-address stack decide
   instead of only predict. Small.
5. **The SDRAM open-page policy** last: a few percent.

The decision gate for the user: if the stall counters put the issue
interlock first, the core needs the forwarding work (weeks, with the
timing sweep after); if the data stall (stores and fills) is first, items
1 and 2 are a few days each and may give half of the gap.
