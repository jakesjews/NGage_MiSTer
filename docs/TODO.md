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

With pull request 10 the core runs the original NOS, not the stand-in. The
entries below that name the stand-in describe the core before that: each
needs looking at again under the original NOS before it is worked on.

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
- [x] **The timing work's exact changes**: released on 2026-11-16 (the
  third NGage_20261116.rbf, seed 50, -1.362 / -1.414 ns; the release
  before: -1.597 / -1.553). The fitter's placement effort at 4, the
  D-cache's relookup multiplexers gone, TLB valid bits as generation
  numbers, the register file's held masks decoded, the D-cache's victim
  line and store merge behind their registers, the memory system's reset
  as a register, two more register sets in the peripheral bus's two-clock
  set. The core is the release before's clock for clock (the same clock
  counts in flashcopy and dfill, the same SPMark04 figures).
- [x] **A read-ahead line for SDRAM line fills**: released as
  NGage_20261119.rbf (seed 5, -1.478 / -1.412 ns), since 2026-11-20
  NGage_20261120.rbf (the same sources, seed 31337 of sixteen, -1.148 /
  -1.321 ns). A line fill reads the
  row's next 16 bytes too and the memory bus keeps them for the next fill
  (`rtl/upp/upp_bus.sv`, `rtl/mem/sdram.sv`). On the board 3D Game 8.88 ->
  8.98 fps and PolyCount 28.41 -> 29.67, nothing slower. In `make -C sim
  dfill`, clocks a load: seq 19.3 -> 17.8, use 20.3 -> 16.8, copy 34.2 ->
  21.3, rmw 32.1 -> 25.5; row and two (another row every load) unchanged.
  With it: the board's reset button during an SDRAM read no longer leaves
  the core unable to read the SDRAM.
- [ ] **Timing**: the aims are hardware accuracy, the benchmarks (nothing
  under the phone) and no negative slack (the user, 2026-11-16). What a
  day of measuring says (log, 2026-11-16): the CPU core's own stages are
  1.1 to 1.9 ns short at 104 MHz on this device, with everything else
  given two clocks; what passes between the core and the caches 0.7 to
  1.3 ns. Fitter effort is in (0.26 ns); router effort, a synthesis seed,
  freeing block RAM, a placement region for the core (0.5 ns worse) and a
  register on the D-cache's answer (0.15 ns at most) do nothing. An
  eight-seed mean of one tree is good to 0.2 ns only: trees differ by
  their synthesis result, so compare over several trees and count failing
  endpoints too. Meeting the clock means a deeper pipeline in the core:
  a project of its own, not started, waiting for the user's word. Its
  budget: the 16 KB D-cache gives 3.6 % in the 3D tests and nothing in
  2D Image (1.9 % over the phone). Its first step is measurement: which
  stage splits the core needs.
- [ ] **Held back from the release, to come back with a sweep of their
  own** (2c7623a, ecd84e1): the predictor's return stack taking its write
  a clock later, upp_haudio's pos and played in the two-clock set, and
  the flash store's registers (lookup, DDR3 read channel, cached-copy
  update). The first two are exact and only fitted badly; the flash
  store's cost a clock on flash misses and word reads, and FillRate, on
  the edge of a whole second, read 1.67 instead of 1.73 with them: they
  need the fill rate off that edge first.
- [ ] **Benchmark runs**: all nine SPMark04 tests once from a fresh C: for
  each candidate core (no second run of the 3D set, no file checks).

## Speed fidelity (the core is faster than the phone here)

- [ ] "CPU caches: 32 KB" is faster than any phone by design (SPMark04's 3D
  Game 9.69 against 8.98 fps, PolyCount 37.5 against 29.7); the default,
  Real, is the phone's sizes. Built large, the caches cost every build
  about 0.3 ns of mean slack: the D-cache's valid flags could be grouped
  by sixteen sets as its dirty bits are (64 flags a way instead of 256),
  and the storage tests are 2 to 7 % lower at 32 KB (the whole-cache
  clean's 96 more clocks and four sets for an operation by index).
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

- [ ] The UEMK's clock interrupts: rtc.dll sets the clock in nine steps
  that wait for UEMK interrupts 15 and 12 (register 21 bits 0 and 3, masks
  in register 22; cbus.dll reads them when CTSI status bit 15 at
  `0x0C150100` is set) and writes minutes and hours to registers 2 and 3,
  with bit 7 of 3 set for one purpose and clear for the other (the time's
  load and the alarm; which is which is open). The core makes none of it,
  so a time set in the phone is never stored as set; the date comes from
  MiSTer's clock at each start instead (`rtl/mister/pmm_date.sv`), and a
  time set in the phone lasts until the next start (medium).
- [ ] Game audio with the original NOS: PCM now goes through MDI to the
  DSP peer (`rtl/upp/upp_dsp_pcm.v`, `upp_pcm.v`). The bench covers the
  path; it has not been listened to on a board in this repository (low to
  test).
- [ ] The original N-Gage's firmware 4.03 in this core: not run through on
  a MiSTer (docs/FIRMWARE-PROFILES.md, "Remaining validation").
- [ ] The reference model does not run the original NOS: it has none of
  the devices NOS needs (the MDI rings and the DSP peer, the SIM interface,
  the CTSI counters) and runs with the stand-in only
  (`NGAGE_PATCHES=standin`), so a boot of the core can no longer be
  compared with it (medium to high).
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

- [ ] The DSP and the real audio path: type and code unknown. NOS runs
  against a peer that answers at the message level
  (`rtl/upp/upp_mdi_peer.v`).
- [ ] The radio chain. The SIM is a test card with made-up identities
  (`rtl/upp/upp_test_sim.v`).
- [ ] The ASIC's boot ROM: never dumped.
- [ ] The LCD controller's identity: needs a module taken apart.

## Standing

- [ ] 104 MHz timing closure: see "Timing" under In progress.
- [ ] The development board's wrong bits on file reads (2026-11-14/15):
  one bit of its own memory, physical `0x1908D7F4` bit 30, takes no
  writes (found 2026-11-16, memtester agrees); not the core. Linux is
  kept off that page since 2026-11-16 (a reservation in the boot loader's
  `u-boot.txt`). The read probes around board sessions are dropped.
