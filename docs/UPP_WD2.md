# UPP_WD2 register reference (N-Gage QD, RH-29)

What the reference model (`model/`) implements and why. Every row cites
the RH-29 v4.60 code that shows the behaviour: a bootstrap address (plain
CS0, `0x0000`-`0x9FFF`) or a ROM address (`0x50xxxxxx`, file named).
Symbian reaches the registers through virtual `0x58000000 + (phys -
0x0C000000)`; ekern's helpers at `0x5031E6B0` (read32), `0x5031E6BC`
(write32), `0x5031E6FC` (read16), `0x5031E708` (write16) and `0x5031E6C8` /
`0x5031E714` (masked read-modify-write) take that offset.

The core runs firmware 4.10 since 2026-11-12. The code was read in 4.60 and
the addresses here are 4.60's: the bootstrap and ekern sit at the same
addresses in 4.10, most other files a little lower (EUser by 0x190, the
files around hci.dll by 0xEA0, nosdriver.ldd by 0x51D0; `tools/romhdr.py ls`
on both images gives every file's place).

Confidence: **A** the code leaves no other reading; **B** consistent with all
uses seen, one plausible reading; **C** a guess the model needs to run.

Model file names are in `model/hw/`. Registers without a model fall into the
storage block in `ngage_upp.c` (reads return what was written) and their
first access is logged to `model/.out/regs.log`.

## Memory map

| Physical | Size | What | Evidence | Conf. |
|---|---|---|---|---|
| `0x00000000` | 16 MB | CS0 NOR flash (AMD command set) | bootstrap reset vector; JAF log | A |
| `0x02000000` | 8 MB | CS1 NOR flash | bootstrap `0xA40` ID probe | A |
| `0x04000000` | - | CS2, empty on the QD (reads 0) | bootstrap `0x0C0047B8` probe | A |
| `0x08000000` | 4 KB | memory controller | bootstrap `0xB24` | A |
| `0x0A000000` | 16 MB | SDRAM | bootstrap memory test `0x264`, stack | A |
| `0x0C000000` | 256 KB modelled | on-chip RAM; bootstrap copies flash routines to `0x0C004748` | bootstrap | A (exists), C (size) |
| `0x0C100000` | 1 MB | peripheral registers | bootstrap page table | A |
| `0x0C1F0000` | 4 KB | **emulator devices** (HLE audio, HLE RTC date): not UPP_WD2 hardware, see the last section | no firmware access to the page (no ROM constant, no access in any run) | - |
| `0x0D000000` | 16 MB | second I/O window; only the STI trace window at `0x0DE00000` is used so far | bootstrap table, ekern `0x5031E4A8` | B |

## Clock and system page (0x0C120000)

| Address | Name / guess | Behaviour in the model | Evidence | Conf. |
|---|---|---|---|---|
| `0x0C120004` | clock source select | storage | bootstrap `0x376C` writes `0xC`, ekern restart writes `0x200` | B |
| `0x0C120020` | clock status | bits 26-28 read as 1 (DPLL locked) | bootstrap polls bit 26 at `0x3770`, bit 27 at `0x382C` (`upp-quirks.txt`) | A |
| `0x0C120044` | OS-timer unit: interrupt enable, bits 2:0 | drives FIQ with `+0x50` | ekern `0x5031C7A8` writes 2 (`ngage_intc.c`) | B |
| `0x0C120050` | OS-timer unit: status, write 1 to clear | nothing sets it yet | FIQ dispatcher `0x5031C99C`: bit 1 = tick (`0x5031C938`) | B (layout), C (source) |
| `0x0C120074` | OS-timer unit: unknown | storage | ekern `0x5031C724` writes 3 | C |
| `0x0C120064`, `0x0C120068` | per-source nibble fields (two values per source group of 64) | storage | ekern `0x5031EDF8` | C |

## Interrupt controller (0x0C120100) — `ngage_intc.c`

Two planes of three 32-source banks. IRQ bank *k* at `0x0C120100 + 0x40k`,
FIQ bank *k* at `0x0C1201C0 + 0x40k`.

| Offset in bank | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `+0x08` | enable set | writing 1s enables those sources on this plane | ekern `0x5031E874` (IRQ), `0x5031E998` (FIQ): single-bit writes; boot `0x31D4` | B |
| `+0x0C` | enable clear | writing 1s disables | ekern `0x5031E8CC`, `0x5031E9F0`; boot ISR `0x3074` | B |
| `+0x10` | raw pending | read | ekern `0x5031E7B0`, `0x5031E930` test one bit | B |
| `+0x14` | active source | 1-based number of the lowest pending enabled source in the bank, 0 = none | IRQ dispatcher `0x5031C87C` calls ISR *n* + 0x5C + 32*bank; FIQ `0x5031C99C` calls *n* - 1 + 32*bank; bank-0 values 5 (IRQ) and 4 (FIQ) are special-cased | A (meaning), C (priority order) |

Source numbers (bit *b* of bank *k* = 32*k* + *b*), from the kernel's name
table at `0x5031D674` (after its ten FIQ-only names) and NOS's tables in
reverse order. Confirmed by three uses: boot timer 0 is bit 0; the kernel's
timer 4 (`0x0C120A80`) is bit 4 (`0x5031C968`); the kernel enables bit 25
(CTSI_IRQ) at start-up.

| Source | Name | | Source | Name |
|---|---|---|---|---|
| 0-5 | Timer0-5 | | 23 | MMCCmdIdle |
| 6-13 | DmaChannel0-7 | | 24 | MMCCmdRdy |
| 14 | FlashCopyRdy | | 25 | CTSI_IRQ |
| 15 | LCDBuffer | | 26 | CTSI_FIQ |
| 16-20 | Ir4M TxData, TxIdle, RxData, RxIdle, RxBusy | | 27 | APIIOAbort |
| 21 | MMCDataIdle | | 28 | APIMissAlign |
| 22 | MMCDataRdy | | 29 + 2*n*, 30 + 2*n* | GPIO*n* Low, High (n = 0-21 named in the kernel) |

Sources enabled so far: IRQ 0 (tick), 1 (high-resolution timer), 4,
5 (IrqTimer5, bound by the NOS stand-in for the HLE audio device),
6-12 (DMA), 21-24 (MMC), 25 (CTSI: cbus.dll and ekeyb.dll), 46 (GPIO8High,
bound by cbus.dll; probably the UEMK interrupt line); FIQ 27.

## Timers (0x0C120A00) — `ngage_intc.c`

Timer *n* at `0x0C120A00 + 0x20n`, *n* = 0-5 (stride from timer 1 at `+0x20`
and timer 4 at `+0x80` using sources 1 and 4). Clock 104/3 MHz = 34.67 MHz:
the kernel converts microseconds with ×34666/1000 (`0x5031CB74`), and its
reload `0x843E2` (`0x5031C6F0`) gives the EKA1 1/64 s tick (B). Uses: timer 0
= system tick (IRQ ISR `0x5031C5B0`); timer 1 = high-resolution timer
(kernel object 0x80000558, ISR `0x5031CAC0`); timer 4 = one-shot
(`0x5031C968`).

| Offset | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `+0x04` | control | bit 1 = run, reload from +0x18 on underflow; bit 0 alone = run once and stop at 0 (guess); reads back what was written | boot `0x31AC`; timer 1 started with 1 (`0x5031CA78`); ekern `0x5031EA58` rewrites until it reads back | B (bit 1), C (bit 0) |
| `+0x08` | interrupt acknowledge | any write clears the latched underflow interrupt; reads return the last value written | tick ISR writes 0 (`0x5031C5C0`); timer-1 ISR writes 1 without disabling its source (`0x5031CACC`); boot and timer-4 ISRs write 1 (`0x3064`, `0x5031C86C`); boot polls the value it wrote (`0x3208`) | B |
| `+0x10` | counter | live down-count; a write reloads | kernel reads it as a free-running time base (`0x5031E6B4`) | B |
| `+0x18` | reload | loaded on underflow | boot `0x31B4`, ekern `0x5031EAC4` | B |

## DMA controller (0x0C120300) — `ngage_dma.c`

Channel *n* at `0x0C120300 + 0x40n`; the kernel allocates channels 0-6 per
transfer (ekern 0x5031B17C).

| Offset | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `+0x04` | channel enable / clear | written 1 before programming, 0 when stopping; 0 acknowledges | ekern 0x5031B2E8, 0x5031B4F0 | B |
| `+0x08` | start / busy | 1 = start memory-to-memory, 2 = start paced by the peripheral, 0 = stop and acknowledge; reads 0 when idle | 0x5031B43C, 0x5031B5D8, polled 0x5031B2D4 | B |
| `+0x0C`, `+0x10` | status? | read 0 | read after a stop, 0x5031B2F4 | C |
| `+0x14` / `+0x20` | source / destination address | physical; `0x1xxxxxxx` = the peripheral at `0x0Cxxxxxx` | tables 0x503401F4, 0x503401D0 | B |
| `+0x18` / `+0x24` | source / destination mode | 0 fixed (FIFO), 2 incrementing in on-chip RAM, 4 incrementing in SDRAM | 0x5031B344 | B |
| `+0x1C` / `+0x28` | source / destination width | 8, 0x10, 0x20 = 8, 16, 32 bits | MMC FIFO 8, LCD FIFO 0x20 (0x5034025C) | B |
| `+0x2C` | count − 1 | in source-width units | 0x5031B5CC | B |
| `0x0C120064`/`68` | request-line select | 4 bits per channel (MMC = 2, LCD = 7); not modelled | 0x5031EDF8 | B |

DMA peripheral targets: `0x10121208` LCD FIFO (type 4), `0x10120624` MMC FIFO
(type 5), `0x10150554`/`0x10150500` accessory interface. Completion raises
IrqDmaChannel*n* (source 6+*n*); the kernel's DMA ISR (0x50326B08) reads no
status and stops the channel.

## MMC host (0x0C120600) — `ngage_mmc.c`

From epbus.dll's WD2MMC layer.

| Offset | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `+0x04` | control | bit 0 starts a transfer (reads 1 until taken; the driver polls it up to 120 times); bits 5:2 = type: 0 none, 1 R1, 2 R3 (with bit 6, CMD1), 3 R2, 4 R1b?, 8/9/10 = read first block (with the command in `+0x1C`) / next block / **last block, then CMD12**, 5/6/7 = the same for writing. For 10 and 7 the driver loads CMD12 into `+0x1C`/`+0x20` and the block length into `+0x08` first, and DMAs that block during the phase (a 4 KB read is 8 + 6 × 9 + 10). Without bit 0: 0x40 at power-up, 0 at power-down | 0x503F53DC jump table, 0x503F5474, 0x503F57D0; last block: 0x503F56E4-0x503F57A8; CMD17 seen as 0x21 | A (cmd types), B (data types) |
| `+0x608` | data length | block length of the following data phase | 0x503F53A0 | B |
| `+0x60C`, `+0x610` | time-outs? | 0x1DC130 at power-up; stored | 0x503F5E18, 0x503F5DDC | C |
| `+0x614` | clock divider? | 0x280 at power-up; stored | 0x503F5DA4 | C |
| `+0x618` | status | bit 3 command busy, 2 data busy, 8 response word ready; errors: 6 response time-out, 1 response CRC, 9 other; data 0 CRC, 5 busy time-out, 7 time-out, 10 other | decoder 0x503F5E4C | A |
| `+0x61C` | command index | | 0x503F52A4 | A |
| `+0x620` | argument (write) / response (read) | 48-bit responses in one word; R2 as four words, MSB first, each after status bit 8 | 0x503F5350, 0x503F54F4, 0x503F555C | A |
| `+0x624` | data FIFO | 8-bit DMA target 0x10120624 | ekern 0x503401D0 | B |

Interrupts are bound by name (epbus 0x503F6180-0x503F62E8): MMCCmdIdle 23,
MMCDataIdle 21, MMCCmdRdy 24, MMCDataRdy 22. The model drives them as
levels from the status bits. The card model does MMC 3.x identification
(CMD0/1/2/3/9/10/7/13/16) and block reads/writes (CMD17/18/24/25/12). Its
CID/CSD come from `<image>.cid`/`.csd` sidecars (16 bytes binary, or hex);
without them it uses a generic CID and a CSD sized to the image.

## LCD bus interface (0x0C121200) — `ngage_lcd.c`

| Offset | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `+0x00` | control | read: last value with bit 30 (ready) set. Write: phase for `+0x08`; bits 15:0 = bytes − 1; bits 19:18 = packing: 2 one command byte (`0x09280000`), 1 three bytes from two 12-bit units (`0x0924xxxx` parameters LSB first; bit 31 set, `0x8314xxxx`/`0x8924xxxx`, = DCS pixel order R0G0 B0R1 G1B1), 3 four bytes LSB first (`0x092Cxxxx` LUT, `0x082Cxxxx` 16-bit pixels). `0x0784xxxx` = read phase | lcd.ldd 0x50406928, 0x50402188; bootstrap 0x6E9C, 0x694C | A (phases), B (bit 31) |
| `+0x04` | auxiliary | bit 2 reads 1 = FIFO can take a word; writes 2 then 1 reset the FIFO | bootstrap 0x6858, 0x6834; lcd.ldd 0x50401F14 | B |
| `+0x08` | FIFO | write: data per phase; read: next byte in a read phase (first a dummy) | bootstrap RDDID 0x6C44 | A |

Panel: DCS-style commands (DISPLAY.md). RDDID returns 0x29xxxx, which selects
LCD module type 0x10 (bootstrap 0x62D8; 0x83 → module 4); the bootstrap
stores the type at SDRAM 0x0A012000+24 and ecust copies it to variant +0x7C.
MADCTL 0xD4 gives an upright image if the panel is mounted rotated by 180°
(inferred from the rendered boot logo).

Partial and idle mode, used only by the screen saver (lcd.ldd `0x50406278`):
it sends PTLAR `0x30` [SR SR ER ER] (rows, 16 bits each), PTLON `0x12`, IDMON
`0x39`, then a full frame (PASET 0-208, RAMWR) with the date bar in rows SR-ER;
every minute again with the bar moved (rows 4-26, 128-150, 164-186 seen).
A key press sends IDMOFF `0x38`, NORON `0x13` and redraws. The model shows
rows outside SR-ER black and, in idle mode, each colour component as its top
bit (eight colours, as DCS defines idle mode): the bar backgrounds the saver
cycles through (`#000000`, `#319A63`, `#737573`) become black, green, black.
The rows are the ones the driver addresses with PASET (the bar it draws falls
in them), whatever MADCTL's row order. Black outside the area is what the
phone shows; idle mode's colours are DCS behaviour, not checked on a phone.

## DPLLs and test interface (0x0C14xxxx)

| Address | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `0x0C149000` | MCU DPLL | bit 0 reads 1 (locked) | bootstrap writes `0x2210` at `0x37F8`, polls at `0x37FC` (`upp-quirks.txt`) | A |
| `0x0C14D000`-`0x0C14D010` | STI (serial trace) control; DCT4 STI `0x0600D000` rebased | storage | ekern `0x5031E40C`: `+0`=2, `+2`=`0x300`, `+4`=`0x205`, `+8`=0, reads `+0xE`, `+0x10` | B |
| `0x0C14F000`-`0x0C14F010` | TESTIF / pin set-up | storage | bootstrap `0x67F8`, ekern | C |

## CTSI, PUP, UIF (0x0C150000)

| Address | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `0x0C150000` | CTSI reset reason | storage (reads 0) | bootstrap `0x2E58` masks `0x0E`; ecust's start-up reason (`0x503439C0`) takes a different path (boot data in on-chip RAM `0x0C00420x`/`0x0C00428E`) when bits 3:1 are nonzero, i.e. after a reset that was not a power-on | B |
| `0x0C150024`, `0x0C150028` | CTSI IRQ / FIQ controller enable | storage | ekern `0x5031C730`/`0x5031C73C` write 1 | C |
| `0x0C150100` | CTSI interrupt status: bit 2 = port E (key rows) interrupt, bit 3 = port D (guess); write 1 to clear; behind main source 25 | `ngage_keypad.c` | ekeyb CTSI ISR 0x5041B9E0 tests bit 2, acks with 0xC at 0x5041CD6C; bootstrap writes 0x8000 (0x2EE4) | B |
| `0x0C150200`-`0x0C150218` | PUP GENIO set/reset/input/direction | storage | bootstrap `0x3A24`, `0x67C0` (LCD /RES = GENIO4) | B |
| `0x0C150400`/`0x0C15040C` | UIF port D (key columns, 5 bits) / port E (key rows, 6 bits) data: output latch, reads pin levels | `ngage_keypad.c` | ekeyb 0x5041CBA8 (reads, inverts, keeps 0x1F/0x3F) | A |
| `+0x02`/`+0x0E` | direction, 1 = output; write: low byte sets, high byte clears | | ekeyb ops 2/3 at 0x5041C804 | A |
| `+0x04`/`+0x10` | interrupt enable, set/clear format | | ops 4/5 | B |
| `+0x08`/`+0x14` | unknown, set/clear format | stored | ops 6/7 | C |
| `+0x0A`/`+0x16` | pull-up enable, set/clear format | | ops 8/9; idle state 0x5041CCE0 | B |
| `0x0C150418` | unknown | written 0 at keypad init | 0x5041CCFC | C |
| `0x0C150420` | CBUS transfer length: bits 4:0 = bits - 1 | `ngage_cbus.c` | cbus.dll `0x5037D014`, bootstrap `0x35F4` | A |
| `0x0C150422` | CBUS control: bits 4:0 register, 7:5 device, bit 8 read (starts it), bit 9 on some writes; bit 10 reads 1 = done | `ngage_cbus.c` | cbus.dll `0x5037D028`, `0x5037CF74`; bootstrap `0x3644` | A |
| `0x0C150424` | CBUS data bits 31:16 | `ngage_cbus.c` | cbus.dll `0x5037D388`, `0x5037D074` | A |
| `0x0C150426` | CBUS data bits 15:0; a write starts a write transfer | `ngage_cbus.c` | bootstrap `0x3604`, cbus.dll `0x5037D39C` | A |
| `0x0C150538`, `0x0C15053C` | unknown, written before STI set-up | storage | ekern `0x5031E410` | C |

Key matrix (ekeyb table 3, row × column): ROW0 Up Left RSK Clear Menu; ROW1
Down Right End Edit OK; ROW2 LSK – 1 6 8; ROW3 Call – 5 7 #; ROW4 – – 9 0 3;
ROW5 – – * 2 4. In the idle state the columns drive 0 and the rows are
pulled-up inputs with interrupts enabled; a scan drives one line at a time.

CBUS devices (`model/cbus-regs.txt`): 1 = UEMK (register numbers as TriX's
DCT4 UEM); 4 = unknown (probably ZOCUS), register 0 must read `0x04xx`
(cbus.dll self-test `0x5037E008`, else `Kern::Fault("CBus:", 25)`); 5 =
unknown. cbus.dll's register table is at `0x5037E544` ({device, type,
register, shadow, width} x 69).

