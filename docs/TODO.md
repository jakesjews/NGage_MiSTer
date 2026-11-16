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

- [ ] **Small-page TLB with ways** (branch `tlb-ways`, not committed). The
  one-way TLB walked at every access when two pages sat 1 MB apart, which
  held 2D Image at 60 to 85 % of the phone. Done: the RTL, the test
  `arm9_tlb_assoc_rtl`, the CPU suite, the benches, twelve fits, the board
  run with two ways (2D Image 38.22 fps against the phone's 37.33). Open:
  two or four ways, the commit, the release.
- [ ] **Caches of 16 KB and 16 KB** (the user's choice, 2026-11-15): the
  smallest sizes with nothing under the phone in SPMark04 (3D score 522
  against 485). The defaults are changed; the suites, the seed sweep, a
  few games on the board, the commit and the release are open.
- [ ] **The data line fill's cost**, so that the phone's own 8 KB D-cache
  can be used: with 16 KB I and 8 KB D the fill-rate test is 4 % under the
  phone (1.66 against 1.73 Mtexels/s). Measured (`make -C sim dfill`): a
  fill costs 21 clocks, fills follow one another every 25; 9 to the first
  word, 6 for the rest, and about 9 for the cache to restore its lookups
  and take the next miss (UNLOCK_REG, UNLOCK_WR, three RELOOKUP states,
  the held load presented again). The 9 are the place to cut; the
  alternative is a next-line prefetch, which the phone does not have.
- [ ] **Benchmark baseline**: the full SPMark04 suite from a fresh C:, as
  booted and with Contacts open, plus the 3D set for the score. Release
  core measured; each candidate core gets the same run.

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
- [ ] Sound in Java games, tones and a second audio stream: never checked
  (low to test, medium to fix).
- [ ] Vibration to gamepad rumble: Call of Duty, Shadowkey and Worms World
  Party carry the vibration library; the path to the UEMK is not traced
  (medium).
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

- [ ] 104 MHz timing closure: the release is at -1.486 ns; the TLB ways
  cost about 0.3 ns more on the seeds tried.
- [ ] The MiSTer's wrong bits on cold file reads (2026-11-15, gone after a
  reboot): a read probe runs before and after each board session to catch
  it coming back.
