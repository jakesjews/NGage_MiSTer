# UPP_WD2 register reference (N-Gage QD, RH-29)

What the reference model (`model/`) implements and why. Every row cites
the RH-29 v4.60 code that shows the behaviour: a bootstrap address (plain
CS0, `0x0000`-`0x9FFF`) or a ROM address (`0x50xxxxxx`, file named).
Symbian reaches the registers through virtual `0x58000000 + (phys -
0x0C000000)`; ekern's helpers at `0x5031E6B0` (read32), `0x5031E6BC`
(write32), `0x5031E6FC` (read16), `0x5031E708` (write16) and `0x5031E6C8` /
`0x5031E714` (masked read-modify-write) take that offset.

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

Sources enabled so far: IRQ 0 (tick), 25, 46 (GPIO8High); FIQ 27.

## Timers (0x0C120A00) — `ngage_intc.c`

Timer *n* at `0x0C120A00 + 0x20n`, *n* = 0-5 (stride from timer 4 at `+0x80`
using source 4). Clock assumed 104/3 MHz (34.67 MHz): the kernel's reload
`0x843E2` (`0x5031C6F0`) then gives the EKA1 1/64 s tick (C).

| Offset | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `+0x04` | control | bit 1 = run; reads back what was written | boot `0x31AC`; ekern `0x5031EA58` rewrites until it reads back | B |
| `+0x08` | interrupt flag | set to 1 on underflow; source asserted while bit 0 = 1; software writes it | kernel tick ISR acks with 0 (`0x5031C5C0`); boot and timer-4 ISRs write 1 after disabling the source (`0x3064`, `0x5031C86C`); boot polls it (`0x3208`) | B |
| `+0x10` | counter | live down-count; a write reloads | kernel reads it as a free-running time base (`0x5031E6B4`) | B |
| `+0x18` | reload | loaded on underflow | boot `0x31B4`, ekern `0x5031EAC4` | B |

## LCD bus interface (0x0C121200)

Storage only so far (panel model pending). See `research/peripherals/DISPLAY.md`.

| Address | Name / guess | Evidence | Conf. |
|---|---|---|---|
| `0x0C121200` | sequencer control (`0x09280000` command, `0x09240000|(n-1)` n parameters) | bootstrap `0x6E9C`, lcd.ldd | B |
| `0x0C121204` | aux control / status (bit 2 polled) | bootstrap `0x669C`, lcd.ldd | C |
| `0x0C121208` | data FIFO | bootstrap `0x66E0` | B |

## DPLLs and test interface (0x0C14xxxx)

| Address | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `0x0C149000` | MCU DPLL | bit 0 reads 1 (locked) | bootstrap writes `0x2210` at `0x37F8`, polls at `0x37FC` (`upp-quirks.txt`) | A |
| `0x0C14D000`-`0x0C14D010` | STI (serial trace) control; DCT4 STI `0x0600D000` rebased | storage | ekern `0x5031E40C`: `+0`=2, `+2`=`0x300`, `+4`=`0x205`, `+8`=0, reads `+0xE`, `+0x10` | B |
| `0x0C14F000`-`0x0C14F010` | TESTIF / pin set-up | storage | bootstrap `0x67F8`, ekern | C |

## CTSI, PUP, UIF (0x0C150000)

| Address | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `0x0C150000` | CTSI reset reason | storage (reads 0) | bootstrap `0x2E58` masks `0x0E` | B |
| `0x0C150024`, `0x0C150028` | CTSI IRQ / FIQ controller enable | storage | ekern `0x5031C730`/`0x5031C73C` write 1 | C |
| `0x0C150200`-`0x0C150218` | PUP GENIO set/reset/input/direction | storage | bootstrap `0x3A24`, `0x67C0` (LCD /RES = GENIO4) | B |
| `0x0C150400`-`0x0C150418` | UIF GPIO D/E (keypad lines) | storage | ekeyb.dll; ekern `0x5031E70C` | B |
| `0x0C150420` | CBUS transfer length: bits 4:0 = bits - 1 | `ngage_cbus.c` | cbus.dll `0x5037D014`, bootstrap `0x35F4` | A |
| `0x0C150422` | CBUS control: bits 4:0 register, 7:5 device, bit 8 read (starts it), bit 9 on some writes; bit 10 reads 1 = done | `ngage_cbus.c` | cbus.dll `0x5037D028`, `0x5037CF74`; bootstrap `0x3644` | A |
| `0x0C150424` | CBUS data bits 31:16 | `ngage_cbus.c` | cbus.dll `0x5037D388`, `0x5037D074` | A |
| `0x0C150426` | CBUS data bits 15:0; a write starts a write transfer | `ngage_cbus.c` | bootstrap `0x3604`, cbus.dll `0x5037D39C` | A |
| `0x0C150538`, `0x0C15053C` | unknown, written before STI set-up | storage | ekern `0x5031E410` | C |

CBUS devices (`model/cbus-regs.txt`): 1 = UEMK (register numbers as TriX's
DCT4 UEM); 4 = unknown (probably ZOCUS), register 0 must read `0x04xx`
(cbus.dll self-test `0x5037E008`, else `Kern::Fault("CBus:", 25)`); 5 =
unknown. cbus.dll's register table is at `0x5037E544` ({device, type,
register, shadow, width} x 69).

## Trace window (0x0DE00000) — `ngage_sti.c`

| Address | Name / guess | Behaviour | Evidence | Conf. |
|---|---|---|---|---|
| `0x0DE00000`-`0x0DFFFFFF` | STI trace output: kernel debug text, one byte per address, `0xC0` at the start, `0xE0` at `0x0DFD0000` on wrap | write sink, text to `model/.out/kern.log` | ekern `0x5031E4A8`, `0x5031E538`; trace mask bit 30 (ROM header `iTraceMask` `0xC0008003`) | B |