UEMK registers the start-up path depends on (`model/cbus-regs.txt`, A/D
converter in `ngage_cbus.c`):

| Register | Name / guess | Model | Evidence | Conf. |
|---|---|---|---|---|
| `0x15` | interrupt status | reads `0x0008` | bootstrap `0x2E6C`: without `0x1F` bit 1 the phone stays on only if bit 3 or 4 is set, otherwise it writes `0x12` = 0 (power off, `0x2F00`); ecust `0x50343B64`: bit 4 gives start-up reason 4 | B (bits), C (value) |
| `0x16` | interrupt mask | storage | bootstrap `0x2E88` unmasks bits 3-4 around the `0x15` read | B |
| `0x19` | A/D control: bits 15:12 channel, bit 11 start, bit 7 set by cbus.dll beforehand | starts a conversion | bootstrap `0x3604` writes `0x6800`, cbus.dll `0x5037E1E8` writes `0x6880` (channel 6); TriX names it ADC control | A (use), B (fields) |
| `0x1A` | A/D result, 10 bits | channel value from `adc` lines | bootstrap `0x3104`, cbus.dll `0x5037E228` read it and mask `0x3FF` | A |
| ADC channel 6 | battery-size indicator (BSI) | 485 | cbus.dll `0x5037E240`: 5-49 → state 2 (ecust start-up 6, reported as 5), 50-93 → state 3 (5), 380-590 → state 1 (normal battery), else 0 (ecust reports 9, a list Starter does not have); bootstrap `0x3124`: 5-93 = test jig, > `0x3DD` powers off | A (ranges), C (value) |
| `0x11`, `0x12`, `0x13` (read) | RTC seconds (bits 5:0), minutes (5:0), hours (4:0); writes go to other functions (vibra PWM, watchdog in TriX's names) | time of day: the QEMU RTC at start-up (`-rtc base=`, local time by default) plus guest time | cbus.dll table entries 32-34 (`0x5037E544`) are read-only aliases of these registers; rtc.dll `0x5034A2C4` reads 32, 33, 34, then register `0x01`, until the seconds read the same twice | A |
| `0x01` | RTC day counter, 8 bits | days since start-up midnight; a write sets it | rtc.dll adds it to its base date (`0x5034A678`), clears it (`0x5034932C`) and treats 255 as a clock that lost power (`0x50349030`) | A (use), B (meaning) |
| `0x02`, `0x03` | RTC alarm minutes, hours (bit 7 of `0x03` enables) | storage | rtc.dll `0x5034A3C8` | B |
| `0x04` | RTC calibration | `0xC0` at start (cbus-regs.txt) | rtc.dll treats 0 as a clock that lost power (`0x50349030`) and sets bits 7:6 when it reads 0 (`0x50349CB0`) | B |
| `0x1F` | power-on status; bit 1 = power key held | bit 1 follows the power key (held for the first 3 guest seconds, then key "power" in the key script, F6 in the window) | ekeyb `0x5041CC9C`-`0x5041CCC4` reads bit 1 as key bit 28 (scan code `0xA6`, the power key) and polls it while set; bootstrap `0x3090`: set at power-on → normal power-on (backlight and regulators on at `0x2F64`, superpage `0x4000101C` = 1), which ecust copies to variant `+0x80` (`0x50342AF4`) and turns into start-up reason 0 (`0x50343A6C`). If the key stays held, SysAp sees a held power key; if it is released before the bootstrap reads it, the reason becomes 9 and Starter faults. TriX's DCT4 emulator has the opposite polarity | A (use), B (hold time) |

Start-up reason (`TWD2StartupReason`) as ecust computes it (variant
`+0xD0` = `0x503439AC`, read by HelperDrv control 0 for EStart and through
sysutil, DosServer and Nokia.dsy for Starter): 0 = normal; 1/2 = from
service 1 (rtc.dll), probably alarm; 4 = UEMK `0x15` bit 4; 5 and 6 = test
modes from the BSI; 9 = unknown battery. Starter's table
(`Starter_Arm.RSC` resource 2) maps (reason, software reason) to a start-up
list: (0, 100) = resource 3, the full list; (4, 100) and (1, 100) =
resources 6 and 7 (no phone application); (5, 100) = test servers;
(7, 100) = resource 5 (Startup.app); (0, 210) = SysAp and Startup only. Starter
forces (0, 210) itself when C: is not flash (`0x50961FDC`: `RFs::Drive(C:)`
media type must be 6, EMediaFlash).

## NOR flash (CS0, CS1) — `ngage_flash.c`

| Item | Model | Evidence | Conf. |
|---|---|---|---|
| Command set | AMD: unlock `0xAAA`/`0x554` (word `0x555`/`0x2AA`), `0xA0` program, `0x80`…`0x30` sector erase, `0x90` autoselect, `0x98` CFI, `0xF0` reset; Samsung `0x60` block lock/unlock accepted, blocks never locked | bootstrap `0x0C004748` routines; medint.pdd `0x5037FE44`, `0x50380020` | A |
| Sector map | 64 KB sectors, the top 64 KB of each chip in eight 8 KB sectors (top boot) | medint.pdd `0x5037FC28`: 8 KB at and above region size - 64 KB, for a region that ends at the top of CS1 | B (CS1), C (CS0) |
| Sector erase | takes 20 ms of guest time; only the erasing sector reads status (DQ7 = 0, DQ6/DQ2 toggle, DQ3 = 1); other sectors read array data | medint.pdd waits for DQ7 = 0 and DQ3 = 1 after `0x30` (`0x5037FEAC`), then for `0xFFFF` twice (`0x5037FF34`); a real erase takes about 0.7 s | A (status), C (time, bank layout) |
| Erase suspend/resume | `0xB0` suspends (status DQ7 = 1, DQ2 toggles), `0x30` resumes | medint.pdd `0x5037FEE4`, `0x5037FDEC`; completion check treats DQ7 = 1 as suspended | A |
| C: drive | CS1 `0x400000`-`0x7FFFFF` (4 MB, LFFS), mapped at virtual `0x59200000` and `0x59600000` | medint.pdd object at `0x5037FD64` (base, alias, size `0x400000`), QEMU `gva2gpa` | A |
| Persistence | `flash1-save` file replaces the image when present, written on exit after changes | model feature | - |

The firmware image's C: area is blank (all `0xFF`); LFFS refuses to mount it
(KErrCorrupt) and EStart falls back to a RAM drive (`0x503E9D40`-`0x503E9E40`),
which makes Starter take the (0, 210) list. Holding Call + * + 3 at power-on
(`model/keys/format-c.txt`) makes EStart erase and format C: as LFFS; the
same happens without keys when HelperDrv request 1 ("auxstart",
`0x5037F1C8`) answers 105. HelperDrv answers 100 itself unless variant flag
bit 0 is set; then it asks NOS service 3 (request 12). The NOS stand-in sets
the flags to 3 and answers 105, so a blank C: formats itself at the first
boot (the query is only made when C: does not mount). With 0, C: stayed a
RAM drive, Starter took the (0, 210) list, found no backup server and the
kernel faulted in Starter's cleanup (`RArrayBase::Count` on NULL).

## Trace window (0x0DE00000) — `ngage_sti.c`

| Address | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `0x0DE00000`-`0x0DFFFFFF` | STI trace output: kernel debug text, one byte per address, `0xC0` at the start, `0xE0` at `0x0DFD0000` on wrap | write sink, text to `model/.out/kern.log` | ekern `0x5031E4A8`, `0x5031E538`; trace mask bit 30 (ROM header `iTraceMask` `0xC0008003`) | B |

## Emulator devices (0x0C1F0000) — not UPP_WD2 hardware

Two inventions of this project, for what NOS and the DSP did on the phone
(both encrypted). Only the NOS stand-in uses them (`firmware-patches/nos-stub`,
`docs/NOS_STANDIN.md`); the FPGA core implements them as small blocks.
Nothing in the firmware touches this page: no ROM constant points into it
and no run accesses it. Symbian maps it at virtual `0x581F0000` with the
rest of `0x0C1xxxxx`.

### HLE audio device (0x0C1F0000) — `ngage_audio.c`

Plays two PCM buffers from SDRAM alternately. All registers are 32-bit.

| Offset | Name | Access | Meaning |
|---|---|---|---|
| `+0x00` | ID | R | `0x41554431` ("AUD1") |
| `+0x04` | CTRL | RW | bit 0 RUN: 0 → 1 starts at buffer 0, position 0; 1 → 0 stops and empties both buffers. Bit 1 IRQ enable |
| `+0x08` | FORMAT | RW | bit 0: stereo (L, R frames). Samples are signed 16-bit little-endian |
| `+0x0C` | RATE | RW | frames per second, 4000-48000 |
| `+0x10`, `+0x14` | ADDR0, ADDR1 | RW | physical byte address of buffer 0 / 1 (even) |
| `+0x18`, `+0x1C` | LEN0, LEN1 | RW | frames in buffer 0 / 1; writing a nonzero value marks the buffer full |
| `+0x20` | STATUS | R, W1C | bits 0/1 DONE0/1: the buffer was played to its end (write 1 to clear); bits 4/5 FULL0/1; bit 8 running; bit 9 buffer being played; bit 10 starved |
| `+0x24` | POS | R | frames played from the current buffer |
| `+0x28` | VOLUME | RW | gain, `0x100` = unity (reset value), values above are clamped |
| `+0x2C` | PLAYED | R | frames played since RUN, silence included |

While RUN is set the device plays the current buffer at RATE, multiplying
each sample by VOLUME / 256. At the end of a buffer it marks it empty,
sets its DONE bit and moves to the other one. If the current buffer is
empty it takes the other one when that is full, otherwise it outputs
silence (starved) until one is filled. The interrupt is DONE0 | DONE1 with
IRQ enable, on interrupt source 5 (IrqTimer5: nothing in Symbian binds it
and no timer 5 runs; the stand-in binds it by name, id 98).

FPGA: a block that fetches 16-bit words from SDRAM at RATE and resamples to
MiSTer's 48 kHz AUDIO_L/R (the model interpolates linearly with a 16.16
phase step RATE / 48000; mono goes to both channels). The stand-in only uses
mono at 8000 or 16000 Hz with halves of up to 5600 samples.

### HLE RTC date register (0x0C1F0100) — `ngage_cbus.c`

| Offset | Name | Access | Meaning |
|---|---|---|---|
| `+0x00` | DATE | R | the date on which the UEMK RTC day counter read 0: bits 31:16 year, 15:8 month (1-12), 7:0 day (1-31); 0 = unknown |
| `+0x04` | CBLANK | R | bit 0: no non-erased data has been loaded or programmed in CS1's C: area (chip offsets `0x400000`-`0x7FFFFF`) since the current image began loading. The NOS stand-in answers HelperDrv's "auxstart" query with 105 (format C:) only while this is set (`docs/NOS_STANDIN.md`). The core (`rtl/mem/ddram_flash.sv`) and model keep this cleared across erases and resets; only a new CS1 image load re-arms it. |

On the phone NOS kept this base date in its flash. The model sets it and the
UEMK RTC registers (`0x11`-`0x13` time of day, `0x01` day counter = 0) from
the QEMU RTC at start-up. The FPGA loads them the same way from MiSTer's RTC
(hps_io, BCD date and time) at reset. The stand-in reads DATE once, at the
NOS entry, and gives rtc.dll the base date (`docs/NOS_STANDIN.md`, Clock).

