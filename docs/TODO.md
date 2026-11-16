# To do

The open work on the core, in the order it is meant to be taken. The
target for speed (2026-11-15): the phone should play close to a real
N-Gage QD's speed, never below it; what the core has above it may be
given up, also to help timing. The phone's figures are in
the progress log entry of 2026-11-15 (SPMark04: 3D Game 8.05 fps, 3D
PolyCount 27.52 Ktriangles/s, 2D Image 37.33 fps, Disk Access 2.64 files/s
and the rest).

Difficulty: **low** a parameter or a small block; **medium** new RTL or
stand-in code with some reverse engineering; **high** a large design;
**blocked** needs something we do not have.

## In progress

- [x] **Small-page TLB with two ways** and **caches of 16 KB and 16 KB**:
  released as NGage_20261116.rbf (2D Image 38.0 fps against the phone's
  37.33, 3D score 522 against 485, nothing under the phone).
- [x] **The data line fill's cost** and the phone's own 8 KB D-cache:
  released on 2026-11-16 (the second NGage_20261116.rbf). A request that
  waits through a fill is taken two clocks after the line is written
  instead of eight; with 16 KB I and 8 KB D FillRate is 1.73 Mtexels/s
  (the phone's; it was 1.66) and nothing is under the phone. What is left
  in a fill: 2 clocks to the bus, 8 to the first word, 6 for three more
  (a 16-bit SDRAM, two clocks a word), 2 to install; after a dirty line's
  write-back the SDRAM's first word takes 23.
- [ ] **Timing**: the aims are hardware accuracy, the benchmarks (nothing
  under the phone) and no negative slack (the user, 2026-11-16). On the
  fixed eight seeds the branch `timing` is at mean -1.7, best -1.25 ns
  (the release: -1.96 and -1.6). What moved it: the fitter's placement
  effort (0.26 ns). What did not, each exact and each measured: cutting
  single paths in the caches, TLBs and register file, the flash side and
  peripheral paths outside the CPU, freeing block RAM. The wall is some
  twenty-five families of paths where one part of the CPU answers another
  within a clock across the device (log, 2026-11-16 midday). Next: a
  register on those answers (the D-cache's hit into the core, the miss
  decision into the bus) costs a clock a load or a miss, so first the
  clocks the core loses against the phone: the data line fill (19.3
  clocks a line), the I side's second page walk, the write buffer's
  depth. Every change on the fixed eight seeds.
- [ ] **Benchmark runs**: all nine SPMark04 tests once from a fresh C: for
  each candidate core (no second run of the 3D set, no file checks).

## Speed fidelity (the core is faster than the phone here)

- [ ] Flash and SDRAM bus timing: the memory controller's registers are
  storage and flash reads come at the core's own speed; the phone's flash
  runs at a third of the CPU clock (medium).
- [ ] Flash program and erase times (assumed values) and the MMC clock
  (26 MHz against 8.66 MHz, `MMC_DIV`): Contacts, Calendar and Disk Access
  run 1.3 to 5.8 times the phone (low).
- [ ] CPU cycle timing: no branch predictor on the phone, multiplies of 3
  to 7 cycles (high; the plan is in docs/CPU.md).
- [ ] The instruction side walks a page twice after a TLB miss (found
  2026-11-15; low to medium).
- [ ] Section, large-page and tiny-page TLBs are still one way; whether to
  model the phone's 64-entry fully associative TLBs outright (open
  question, see the log).

## Things a player can run into

- [ ] Unanswered modem requests in the stand-in: call set-up (dialling a
  number freezes the keys until reset), the request behind Settings >
  Device > Display, network, GPRS, SMS, two SIM reads, modem state (low to
  medium each; docs/NOS_STANDIN.md, "Not answered yet").
  A lead for the Display page (github.com/nortido/NGage-MiSTer,
  `hps/guest/nos_isi.c`, on the first N-Gage's firmware): resource `0x3A`
  is the light service; message `0x01` asks for light values by a 32-bit
  mask in its last four bytes (ours: `00 00 00 20`, bit 5), and the answer
  is message `0x02` with `[10]` 0, the count at `[11]` and one four-byte
  sub-block a set bit: id, 4, value, 0 (ids by bit 0-7: 01 05 06 02 07 03
  04 00; that core answers 100 for every value). Not checked on our
  firmware.
- [ ] The System Agent's current-call variable (`0x100052CB`), which the
  Phone app publishes once its call engine is up: not in our notes. Left
  unknown, games take it for a call in progress (Snakes pauses its music
  at start; github.com/plasticbugs/n-gage, docs/hardware.md section 8).
  Check what our boot leaves there (low).
- [ ] Sound in Java games, tones and a second audio stream: never checked
  (low to test, medium to fix).
- [ ] Vibration to gamepad rumble: Call of Duty, Shadowkey and Worms World
  Party carry the vibration library (medium). The path, half traced on
  2026-11-16: the games' `VIBRACTRL.DLL` (N-Gage SDK 2.5; it reads the
  profile's `VibrAlert` setting) loads the ROM's `vbrdrv.dll`
  (`0x510EE1C0` in 4.10), which calls DSClient.dll: start and stop
  (its export slot at `0x50FF6DFC`, with 0 and 1) and an intensity of 0
  to 40 (two fifths of the caller's 0 to 100, `0x510EE3D4`). From DosSrv on it is a modem
  message, not a UEMK access of ours: on the first N-Gage's firmware it is
  resource `0x1C`, message `0x0C` with `[10]` on/off and `0x0E` with
  `[10]` the level 0-100, each answered with the message number + 1
  (github.com/nortido/NGage-MiSTer, `hps/guest/nos_isi.c`). Open: see the
  request our firmware sends (a game with vibration on, the stand-in's
  log), answer it and give the level to the gamepad.
- [ ] Bluetooth play between two cores: a link at HCI level, not a radio
  (high).

## Accuracy with little to show for it

- [ ] Check the stand-in's replies against the decoded NOS code; a real
  IMEI (medium).
- [ ] The rest of the UEMK: power-off, lights, charger, RTC alarm, its
  interrupt line (low to medium).
- [ ] The display: the panel's reset line (GENIO4, which lcd.ldd pulses)
  and its tearing-effect line (GENIO28, which nothing in the Symbian ROM
  reads) are not connected; the bus timing and the panel's refresh rate
  are assumed; power-on delays are missing (low).
- [ ] TLB lockdown, write-buffer depth (4 entries against 17 words), a
  cache switched off loses its contents (medium).
- [ ] Interrupt sources that never fire (LCDBuffer, FlashCopyRdy,
  infrared, the GPIOs), the OS-timer status (low to medium).
- [ ] Clock switching and sleep on the 32 kHz clock (medium).
- [ ] MMC card extras (stream read, erase, lock); flash lock state and
  sector map (low).
- [ ] Serial ports, infrared, microphone (medium).
- [ ] JTAG, EmbeddedICE, big-endian mode (medium, never exercised).

## Blocked

- [ ] The DSP and the real audio path: type and code unknown.
- [ ] NOS running for real: needs the DSP, the whole UEMK, the SIM and the
  radio.
- [ ] The radio chain and the SIM interface.
- [ ] The ASIC's boot ROM: never dumped.
- [ ] The LCD controller's identity: needs a module taken apart.

## Standing

- [ ] 104 MHz timing closure: see "Timing" under In progress.
- [ ] The development board's wrong bits on file reads (2026-11-14/15):
  one bit of its own memory, physical `0x1908D7F4` bit 30, takes no
  writes (found 2026-11-16, memtester agrees); not the core. Open, the
  user's choice: keep Linux off that page (`memmap=4K$0x1908D000`). The
  read probes around board sessions are dropped.
