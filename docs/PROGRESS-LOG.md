# N-Gage QD MiSTer core: progress log

Newest entries at the bottom. Each entry says what was done, what was
found, and what comes next. Research material lives in `research/`
(untracked); this log is the tracked record.

## 2026-10-19

### Setup
- Renamed the MiSTer template to `NGage.*`; added `build.sh` (Quartus in
  Docker on `ubuntu`, or CrossOver locally), `deploy.sh`, and
  `tools/report_timing.tcl`. `research/` is gitignored.

### Research (agents, all written up under `research/`)
- `research/hardware/`: Nokia RH-29/RH-47/NEM-4 service manuals and
  schematics. **The N-Gage QD has no OMAP1510.** The only processor is
  Nokia's UPP_WD2 ASIC (D100, V3.2E): an ARM9 MCU at up to 104 MHz plus a
  DSP and control logic, running both Symbian and the GSM stack.
  - 16 MB SDRAM (K4M28163, 16-bit, 104 MHz).
  - Two muxed burst NOR flashes: K8S2815ETA 16 MB on CS0 and K8S6415ETA
    8 MB on CS1.
  - Display: 176x208 module (Nokia 4850819, "GD82") on an 8-bit 8080 bus
    with its own controller and frame memory. The controller IC is unknown.
  - Keypad: 6x5 matrix on UPP_WD2 GPIOs, scanned in software.
  - Audio: PCM over EarData to the UEMK codec; no separate DSP chip on the QD.
  - MMC: 1-bit, 8.66 MHz.
- `research/symbian/`, `research/firmware/`: EKA1 ROM format, firmware
  versions, Phoenix flash-file format, game cards (per-title CID; the core
  must present real CID/CSD/OCR).
- A 2002 Nokia paper calls the chip a "130 MHz ARM925 MCU" with "the
  structure of TI OMAP". The boot code's CP15 use agrees (see below), so
  the OMAP5910 docs in `research/omap/` may apply block by block.
- `research/arm925t/`, `research/fpga-cores/`: ZAP is the recommended
  fabric CPU base (only open core with an ARMv4 MMU); the runner-up is
  Robert Peip's ARM9 lineage.
- `research/hps-hybrid/`, `research/bench-hps/`: QEMU-class emulation of
  an ARM9 on the MiSTer's Cortex-A9 measured about 9 MIPS, about 4-8x too
  slow. Native execution on CPU1 under a supervisor is feasible. The
  unmodified framework gives the core only DDR3 and a vsync IRQ toward
  the HPS, so a hybrid would need DDR3 mailboxes and polling.
- Prior art: MiSTer forum thread t=10933 (2026-10-04, user "Nortido"):
  an N-Gage core with the ARM on the HPS's second A9 and peripherals in
  the fabric, with no source posted.

### Decisions (user)
- Download RH-29 v4.60 firmware for development: approved. Files are in
  `research/firmware/images/`, never committed.
- CPU path (fabric vs HPS): decide after reverse engineering.

### Firmware findings (RH-29 v4.60)
- Phoenix data package from archive.org `Nokia_DCT4_firmwares` (range
  fetch), and the SDumper ROM dump from `symbian-firmware-dumps`.
- `tools/fls2bin.py` converts the MCU file `RH2946.0C1` and the language
  pack `RH2946.0S5` into flat NOR images.
  - MCU: CS0 0x000000-0xEFFFFF and CS1 0x2000000-0x2269FFF.
  - Language pack: CS0 0xF00000-0xF8EFFF and CS1 0x2330000-0x23FFFFF.
- The Symbian TRomHeader is at flash 0. The XIP ROM (0x1170000 bytes) is
  CS0[0..0xEFFFFF] + CS1[0..0x26FFFF] at virtual 0x50000000. It matches
  the on-device dump except in two places:
  - 0x12C-0x163: 56 per-phone bytes after the marker "KaeP". The flash
    file leaves them out.
  - **0xA000-0x310FFF is encrypted in flash** and plain Thumb code on the
    device. It is not the published S40 DCT4 scramble, and no GF(2)
    polynomial fits it. Over a zero run the pad looks random, which
    suggests an address-tweaked cipher. It is unknown whether the
    hardware decrypts on the fly or the boot code decrypts into RAM.
- `tools/romhdr.py`: EKA1 header pointers lead to the file's TRomEntry.
  Kernel `ekern.exe` code is at 0x5031B000; the variant is `ecust.dll`.
  Drivers: lcd.ldd, LCDDEV.DLL, medmmc.pdd, epbus.dll, ekeyb.dll,
  euart1.pdd, medint.pdd, btldd.ldd, rtc.dll.
- Boot code (flash 0-0xA000, plain):
  - It sets CP15 control to 0x1272 (alignment faults on) and DACR to
    0x55555557, and cleans the D-cache with c7,c10,0. That operation is
    ARM925T-only, so the core is an ARM925T.
  - It uses MD5 constants, likely the program-code check.
  - It probes the CS1 flash ID: Intel 0x89/0x8874, or Samsung 0xEC with
    device 0x22F2/0x22FA, or AMD 0x01 with device 0x277E.

### Reference model (QEMU)
- `model/`: a QEMU v11.1.2 machine `ngage-qd`.
  - `model/hw/ngage.c`: the board, plus a probe that logs every unclaimed
    access with the exact guest PC.
  - `model/hw/ngage_flash.c`: AMD command-set NOR.
  - `model/build.sh` clones and builds QEMU into `model/.qemu-src` and
    `model/.build`. `model/run.sh -t 5` runs the firmware and writes logs
    to `model/.out/`.
- The physical map learned so far from running the boot code:
  - 0x00000000: CS0 flash. 0x02000000: CS1 flash.
  - 0x08000000: memory-controller registers. The boot code writes
    0x7037F800, 0xB2950489, 0x37, and 0x20202112 at +0x10 and +0x14.
  - 0x0A000000: SDRAM, 16 MB. The boot code memory-tests it at 0x264.
  - 0x0C000000: on-chip RAM. Flash routines are copied to 0x0C004748
    and run there. The size is unknown; 256 KB is mapped.
  - 0x0C120000 and up, 0x0C150004: registers. Symbian maps this space
    at virtual 0x58000000.
  - 0x04000000: touched during boot (next to investigate).
- Current state: the boot polls a register at 0x0C1200xx (about 200k
  reads).

### Next
1. Model the register at 0x0C1200xx so boot continues. Keep iterating on
   the probe log and documenting each register in `docs/UPP_WD2.md`.
2. Find how the encrypted region is decrypted. Look in the boot code
   around the MD5 check and the 0x0C12xxxx/0x0C15xxxx registers.
3. Then the shared fabric peripherals with Verilator tests, then the CPU
   path decision.

### 2026-10-19, later: boot reaches the MMU and the integrity check
- `model/upp-quirks.txt` holds read-status facts; editing it needs no rebuild:
  - 0x0C120020 bits 26-28: DPLL lock.
  - 0x0C149000 bit 0: ready.
  - 0x0C150422 bit 10: serial (CBUS) transfer done.
- `model/hw/ngage_upp.c` models register blocks as storage. It logs the
  first access to each register with its PC in `model/.out/regs.log`.
- `model/where.sh N` runs N seconds and then prints the CPU state under GDB.
  Extra GDB commands go in `NGAGE_GDB_EXTRA`.
- Facts learned from running the boot code:
  - The boot code runs flash-ID routines from on-chip RAM at 0x0C004748
    and probes a third chip select at 0x04000000. That one is empty on
    the QD.
  - Stack at 0x0AFFF348, which confirms SDRAM is 16 MB at 0x0A000000.
  - LCD block at 0x0C121200/04/08, as the peripheral agent found.
  - Registers at 0x0C1502xx and 0x0C150034.
- MMU page tables, from the model:
  - Page directory at 0x0A078000, superpage at 0x40000000.
  - ROM: VA 0x50000000-0x50EFFFFF maps CS0 linearly, and 0x50F00000 up
    maps CS1. The extension ROM pages are at 0x51100000-0x513FFFFF.
  - Registers: VA 0x58000000/0x58100000 map PA 0x0C000000/0x0C100000,
    and VA 0x58200000/0x58300000 map **PA 0x0D000000/0x0D100000**. That
    is a second register space, still to identify.
- **Correction to the earlier entry:** the SDumper "plaintext" at
  0x5000A000-0x50310FFF is not plaintext. After the integrity check,
  routine 0x3384 adds 0x500000 to the physical address of every page in
  that range. Symbian therefore sees ROM content from 0x5050A000 there,
  which hides the region. The dump region is byte-identical to
  0x5050A000-0x50810FFF.
- The hidden region holds a high-entropy blob at flash
  [0xA000, 0xA000+0x2AD000), described at 0x174 (start 0xA000, length
  0x2AD000, then 0x11C4 and 0xE3DEFE99). Data after 0x2B7000 looks like
  normal code. It is probably the cellular (ISA) software. It is
  encrypted or compressed, and the algorithm is unknown.
- Integrity check:
  - Routine 0x3238 checks MD5 per table entry {start, end, digest} at
    0x8F00. It is called from 0x3568/0x3574; a mismatch reaches the halt
    loop at 0x3230.
  - Entry 0x8F18 covers 0x50009000-0x51169FFF with digest
    2f00b1ff1b8f03f0592c4355f3177651. That matches neither the raw bytes
    (4704ca03...) nor the alias (194165af...). So a real phone reads
    different bytes in the blob at boot, most likely through hardware
    decryption of a flash window. This is unproven.
  - Entry 0x8F00 covers 0x51230000-0x5138EFFF (language-pack ROM) and
    passes with our image. That confirms the flash image and the mapping.
- Model image `research/firmware/images/nor/rh29-4.60-cs0-model.bin`:
  the raw flash, the 56 per-phone bytes restored from the dump, and digest
  0x8F20 replaced with the MD5 the model sees. This is a deliberate model
  shortcut. If the blob turns out to be needed at run time, its
  decryption is a blocker.
- Now: the boot starts a timer at 0x0C120A00 (+04=2, +10/+18=0x016B28C0,
  +08=0, then 0x0C120108=1), enables IRQs, and waits at 0x3208 for
  0x0C120A08 to become nonzero. Next: model the timer and the interrupt
  controller. The IRQ vector is at 0x18 and goes to the handler at 0x418.

### 2026-10-19, later: kernel starts
- `model/hw/ngage_cbus.c`: the CBUS master at 0x0C150420, with a UEMK
  register file loaded from `model/uemk-regs.txt`.
  - Read: device to +0x420, register|0x100 to +0x422, then poll bit 10
    of +0x422 and read the data at +0x426.
  - Write: device to +0x420, register to +0x422, data to +0x426.
  - The boot reads UEMK 0x3F, 0x36 and 0x35. It continues only if UEMK
    0x35 bit 3 or bit 4 is set; otherwise it writes UEMK 0x32 = 0, which
    is power off. The model returns 0x35 = 0x0008, read-only.
- `model/hw/ngage_intc.c`: the interrupt controller at 0x0C120100 and
  timer 0 at 0x0C120A00.
  - Interrupt controller: +08 enable, +0C acknowledge, +14 "current IRQ
    number" (0 = none). The kernel also reads the +0x14 registers of banks
    at +0x40 and +0x80, adding 32 and 64, and dispatches through ISR
    table index number + 0x5C (dispatch code at 0x5031C87C).
  - Timer: +10 live down-counter, +18 reload, +04 bit 1 run. The kernel
    reload of 0x843E2 gives a 1/64 s tick at 104/3 MHz, so the timer
    clock is 34.67 MHz (inferred).
- Kernel interrupt-source names, in kernel order:
  `research/firmware/analysis/ekern-interrupt-table.txt`. FIQ STIAbort
  ... RTCWBStatus; then IRQ Timer0-5, DMA0-7, FlashCopyRdy, LCDBuffer,
  Ir4M x5, MMC x4, CTSI x2, APIIOAbort, APIMissAlign, GPIO0..26 Low/High.
  The bit numbering is not confirmed: the boot enables bit 0 for timer 0,
  and the kernel enables bit 25.
- Other facts:
  - EKA1 runs kernel code in UND mode (0xDB) and calls SVC from there.
    The interrupt exit at 0x50321B00 reloads DACR from the current thread
    at offset 0x168.
  - Register access in ekern goes through helpers at 0x5031E6B0 (read)
    and 0x5031E6BC (write), with 0x58000000 + offset.
- Now: the kernel reaches its halt at 0x5031E394, entered from 0x5032DFEC,
  which looks like a fault/restart path. The cause is not yet known.

### 2026-10-19, end of session (usage limit)
- Three agents were stopped before they produced anything:
  - firmware bring-up in the model;
  - the FPGA board-level devices and MiSTer shell;
  - the UPP_WD2 community register-map research. That one's partial
    notes may be in `research/upp-wd2/`.
- Resume plan:
  1. Model: find why the kernel faults (halt at 0x5031E394 via
     0x5032DFEC; decode Kern::Fault's category and reason). Then fix the
     interrupt-controller numbering. Then the LCD panel model with
     on-screen output, the MMC card, keys. Document registers in
     `docs/UPP_WD2.md`.
  2. FPGA, independent of the CPU choice: `rtl/board/` lcd_panel,
     video_out, mmc_card (native 1-bit, CID/CSD sidecar), nor_flash (AMD
     set, IDs 0xEC/0x22F8/0x22FA), keypad_matrix. Then a minimal NGage.sv
     with OSD flash loading to DDR3, Verilator tests, and
     `./build.sh remote map`.
  3. Decide the CPU path once the model boots.

### 2026-10-19, late: LCD controller research (agent finished after stop)
- The controller IC is still unidentified. The interface and command set
  are pinned down:
  - Interface: Nokia "MeSSI-8" 8-bit 8080 bus (later MIPI DBI-B).
  - Frame memory: 176x208x16 RAM (RGB565). The OS uses COLMOD 12 bpp,
    packed as 3 bytes per 2 pixels.
  - Commands: the Nokia/MIPI DCS-style set: CASET 0x2A, PASET 0x2B,
    RAMWR 0x2C, RAMRD 0x2E, MADCTL 0x36, COLMOD 0x3A, RGBSET 0x2D (48 bytes),
    TEON 0x35, PTLAR 0x30, GAMSET 0x26, RDDID 0x04, RDDST 0x09. 0x24 (one
    parameter) is not in any datasheet; accept and ignore it.
- Boot LCD helper 0x6E9C:
  - Writes 0x09280000 to 0x0C121200, then the command byte to +0x04.
  - For n parameters, writes 0x09240000|(n-1) to +0x00, then the bytes
    to +0x04.
  - The LUT upload uses control word 0x092C002F.
- The original N-Gage panel also sits on the 8080 bus, without CS and TE.
- Full report, datasheets and the sibling Nokia LCD table:
  `research/upp-wd2/` (downloads/lcd/, repos/).

### 2026-10-19, late: DCT4 flasher-community findings (agent report)
- Flash chip selects on WD2 are four windows 32 MB apart: 0x00000000,
  0x02000000, 0x04000000, 0x06000000. On the QD, UFS shows 16 MB at CS0
  and 8 MB at CS1; NEM-4 also fills CS2. This matches the model.
  - One QD (UFS) reports AMD 29BDS128J/29BDS064J parts.
  - JAF reports CS1 ID 0x22FA00EC (Samsung 0xEC, device 0x22FA), which
    the model already uses.
- WD2 hardware IDs: 0x0082 = WD2 v2.x (N-Gage, 6600), 0x1080/0x1081 =
  WD2 v3.x (QD, 7610). TI is the likely maker: the parts are marked
  "F7xxxxx", and TechInsights has a report CAR-0501-005 on "TI UPPWD2".
- Flasher boot sequence:
  - The boot ROM answers over FBUS ("1st Boot Ok, WD2, UPP: xxxx").
  - Then the w3_2nd.fia second stage (about 4 KB), then w3_amd.fia, the
    flash algorithm (about 32 KB).
  - The boot ROM itself has never been dumped publicly.
- The ARM core is named only in secondary sources (ARM920T). The
  firmware's CP15 use (ARM925T-only c7,c10,0) remains the best evidence.
- UPP8M (Series 40) differs: flash at 0x01000000, boot ROM at 0x008xxxxx
  with a "hardware decryptor" set up by ROM calls (g3gg0, 2006). This
  supports the idea that WD2 decrypts its encrypted flash region in
  hardware.
- No public source confirms the 0x0Cxxxxxx register addresses, so the
  firmware is the only evidence for them.
- Material: `research/upp-wd2/` (MEMORY-MAP.md, REGISTERS.md,
  OPEN-QUESTIONS.md, downloads/web, repos).

### 2026-10-19/20: resumed after the usage-limit reset
- Restarted two agents: firmware bring-up in the model, and the FPGA
  board-level devices with the MiSTer shell. Both log under their own
  headings here.
- ZAP trial build: Quartus 17.0.2 on ubuntu (`~/dev/mister/zap-eval`,
  sources in `research/fpga-cores/quartus-zap/`).
  - ZAP was converted to Verilog with sv2v and set to 16 KB I-cache and
    8 KB D-cache with 16-byte lines, targeting 104 MHz.
  - Quartus 17 rejects sv2v's empty `begin ; end` generate branches;
    they were stripped. A stub replaces the debug decompiler.
  - The result goes here when the compile finishes.
- SSH: `root@mister` authorizes only the 1Password-held key, so logins
  depend on the 1Password agent signing. One login failed for that reason
  and the retry worked. `ubuntu` also authorizes `~/.ssh/id_ed25519` (no
  passphrase), so it never depends on 1Password.

## FPGA side

### 2026-10-20: LCD panel (`rtl/board/lcd_panel.sv`)
- Display module on the 8080 bus: 176x208 RGB565 frame memory in block
  RAM with a second read port for scan-out; the DCS command set from the
  brief plus RDDPM/RDDMADCTL/RDDCOLMOD/RDDIM/RDDSM/RDDSDR and RDID1-3
  (cheap, and standard DCS). 12 bpp through the RGBSET table, 16 bpp, and
  18 bpp. 0x24 takes its parameter and is ignored; other opcodes are NOPs.
- Bench `make -C sim lcd`: firmware-style start-up and a picture written
  three ways (MADCTL 0xD4 in 12 bpp, MADCTL 0 with mirrored coordinates in
  16 bpp, MV in 18 bpp) must equal a reference built from the source
  pictures (PPMs in `sim/build/out`); then 40 random rounds against a C++
  model, byte-exact reads, TE timing, /RES. Passes; injected bugs are caught.
- Assumptions, each a parameter or noted in the file header:
  - `PANEL_ROT180=1`: memory (175-x, 207-y) is the viewer's (x, y). Both
    lcd.ldd variants (MADCTL 0xD4; MADCTL 0 with software mirroring) only
    come out upright that way, given that ML/MH change refresh order only.
  - TE from an internal 74 Hz refresh over 208+12 lines; `te_ext_sel`
    switches TE to an outside signal (e.g. the video's vertical blank).
  - RDDID bytes (`ID1-3`), blank colours, COLMOD after reset, RAMRD always
    16 bpp, scroll area counted from the top whatever ML says.

### 2026-10-20: video output (`rtl/board/video_out.sv`)
- Scan-out of the panel's picture: 176x208 portrait in a 240p-compatible
  frame (104 MHz clock, a pixel every 16 clocks = 6.5 MHz; 413 x 262,
  15.74 kHz, 60.07 Hz), centred on the TV's visible area, DE only over the
  picture so the HDMI scaler gets just the picture. `rotate` turns it a
  quarter turn either way (208x176), switching at a frame boundary.
- Bench `make -C sim video`: pixel clock, line/frame totals, sync widths,
  rates, DE/blanking placement and the captured picture in all four
  rotate settings, plus a mid-frame change. PPMs in `sim/build/out`.

### 2026-10-20: keypad (`rtl/board/keypad_matrix.sv`, `rtl/board/ngage_keys.sv`)
- 6x5 matrix with the firmware table's positions (Clear ROW0/COL3, Edit
  ROW1/COL3); `ngage_keys` names the bits (row * 5 + column). Lines joined
  through pressed keys form nets, so ghosting is as on the real matrix;
  either side may be driven. Power key is a separate PWRONX output.
- Assumed: a line driven high against a low one reads low (100 ohm column
  resistors; not documented). Lines have pull-ups (firmware reads them
  active-low).
- Bench `make -C sim keypad`: every key alone by the firmware-style column
  scan and the reverse scan, unfitted positions, the ghost case, a long
  chain, 200k random cases against a union-find reference, PWRONX.

### 2026-10-20: NOR flash (`rtl/board/nor_flash.sv`)
- AMD command set on a 16-bit word device: read array, autoselect (0xEC,
  `DEVICE_ID` 0x22F8 / 0x22FA), CFI (QRY, PRI 1.3, sector map), word
  program (only clears bits; DQ5 on a 0-to-1 program until F0), sector
  erase with the 50 us window for more sectors, chip erase, erase
  suspend/resume with programs outside the suspended sectors, unlock
  bypass, F0 and RP#. DQ7/DQ6/DQ3/DQ2 status per bank; other banks read
  the array (read-while-write).
- The array is behind a req/ack word port for a later SDRAM/DDR3
  controller; erase writes 0xFFFF word by word. An operation lasts
  max(busy time, memory time): `PROGRAM_CLKS` (10 us), `SECTOR_ERASE_CLKS`
  (0.7 s), `ERASE_WINDOW_CLKS` (50 us); chip erase = every sector in turn.
- Assumed: top-boot map (8 x 4K-word sectors at the top, 32K-word
  elsewhere: 263 / 135 sectors), 16 banks, busy times, CFI timing/voltage
  fields, extra IDs 0, autoselect/CFI answered at every address, 555/C0
  burst configuration taken and ignored.
- Bench `make -C sim flash` runs the 16 MB and the 8 MB chip against a
  memory with random 1-12 clock latency: reads, IDs, CFI, program with
  status and busy time, erase (main, parameter, two banks in one window,
  window abort), suspend/resume, bypass, RP#, chip erase. Passes (4 seeds).

### 2026-10-19, night: kernel faults found and fixed; file server starts
- **The kernel halt was `Kern::Fault("CBus:", 25)`.** Restart path
  `0x5032DF68` stores the reason at superpage `0x40000410` and the category
  (8 chars) at `0x40000418`, then copies both to on-chip RAM `0x0C0047F0`.
  Read them with `NGAGE_GDB_EXTRA=$'x/4wx 0x40000410\nx/8c 0x40000418'`.
- CBUS was decoded wrongly. Correct layout (cbus.dll `0x5037CF4C`/`0x5037D28C`):
  `+0x420` = bits - 1; `+0x422` = register (4:0) | device (7:5) | read (bit 8);
  bit 10 = done; `+0x424`/`+0x426` = data high/low; writing `+0x426` starts a
  write. So the bootstrap's "UEMK 0x35" is device 1 (UEMK) register 0x15.
  cbus.dll self-tests device 4 (register 0 must read `0x04xx`, register 0x0D
  must hold a value). `model/uemk-regs.txt` is now `model/cbus-regs.txt`
  (`<device> <register> <value> [ro]`).
- Interrupt controller rebuilt from the kernel (IRQ dispatcher `0x5031C87C`,
  FIQ dispatcher `0x5031C99C`, enable/disable helpers `0x5031E874-0x5031EA44`):
  IRQ plane at `0x0C120100`, FIQ plane at `0x0C1201C0`, three 32-source banks
  each; `+08` enable set, `+0C` enable clear, `+10` pending, `+14` active
  source (1-based). Source numbering follows the kernel's name table, e.g.
  Timer0-5 = 0-5, LCDBuffer 15, MMC 21-24, CTSI_IRQ 25. Six timers at
  `0x0C120A00 + 0x20n`; `+08` is the interrupt flag (the tick ISR
  `0x5031C5B0` acks it with 0). Details in `docs/UPP_WD2.md` (new).
- **NOS (cellular RTOS) blocker.** nosstarter.ext calls the NOS entry
  `0x5149E4D4` = CS0 `0x9E4D4`, inside the encrypted region, and the kernel
  restarts. NOS also provides kernel interfaces Symbian depends on:
  - variant services 3, 6, 7 (`RegisterService` = ecust vtable `+0xFC`,
    `GetService` = `+0x100`; no Symbian file registers these);
  - the kernel's power-model object (ekern ordinal 394 installs it at
    `0x80006BC4`; base class constructor = ordinal 493);
  - the variant flag word `+0x90` (setter vtable `+0x128`), which ecust waits on.
- Model shortcut: `model/rom-patches.txt`, applied at load by
  `model/hw/ngage_patch.c` and logged. It places a small NOS stand-in
  (`model/nos-stub/nos_stub.S`, linked at `0x5149E4D4`) at the NOS entry, and
  recomputes the integrity digest of table entry `0x8F18`. The digest is
  MD5(CS0[0x9000:0xF00000] + CS1[0:0x26A000]). The stand-in registers
  placeholder services (methods return 0; service 3's read zeroes its output),
  builds the power model with the kernel's own base constructor, and sets the
  flags to 3. Every behaviour in it is a guess about NOS.
- Kernel debug text goes to the STI trace window at PA `0x0DE00000` (virtual
  `0x59000000`), because ROM `iTraceMask` = `0xC0008003` has bit 30 set. The
  model writes it to `model/.out/kern.log`; so far it only shows
  "TRtcQueue::Add: 2" from rtc.dll.
- New tools: `model/sample.sh` (PC histogram via the monitor),
  `model/gdbrun.sh CMDFILE` (start halted, run GDB commands),
  `model/gdbat.sh SECS CMDFILE`, `model/threads.sh` (lists EKA1 threads from a
  kernel-memory dump), `model/tools/romdis.py ROM NAME [-t]` (disassemble one
  ROM file at its address). Disassemblies of cbus.dll, ecust.dll, epbus.dll,
  medint.pdd, lcd.ldd, EUser, ELocal, EFile and others are in
  `research/firmware/analysis/`.
- State: kernel, ecust.dll, extensions rtc, nosstarter, epbus, product_info,
  ekeyb, and the file server start. Threads: Supervisor, NULL, EFile's Main,
  LoaderThread and StartupThread. The StartupThread waits on a file-server
  request, and Main waits inside ELocal (FAT) code; the cause is not yet found.
  Candidates: rtc.dll's alarm path through NOS/UEMK, or the FIQ tick
  (`0x0C120050` bit 1), which nothing raises yet.

### 2026-10-20: MMC card (`rtl/board/mmc_card.sv`)
- MMC 3.x card in 1-bit native mode, clocked by the host's CLK (sampled
  in clk; CLK high and low >= 2 clocks): CMD0/1/2/3/4/7/9/10/12/13/15/16/
  17/18/24/25, R1/R2/R3 with CRC7, data with CRC16, CRC status token and
  busy, card states idle..dis/ina, error bits reported in the next R1.
  Reads of 1-512 bytes across block boundaries; a two-sector buffer
  prefetches the next block of CMD18. Backed by hps_io slot 0 (WIDE=1).
- Sidecar: the last 512 bytes of the image, "NGAGEMMC", version, CID at
  16, CSD at 32, OCR at 48 (big-endian); the card's data is the rest.
  CRC7 bytes are computed. Without the sidecar: a writable default card
  (CID "MiSTer", CCC 0x015, capacity from the file size up to 1 GB,
  TMP_WRITE_PROTECT when mounted read-only). Retail CSDs (CCC 0x007) make
  CMD24/25 illegal; write-protected writable classes give WP_VIOLATION.
- Bench `make -C sim mmc`: C++ host on the bus plus an hps_io model; the
  SonicN CID/CSD sidecar must come back with CRC bytes 0x5D/0xDB as
  computed in MMC.md; identification timing (NID 5, NCR 2), reads
  (single, multiple + CMD12, partial, across blocks, past the CSD end,
  past the file end -> zeros), writes (token, busy, CMD25 + CMD12, bad
  CRC), errors, deselect, inactive, read-only. Passes on 8 seeds.
- Not modelled: CMD11 stream read (the retail CSD claims class 1), erase,
  write-protect groups, CMD42 lock. Open question: does the firmware use
  CMD11? If it does, the card needs it.

### 2026-10-20: ZAP fits and meets 104 MHz on the 5CSEBA6
- Quartus 17.0.2 full compile of ZAP (HEAD fc7bd75, sv2v-converted),
  configured with 16 KB I-cache and 8 KB D-cache, 16-byte lines, MMU on,
  behind a 16 KB test RAM:

  | Resource | Used |
  |---|---|
  | ALMs | 12,076 of 41,910 (29%) |
  | Registers | 12,687 |
  | M10K blocks | 64 (12%) |
  | DSP blocks | 4 |
  | Worst setup slack at 104 MHz (9.615 ns) | +0.082 ns, slow 100C corner |

  All corners pass.
- Two Quartus 17 fixes were needed:
  - Strip sv2v's empty `begin ; end` generate branches.
  - Rewrite `zap_ram_simple_ben` as one `zap_ram_simple` per byte lane,
    because Quartus did not infer the byte-enable RAM after sv2v and
    built 24 KB of cache from flip-flops.
  - Also add a stub for the debug `zap_decompile`.
- Project: `research/fpga-cores/quartus-zap/` (on ubuntu:
  `~/dev/mister/zap-eval`).
- Meaning for the CPU decision: a fabric ARM at the real clock, with
  ARM925T cache sizes, fits with room for the peripherals and the
  framework. Timing margin is thin, so the CPU may need its own clock
  domain or a couple of pipeline tweaks once inside the full core. ZAP
  still needs the ARM925T changes listed in research/fpga-cores/README.md
  (CP15 identity, alignment faults, high vectors, ARMv4T-only decoding,
  cache geometry and maintenance ops). GPL: HEAD is GPLv3; the last
  GPLv2 commit is 93b3553.

### 2026-10-20, FPGA side: shell (`NGage.sv`, `rtl/mister/`)
- clk_sys is now 104 MHz (rtl/pll: 4 x 26 MHz, so 104/3 and 26/3 divide
  exactly). Video: a pixel every 16 clocks.
- OSD: F1/F2 load the CS0/CS1 flash images into DDR3 at 0x31000000 /
  0x32000000 (`ddram_loader`, one DDR3 write per 16-bit word, ioctl_wait
  while the port is busy); S0 mounts the MMC image (`mmc_card` on hps_io
  slot 0, WIDE=1); rotation, aspect ratio (11:13 / 13:11), scandoubler
  through the framework's video_mixer, reset. Joystick J1 buttons: 5, 7,
  OK, soft keys, Menu, Call, End, *, #, Clear, Edit, Power; keyboard map in
  `rtl/mister/ngage_input.sv` (arrows, Enter/Space OK, digits, Z/X = 5/7,
  F1/F2 soft, F3/F4 call/end, F5 menu, Backspace clear, Shift edit, F8 power).
- No CPU yet: `lcd_testgen` drives the panel's 8080 bus like the firmware
  (MADCTL 0xD4, COLMOD 3, RGBSET) with a test picture, and scans the keypad
  matrix to draw each key's state. The flash chips are instantiated with an
  idle bus and an unserved memory port; the MMC card has an idle bus.
- Bench `make -C sim top` (emu with hps_io/PLL/video_mixer stand-ins): the
  picture at the video outputs equals the reference, upright and turned;
  held keys light their boxes (Up+Call+5 also light RSoft: a real ghost);
  ioctl images land in DDR3 byte for byte; mounting reads the sidecar.
- Verilator cannot simulate sys/video_mixer.sv: it declares R_in/G_in/B_in
  in unnamed generate blocks and uses them outside (Quartus accepts it), so
  the bench uses a pass-through stand-in.
- Quartus 17.0.2 map (`./build.sh remote map`): 0 errors, 20 warnings (the
  only one in our files: the unused BFA register). Whole design 14847 ALUTs,
  14532 registers, 1045860 block bits, 33 DSPs; emu 4015 ALUTs, 3343
  registers, 661603 bits (lcd_panel 1000 / 644 / 585728; keypad_matrix
  242 ALUTs; lcd_testgen 521; video_out 126; mmc_card 109 / 149 / 8192 with
  its bus idle; the idle flash chips are optimised away).
- Removed the template's demo core (rtl/mycore.v, cos.sv, lfsr.v).

### 2026-10-19, night: LCD shows the boot logo; S60 start-up reaches Starter
- **LCD**: `model/hw/ngage_lcd.c` models the LCD bus interface (0x0C121200)
  and a DCS-style 176x208 panel, with a QEMU graphic console
  (`model/run.sh -w` opens a cocoa window) and PNG/PPM screenshots
  (`model/.out/lcd-last.png` on exit; `NGAGE_SHOT=N` for every N guest
  seconds). The **Nokia boot logo renders correctly**, upright and in the
  right colours. Interface facts (lcd.ldd `0x50406928`, bootstrap 0x6600-0x6F40):
  - Control bits 19:18 select the FIFO-word-to-bus-byte packing: 2 = one
    command byte; 1 = 3 bytes from two 12-bit units (LSB first, or with
    bit 31 the DCS pixel order R0G0 B0R1 G1B1); 3 = 4 bytes, LSB first.
    Bits 15:0 = bytes - 1. 0x0784xxxx = read phase, one byte per +0x08 read.
  - Control bit 30 reads 1 (ready). Aux bit 2 reads 1 (FIFO can take a word).
  - Panel RDDID ID1 0x29 selects module "0x10" in both drivers (0x83
    selects module 4). The bootstrap stores the module type at SDRAM
    `0x0A012000+24` (0x39B0); ecust copies it to variant `+0x7C`, which
    lcd.ldd reads. With 0x29 the image comes out upright under MADCTL 0xD4,
    so the panel is assumed mounted rotated 180 degrees.
- **Timers**: high-resolution timer 1 (kernel object 0x80000558) uses
  control = 1, i.e. one-shot; control bit 1 = periodic. Any write to +0x08
  acknowledges. The timer clock of 34.67 MHz is confirmed by the kernel's
  microsecond conversion (x34666/1000 at 0x5031CB74).
- **MMC**: `model/hw/ngage_mmc.c` covers the command and response path from
  epbus.dll; register details are in `docs/UPP_WD2.md`. An empty slot now
  times out cleanly. The data path uses DMA channel 5 through kernel DMA
  objects and is not modelled yet.
- **Flash**: medint.pdd uses the Samsung block lock/unlock command (0x60,
  0x60 with A6), which is now accepted.
- **NOS stand-in additions**:
  - service 3 reads that carry a DFC complete by queueing it (TDfc::Add =
    ekern ordinal 7);
  - the hidden NOS DLL (header 0x51168FF0) exports ordinals 4 (0x514A1CA0)
    and 6 (0x514A261C) into the encrypted code, and nosdriver.ldd uses them;
    stand-in `model/nos-stub/nos_dll.S` at CS0 0xA1CA0.
- **State after 20 s**: processes EFile, EStart, EwSrv (window server),
  FbServ, SharedDataServer, DosServer, Starter, and two AppRun.exe (started
  by EikCore for the Eikon server). Starter then fails:
  `CBaBackupSessionWrapper` cannot find the backup server, which EikSrv.dll
  hosts ("BackupServerThread"). It leaves with KErrNotFound, crashes in its
  own cleanup (RArrayBase::Count on NULL), and the kernel restarts. The two
  AppRun processes are blocked in a session connect and a SendReceive.
- New tools:
  - `model/tools/implib.py LIB --rom ROM --image NAME` names a ROM DLL's
    exports from the SDK's ARMI import libraries. EUser and Bafl tables are
    in `research/firmware/analysis/*.exports.txt`. The EUser ordinals check
    out: `User::Leave` = 0x503A188C, `LeaveIfError` = 0x503BA5CC,
    `WaitForRequest` = 0x503AD5D0, `RProcess::Create` = 0x503B36A4.
  - `model/threads.sh` lists threads with their process (named by code
    address).
  - GDB command files with `commands` blocks log leaves and process creation
    (examples in this session's notes; see the next entry).

### 2026-10-20, FPGA side: 104 MHz timing, flash block lock, open questions
- Full compile of the core (`./build.sh remote compile`): the first run
  missed 104 MHz by 0.263 ns, all in keypad_matrix (six-pass propagation
  between lcd_testgen's column register and its row capture; the
  framework's worst path is +0.56 ns). keypad_matrix now works the joins
  out in registers (one step a clock, settled ten clocks after a key
  change); the drive-to-level path is one AND-OR. Second run meets
  every corner: worst setup +0.354 ns (slow -40C), hold +0.058 ns; 9,472
  ALMs (23%), 15,282 registers, 137 M10K, 33 DSP, 3 PLLs. RBF builds.
- Block-level compile (every board device, ports on virtual pins, 104 MHz;
  project kept outside the repo): the MMC card's buffer bookkeeping was
  about 15 ns (now two register stages, used only once their inputs have
  been stable) and its CMD17/18/24 range checks 0.5 ns over (now
  registered a clock after the frame). Final: every
  corner met, worst setup +0.031 ns (slow -40C); 5,264 ALMs for all six.
  Per block (ALUTs / registers / block bits): keypad_matrix 401 / 146;
  lcd_panel 1117 / 712 / 585728 (72 M10K); video_out 117 / 69; mmc_card
  2739 / 1355 / 8192; nor_flash 16 MB 2271 / 824; nor_flash 8 MB
  1411 / 563.
- Final `./build.sh remote map` on HEAD: 0 errors, 20 warnings (ours: the
  unused BFA register only). sys_top 14,843 ALUTs / 14,795 registers /
  1,045,761 block bits / 33 DSP; emu 3,988 / 3,509 / 661,504 (the flash
  chips and most of the MMC card are optimised away while their buses are
  idle; see the block figures above).
- Flash: Samsung block lock/unlock (60, 60 at the block, A6 = unlock), as
  the model found medint.pdd using; lock state at autoselect +02; locked
  sectors are not programmed or erased. `LOCKED_AT_RESET = 0` [assumed].
- MMC sidecar formats differ: the FPGA card reads a trailer block in the
  image (MiSTer mounts one file a slot); the QEMU model reads
  `<image>.cid` / `.csd`. A small converter would let one dump serve both.
- Open questions for the FPGA side:
  - LCD: which module a QD has (RDDID now defaults to 0x29 00 00, the
    module-0x10 answer the boot code and the model use); whether the panel is mounted rotated (`PANEL_ROT180`);
    whether TE should follow the 60 Hz video (tear-free on MiSTer) rather
    than the panel's own 74 Hz; blank colours; ML and the scroll area.
  - MMC: the retail CSD lists command class 1 (CMD11 stream read), not
    implemented; card-detect for hotswapdrv.ldd; the UPP_WD2 host's
    time-outs against HPS latency (TAAC in the default CSD says 10 ms).
  - Flash: sector map (top boot assumed), bank count, busy times, lock
    state at power-up, burst configuration (C0) and secured-silicon (88)
    commands, CFI fields.
  - Keypad: which side wins a drive fight; the firmware's scan timing.
  - Next for the shell: a DDR3 controller for the flash memory ports
    (images at 0x31000000/0x32000000) and the 16 MB SDRAM at 0x30000000.

### 2026-10-20: priorities and CPU decision
- The user's priorities: working first, then accuracy, and only what fits.
- CPU: ZAP in the fabric, made functionally ARM925T-correct first. Timing
  fidelity to the ARM9TDMI comes in a later pass. The HPS-native hybrid is
  dropped.
- Budget estimate, in ALMs:

  | Part | ALMs |
  |---|---|
  | ZAP | about 12K |
  | Board devices | about 6K |
  | Framework | about 7K |
  | UPP peripherals | 5-8K, estimated |
  | Total | about 30-33K of 41.9K (75-80%) |

- Licence: ZAP HEAD is GPL-3.0-or-later. The framework's hps_io.sv is
  also GPL-3.0-or-later, so the combined core is GPLv3 either way.

### 2026-10-20: correction to the ZAP timing result
- With every Wishbone output wired to an observed pin (nothing can be
  optimised away), ZAP is 12,679 ALMs (30%), 13,363 registers, 73 M10K
  and 4 DSP.
- Worst setup slack at 104 MHz is **-0.448 ns** at the slow 100C corner,
  and -0.025 ns at the next corner. That is about 99 MHz standalone.
- The earlier +0.082 ns result had about 5% of the logic pruned.
- For a working first version: clock the CPU domain lower, or retime the
  critical paths. ZAP's IPC is likely at or above an ARM9TDMI's, so a
  slightly lower clock should not cost speed against the real phone.

### 2026-10-20: first run on the MiSTer
- The board-level core (RBF from the FPGA-side agent's full compile) loads
  on the MiSTer and shows the test picture: colour bars, gradient grid,
  and key boxes. It was captured with the Zaparoo `screenshot` API at
  880x1040, which is 176x208 at 5x. The capture is
  `build/hardware/ngage-testpattern.png`, untracked.
- MiSTer setup for captures:
  - Zaparoo service started (`zaparoo.sh -service start`).
  - `[NGage]` section with `direct_video=0` added to /media/fat/MiSTer.ini,
    so only this core uses the scaler. Backup:
    /media/fat/MiSTer.ini.ngagebak.
- Not yet checked on hardware: key input through the test picture, OSD
  flash loading, MMC mount.

### 2026-10-20, model: keypad, DMA, MMC data, S60 start-up analysis
- **Keypad** (`model/hw/ngage_keypad.c`, from ekeyb.dll): UIF port D
  (0x0C150400, 5 column lines) and port E (6 row lines). Each port has
  data, direction set/clear, interrupt-enable set/clear and pull-up
  set/clear registers (set = low byte, clear = high byte of one word).
  Rows are inputs with pull-ups, columns are driven low to scan. A row
  falling edge latches CTSI `+0x100` bit 2 (W1C; ekeyb writes 0xC), which
  raises source 25 (CTSI_IRQ). The key matrix is ekeyb's table 3. A
  scripted '5' (`NGAGE_KEYS=file`, lines `<sec> down|up <key>`) is scanned
  and decoded at row 3, column 2. Host keys work in the `-w` window.
- **DMA** (`model/hw/ngage_dma.c`, from ekern 0x5031B2C0-0x5031B868): 8
  channels at `0x0C120300 + 0x40n`; source/destination address, mode
  (0 fixed, 2/4 increment) and width (8/0x10/0x20); count - 1 at `+0x2C`;
  `+0x08` = 1/2 starts, 0 stops and acknowledges. The DMA side sees
  register 0x0Cxxxxxx at 0x1xxxxxxx (MMC FIFO 0x10120624, LCD FIFO
  0x10121208). Transfers complete at once and raise source 6+n; the ISR
  reads no status.
- **MMC data**: read/write phases (control types 8/9/10 = read first,
  next, stop; 5/6/7 = write; CMD17 goes out as 0x21) and the FIFO at
  `+0x624`. A **FAT12 test card mounts**: MBR, boot sector, FATs and the
  root directory are read with CMD17/18 through DMA channel 5.
  `model/tools/mkcard.sh OUT.img` makes one (16 MB, FAT12 at LBA 32,
  GAME.ID); `NGAGE_MMC=OUT.img` inserts it. A card made with FAT32 is not
  recognised (Symbian 6.1 has no FAT32).
- **Starter blocker, more detail.** Starter takes the WD2-reason-0 path
  (state machine at 0x5096178C) and starts the minimal list, SysAp.app and
  Startup.app (both through AppRun.exe), not the full list from
  Starter_Arm.RSC (SplashScreen, SelfTestServer and the rest). It then
  builds `CBaBackupSessionWrapper` (Bafl 0x50903B00, connect at
  0x509032E0 to "BackupServer"). The backup server is in EikSrv.dll
  (eiksrvs.exe, started on demand by EikSrvc), which is not running, so the
  connect fails with KErrNotFound and Starter crashes in cleanup.
- **Start-up reasons** come through sysutil (GetStartupReasons) to
  DosServer, then Nokia.dsy. That uses HelperDrv: request 0 reads variant
  `+0x80`, which comes from superpage 0x4000101C, set by the bootstrap at
  0x3178 from UEMK register 0x1F bit 1 and register 0x15. It also uses
  NOSDRIVER over ISI (PermRecordRead, NetCsControl). Without NOS answering
  ISI messages (through the nosdriver channel to the NOS object's vtable
  `+0x0C/+0x10/+0x14`), the DOS phone services cannot answer. That is the
  likely next blocker after the backup server.
- **Audio** needs NOS and the DSP: audio.ldd touches no UPP registers, and
  SoundDevice.mda reaches the audio path over PhoNet/ISI to the cellular
  side. The encrypted blob alone would not be enough; the DSP firmware and
  its interface would also have to be modelled or high-level emulated.
- New tools: `model/tools/romsyms.py` (every ROM DLL export named from the
  SDK import libraries, to `research/firmware/analysis/romsyms.txt`),
  `model/tools/annotate.py` (names `bl` targets in a disassembly),
  `model/monitor.sh` (QEMU monitor commands on a running model),
  `model/gdb/desc.gdb` with `model/tools/gdbdesc.py` (print a TDesC16).

### 2026-10-20, model: start-up reason 0, C: drive on flash, full start-up list
- **Why Starter took the minimal list.** Starter reads (hardware reason,
  software reason) from sysutil and looks up its list in
  `Starter_Arm.RSC` resource 2. It got hardware reason 9 (no list) and then
  forced (0, 210), the SysAp + Startup list, because `RFs::Drive(C:)` said
  RAM, not flash (`0x50961FDC`).
- Reason 9 came from the UEMK: ecust (`0x50343A10`) wants the battery-size
  indicator (UEMK ADC channel 6, read through registers `0x19`/`0x1A`) in
  380-590 for a normal battery, and UEMK register `0x1F` bit 1 for a
  normal power-on (bootstrap `0x3090` → superpage `0x4000101C` → variant
  `+0x80`). `model/hw/ngage_cbus.c` now has the A/D converter (`adc`
  lines in `model/cbus-regs.txt`); BSI = 485 and `0x1F` = `0x0002` give
  **reason 0**. Values are guesses inside the firmware's ranges.
- C: was a RAM drive because LFFS will not mount the blank C: area (CS1
  `0x400000-0x7FFFFF`, all `0xFF` in the image) and EStart falls back to
  RAM. The firmware's own fix is the reset key combination: holding Call +
  * + 3 at power-on makes EStart erase and format C: (`model/keys/format-c.txt`).
- That needed a real erase in the flash model: medint.pdd waits for the
  erase-busy status and uses erase suspend/resume. Sector erase now takes
  20 ms of guest time, with status reads in the erasing sector only, and
  `0xB0`/`0x30` suspend and resume. The sector map is top boot (8 KB
  sectors in the top 64 KB, from medint's sector-size rule).
- New: `flash1-save` keeps CS1 across runs (`model/.out/cs1-save.bin` by
  default; `NGAGE_SAVE1=none` starts from the image).
  First boot: `NGAGE_KEYS=model/keys/format-c.txt model/run.sh -t 40`.
- **State** after the format: LFFS mounts on C:; Starter gets reason 0 and
  runs the full list. SplashScreen, SelfTestServer (which starts RfsServer and
  BTTestServer), EInfoServer and randsvr start; then Starter waits, with
  the next entries (Sae, SysAp, Phone) not started after 60 s. The screen
  still shows the boot logo.
- Details: `docs/UPP_WD2.md` (UEMK registers, start-up reason table, NOR
  flash section).

## CPU

### 2026-10-20: ZAP vendored, wrapper, generator, bench, first ARM925T changes
- `rtl/cpu/zap/`: ZAP fc7bd75 (GPL-3.0-or-later) with NOTICE; changes are
  tagged `ARM925T:`. `rtl/cpu/arm925t.sv` wraps it with a req/ack bus (with
  a burst flag) and sets the ARM925T parameters. `tools/gen_cpu.sh` (sv2v +
  the Quartus fixes) writes `rtl/cpu/arm925t_gen.v`; `make cpu-gen-check`.
- `sim/cpu/`: Verilator bench on ubuntu (`make -C sim/cpu remote`), tests
  assembled here, the same binaries on QEMU's ti925t (`-M none`, GDB stops at
  the halt loop), signatures and per-instruction traces compared. All six
  tests so far agree with QEMU instruction by instruction.
- Done: CP15 ID/cache type, control register (A, V, 6:4), TI c15 registers,
  ARM925T c7 decode (drain/WFI/prefetch no longer flush both caches), FSR/FAR
  only on aborts (upstream overwrote them on every uncached access), MCR/MRC
  retire and refetch, UND for user-mode CP15, other coprocessors and the
  ARMv5 instructions, conditional UND, the 011x..1 UNDEFINED space (upstream
  decoded `0xE7F000F0` as a load).
- QEMU differs from the ARM925T in places the tests avoid: every unaligned
  word access aborts even with A=0, c13 adds the unmasked PID, a CP14 read
  returns 0, PSRs carry the ARMv6 A bit.

### 2026-10-20, model: deterministic timing; Starter runs its whole list
- **Guest time now follows executed instructions** (`-icount shift=4,sleep=off`,
  the default in `model/args.sh`; `NGAGE_ICOUNT=none` restores wall-clock
  time). medint.pdd programs the C: drive one word per timer-3 FIQ (reload
  `0x1FE`, 14.7 us); with host timers only about 1000 FIQs per second got
  through, so the first-boot file work (RfsServer) took minutes. With
  icount the timers fire on time, idle time is skipped, and runs repeat.
  `-t` stays wall time; about 400 guest seconds pass in 60 wall seconds
  once the system idles.
- First boot after the C: format: Starter finds no
  `C:\system\bootdata\FirstBoot.dat` and runs RfsServer (restore factory
  settings) before the Eikon step; that is file-server work and finishes
  under icount.
- **Kernel fault in rtc.dll fixed in the NOS stand-in.** rtc.dll gets
  service 3 only when its service method `+0x20` receives event 1
  (`0x50349394`), which nothing in the Symbian ROM sends. Without it,
  HelperDrv control 7 from DosServer calls through a NULL pointer
  (`0x5034A944`, kernel restart 0x10000000, type 0xC). The stand-in now
  sends event 1 with zero times, which rtc treats as "time not set".
  The values are a guess.
- **State:** Starter starts every entry: SplashScreen, SelfTestServer,
  EInfoServer, randsvr, DbRecovery, Sae, SysAp, Phone, Watcher,
  ScreenSaver, Autolock and Startup (through AppRun), and more. Other
  processes now running: EDbsrv, Sysagx, C32exe, Ealwls, MediaServerStub,
  PhoneServer, btmanserver, and the AppArc, backup and key-sound servers.
  No kernel fault in 60 s.
- **Display:** the screen still shows the boot logo. The window server opens
  the `Lcd` channel (scdv.dll `0x50418A94`) and calls controls 0x2001,
  0x100D, 0x2006 and 0x2002 (twice). lcd.ldd then sends no panel
  transfers after its first full frame, and the frame buffer at
  `0x0A000020` still holds the logo. Next step: find out whether nothing has
  drawn yet (Startup.app and SysAp may be waiting on DOS/ISI answers from
  NOS) or whether lcd.ldd's update path (DMA + LCD FIFO) is not modelled.

## Memory system

### 2026-10-20: SDRAM, flash in DDR3, UPP bus map, self-test in the core
- New: `rtl/mem/sdram.sv`, `rtl/mem/ddram_flash.sv`, `rtl/mem/bram32.sv`,
  `rtl/upp/upp_bus.sv`, `rtl/upp/ngage_mem.sv` (the memory system as one
  block: bus, SDRAM, both flash chips, their DDR3 path),
  `rtl/upp/upp_periph_stub.sv`, `rtl/upp/wb_selftest.sv`. NGage.sv
  instantiates them; the OSD has "Memory test".
- **SDRAM** (`sdram.sv`, GPL-3.0-or-later: derived from Sorgelig's MiSTer
  `sdram.sv`): 104 MHz on clk_sys (2 x 52 MHz), SDRAM_CLK = inverted clock
  from a DDIO output, CL2, capture CAS latency + 1 clocks after READ.
  Closed page, burst 8 reads (wrapping, asked word first), single-location
  writes with DQM. Timing is the slowest of the module chips' data sheets
  (tRCD/tRP 20 ns, tRAS 45, tRC/tRFC 70, tWR 15), i.e. 3/3/5/8/8/2 clocks.
  A word read reaches the port 7 clocks after the request is taken, a line
  7, 9, 11, 13; refresh every 780 clocks between accesses (longest gap
  7.6 us). The guest's 16 MB is the first 16 MB of the module.
- **Flash arrays in DDR3** (`ddram_flash.sv`): CS0 at 0x31000000, CS1 at
  0x32000000. Per chip a one-beat (8-byte) buffer answers in the request
  clock; an 8 KB direct-mapped cache (32-byte lines) answers in 2 clocks;
  a miss is one 4-beat DDR3 burst (about 20 clocks). Writes (program,
  erase) go through to DDR3 and update the cached copy. The loader shares
  the port; the cache empties after every reset and any loader write.
- **Bus** (`upp_bus.sv`): Wishbone B3 slave, registered ack. Map as in the
  task; 0x0C100000-0x0DFFFFFF all go to the peripheral register bus
  (p_sel/p_addr/p_we/p_be/p_wdata, p_rdata/p_wait). Bursts read ahead in
  every target. On a quiet bus, clocks from a beat appearing to its ack:
  SDRAM word 10, line 10 + 2 + 2 + 2; on-chip RAM and EMIF 2, then one a
  clock; flash line 12 + 3 x 8 (beat buffer/cache) to 29 + 3 x 8 (DDR3
  miss); posted SDRAM writes 1 (a burst beat every 2 clocks); empty CS2/3
  and unmapped 1.
- Flash is a 16-bit chip behind nor_flash's req/ack port, so a word is two
  halfword accesses of about 4 clocks each. Reads ask only for the halves
  SEL names (the other half reads 0): a second status read would toggle
  DQ6. Read-ahead in a burst never passes the burst's end for the same
  reason.
- **CPU hookup**: the CPU agent's `arm925t` req/ack bus maps straight onto
  the port (`wb_cyc = wb_stb = bus_req`, `wb_cti = bus_burst ? 010 : 111`,
  `wb_bte = 0`, rest by name); NGage.sv has the mapping in a comment.
- **Self-test** (`wb_selftest.sv`, the placeholder master): with "Memory
  test" on it runs passes over the EMIF block, the CS2 probe, on-chip RAM
  and all 16 MB of SDRAM (bursts, byte and halfword writes with the other
  lanes inverted), and CS0 (classic vs burst reads must agree), about
  0.8 s a pass. It shows "Memory test passed" / "FAILED" on the OSD after
  the first pass and after new errors; the power LED blinks slowly while it
  passes, fast after a failure. Not yet run on hardware.
- **Benches** (all in `make test`): `sdram` (C++ chip model,
  `sim/harness/sdram_model.h`: power-up, tRCD, tRP, tRAS, tRC, tRRD, tRFC,
  tWR, tMRD, refresh interval, DQM, contention, and the read capture window
  with 4.5-7 ns board delay); `sdram-faults` (four builds with a timing
  fault, each must be reported); `ddrflash` (DDRAM port model from
  Cray1_MiSTer, now with Avalon checks, `sim/harness/ddram_model.h`);
  `upp` (ngage_mem under a scripted Wishbone master: classic cycles with
  every SEL, ZAP-style 4-beat bursts, longer and wrap-4 bursts, mirrors,
  peripheral waits, AMD program/erase/autoselect through the bus; again with
  a 256 KB on-chip RAM in SDRAM); `top` (the self-test in the whole core
  against the SDRAM and DDR3 models, and its failure report with SDRAM bits
  flipped). Injected bugs in sdram, ddram_flash and upp_bus are caught (the
  few that are not are redundant checks).
- Unknowns, each a named parameter: on-chip RAM size `ONCHIP_BYTES` (64 KB
  of block RAM; the firmware's literals point into 0x0C000000-0x0C005FFF
  only, the model maps 256 KB; above `ONCHIP_BRAM_MAX` it moves to SDRAM
  at 16 MB); `EMPTY_DATA` and `UNMAPPED_DATA` (0, as the model);
  `UNMAPPED_ERR` (0: no abort); `EMIF_WORDS_LOG2` (64 words, mirrored);
  the SDRAM timing and `CAPTURE_CLKS`; the cache geometry. Mirroring of the
  flash, SDRAM and RAM windows is assumed (incomplete decoding).
- **Saves (not built)**: the C: drive (LFFS, CS1 0x400000-0x7FFFFF per the
  model) changes only DDR3. To keep it, mount the CS1 image as a second
  hps_io block device instead of loading it with ioctl: read it into DDR3
  at mount, let ddram_flash mark each 512-byte block it writes dirty, and
  write dirty blocks back with sd_wr when the bus is idle (like other
  cores' save RAM). A whole-image ioctl upload on an OSD "Save" would also
  work but rewrites 8 MB.
- **Quartus** (`./build.sh remote map`, then `compile`): 0 errors. Every
  corner meets 104 MHz: worst setup +0.374 ns (slow 100C, the SDRAM
  controller's step counter to the SDRAM_A I/O register), worst hold
  +0.088 ns (slow -40C). All SDRAM command, address, DQM, DQ and DQ-enable
  registers are in the I/O cells. Whole core 13,112 ALMs (31%), 18,960
  registers, 218 M10K (39%), 33 DSP; before: 9,472 ALMs, 137 M10K.
  Fitter figures (ALMs / registers / M10K): ngage_mem 3,323 / 3,343 / 77
  (upp_bus 504 / 846 / 68 with the 64 KB on-chip RAM; sdram 173 / 254;
  ddram_flash 302 / 316 / 9; nor_flash CS0 1,396 / 1,178 and CS1 948 / 749,
  no longer optimised away); wb_selftest 243 / 188; upp_periph_stub 5 / 1 / 4.
- Quartus 17 notes: loop and conditional generates need `generate`, a
  genvar declared apart, no nets of a typedef type, and a module variable
  read inside a function is not counted as a use (pass it as an argument).
- Open questions:
  - On-chip RAM size; whether 0x0C000000-0x0C003FFF is the boot ROM rather
    than RAM (research says a ROM entry point sits at 0x0C000D01).
  - What CS2/CS3 and unmapped addresses really read, and whether unmapped
    accesses abort (APIIOAbort is an interrupt source name).
  - DMA: the model has 8 DMA channels addressing memory (and registers at
    0x1xxxxxxx). upp_bus has one master; DMA needs a second master port and
    an arbiter in front of it.
  - Flash speed: nor_flash's req/ack takes 4 clocks a halfword, so a 16-byte
    line from flash is about 40-55 clocks against 16 from SDRAM. A
    read-array fast path in nor_flash (answer array reads from its memory
    port directly) would halve it, if XIP misses turn out to matter.
  - SDRAM: open-page or bank interleaving would cut 3-6 clocks a miss;
    tRCD/tRP at 18 ns (2 clocks) suit most modules but not the slowest data
    sheet. Board delay for the capture is assumed 4.5-7 ns; confirm on
    hardware with the memory test (and CAPTURE_CLKS if it fails).
  - The core needs the SDRAM module; hps_io's sdram_sz could warn when none
    is fitted.

### 2026-10-20, model: why the screen stays on the Nokia logo
- **The LCD update path works; nothing new has been drawn.** The window
  server opens the `Lcd` channel through scdv.dll and sends update requests
  (control `0x2002`, lcd.ldd `0x504042B4`); each one makes lcd.ldd push a
  full 176x208 frame through the LCD FIFO (CPU writes, ctrl `0x8314D67F`),
  and the panel model takes every frame. The frames hold the Nokia logo
  because that is what is on screen: SplashScreen.exe shows
  `SplashScreen.mbm`, a 176x208 256-colour bitmap of the same logo (decoded
  from the ROM).
- Starter has started every item up to Startup.app and is waiting at the
  next list entry (type 12), which only Startup.app's "ready" signal ends.
  Startup.app, SysAp and the rest are waiting on the modem side:
  nosdriver.ldd forwards every request to the NOS object (vtable
  `+0x10` request, `+0x14` control, `+0x0C` cancel), and the stand-in
  answers none. In 60 s, DosServer and the telephony server sent 12 ISI
  messages through NOSDRIVER control 4, with resources 0x17, 0x1C, 0x3A,
  0x35, 0x31, 0x0A, 0x09 and 0x0B. Ten receive requests (request 0) stay
  pending.
- So the next display step needs the modem's answers (SIM, security and
  start-up state). That means emulating NOS at the ISI message level, or
  running the real NOS. This is a design decision for the user; it is
  not done here.
- `model/threads.sh` now dumps the kernel heap one page at a time (it is
  committed sparsely), so all threads are listed: 5 AppRun processes,
  Watcher, LogServ, MSexe, Sysamob, Loadersrv, WAPSTKSRV, SplashScreen.

### 2026-10-20: memory self-test passes on the MiSTer
- The core with the memory-test status square (commit 6ef5adf; full
  compile: worst setup +0.142 ns, slow -40C, all corners met) was deployed.
  "Memory test" was switched on through the OSD with Zaparoo key presses
  (F12, six downs, Enter, Esc). The square went from blue to green: one
  or more full passes over 16 MB SDRAM, on-chip RAM, EMIF registers and
  the CS0 flash path, with no errors.
- The one-minute soak check was stopped before it finished, because the
  user took the MiSTer back. **Do not use the MiSTer (deploy, ssh,
  screenshots) until the user says it is free again.**
- The OSD menu order, for key macros: Load CS0, Load CS1, Mount MMC,
  Rotate, Aspect ratio, Scandoubler Fx, Memory test, then Reset. The
  cursor starts on Load CS0.

### 2026-10-20, CPU: tests, ZAP bugs found, 104 MHz met standalone
- 15 tests in `sim/cpu/tests` (ALU, shifts, multiplies, loads/stores, LDM/STM
  with aborts, modes/PSRs/SWP, SWI/UND, Thumb, CP15, alignment, ARMv5 opcodes,
  MMU sections and pages, IRQ/FIQ, RTL-only ARM925T details). All pass at
  three bus latencies; the 13 that QEMU can run match it instruction by
  instruction.
- Upstream ZAP bugs fixed on the way (all tagged `ARM925T:`): uncached
  accesses with the MMU on used the virtual address whenever that cache was
  off; fine page tables were walked with the coarse layout; page faults
  reported the wrong domain; Thumb SWI/UND returned to themselves; Thumb B
  with condition 1110 branched; LDM loading its own base lost the
  base-restored behaviour; the 011x..1 space decoded as a load.
- Quartus 17 standalone trial (`sim/cpu/quartus/run.sh`, every input and bus
  output registered to pins): 12,573 ALMs (30%), 14,167 registers, 57 M10K,
  4 DSP. Worst setup slack at 104 MHz: **+0.270 ns** (slow 100C), +0.285 ns
  (slow -40C), all corners met (about 107 MHz). The first run, before two
  timing fixes (ARMv5/UND classification moved from decode to predecode,
  alignment check registered a stage early), was -0.501 ns. Margin is thin:
  in the full core, keep the CPU on clk_sys at 104 MHz and recheck; the
  fallback is a CPU clock of 96 MHz (see docs/CPU.md).

### 2026-10-20, model: power key; key interrupts verified; MMC polling
- **UEMK register `0x1F` bit 1 is the power key** (register semantics
  change for the RTL). ekeyb `0x5041CC9C` reads it as key bit 28
  (scan code `0xA6`) and polls it while set. With the earlier constant
  `0x0002` the power key looked held forever: ekeyb polled the CBUS about
  1500 times a second and posted a power-key-down event. Now
  `ngage_cbus.c` takes bit 1 from the power key. The keypad model holds the
  key for the first 3 guest seconds after reset; after that it comes from
  key `power` in the key script or F6 in the window.
  The bootstrap reads it only after its flash digest check (about 1-2 guest
  seconds). If the key is already up, the start-up reason is 9 and Starter
  reads resource 0, leaves with -1 and panics. Starter is system-critical,
  so the kernel faults with `PLAT` 0x1005B. Hence the 3 s hold.
- **Key input works by interrupt**: a scripted '5' at 20 s latches CTSI
  `+0x100` bit 2, source 25 runs ekeyb's CTSI ISR (`0x5041B9E0`), and
  ekeyb posts EKeyDown scan code `0x35`. The window server's event request
  completes. (The earlier '5' test was decoded only because ekeyb was
  polling the stuck power key.)
- **MMC**: the card mounts. Afterwards the stack polls it about every 1.6
  guest seconds: a status session (CMD13 x13, then power-up and CMD0, CMD0,
  CMD1, CMD2 without CMD3). The main session re-acquires with CMD3, CMD9
  and CMD7 when it needs the card. This looks like card-presence polling
  and appears with and without icount, so it is left as is.
- Starter now runs past Startup.app to the end of its list (state 2) with
  no fault in 60 s. The screen still shows the splash logo; see the
  previous entry (NOS ISI).

### 2026-10-20: decision: offline no-SIM NOS stand-in
- S60 start-up completes in the model, but the UI waits on modem replies.
  The decision is to emulate NOS at the message (ISI/PhoNet) level as an
  offline phone with no SIM: SIM absent, no PIN, no network, modem state
  normal/offline.
- The responder lives in the NOS stand-in ARM code (`model/nos-stub/`),
  not in QEMU. The FPGA core then runs the same binary from the patched
  flash image (`tools/mkimage.py` applies `model/rom-patches.txt`).
- Running the real NOS is infeasible: its cipher and key are in the ASIC.
- Replies will be documented per message in `docs/NOS_STANDIN.md`.

## UPP peripherals (RTL)

### 2026-10-20: the UPP_WD2 peripherals in the core
- `rtl/upp/upp_periph.sv` replaces `upp_periph_stub` on upp_bus's register
  bus. Each block follows its model file register for register and cites
  the firmware evidence in its header:
  - `upp_intc`: IRQ/FIQ planes x 3 banks and the OS-timer unit.
  - `upp_timers`: timers 0-5 at 104/3 MHz.
  - `upp_dma`: 8 channels, 3 engines, its own bus master.
  - `upp_mmc`: 1-bit host on mmc_card's CLK/CMD/DAT0.
  - `upp_lcdif`: packing modes, read phase, ready bits, 8080 bus.
  - `upp_uif`: ports D/E to keypad_matrix, CTSI key interrupt.
  - `upp_cbus`: UEMK (ADC/BSI, 0x15, 0x1F with the power key), device 4
    ID, device 5 and the rest as storage.
  - The top: the clock-page and DPLL read quirks, the STI window
    (`sti_*` debug outputs, reads 0), and storage for every other
    0x0C1xxxxx register. 0x0Dxxxxxx and 0x0C2xxxxx read 0, as in the model.
- `ngage_mem` has a second Wishbone port for the DMA. `wb_arb2` switches
  masters only between transactions; upp_bus reports `idle`, and a
  simulation check asserts it. NGage.sv: lcd_testgen keeps the panel and
  the key lines until the UPP LCD interface first drives the bus.
  `cpu_irq`/`cpu_fiq` are wires waiting for arm925t.
- Benches, all in `make test`:
  - `intc`, `timers`: against C++ ports of `ngage_intc.c`; underflow edges
    exact in clocks.
  - `periph`: ngage_mem + upp_periph + lcd_panel + mmc_card +
    keypad_matrix under a scripted CPU:
    - storage, quirks, and access sizes the model's regions refuse;
    - `model/.out/regs.log` and `cbus.log` replayed;
    - DMA in every width pair, five transfers at once, stop, with CPU
      bursts through the arbiter;
    - three LCD pictures (12 bpp by CPU, lcd.ldd-style DMA frame, 16 bpp by
      DMA) and RDDID;
    - MMC CID/CSD, CMD17/18 + CMD12, CMD24/25 via DMA channel 5, time-outs;
    - every key by ekeyb's scan;
    - UEMK reads.
  - Mutants in every block are caught.
- `tools/mkimage.py` turns Phoenix files or flat dumps into cs0.bin/cs1.bin
  with `model/rom-patches.txt`. The stand-ins are committed in
  `tools/standin` (`make standin` / `standin-check`, built from the
  committed `model/nos-stub`). The bootstrap's integrity table is checked
  through the bootstrap's ROM mapping: the language-pack entry 0x8F00 spans
  the end of CS1 and the top of CS0. `make image-check` builds the model's
  own `ngage_patch.c` outside QEMU (`tools/patchcheck`) and compares. The
  output equals the model's byte for byte, both for the model's image and
  for RH2946.0C1/.0S5 plus `--phone-data` from the SDumper dump. That dump
  supplies the 56 per-phone bytes the flash files leave out; whether the
  firmware needs them is unknown.
- Quartus 17 full compile: every corner met at 104 MHz.
  - Worst setup +0.257 ns (slow -40C), hold +0.097 ns.
  - The first run was +0.014 ns, with the arbiter mux in upp_bus's flash
    read-ahead path. That path's adder is gone now: the test is
    `fe_adr == wb_adr`.
  - Whole core 18,506 ALMs (44%), 23,940 registers, 250 M10K, 33 DSP.
  - upp_periph 2,839 ALMs: DMA 828, MMC 758, timers 346, top 324, intc 208,
    CBUS 177, UIF 117, LCD 79. Storage is 32 M10K. The arbiter is 26 ALMs.
  - mmc_card grew from 109 to 1,763 ALMs now that its bus is live.
  - With the CPU (about 12.7K) the core comes to about 31.2K of 41.9K (74%).
- Deviations from the model, each marked in the headers:
  - Real time where the model is instant: LCD ready (control bit 30 = queue
    empty and bus idle, aux bit 2 = room), MMC busy bits, DMA duration,
    CBUS done 2 clocks.
  - Storage is 8 x 4 KB slots by page instead of 1 MB (unknown pages share
    two slots), cleared at reset.
  - The power key counts as held for 3 s and until the first read of
    UEMK 0x1F.
  - DMA paced by the MMC/LCD FIFOs when that side is fixed;
    0x0C120064/68 stay storage.
  - MMC CLK 104/12, response CRC checked, time-outs 64 / 2^21 clocks, R1b
    busy for types 4 and 7.
  - LCD bus 2+2 clocks a write, 4+6 a read; /CS low, /RES high.
- Open:
  - 0x0C120064/68 request-line semantics.
  - GENIO4 as LCD /RES.
  - The MMC registers +0x60C/+0x610/+0x614.
  - The GPIO interrupts (GPIO8High for the UEMK, GPIO23Low for ekeyb);
    the model drives neither.
  - The DMA LCD frame takes about 5 ms (27 clocks a word); bursts would
    speed it up.
  - A QEMU flash dump against mkimage's output was not made (QEMU in use).

### 2026-10-20: ISI responder in the NOS stand-in; DOS self test passes
- `model/nos-stub/nos_isi.c` (C, ARMv4T, freestanding) is now the object
  behind nosdriver.ldd's channels: it takes sends (control 4), completes
  receives (request 0) from a per-channel queue and logs each message to
  the kernel log (`NOS<` request, `NOS>` reply). Replies are in
  `nos_isi_replies.h`; `docs/NOS_STANDIN.md` lists each with the client
  code that parses it. Size and place are unchanged in
  `model/rom-patches.txt` (NOS DLL entry points `0x514A1CA0`,
  `0x514A261C`; BSS in NOS RAM).
- Assumed replies so far (all **guesses from the client parsers**):
  - `0x1C/0x10` → `0x11 [00]` (Nokia.dsy `0x50FFAD98`), followed by SIM_IND
    `0x09/0xEF [00 06 05 00]`: SIM state 5 → SA `0x100052E9` = 4, "SIM not
    present". State 8 had given 7 ("SIM usable") and was wrong.
  - DOS self test: `0x35/0x02` → `0x03 [00]`, `0x35/0x00` → `0x01 [00]`,
    `0x59/0x01` → `0x02 [00]`: DOS event 1 = 3, self test passed
    (Nokia.dsy `0x50FFBB04`, `0x50FFBBBC`, `0x50FFBC74`). Status 12 in the
    first reply gives "Device start-up failed. Contact the retailer."
  - An unsolicited SIM `0x2C` message tried earlier is removed: its
    handler (`0x50FFB4BC`) expects a reply to a request DOS never sent.
- Result: Startup.app's state machine goes 0 → 1 → 2 → 4 and sets the
  start-up state 211. It now waits for state 213, which Phone.app sets
  (`0x50CA1A66`) from a step of its construction that has not run yet.
  Phone.app, SysAp, ScreenSaver, Autolock and Startup are all started; the
  screen is white, then the screensaver's date bar (partial mode, not in
  the panel model). The TSY, DOS battery and sound requests are not
  answered yet; Phone.app is likely waiting on the TSY.

### 2026-10-20: idle screen reached with an inactive SIM; no-SIM start-up stops
- **No SIM card cannot reach the idle screen.** Startup.app finishes only
  with System Agent `0x100052E9` (SIM status) = 7 and `0x100052F0`
  (security-code state) = 0 (`0x50BBBCD6`, `0x50BBBDDC`). With SIM state 5
  (no card) it removes the splash, shows a blank view behind the "Insert
  SIM card" note and never leaves state 5. The stand-in now reports an
  **inserted, ready SIM without PIN** (as with an expired SIM card); network
  stays absent. This deviates from the "SIM absent" brief, on firmware
  evidence.
- The earlier DOS event → SA variable map was off; the real one, from
  DSClient.dll's switch (`0x50FF6B2C`) and sae.exe's observer (vtable
  `0x50BF36AC`), is in `docs/NOS_STANDIN.md`. `0x100052F0` is DOS event 23
  (DosSrv ord27), raised by the security indication.
- New assumed replies (details and evidence in `docs/NOS_STANDIN.md`):
  - SIM_IND `0x09/0xEF [0D 0B 08 00]` (SIM_ST_INFO, INIT_OK, state 8)
    instead of state 5;
  - security indication `0x08/0x10 [05 00 00 00]` → SA `0x100052F0` = 0;
  - SIM `0x3B` → `0x3C [FA 2A]` (IMSI equal), `0x2D` → `0x2E [3A 01 00 00]`,
    `0x2B` → `0x2C [3A 01 01 00 00 00]` (DOS SIM flags all clear);
  - sound `0x0B/0x11` → `0x12`, which completes PhoneServer's
    GetHandsfreeMode (it was blocking Phone.app and Autolock in
    RPhCltServer::Connect).
- Result: Startup.app runs 0 → 8, the operator start-up animation plays
  (this ROM is Telefónica/movistar branded), then the time and date queries
  of a first start-up. With `model/keys/first-boot.txt` (left soft key at
  30 s and 40 s guest time) the **idle screen draws**: N-GAGE wallpaper,
  analog clock, signal and battery icons (`model/.out/idle-first.png`). The
  soft-key labels at the bottom are not drawn yet.
- Still unanswered: DOS battery (`0x17`), `0x3A/0x05`, MTC_STATE_REQ from
  DOS object `0x4F`, TSY network/GPDS/SIM reads, `0x0B/0x00` from object
  `0x4A`.

### 2026-10-20: idle screen stays up; the menu opens
- After the date query the system restarted: Phone.app was panicked by the
  view server (`ViewSrv 11`: no answer to its idle-view activation),
  Starter re-raised the panic, and Starter being system-critical, the
  kernel faulted (`PLAT` 0x1005B, halt loop at ekern `0x5031E394`). Phone.app
  was blocked in synchronous custom-TSY calls. The same pattern held SysAp
  and Menu.app. Each is now answered (details in `docs/NOS_STANDIN.md`):
  - `0x09/0x60` → `0x61 [FA 31]` ciphering indicator not required
    (GetCipheringInfo);
  - `0x09/0x21` → `0x22 [2C 24]`, `0x09/0x33` → `0x34 [3E 24]`: no service
    provider or operator name on the SIM;
  - `0x09/0x13` → `0x14 [11 24]`: no SIM service table (no SIM toolkit);
  - `0x09/0x31` → `0x32 [3B 24]`: no ALS line, no CSP;
  - `0x1B/0x02` INFO_PP_READ → `0x03`, product profile value 0
    (CheckAlsPpSupport).
- Result: the operator idle screen draws and stays (movistar wallpaper,
  date, analog clock, soft keys "Contacts" and "emoción";
  `model/.out/idle-movistar.png`), and the Menu key opens the application
  grid (Juegos, Contacts, Calendar, Bluetooth, Messaging, Web, Extras,
  Tools, N-Gage Arena; `model/.out/menu.png`).
- New debug tool: `model/stacks.sh [SECONDS]` lists each thread's user-stack
  return addresses (`model/tools/kstacks.py` reads the process's data
  chunk at its home address). It is how the blocked calls were found.
- Battery: DOS's charger and battery queries (`0x17/0x08`, `0x17/0x0A`)
  now get "no charger, battery fine, 7 bars"; the idle screen shows a full
  battery. A 120 s run (several guest minutes) with the menu and the
  Juegos folder open ends without a kernel fault.
- Juegos (games) opens; on this movistar ROM it is the operator's games
  portal list. Installed N-Gage games appear as their own menu icons from
  the game card; not tested, as there is no game image (`NGAGE_MMC` with a
  blank `model/tools/mkcard.sh` card mounts without errors).

### 2026-10-20, CPU: boot code on the RTL, four ZAP bugs, 104 MHz is marginal
- `make -C sim/cpu boot` runs the real CS0 boot code on the RTL in Verilator,
  with the model's memory map and the devices the boot uses ported into the
  bench (`sim/cpu/tb/ngage.h`), and compares the register and CBUS logs
  with the model's. The whole bootstrap matches (32 register accesses,
  CBUS/UEMK and ADC traffic, both MD5 integrity checks over 19.6 MB with
  the caches on), and the kernel starts and matches for 23 more register
  accesses and the first 64 CBUS transfers. The kernel's first debug text
  (`TRtcQueue::Add: 2TRtcQueue::Add: 4`) is the same as the model's.
- It found four upstream ZAP bugs that the instruction tests had missed
  (they ran mostly with the caches off), all fixed and covered by tests now:
  - byte, halfword, signed and unaligned loads that missed the D-cache got
    the whole word (the bootstrap's digest compare reads bytes from flash);
  - an instruction writing a register could be overtaken by an older load
    to it that missed (found by the new cache-on random tests);
  - instruction fetches were permission-checked as User mode during
    LDRT/STRT and at random after flushes (`'x`), so the kernel took a
    prefetch abort in a privileged-only section;
  - the branch target buffer stored an undefined target (simulation only;
    Quartus had resolved it).
- Tests: 17 directed tests, random ARM/Thumb programs with caches off and
  on (seeds 1-100 of each, 400 programs, agree with QEMU instruction by
  instruction), jsmolka/gba-tests (161/183 ARM, 101/109 Thumb; the rest
  are ARM7TDMI-specific UNPREDICTABLE cases). Default regression: 159 RTL
  runs pass, 48 agree with QEMU, on the netlist and on the SV sources.
- Quartus 17 standalone (every output on a pin): 13,217 ALMs (32%), 14,038
  registers, 57 M10K, 4 DSP. **104 MHz is marginal:** worst slack over four
  fitter seeds +0.317, -0.124, -0.294, +0.049 ns (about 101-107 MHz); on
  the worst seed 100 MHz gives +0.006 ns and 96 MHz +0.719 ns. The limit
  is ZAP's single-cycle stall broadcast (bus acknowledge, TLB walker, cache
  hit to every stage). **Recommendation: plan for a 96 MHz CPU clock** (or
  clk_sys at 96 MHz) until the stall is retimed; the fix is described in
  docs/CPU.md.
- docs/CPU.md: design, interface, every known difference from a real
  ARM925T, tests, timing, and the plan for the timing-fidelity pass.

### 2026-10-20: game cards (`tools/mkcard.py`); SonicN, Rayman 3 and Sega Rally play
- `tools/mkcard.py` turns an Aaru dump (`.aaruf` or its `.zip`) or a raw
  image plus `--cid`/`--csd` into the model's card (`OUT.img`, `.cid`,
  `.csd`) and the core's (`OUT.mmc`: sectors plus the `NGAGEMMC` trailer of
  `rtl/board/mmc_card.sv`). CID and CSD are the card's own, with CRC7
  computed (SonicN 5D/DB, Rayman 3 23/DB, Sega Rally 3D/FD, as in
  `research/peripherals/MMC.md`). Sectors are checked against the dump's
  own MD5/SHA-1/SHA-256, or its CICM sidecar (Sega Rally). Aaru's OCR
  (0x00200000) is the voltage Linux negotiated; the OCR written is
  0x00FF8000. Card images stay untracked in `model/.out/cards/`.
- **MMC types 10 and 7 carry the last block (register-semantics change for
  the RTL).** The model took type 10 as "CMD12 only", so the last block of
  every multi-block read came back as zeros. SonicN's relocation table was
  cut short, and the loader died ("App. closed LoaderThread", KERN-EXEC 3
  at EFile `0x503CDCD0`). epbus `0x503F56E4`-`0x503F57A8` loads CMD12 and
  the block length before the last phase and DMAs that block in it. The
  model now reads (10) or writes (7) one more block, then does CMD12.
  `rtl/upp/upp_mmc.sv` reads type 10 as the model did and needs the same
  change (not touched here). `docs/UPP_WD2.md` updated.
- The LCD log now gives the guest time (ms) of each RAMWR, for frame rates.
- Each card's game shows up in the menu (fourth row) and runs with its real
  CID and no patching. Screenshots in `model/.out/`:
  - SonicN: intro, title, demo; 5 opens the menu, then character select and
    play in Neo Green Hill (`game-sonicn.png`). 30 frames/s.
  - Rayman 3: intro, menus, save slots, story, level 1 play with running
    and jumping (`game-rayman3.png`). 21.3 frames/s.
  - Sega Rally: menus, cup and car select, a race (5 accelerates, steering,
    time-up) (`game-segarally.png`). 12.8 frames/s.
- Graphics show no defects. Keys (5, directions, soft keys) work. In-game
  clocks follow guest time. Frame rates are 2, 3 and 5 kernel ticks
  (1/64 s) and stay the same with a twice-as-fast emulated CPU (icount
  shift 3), so the model is not CPU-bound; it runs faster than real time.
- Copy protection: all three import NokiaFC.DLL, which needs `game.id` and
  `nokia.dat` on the app's drive and compares `game.id` with text the game
  passes; on a mismatch it shows a note and exits (NokiaFC `0x510F2E04`).
  SysAp reads the CID once at card detection through MmcIf (GD1DRV.ldd
  controls 4 and 6). With one CID byte changed, SonicN still plays and Sega
  Rally reaches its title: these titles do not check the CID.
- Saves: Rayman 3 writes `save.dat` to C: (in the flash image after play).
  After a reboot on that C: its slots still read EMPTY; no level had been
  finished, so this is not conclusive. Every boot asks for time and date
  again: the stand-in reports the RTC as unset.
- **Audio:** silent; no game blocks on it. Details and what sound needs:
  `docs/NOS_STANDIN.md` "Audio" (PCM through audio.ldd into a 60 KB SDRAM
  buffer at 0x0A061000, control over ISI resources 0x0B, 0x1F, 0xE8 and
  0x00, none answered).

### 2026-10-20: next steps after the games (coordinator)
- The MMC transfer-type fix (types 10/7) goes to the UPP RTL agent for
  `rtl/upp/upp_mmc.sv`.
- The model agent takes on HLE audio and the real-time clock:
  - Audio: decode the NOS audio protocol and add an emulator-only "HLE
    audio" device that the stand-in drives. The FPGA reads PCM from SDRAM
    and outputs it to AUDIO_L/R.
  - Clock: the UEMK RTC model, fed from MiSTer's RTC on the FPGA.
- Still to do on the FPGA side:
  - integrate the CPU when its agent reports;
  - C: drive saves: mount CS1 as an hps_io block device with dirty-block
    write-back, as the memory system entry describes;
  - the HLE audio block in RTL;
  - the RTC from hps_io into the UEMK registers.

### 2026-10-20, UPP peripherals (RTL): MMC types 10 and 7 carry the last block
- `rtl/upp/upp_mmc.sv` now follows the corrected model (71b0d8a). Types 10
  and 7 move one more block (a read like type 9, a write like 6), then send
  the command the driver loaded into `+0x1C`/`+0x20` (CMD12). For 10 it
  goes after the block's end bit; for 7 after the card's busy, as R1b.
  Command busy covers the block. That is safe: epbus starts the DMA
  straight after the control write and then waits for command idle, data
  idle and the DMA in any order (`0x503F57D0`-`0x503F5A94`). Before, type
  10 was CMD12 alone, so the RTL had the model's old bug: the last block of
  every read came back as zeros.
- periph bench: multi-block transfers run the way epbus runs them, 3 blocks
  and 4 KB (8, six 9s, 10; 5, six 6s, 7).
  - Every block is checked against the card image, plus a 4 KB read-back
    and the R1 states (CMD18/25 tran; CMD12 data or rcv).
  - The previous host fails these with exactly the games' symptom: the last
    block zeros or unwritten.
  - `--card FILE.mmc` (`MMC_CARD` in sim/Makefile, default
    `model/.out/cards/sonicn.mmc`): the real card's CID and CSD and its first
    16 sectors match. It is local data, not committed, and skipped when the
    file is absent.
- Quartus: every corner met at 104 MHz.
  - Worst setup +0.335 ns (slow -40C), hold +0.107 ns.
  - 18,247 ALMs (44%); upp_mmc 812 ALMs, up from 758.

### 2026-10-20, CPU: boot bench follow-up
- The bench now releases the power key after 187.5M instructions, as the
  model does (3 guest s at 16 ns per instruction). The CBUS logs then agree
  for all 67 transfers the RTL makes. At 2.5 billion cycles the RTL kernel
  makes no more device accesses where the model goes on with CBUS device 5
  and an emif read (0x08000040); the cause is not known yet. Next: a model
  instruction trace around that point (needs a QEMU slot).

### 2026-10-20, model: game audio and the real-time clock
- **Audio plays in all three games.** SoundDevice.mda streams PCM to NOS
  with ISI resource `0xE8` from object `0x48`: `0x20` start (two halves of
  the audio.ldd chunk at `0x0A061000`, 5600 samples each, rate code 70 =
  16 kHz), `0x21` reply, `0x23` half filled, `0x26` half free, `0x2A` stop,
  `0x2B` bytes played. Volume 0-9 comes as `0x0B/0x14` parameter 2. Details,
  evidence and the stand-in's answers: `docs/NOS_STANDIN.md`, Audio.
- New emulator device, `0x0C1F0000` (`model/hw/ngage_audio.c`, documented in
  `docs/UPP_WD2.md` under its own heading): two SDRAM buffers, RATE,
  FORMAT, VOLUME, DONE interrupt on source 5 (IrqTimer5). The stand-in binds
  the interrupt by name, acknowledges DONE in its ISR and sends `0x26` from
  a DFC. Delivery to a client now always goes through the channel's
  DThread (vtable `+0x54` raw write), so it works outside the client's
  context.
- The model writes what the device plays to `model/.out/audio.wav` and
  events to `audio.log`; `NGAGE_AUDIO=coreaudio` also plays it on the host,
  in real time with `NGAGE_ICOUNT=shift=4,sleep=on,align=on` (tried: Sonic,
  45 s of host audio, no errors).
- Formats (stream settings at SoundDevice `0x505AC5B8`), all mono 16-bit:
  SonicN 8 kHz, 400-sample buffers, volume 9; Rayman 3 16 kHz, 1000
  samples, volume 6; Sega Rally 8 kHz, 360 samples, volume 1, one stream
  per piece. SoundDevice upsamples 8 kHz x2, so the DSP side is always
  16 kHz. Recordings: no device underruns after each stream's first buffer;
  Sega Rally's `bgm02_select_8.snd` matches its recording (decimated by 2)
  with correlation 0.986, so the rate is right.
- Fixed on the way: the stand-in's NOS object constructor did not return
  the object, which nosdriver stores (`0x511691F0`); the old binary worked
  by luck of register allocation.
- **The clock is set at start-up.** rtc.dll needs NOS's event 1 with a base
  date (two equal copies) to which it adds the UEMK RTC's time of day and
  8-bit day counter (UEMK `0x11`-`0x13`, `0x01`, read through cbus.dll
  entries 32-34). The stand-in sent zeros, so DOS reported the clock unset
  and Startup.app asked for time and date at every start. Now:
  - the UEMK model counts real time (QEMU RTC at start, local time by
    default, `NGAGE_RTC` overrides) and `0x04` calibration reads `0xC0`;
  - an emulator register at `0x0C1F0100` holds the start-up date;
  - the stand-in turns it into a TTime in EUser's calendar (Julian leap
    years up to 1600: 12 days ahead of proleptic Gregorian, the first try
    showed the date 12 days early) and sends it.
  A second boot goes straight to the idle screen showing today's date and
  time (`model/.out/rtc3/lcd-0005.png`). The first boot after a C: format
  still asks once (`FirstBoot.dat` missing), as a new phone does.
- `model/hw/ngage_patch.c` and `tools/mkimage.py` compute digests through
  the bootstrap's ROM map (CS0 `0xF00000`+ at `0x51300000`), as
  `sim/cpu/boot/prep.py` does (9385f28).
- FPGA: the HLE audio block (SDRAM reads at RATE, linear resampling to
  48 kHz) and loading the UEMK RTC and the date register from hps_io's RTC
  at reset.

### 2026-10-20, FPGA side: C: drive saves (CS1 as a save file)
- Setup on the MiSTer:
  1. Make `cs1.bin` with `tools/mkimage.py` and copy it to the core's games
     folder. The file must be exactly 8 MB. It is the save file: keep a
     copy of the fresh one.
  2. Load CS0 with "Load flash CS0" as before.
  3. Mount `cs1.bin` with **"Mount flash CS1 (save)"**. The OSD says "CS1
     mounted: C: saves to it". The core holds while the 8 MB load runs.
  4. A fresh image has a blank C: drive. On the first boot hold Call + * +
     3 at power-on to format it (model finding).
- Changes go back to the file 100 ms after the last flash write, and at
  most 2 s after the first. "Save C: now" writes them at once and says "C:
  saved"; use it before switching off. LED_DISK shows the transfers.
- "Load flash CS1" (ioctl) still loads a throwaway CS1. It detaches the
  save file: nothing more is written to it until the next mount. A
  read-only file loads but is never written ("CS1 read-only: no C:
  saves"). A file of another size is refused ("CS1 save file must be 8
  MB").
- OSD order for key macros: Load flash CS0, Load flash CS1, Mount flash
  CS1 (save), Mount MMC card, Rotate, Aspect ratio, Scandoubler Fx, Memory
  test, Save C: now, Reset.
- How it works:
  - `rtl/mister/flash_save.sv` (SD slot 1) reads the file in 4 KB requests
    and copies it into DDR3 at 0x32000000.
  - ddram_flash marks each CS1 block it writes in a 16K-bit bitmap.
  - A pass then reads each dirty block back from DDR3 (64-beat burst) and
    sends it with sd_wr. The bit clears in the clock that read is issued,
    so a block written during its write-back goes out again.
  - The state survives a core reset.
  - mmc_card's buffer writes are now gated with its own sd_ack (both slots
    share hps_io's buffer signals).
- CS0 stays on ioctl.
  - In the RH-29 v4.60 ROM only medint.pdd issues program or erase
    sequences, in its CS1 region. ecust's command is the burst
    configuration (0x60/0x03); the 0xAAA in ekern is table data.
  - Every saved CS1 the model wrote differs from the firmware's only in
    0x400000-0x7FFFFF.
  - A model run with `flash0-save` would confirm it dynamically; it was not
    run, as QEMU is in use.
- nor_flash: the erase and lock sector bits are now set a clock after
  their command, from a registered sector number. The decode had become
  the worst path (−0.219 ns). Bench and behaviour are unchanged, and it is
  880 ALMs smaller.
- Benches:
  - `make -C sim save` covers mount, programs and an erase through the
    bus, exactly the dirty blocks written back with the right data, a
    re-dirtied block sent again, nothing sent while nothing changed, save
    now, the 2 s limit, core reset, detach, read-only, and a refused size.
  - Mutants are caught: lost marks, the bit cleared at the end of the
    write instead of at the read, the quiet time ignored, a dropped load
    write.
  - The top bench mounts a save image through the shell.
- Quartus: every corner met at 104 MHz.
  - Worst setup +0.305 ns (the framework's scaler), hold +0.016 ns.
  - 18,073 ALMs (43%), 256 M10K. flash_save is 207 ALMs and 6 M10K.

### 2026-10-20, model: saves persist; audio after the first boot; screen saver
- **Saves persist.** Sega Rally, Options: SPEED km/h → mph, SOUND 1 → 6,
  END (the game writes `c:\System\Apps\6R12\6R12.dat`). The model wrote C:
  back to `cs1-save.bin` on exit; a reboot on that C: shows mph and 6 in the
  Options screen, and the game's sound runs at volume 6
  (`model/.out/sv1`, `sv3`). `C:\system\bootdata\FirstBoot.dat`, written on
  the first boot, is also read back (no time query on the second). The
  flash and LFFS handling need no change. Save files of the others:
  SonicN `c:\system\apps\SonicN\sonic.da0-2`, Rayman 3
  `c:\system\apps\rayman3\save.dat`.
- The sound option is SoundDevice's volume: `0x0B/0x14` parameter 2 follows
  it live (1 to 6 while the bar moves), on a 0-9 scale (the game's bar has
  ten steps).
- **Fixed: no game sound from the second boot on.** From then on a sound at
  start-up makes SoundDevice reserve (`0x1F/0x01`) and release
  (`0x1F/0x04`) the audio resource; after the release it waits in state 14
  for NOS's resource `0x1F` message 3 or 6, and refuses every start until
  then (PlayInit `0x505AC264`; the games retry forever, sending `0x00/0x02`
  each time). The stand-in now answers the release with `0x06 [0D 00]`
  (`docs/NOS_STANDIN.md`). Sega Rally and SonicN play on a second boot.
- **Screen saver (LCD partial and idle mode).** lcd.ldd `0x50406278` sends:
  - PTLAR `0x30` with start and end row (16 bits each: `00 04 00 1a`, then
    `00 80 00 96`, `00 a4 00 ba` a minute apart), PTLON `0x12`, IDMON `0x39`,
    then a full frame (PASET `00 00 00 d0`, RAMWR) with a date bar in those
    rows;
  - on a key: IDMOFF `0x38`, NORON `0x13`, then the normal screen.
  `ngage_lcd.c` now shows rows outside the partial area black and, in idle
  mode, each colour component as its top bit (eight colours). The rows are
  the driver's PASET rows: the bar it draws falls in them. The screen saver
  is black with a moving bar, as on the phone, instead of white
  (`model/.out/ss1`). `rtl/board/lcd_panel.sv` needs the same.

### 2026-10-20: model agent done; screensaver modes already in the panel RTL
- Model status: saves persist (tested with Sega Rally options), and sound
  plays on every boot after the 0x1F/0x06 release-answer fix. The
  screensaver's partial and idle modes are modelled.
- `rtl/board/lcd_panel.sv` already implements the same behaviour
  (PTLAR/PTLON blank outside the area with PARTIAL_RGB = 0, and IDMON keeps
  the top bit of each channel), so nothing needs porting.

### 2026-10-20, UPP peripherals (RTL): HLE audio and the RTC in the core
- On the MiSTer nothing needs setting up. Game audio comes out of MiSTer's
  audio outputs at 48 kHz. The phone's clock is set from the time the HPS
  sends the core (MiSTer's clock: NTP or an RTC board). Neither has run on
  the MiSTer yet: there is no CPU in the core.
- `rtl/upp/upp_haudio.sv`, the HLE audio device at `0x0C1F0000`, follows
  `model/hw/ngage_audio.c` register for register:
  - A frame is due each time a RATE-per-second frame clock comes round,
    counted from the RUN write, or from a RATE write that changes the rate.
  - It plays frame by frame as the model's catch-up does: buffer switching,
    starving, DONE, STATUS, POS and PLAYED, and VOLUME as `(v * vol) >> 8`.
    A frame due at the edge of a register write is played first.
  - The interrupt is source 5, ORed with timer 5.
  - Samples are read through the DMA controller's master port. upp_periph
    alternates the two, a cycle each.
  - AUDIO_L/R are interpolated linearly at 48 kHz between the two frames
    before the latest, at the frame clock's phase. The extra frame gives
    the reads a whole frame period. The output is 0 while stopped; AUDIO_S
    is 1.
  - Deviations:
    - Frame by frame instead of in chunks. This differs only when LEN is
      rewritten below POS for the buffer being played.
    - The phase is real time. The model's 16.16 step is truncated, so its
      48 kHz stream runs slightly fast.
- Model note (not changed): in `out_put`, `(l - last) * a` is an `int`. It
  overflows for a step of more than half of full scale (for example
  -20000 to 20000) near phase 1, which gives a wrong host sample. Only
  host playback is affected, not the WAV. The FPGA computes it in 34 bits.
- RTC:
  - `rtl/mister/rtc_wall.sv` takes hps_io's RTC (BCD, MSM6242B layout)
    each time the HPS sends it, and counts seconds and the calendar
    (2000-2099) in between. It is not reset with the core.
  - upp_cbus: UEMK `0x11`-`0x13` read its time of day.
  - `0x01` is the 8-bit day counter. It is days since 2000 modulo 256 plus
    an offset, so it steps with the date, also when the HPS changes the
    date. Writing `0x01` sets the counter, as `rtc_day_off` does in the
    model.
  - `0x04` reads `0xC0` after reset (cbus-regs.txt).
  - The date register at `0x0C1F0100` is 32-bit only, and `+4` to `+C`
    read 0. At reset it takes the wall clock's date, with the counter at 0.
    If the HPS's first time comes after reset, it takes the date then.
  - Deviation: until the HPS sends a time, the date register reads 0
    ("unknown", docs/UPP_WD2.md) and the time runs from 00:00:00. The model
    always has a time.
- wb_selftest's register check moved from `0x0C1F0010`, which is now ADDR0,
  to `0x0C1E0010`.
- Benches:
  - `make -C sim haudio` runs the block against a port of ngage_audio.c,
    at 104 MHz and again at 2 MHz (many more buffers per clock). It
    checks:
    - every frame read (value, order, silence, volume, bus errors) and
      every register read;
    - the interrupt line every clock, so the edge of each DONE;
    - the 48 kHz output against a separate model of the interpolation.
  - Cases: registers and clamps; mono and stereo, aligned or not; rate
    and volume changes; restarts with reads under way; reads that take a
    whole frame period; random sessions in the stand-in's style (about 200
    sessions, 300,000 frames).
  - With a model recording (`--wav`, default
    `model/.out/au-rayman/audio.wav`, 8000 frames; local data), played the
    stand-in's way in halves of 5600 samples:
    - the frames come out unchanged (au-rayman, au-sega, au-sonic,
      au-host);
    - the 48 kHz output against the model's own resampler on the same
      frames gives an SNR of 25-29 dB (Rayman), 25.7 dB (Sega Rally) and
      19.0 dB (Sonic), at the best whole-sample offset. The model's stream
      against itself half a sample later gives 24.6, 24.2 and 18.7 dB, so
      what is left is the phase alignment;
    - both streams are written to `sim/build/out` as WAV files.
  - periph:
    - audio through the bus with a DMA transfer running at the same time:
      DONE0 on source 5 at its frame's clock, IRQ number 6, the output
      levels, stop;
    - RTC: before the HPS time, the HPS time, midnight, month, year and
      leap-day ends, the counter written and wrapping, the clock set back,
      core reset.
    - The CBUS log replay no longer compares the RTC registers (wall clock)
      or `0x04`, because the log is older than `0xC0`.
  - All 21 mutants are caught (12 in upp_haudio, 9 in the RTC path). They
    include: a buffer ending a frame late; no phase restart at a rate
    change; switching, starving or stop not clearing; wrong gain or phase
    bits; the unaligned stereo read; the drop at restart; IRQ enable
    ignored; a frame arriving in the clock of the next one; the day offset, write, rebase, `0xC0`,
    the date before the HPS time, leap years, month lengths, and the
    month-end compare. The month-end compare survived until the periph
    bench checked the date after each kind of day's end.
- Quartus: every corner met at 104 MHz.
  - Worst setup +0.102 ns (slow -40C: lcd_panel `tfa` to `s2_row`, then
    the scaler); worst hold +0.067 ns (the scaler). The audio and RTC
    logic is not in the worst 20 paths.
  - 18,722 ALMs (45 %, +649 since the C: drive build), 256 M10K, 40 DSP
    blocks.
  - upp_haudio is 479 ALMs and 6 DSP blocks; rtc_wall is 110 ALMs.

### 2026-10-20: MiSTer free again
- The user says the MiSTer is available; the hold is lifted.

### 2026-10-20, CPU: the boot matches the model; 104 MHz closes on eight seeds
- Kernel divergence found and fixed. Causes were in both the CPU and the
  bench. The RTL now makes every device access of the model's run, in the
  same order and with the same values: 76,975 accesses, through the MMC
  and LCD driver start-up and the RTC, to the model's last one at 581M
  instructions. Register logs (61), CBUS logs (79), mmc.log and the kernel
  text are identical.
  - CPU, two upstream ZAP bugs, each with a test that fails on the old
    netlist:
    - Thumb `LDR/STR Rd, [SP, #imm]` used SP - imm (tests/thumb.S);
    - MOV/ADD PC kept an older instruction's predicted PC, so a
      `MOV PC, LR` could run on past itself after a conditional BL
      predicted not taken (tests/bpred.S).
  - Bench:
    - keypad UIF/CTSI;
    - the current model's UEMK and HLE RTCs;
    - the MMC host (empty slot);
    - instructions counted as QEMU's icount counts them. SWI and UND
      count, and a Thumb BL pair counts once. Before, guest time drifted
      240 instructions by the first ticks.
  - Method: the model is built from git HEAD on the ubuntu server
    (sim/cpu/model/build_linux.sh, run_model.sh, a TCG plugin for device,
    interrupt and instruction traces). sim/cpu/boot/cmp_dev.py and
    cmp_window.py compare the two sides. `make -C sim/cpu boot-prep
    boot-model boot` runs it all.
- Timing at 104 MHz, standalone, every output observed, Quartus seeds 1-8:
  every seed positive at every corner. Worst setup slack is +0.20 ns at
  slow 100C / +0.33 ns at slow -40C (seed 7 and seed 3 give the minimums),
  hold is at least +0.09 ns, and the fast corners have about 4 ns spare.
  - Changes:
    - registered bus responses in both caches;
    - background-load register write from a latch;
    - valid/dirty write-behind;
    - registered RAM collision checks;
    - load transform before the memory-stage register;
    - RAS pushes one cycle late;
    - the ARMv5 patterns folded out of the decoder.
  - Placement noise is about ±0.3 ns.
- Cost: one cycle per uncacheable access and per D-cache load miss.
  - Boot bench (zero wait states): the uncached bootstrap +21% cycles,
    cached integrity checks +6%, cached kernel code about 0%.
  - Bench tests: +12% at zero wait states, +4% at 2-9.
- Regression: 162 runs (49 agree with QEMU), 400 random programs,
  gba-tests, RTL=sv. All pass.

### 2026-10-20: paused by the user (conserving usage)
- The CPU integration agent was stopped mid-task. Its last commits are
  the full-core boot bench (`sim/cpu/boot/cmp_flow.py`, coreboot), timing
  fixes in the memory system and SDRAM, two CPU fixes (Thumb BL second
  half after an interrupt; data permission checks in the instruction's own
  mode), and `NGage.qsf` with fitter seed 3. Any uncommitted changes it
  left are in the working tree.
- Background jobs it started on the ubuntu server (Quartus in Docker,
  Verilator boot runs) may still finish on their own.
- On the MiSTer, in /media/fat/games/NGage/, ready for the first hardware
  boot: rh29-460-cs0.bin, rh29-460-cs1.bin (from tools/mkimage.py) and
  sonicn.mmc (test data). MiSTer.ini has an `[NGage]` direct_video=0
  section; the backup is MiSTer.ini.ngagebak.
- Resume: finish the CPU integration (full-core boot sim to the idle
  screen; a full Quartus compile at 104 MHz with the CPU), fetch the RBF,
  deploy, boot with the images and the card on the MiSTer, then write the
  README.

### 2026-10-21: CPU integrated; the whole core boots to the idle screen in simulation
- Resumed after the pause. The stopped CPU agent had committed everything
  but docs/CPU.md, now committed (5c77791).
- Whole core (seed 5, commit 260d356): 30,578 ALMs (73%), 314 M10K, 43
  DSP. Timing at 104 MHz meets every corner: setup +0.074 ns (slow 100C),
  +0.089 ns (slow -40C); hold +0.089 ns or more; recovery and removal
  positive. The RBF from the server's `ngage-q-c14-5` build is
  `output_files/NGage.rbf` (md5 62afab6b...).
- Whole-core Verilator boot (server, `~/dev/mister/coreboot/run16`): 86.5
  guest seconds in 6.6 hours, 1.02 G instructions, 17 LCD frames. The
  kernel log shows the full S60 start-up with NOS stand-in replies, and the
  last frame is the movistar idle screen with the bench's date
  (Tu 01/06/2004). The FPGA design therefore boots the real firmware to
  the idle screen in simulation.
- Hardware test set up on the MiSTer: `/media/fat/_Console/NGage_20261021.rbf`
  and an MGL launcher `/media/fat/_Console/NGage-SonicN.mgl` that loads
  CS0 (F1 index 1), mounts `rh29-460-cs1-save.bin` on S1 and `sonicn.mmc`
  on S0. Keyboard: arrows = rocker, Enter = OK, F1/F2 = soft keys,
  F5 = Menu, F8 = Power (rtl/mister/ngage_input.sv).

### 2026-10-21: hardware boots to the Nokia logo, then a kernel fault
- The CPU build on the MiSTer shows the Nokia logo and stops. Two Quartus
  rounds of a debug overlay (OSD "Debug overlay": the fetch address,
  status bits, interrupt words and the Kern::Fault record words the kernel
  copies to on-chip RAM 0x0C0047F0, decoded from Zaparoo screenshots by
  `tools/mister_dbg.py`) show the CPU in the kernel halt loop at
  0x5031E394 with IRQ pending and masked, and the fault record
  `503A879C E59FF044 10000000`: an exception at 0x503A879C, which is
  `RArrayBase::Count` in EUser (`ldr r0,[r0]; bx lr`), with 0xE59FF044 as
  the data address: the `this` pointer held an instruction word
  (`ldr pc,[pc,#68]`, the shape of an exception vector).
- The fault is deterministic and independent of the inputs: five boots
  gave the same record, with the save mount or without, with the CS0
  image with the 56 per-phone bytes or without them, with the MiSTer's
  clock at 2026-10-21 or set to 2004-06-01 (the simulation's date). It
  happens before the C: format (no CS1 writes), within the first 25 s.
- Ruled out: the image in DDR3 (the bootstrap's MD5 over 0x50009000-
  0x51169FFF passes before the kernel starts, and the file on the card
  matches `tools/mkimage.py`'s output); the sv2v netlist (the whole-core
  simulation compiles `rtl/cpu/arm925t_gen.v`, the file Quartus builds,
  and reaches the idle screen with the same images); the memory test
  (passes on the same build). The whole-core simulation takes no abort,
  undefined-instruction or prefetch-abort exception at all in 86 s (1.4 M
  exceptions: SWI, IRQ, FIQ only), so the first one on hardware is the
  anomaly. Quartus's warnings for our RTL are benign (the V4T-only case
  items that never match, sv2v width casts).
- Still open: Verilator's X choices (the simulation ran with
  `--x-assign unique --x-initial unique`, one seed, so a reachable
  don't-care that Quartus resolves the other way would never show). Four
  whole-core runs with `--x-assign 0`, `--x-assign 1`, `--x-initial 0` and
  another seed are running on the server (`~/dev/mister/coreboot/x*`,
  `xvar.sh`); their `dev.log` would show the abort ("X n exc pc 00000010").
- A hardware trace, to see the fault happen: `rtl/mister/dbg_trace.sv`
  keeps the last 8192 retired instructions (PC, CPSR, event, clock), 4096
  data-port accesses and 2048 bus beats in block RAM and, on the first
  abort or undefined instruction (or the fault-record write), writes them
  to DDR3 at 0x33000000 through the loader port, up to four dumps.
  `tools/mister_trace.py fetch` reads them over ssh from /dev/mem and
  `show` decodes them with the ROM disassembly. Taps come out of ZAP's
  writeback stage and data port (`dbg_wb_*`, `dbg_d_*` on arm925t).
  Verilator bench `make -C sim trace`; `make test` and lint pass; the
  overlay gained the trigger PC and the dump counts (rows 32 and 36).
  `localparam DBG_TRACE` in NGage.sv switches it off for a release build
  (about 1.3 Mbit of block RAM).

### 2026-10-21: Game cards from game folders (`tools/mkcard.py` folder mode); five cracked games play
- **Folder mode.** `tools/mkcard.py` now also takes a game folder (the card's
  root, holding `System/Apps/...`) or an archive of one (.rar, .7z, a .zip
  without an .aaruf), as cracked games are passed around. Archives are
  extracted with unar into `model/.out/cards/src/<name>/` (untracked; reused
  on the next run). The output is the same `OUT.img` + `.cid`/`.csd` and
  `OUT.mmc` as the other modes. `--batch OUTDIR INPUT...` builds many and
  writes `OUTDIR/cards.csv`. Aaru and raw output is byte-identical to before
  (Rayman 3, SonicN).
- **Layout** as the retail cards (MMC.md 3.3), on 16, 32, 64 or 128 MB:
  - MBR with one partition at LBA 32, ending on a cylinder (32 sectors a
    track; 2, 4, 8 or 16 heads); type 0x01 (FAT12), 0x04 (32 MB) or 0x06.
  - FAT12 on 16 MB, FAT16 above; 4 KB clusters, 1 reserved sector, 2 FATs,
    512 root entries, media 0xF8, `MSWIN4.1`, serial 0, `NO NAME`.
  - Capacities 32760, 65520, 131040 and 262080 blocks (C_SIZE 4094,
    C_SIZE_MULT 1-4), as the MID 0x07 retail cards of 16, 32 and 64 MB.
  - The size is the smallest with 128 KB free (`--free`, `--size`).
- **Files** go in with mtools (mmd, mcopy) with their dates; directories
  get the newest file's date (SOURCE_DATE_EPOCH), so an input always gives
  the same image.
  - Long names keep the folder's case. mcopy stores an 8.3 name with an
    all-lower-case part (`AFO.cfl`) with the NT case flags instead of a long
    name; Symbian, whose FAT ignores case, may show it in capitals.
  - Thumbs.db, desktop.ini, .DS_Store, `._*` and `__MACOSX` are left out.
  - Two packaging slips are fixed and reported (`--as-is` turns this off):
    Apps, Libs or Programs beside System instead of in it (Ghost Recon:
    built as is, it stops with "System error", its DLLs not found), and
    `System/App` for `System/Apps` (TechWars).
  - Every file is read back from the image with the tool's own FAT12/16
    reader and compared with the source. macOS `fsck_msdos` passes on every
    card of the collection.
- **CID and CSD** (`--cid`/`--csd` override them):
  - CID synthetic: MID 0, OID 0, PNM the first six letters and digits of the
    name, PRV 1.0, PSN the CRC-32 of the name, MDT the newest file's month.
    Cracked games do not check it.
  - CSD: SonicN's made writable. CCC 0x017 (block write added), WRITE_BL_LEN
    9, R2W_FACTOR 2, no PERM/TMP_WRITE_PROTECT. TAAC 10 ms and NSAC 0 as the
    core's default card, since its reads wait for the HPS. C_SIZE_MULT
    follows the size.
- **The user's collection** (73 .rar, a .zip, a .7z, two .sis; "N-Gage
  cracked games collection"): 67 cards in `model/.out/cards/collection/`
  (untracked) with `cards.csv`.
  - Sizes: 40 of 16 MB, 25 of 32 MB, 2 of 64 MB (Glimmerati, Pathway to
    Glory: Ikusa Islands). None needs 128 MB.
  - Not built: six BLZ packages (MLB Slam!, MotoGP, Pandemonium, Puyo Pop,
    Puzzle Bobble VS, Tomb Raider), the BLZ installer and a patched-libraries
    installer (.sis), loose patched libraries (libs.rar), and save games for
    C: (Game Cheats.rar).
  - The CSV notes the rest: Habbo Island (extras; the readme says dev kits
    only; not tested), Polish versions, prototypes, the unused Bomberman
    "fix" APP (its nfo calls it a placebo, not needed on the QD), Sango's
    English patch (a .sis), crack-group intro .sis files on some card roots.
- **BLZ packages** (not implemented): header "NGPK", version 0x100, packed
  and unpacked sizes, and a 661-byte packed directory at the end. The payload
  is neither zlib nor raw deflate, so it is compressed or enciphered. A BLZ
  game needs the BLZ installer (BLZinstapp.sis) installed on the phone, the
  .blz in the card root and room for the unpacked game. Tomb Raider: 7.5 MB
  package, 7.8 MB unpacked, so a 32 MB card. The installer then unpacks it
  onto the card. The model keeps card writes in memory only
  (`ngage_mmc.c`), so an unpacked game would last one run there; the core
  writes them back to the .mmc file.
- **Model runs.** C: formatted and booted once
  (`model/.out/fc-base/cs1-base.bin`), then copied for each game. Key
  scripts are in `model/.out/fc-keys/`. Launch: Menu at 30 s, down, down,
  OK; the card's game is in the fourth row. Frames are counted as bursts of
  RAMWR in the LCD log; Asphalt writes each frame in strips.
  - Alien Front (16 MB): "Bluetooth is switched off" answered No; logos,
    title, campaign, tank and difficulty, briefing, then Mufthasa Base:
    driving, turning, firing, taking hits. 16.8 frames/s.
    `model/.out/game-alienfront.png`.
  - Tony Hawk's Pro Skater (16 MB; needs the model fix below): logos, menus,
    career, Warehouse: skating, grinding, a box smashed. 27.8 frames/s.
    `game-tonyhawk.png`.
  - Asphalt Urban GT (16 MB): menus, Instant Play (a random race), 5
    accelerates. 20.5 frames/s, 3 ticks. `game-asphalt.png`.
  - Glimmerati (64 MB, FAT16, type 0x06): crack intro, menus, name entry,
    Quick Race in Milan, driving. 29.5 frames/s. `game-glimmerati.png`.
  - X-Men Legends (32 MB, FAT16, type 0x04): new game, cutscene, dialogue,
    walking, breaking a barrier (25 Quest XP). 21.3 frames/s, 3 ticks.
    `game-xmenlegends.png`.
  - Alien Front and Tony Hawk's frame times vary instead of following the
    1/64 s tick, which suggests they are CPU-bound in the model (62 MIPS),
    unlike the three retail games of 2026-10-20. An icount
    shift 3 run (twice the CPU) showed "App. closed EmonServer" at boot and
    the key script missed the menu; not followed up.
  - None of these games wrote to the card.
  - Also checked: Ghost Recon: Jungle Storm (title and attract demo) and
    TechWars (starts).
  - Tomb Raider, from the task's list, is a BLZ package and was not tried.
- **Model bug fixed: MOVS PC, LR in User mode.** Tony Hawk's first stopped
  with "App. closed Main" (KERN-EXEC 3).
  - Cause: an undefined-instruction exception at `0xFF947D98` in the game's
    RAM-loaded code, a division helper that returns with `movs pc, lr` in
    User mode.
  - The ARM ARM calls this UNPREDICTABLE and QEMU UNDEFs. ARMv4/v5 cores have
    no User-mode SPSR, and the game runs on the phone, so the ARM925T must
    take it as a plain return with the CPSR unchanged.
  - Fix: `model/qemu-patches/arm-v5-user-movs-pc.patch` (QEMU
    `target/arm/tcg/translate.c`: on pre-v6 cores, MOVS/SUBS PC in User mode
    writes the PC and leaves the flags). `model/build.sh` applies the
    patches in `model/qemu-patches/` once.
  - The core needs no change: ZAP keeps the CPSR for an S-bit write of the
    PC in USR/SYS mode (`rtl/cpu/zap/zap_alu_main.sv`, "Restore CPSR from
    SPSR if not in USR/SYS mode").
- **For the core:**
  - Folder cards above 16 MB are FAT16 cards of 65520 or 131040 blocks
    (.mmc files of 33,546,752 and 67,092,992 bytes). `mmc_card.sv` takes the
    capacity from the CSD, so nothing new is needed.
  - Folder cards are writable (class 4, no write protect): CMD24/25 reach
    the .mmc file unless it is mounted read-only.
- **Found (same day, later): the fault is the firmware's blank-C: path,
  not a hardware bug.** The model takes the identical exception: its
  superpage holds the same record (`0x503A879C`, `0xE59FF044`), and under
  GDB the kernel's dispatcher classifies it as a user-mode data abort
  (type 12) in thread `0x8040ce7c` (Starter), finds no handler, and runs
  the Kern::Fault epilogue at `0x5031E340`: it copies the record to on-chip
  RAM, writes `0x200` to `0x0C120004` and 4 to `0x0C150000` (reset reason),
  masks IRQ and FIQ and spins, waiting for the phone's reset. It is the
  crash the bring-up notes of 2026-10-19 describe: with the C: area of CS1
  blank, LFFS cannot mount it, EStart falls back to a RAM drive, Starter
  takes the (0, 210) start-up list, `CBaBackupSessionWrapper` finds no
  backup server and Starter's cleanup calls `RArrayBase::Count` through a
  null pointer (the `this` value is the exception vector's instruction,
  read through the page at virtual 0). The kernel log shows `auxstart 0`
  (HelperDrv's start-up query, answered 0 by the NOS stand-in) and stops.
- Model matrix (`build/dis/matrix.sh`, GDB breakpoints on the abort
  handler and the fault epilogue): the pristine CS1 image (`cs1.bin` from
  `tools/mkimage.py`, C: all `0xFF`) faults; the freshly formatted C:
  (`model/.out/fc-base/cs1-base.bin`) boots on. The hardware runs so far
  all used the pristine image or a save file of unknown state, and the
  whole-core simulation that reached the idle screen used a formatted one.
  The word `0x10000000` the overlay showed is the superpage word at
  `+0x10`, the same in the model; it is not a fault reason.
- Consequences: (1) the core needs a formatted C: to boot, as the phone
  has from the factory: test the hardware with `cs1-base.bin` mounted as
  the CS1 save; (2) a blank C: should format itself as on the phone: the
  firmware does that when HelperDrv's "auxstart" answers 105
  (docs/UPP_WD2.md); the stand-in answering 105 is being tried in the
  model; (3) after a Kern::Fault the phone restarts; the core (and the
  model) spin instead. The hardware trace build (above) was not needed
  for this but stays for the next fault.
- **Fix: the NOS stand-in answers 105 to HelperDrv's "auxstart" query**
  (service 3 id 12, `model/nos-stub/nos_stub.S`). In the model with the
  pristine CS1 image the kernel log then reads `auxstart 105` and the boot
  goes on (Bluetooth driver, NOS traffic) with no abort. The query is only
  made when C: does not mount (no `auxstart` line in a boot with a
  formatted C:), so a healthy C: is never reformatted. `tools/standin` and
  the hardware images (`tools/mkimage.py`) rebuilt. On the FPGA a format
  erases 64 sectors at the chip's 0.7 s each, so the first boot of a blank
  image takes about a minute longer.
  Confirmed with a persisted image (`build/dis/cs1-105.bin`): after the
  boot the C: area holds a formatted LFFS (776 KB written) and the kernel
  log runs on. A whole-core Verilator run of the same (new cs0.bin, blank
  cs1.bin) is on the server in `~/dev/mister/coreboot/fmt1`, to see the
  RTL's flash erase under the firmware's format before the hardware does.
- Next on hardware (blocked at the time of writing by the SSH agent
  refusing the MiSTer key): `build/hwtest-fmt.sh 60 120 200 300` copies the
  rebuilt `build/hwtest/cs0.bin` over, deploys the trace build RBF
  (`build/hardware/NGage-trace.rbf`, setup -0.060 ns at slow 100C, fine
  for debugging) and boots the no-save MGL; the firmware should format C:
  (about a minute of sector erases) and reach the idle screen. The MiSTer
  still has the old `rh29-460-cs0-nophone.bin` copy to delete.

### 2026-10-21, evening: the N-Gage boots to the idle screen on the MiSTer
- With the rebuilt `cs0.bin` (stand-in answering 105) and the pristine
  `cs1.bin` loaded as plain files (`NGage-nosave.mgl`), the trace build
  boots on the MiSTer: the Nokia logo, about two minutes of C: format (the
  flash model's 0.7 s sector erases), the N-Gage splash with the first-boot
  Time and Date dialogs, and after OK, OK the movistar idle screen with
  signal and battery bars (`build/hardware/fmt-ok2.png`). The overlay
  shows no fault record and no trace trigger throughout.
- Open: the Date dialog offered 01/01/2005 and the idle screen shows it,
  while the model's first boot shows the host's date (21/10/2026): the HLE
  RTC date register path on the FPGA (rtc_wall → upp register 0x0C1F0100 →
  the stand-in's base date) is to be checked. The Time dialog had the
  MiSTer's time, so the UEMK time of day works.
- The MiSTer's `rh29-460-cs1-save.bin` is the pristine image too (C:
  blank), which is why the save-mounted boot stalled the same way.
- Next: boot with the save mount so the format persists and the second
  boot goes straight to the idle screen; mount `sonicn.mmc` and start the
  game; then the date register, keys, sound.
- **Saves and the game card work on the MiSTer.** With `NGage-SonicN.mgl`
  (CS1 mounted as the save, `sonicn.mmc` on SD 0) the first boot formats
  C: and "Save C: now" writes the formatted image back to the SD card
  (ROM part untouched, 766 KB of LFFS in the C: area). A cold boot from
  that save skips the format: Nokia logo, operator splash, idle screen in
  about two minutes. Menu (F5) shows Juegos … N-Gage Arena and the card's
  SonicN icon in a fourth row; OK on it starts the game ("PRESENTED BY
  SEGA"; `build/hardware/sonic2-game.png`).
- **MiSTer's clock arrives after the CPU has started.** Main_MiSTer sends
  the RTC once, at the end of the core's start-up, after the files the
  launcher loads (`user_io.cpp` `send_rtc(3)` after the mounts; only
  Minimig and a few others get it again every minute). The CPU was
  released the moment both images were in, so the stand-in's one-time
  read of the HLE RTC date (at the NOS entry) saw 0: rtc.dll counts the
  clock as unset and Startup.app asks for the time and date at every
  start (its dialog defaults, 10:26 PM and 01/01/2005, are the firmware's
  own; the model shows the same dialog and drops it once the date is
  valid). Fix in NGage.sv: the CPU start also waits for `rtc_valid`, up to
  3 s after the images; the overlay gained the wall clock and its date
  (rows 40 and 44, `tools/mister_dbg.py`). Quartus build running.
- Open: after "Reset and close OSD" (a warm reset, DDR3 and on-chip RAM
  kept) the firmware stays on the Nokia logo with the CPU running user
  code for minutes and no fault; a cold start from the same save is fine.
  A QEMU `system_reset` through the monitor did not restart the model
  (the machine does not implement it), so no model analogue yet. The
  phone itself resets this way after a Kern::Fault, so it matters later.
- Sonic N on the MiSTer: SEGA logo, title screen and the attract demo
  (Tails in a level) render correctly from the mounted card
  (`build/hardware/sonic2-k5b.png`, `sonic2-k5c.png`); the game's code
  runs from RAM (fetch addresses `0xFFE0xxxx`). Keys in the game, sound
  and other cards are not tested yet.
- Clock-wait build (5f646c2) on the MiSTer: the overlay's clock rows read
  `valid=1 17:14:38 2026-10-21` from the first screenshot on, so the wall
  clock is set and right before the CPU starts, yet Startup.app still
  asks for the time (the model shows the same dialog for a few seconds
  and drops it once rtc.dll has the stand-in's base date). So the fault is
  downstream: the HLE date register as the stand-in reads it, or rtc.dll's
  UEMK reads. Next build: the trace also triggers 16 clocks after a read of
  `0x0C1F0100` (`DBG_TRIG_RD` in NGage.sv), so the dump shows the value the
  stand-in got and the accesses around it.
- Date-trigger trace build (2af9a2f) meets timing at every corner (+0.087
  ns slow 100C, +0.024 ns slow -40C); `build/hardware/NGage-datetrig.rbf`
  and `output_files/NGage.rbf`. Its hardware run was cut short by the SSH
  agent; to redo: `build/hwboot-dbg.sh NGage-SonicN 40`, then
  `tools/mister_trace.py fetch build/hardware/dt-trace.bin` and `show
  --dump 0 --rom build/hwtest/cs0.bin build/hwtest/cs1.bin`: the data ring
  holds the stand-in's read of `0x0C1F0100` (virtual `0x581F0100`).
- README.md written for users (eb443ad); the MiSTer template's notes
  moved to docs/MISTER-TEMPLATE.md. A warm OSD reset boots (bootstrap,
  flash driver, file server PCs) but stays on the Nokia logo with the
  system mostly idle; still open.
- Date-trigger trace on the MiSTer (`build/hardware/dt-trace.bin`, fetched
  with the new `tools/mister_trace.py fetch-devmem`: the MiSTer kernel
  refuses `read()` of `/dev/mem` above RAM, busybox `devmem` maps it): the
  stand-in's read of `0x581F0100` at 5.67 s returns `0x07EA0A15` =
  2026-10-21, so the date reaches rtc.dll's event 1 intact. The model
  shows the same Time dialog at every start too (it stays until the
  screensaver covers it at about 40 s, which then shows the right date and
  time), so the dialog is the firmware's behaviour in this environment,
  not a hardware fault; what the hardware lacks is the screensaver (none
  after 200 s), to be checked next. The overlay gained the audio peaks of
  each frame (rows 48-50) for the sound check.
- SSH: `~/.ssh/config` now has a `Host mister` entry using the key the
  MiSTer has (`mister-sinden_ed25519`, `IdentityAgent none`) ahead of the
  1Password `Host *` block, so the tools no longer depend on the agent.
- Keys in Sonic N on the MiSTer: at the SEGA intro, 5 (keyboard 5 through
  Zaparoo) skips to the character select, down moves from Sonic to Tails
  (`build/hardware/k-5a.png`, `k-down.png`), so key presses reach the
  game. The screensaver does not start on the idle screen after 105 s
  (the model's starts at about 40 s and shows the clock); the panel model
  supports the partial and idle modes it uses, so the saver is not being
  started. To see what the firmware says, the STI debug text now goes to
  a DDR3 ring on hardware (`rtl/mister/dbg_sti.sv`, 0x33100000, the
  model's kern.log; `tools/mister_trace.py fetch-sti`); overlay row 36
  carries its byte count in bits 15:1.
- **Boot stalls on the Nokia logo with a save that was warm-reset mid-write.**
  After "Reset and close OSD" right after the first-boot dialogs, every
  start with that save (`build/hardware/cs1-save-after3.bin`) stays on
  the logo with the system mostly idle (PCs in medint.pdd, EUser, the
  kernel idle), with the timing-clean build too; the freshly formatted
  image (`model/.out/fc-base/cs1-base.bin`, on the MiSTer as
  `rh29-460-cs1-fresh.bin`, launcher `NGage-Fresh.mgl`) boots to the
  dialogs in two minutes. So the earlier "warm reset does not come back"
  was the same thing: the state C: was left in. Being checked: the model
  with the same image, and the kernel text of the stalled boot.
- Builds: audio meter (a482fc1) -0.202/-0.257 ns, kernel text (1800aa6)
  -0.276/-0.172 ns at the slow corners (`build/hardware/NGage-audio.rbf`,
  `NGage-sti.rbf`), usable for these checks; the date-trigger build
  (2af9a2f, `NGage-datetrig.rbf`) meets timing. The audio check with the
  stalled save read 0 throughout, which says nothing yet.
- Kernel text on hardware works (`tools/mister_trace.py fetch-sti`): the
  stalled boot's text stops after the Bluetooth driver's first lines (841
  bytes, no NOS traffic), i.e. before Starter and DOS, so the hang is in
  the file-system start (EStart's C: mount); the PCs agree (medint.pdd).
  The model boots the same image through to the screensaver (3.5 KB of
  text), so this is an RTL flash-path divergence on what LFFS does with
  this image. A whole-core Verilator run with it is on the server
  (`~/dev/mister/coreboot/stall1`, `--devlog`).
- Kernel text of a good boot (fresh save, `build/hardware/sti-fresh.txt`)
  matches the model's log line for line, apart from the Bluetooth driver
  retrying its CBUS open a few more times on hardware before the NOS
  traffic starts, through to Startup.app's animation; so the firmware's
  own view of the two can now be compared directly.
- The fresh image stalls too once it has been booted twice, each boot
  ended by a core reload while the firmware was at the Time dialog
  (`build/hardware/cs1-fresh-after2.bin`; 1.4 MB of the C: area changed
  over the two boots, LFFS compacting its log). So the stall needs no warm
  reset: a reload while flash_save is writing dirty blocks back leaves the
  SD file with a mix of old and new blocks (the write-back scans the dirty
  bitmap in address order), which is not a state a power loss can leave a
  log-structured file system in; the model boots such an image anyway, so
  the RTL's C: mount also mishandles it (to be seen in the CS1-write trace).
  Fix planned: write dirty blocks back in the order they were dirtied, so
  an interruption leaves a prefix, as a power loss does on the phone.
- Fix: `flash_save` writes dirty blocks back in the order they were first
  dirtied (queue of 8192, bitmap sweep as the fallback; 54512fa, the save
  bench checks the order). Quartus build running; to verify on hardware:
  boot the fresh image several times with reloads at arbitrary moments,
  then check it still mounts. The images already corrupted
  (`cs1-save-after3.bin`, `cs1-fresh-after2.bin`) stay as test cases for
  the C: mount hang, which the CS1-write trace build is to show.
- **The "stall" is a slow C: recovery, not a hang.** Left alone, the boot
  with the inconsistent save came up after several minutes: the kernel
  text grew from the Bluetooth lines to the full start-up (NOS traffic,
  3.8 KB), the CS1-write trace showed the flash driver issuing command
  sequences in bursts a second or more apart (medint.pdd, interrupts off,
  AA/55/A0 and erases), and the screen then showed the screensaver's
  black frame with its band. LFFS recovers the mixed-up log by rewriting
  and erasing, and a sector erase takes the chip's 0.7 s here (the model's
  takes 20 ms, which is why it boots the same image in seconds). So no
  RTL divergence; the ordered write-back keeps such images from arising,
  and a phone would recover a power-loss image the same slow way.
- The screensaver does start on hardware, after a longer idle than the
  model's 40 s (seen after minutes); fine.
- Ordered write-back on hardware (build of 54512fa, `NGage-order.rbf`,
  -0.114/-0.180 ns at the slow corners with all debug rows): a fresh
  image booted, the core reloaded through the launcher while the firmware
  was running (twice, 100 s apart), and each following boot started up at
  the normal pace (kernel text with NOS traffic and SysAp within 2.5
  minutes), where before one such reload left the next boot in minutes of
  recovery. Saves now survive stopping the core at any moment.
- **Sound on hardware:** with the overlay's audio rows (the largest sample
  magnitude of each channel per frame) the idle screen reads 0 and Sonic
  N's intro reads 60-2076 of 32767, left and right alike (mono), through
  the Eggman cut-scene (`build/hardware/snd-g8.png`): the HLE audio device
  plays on the MiSTer. Listening level and quality not checked by ear.
- State at the end of 2026-10-21: boots, formats, saves (reload-safe),
  card games, keys and sound all verified on the MiSTer with debug builds.
  Next: a release build with `DBG_TRACE` off (timing-clean, no trace
  rings), the Time dialog at every start (the stand-in's RTC status), and
  more games from the collection.
- ALSA left out of the build from now on (`NGage.qsf`:
  `MISTER_DISABLE_ALSA=1`, as the Cray core does). The framework's ALSA
  path mixes the Linux side's audio into the output through a DDR3 read
  channel, a sample FIFO and an SPI slave; the core never uses it (its
  sound drives AUDIO_L/R and reaches HDMI, analog and S/PDIF without it),
  so only Linux-side sounds (Zaparoo's feedback) go quiet while the core
  runs. It frees a little logic and block RAM; it does not touch the
  paths that miss timing (SDRAM data-out registers, the CPU). The release
  seeds already building keep ALSA; every build after them drops it.

### 2026-10-21, late: what to do if no seed meets 104 MHz

Investigated while the release seeds build (seeds 9-12 on the server,
13 on the Mac, all without ALSA; the eight before missed, the nearest
three by under 0.035 ns). Where it stands, from docs/CPU.md and the sweep:

- The CPU alone closes 104 MHz on every seed with 0.20-0.77 ns to spare.
  In the whole core (74% of the ALMs) the seeds land within about ±0.3 ns
  of zero, and the worst paths move between families from seed to seed:
  the CPU's stall and issue paths, the D-cache tag forwarding and fill,
  the CPU's bus registers into upp_bus, plus one hold miss at the -40C
  corner in the SDRAM output stage (seed 1). An earlier netlist passed 2
  of 6 seeds, so passes exist; the netlist changes since (debug taps,
  rtc wait, the ordered write-back, DBG_TRACE off) reshuffled it, and so
  does the build date in build_id.v. Already tried without effect: the
  ALSA and YC macros (about 200 ALMs), Physical Synthesis effort Extra
  (a no-op in Lite), LogicLock regions (licence).
- Options, cheapest first:
  1. Keep sweeping, five at a time (running). A pass is luck, not
     margin: every release needs its own sweep, and a passing RBF is tied
     to its build. Fitter knobs not yet used, cheap to add to the next
     seeds: OPTIMIZE_HOLD_TIMING "ALL PATHS" (if the hold miss is an
     internal path), PLACEMENT_EFFORT_MULTIPLIER 2-4,
     ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM. They move the distribution
     a little and lengthen the fit.
  2. A lower system clock, the fallback that always works. 100 MHz adds
     0.385 ns to the period, more than the whole seed spread; 96 MHz adds
     0.8 ns and every seed so far would have passed. Everything times
     itself from CLK_HZ already (sdram, flash, audio, LCD, holds, the RTC
     wait); only TIMER_DIV = 3 and MMC_DIV = 12 in upp_periph are integer
     dividers and would become phase-accumulator enables so the timers,
     the MMC clock and the audio keep their real rates (one clock of
     jitter, invisible). Cost: the CPU runs 4% (100) or 8% (96) under the
     phone's 104 MHz. ZAP retires more instructions a cycle than the
     ARM9TDMI on most code, so the games would most likely still run at or
     above the phone's speed; the planned cycle accountant (docs/CPU.md)
     would absorb the difference anyway. A day's work with the model and
     benches; the user prefers accuracy, so 100 MHz before 96.
  3. Margin in the design, so passes stop depending on the seed:
     (a) a register slice on the CPU's request into upp_bus (one more
     clock per uncached access and line fill; removes that family);
     (b) the CPU families one at a time, as docs/CPU.md suggests
     (classify in the pre-decoder, the issue stage's shift-operand read
     and interlock, the TLB result into the front end, the D-cache tag
     forwarding), each a focused pipeline change checked on the CPU and
     boot benches; (c) less congestion: HQ2x and the scandoubler out of
     video_mixer (the panel is 176x208 and the scaler upscales it), which
     frees ALMs and M10K but touches timing only indirectly.
  4. Not worth it: 2-way caches (adds a way-select mux to the hit path,
     so worse), dual SDRAM (a second controller with the same paths and
     no analog output), timing exceptions (none of the families is a
     multicycle path).
- Recommendation: let the sweep run; if the five miss, add the three
  fitter knobs to the next five. Prepare option 2 at 100 MHz as the
  release fallback in parallel, and plan 3(a) and 3(b) after the release
  so that later releases do not depend on seed luck.
- The seeds' worst paths (from the release session's per-seed reports at
  the slow 100C corner; the directories of seeds 1-8 were reused, so only
  the endpoints survive; from seed 9 on a full STA report of each
  finished seed is kept in ~/dev/mister/sta/ on the server):
  * Setup, the recurring family (seeds 1, 3, 5, 6, 7, 8): the D-cache
    state machine's state register, the TLB state machine's state
    register or the MMU-enable bit fanning into the pre-decoder's
    micro-op sequencer or the prefetch FIFO's full flag, that is the
    data stall reaching the front end in the same clock. Seed 5's worst
    (-0.685 ns) is 7 logic levels with 9.5 ns of data delay, 5.9 ns of it
    interconnect, and -0.5 ns of clock skew: distance between the D-cache
    and the front end, not logic depth. Seeds 3, 6 and 8 miss by under
    0.035 ns on it.
  * Setup, the others: the D-cache tag RAM's forwarding into the valid
    and dirty bits (seed 2, -0.287); the shifter's operation register
    into the ALU flags (seed 1, -0.226); the bus acknowledge register
    into the CPU's Wishbone merger (seed 2, -0.156); the peripheral bus
    address into the DMA engine's destination register (seed 4, -0.118,
    the only miss outside the CPU).
  * Hold: the SDRAM output stage's internal register into the DQ I/O
    register (seeds 1 and 3, -0.058 to -0.141 ns, worst at the -40C
    corner); the other seeds' hold is fine (+0.18 ns in the scaler).
- What that changes in the options above: the stall-into-the-front-end
  family is the one to attack for structural margin (option 3b), and it
  is placement-dominated, so the fitter knobs (option 1) can move it;
  the SDRAM hold pair is exactly what OPTIMIZE_HOLD_TIMING "ALL PATHS"
  addresses (the default fixes hold only on pin paths and minimum-delay
  paths); the DMA decode miss is a one-register fix outside the CPU. If
  the five seeds now building miss, the next five should carry the hold
  setting, the placement and router knobs, and the DMA register, rather
  than the knobs alone.
- Fitter knobs on from now on (the user's call, 2026-10-21 late, after
  thirteen seeds missed): `OPTIMIZE_HOLD_TIMING "ALL PATHS"` (for the
  SDRAM output register pair), `PLACEMENT_EFFORT_MULTIPLIER 2.0` and
  `ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM`. Builds that had run for
  more than five minutes finish as they were; younger ones restart with
  the knobs. HQ2x is off as well (NGage.sv ties video_mixer's `hq2x` low
  and the OSD's Scandoubler Fx list loses its HQ2x entry; `sl` is now the
  option value itself). sys/ is untouched: the scandoubler's pixels still
  pass through the framework's Hq2x block, whose line buffers stay (the
  core's 15.7 kHz picture needs the scandoubler for VGA), so only the
  blend logic goes, not block RAM.
- DMA decode registered (the user's call, after an Opus 5.5 review of
  upp_dma.sv): seed 4's miss was the peripheral page bit through the DMA
  select and the size check into the DMA's write strobe, and from there
  through the start-register cancel guard into every engine field's
  enable. upp_periph now registers `s_dma && size_ok` and the offset in
  the access's first clock and feeds the DMA block from those; a write
  completes a clock later at the earliest and a read two, so nothing
  changes in when writes land or what reads return. Lint clean; periph,
  upp, intc, timers, mmc and lcd benches pass. The same pattern is there
  for the interrupt controller, the timers and the storage block if they
  show up in a seed.
- Sweep restarted at seed 1 (the user's call): every build in flight
  killed, five builds (four on the server, one on the Mac) from seed 1 on
  the tree with the knobs, HQ2x off and the DMA register.
- Codex CLI (gpt-6-astra, xhigh reasoning, read-only on this checkout)
  consulted on options not in the plan (full answer in
  docs/consults/2026-10-21-codex-timing.md). The ones that hold up, all
  zero-cycle and behaviour-identical, in its order:
  1. Sink-directed duplicates of the D-cache FSM's IDLE bit (and then the
     TLB FSM's IDLE bit and cp15's MMU-enable) for the acknowledge/stall
     cone only, as explicit RTL copies with dont_merge, fed from the same
     next-state as the original. The fitter's own duplicates are not
     sink-directed. Risk: the long route moves to the copy's D input.
  2. The prefetch FIFO's full flag with the late pop at the last gate:
     `full_nxt = !i_clear && !read_ok && (full_ff || (write_ok &&
     almost_full))` with almost_full from the current pointers; today
     read_ok (which carries the data stall) goes through the pointer
     adders and the compare. Provably equivalent; simply ignoring the
     pop would not be (it delays reopening after full).
  3. Registered state-class predicates: the D-cache acknowledges
     unconditionally in five states; register their OR from the next
     state beside the FSM and hand preserved copies to the stall logic,
     so the predecoder sees one flip-flop instead of a state decode.
  4. (Conditional) the Wishbone merger registering both data candidates
     and selecting with the registered state, if a detailed path shows
     the merger's acknowledge-dependent select.
  5. Fitter experiments: auto packed registers off for the CPU instance,
     MUX_RESTRUCTURE off on the predecode cones; global-signal promotion
     of data_stall is low-confidence (insertion delay); a scoped, slightly
     tighter set_max_delay on the stall family to push placement.
  It confirmed what the plan already says: no SDC relaxation is
  legitimate (the ack_q -> merger path is a real next-edge path), and
  none of this is a guarantee on an interconnect-dominated path; judge
  by margin across families over several seeds, not one endpoint.
  Deferred like the rest: these go in only if ten seeds of the current
  tree miss, 2 and 1 first, verified on the CPU bench for cycle
  equivalence.
- Branch `timing-frontend` (e5159ba, worktree ../NGage_MiSTer-timing, not in
  the sweep's tree): Codex's two zero-cycle changes, prepared on the
  user's go-ahead. The prefetch FIFO's full and empty flags take the pop
  (the data stall) at the last gate, with occupancy from the registered
  pointers; the TLB's busy output and the D-cache's acknowledge decode
  their own copies of the state (preserve, dont_merge), the acknowledge
  as a transcription of the FSM's decisions. Each keeps its original form
  as a reference asserted equal in simulation. Verified cycle-identical:
  171 CPU tests with assertions on (the benches run without --assert by
  default, and the flattened arm925t_gen.v drops assertions, so the
  SystemVerilog build was used for that), the flattened build's traces
  identical to master's, the whole-core boot bench to the clock. Not yet
  fitted: a Quartus trial waits for a free build slot. To fold into the
  sweep when the user says so (the ten-seed threshold, or earlier).

### 2026-10-22: release build, NGage_20261022.rbf
- `DBG_TRACE = 0` in NGage.sv: no trace rings, no kernel-text ring, no
  triggers (the `DBG_TRIG_*` logic has no reader and drops out). The two
  `else` generate branches sink the CPU's trace taps and the STI wires so
  the -Wall lint stays clean. The overlay keeps the PC, the status bits,
  the interrupt words, the fault record, the wall clock and the audio
  peaks; its trace, kernel-text and trigger rows read 0. `make lint` and
  `make test` pass (the `top` bench with 516e887).
- Seed sweep 1 (DBG_TRACE off; ALSA in for seeds 1-8, out from 9): 14
  seeds, none clean. Worst setup slack at slow 100C / slow -40C, ns:
  5 -0.685/-0.654, 1 -0.259/-0.119 (hold -0.074/-0.141), 2 -0.287/-0.399,
  3 -0.019/-0.044 (hold -0.058), 4 -0.118/+0.008, 6 -0.033/-0.086,
  7 -0.069/-0.126, 8 -0.017/+0.008, 9 -0.058/-0.006, 10 -0.051/+0.170,
  11 -0.184/+0.160, 12 -0.196/+0.013, 13 (Mac) -0.116, 14 -0.084/-0.007.
  The worst paths are in the entry above. Without the trace: 31,003-31,153
  ALMs, 2,380,517 block memory bits (42 %), 328 M10K (the debug build:
  31,186 ALMs, 3,402,469 bits, 448 M10K). ALSA out freed about 100-240
  ALMs and 700 registers, no memory (30,637-30,914 ALMs).
- Seed sweep 2, from the tree with the fitter knobs (d704f78), HQ2x off
  and the registered DMA decode (335ce98), seeds 1-5 at once (four on the
  server, one on the Mac): **seeds 2 and 5 meet every corner**; 1
  -0.260/-0.191, 3 -0.132/+0.094, 4 -0.061/+0.028 (worst paths now the
  issue stage's stall into its operand registers, the TLB's fault status
  into the Wishbone merger, the Thumb decoder into the BTB). The knobs
  cost nothing visible: the fit took 18-19 min on the server with four
  builds running (17-18 before), 16 min on the Mac; a whole build 22-23
  min.
- **The release is seed 2** (server, Quartus 17.0.2 in Docker, the
  standard `./build.sh remote compile` with `SEED 2` in NGage.qsf):
  setup +0.209 ns at slow 100C and +0.256 at slow -40C; hold +0.142 and
  +0.043 (fast corners +0.128, +0.061); recovery 3.45 ns or more, removal
  0.35 or more. 30,142 ALMs (72 %), 37,077 registers, 2,380,589 block
  memory bits (42 %), 329 M10K, 43 DSP. `releases/NGage_20261022.rbf`
  (md5 02af9d7d4631976e937ba2e885208be7); its BUILD_DATE reads 261021,
  the date the build started. Seed 5 on the Mac (CrossOver) is clean as
  well (+0.232/+0.175, hold +0.058 at worst, 30,206 ALMs) and is kept as
  a spare in the session's scratch area only. A pass is still seed luck
  (2 of 5): every later release needs its own sweep until the front-end
  margin work lands.
- On the MiSTer (`/media/fat/_Console/NGage_20261022.rbf`,
  `NGage-SonicN.mgl`): boot from the save to the N-Gage splash and the
  Time and Date dialogs by 150 s, the movistar idle screen after OK, OK;
  no fault record, clock valid, trace rows 0. Menu, three rows down to
  SonicN, OK: SEGA logo, the title wipe, 5 skips to the Eggman cut-scene
  with audio peaks 796-1124 of 32767 on both channels; the game's PCs are
  in RAM (0xFFEECBE8); a second 5 reaches the title menu, where the
  rocker moves the highlight. Keys through Zaparoo's macro reach the
  game about one press in three (three downs in one macro move one
  row; the S60 shell catches every press): the game polls the key
  state per frame and the macro's pulse is short, so retries are
  needed in scripted key tests, same as with the debug builds.
  Screenshots in `build/hardware/rel/`.
- README: the setup step points at `releases/`; the status names the
  release.

### 2026-10-22: per-second counters for the speed question

- The accuracy assessment (build/accuracy-assessment-draft.md, an Opus
  5.5 draft on the user's request) found that nobody has measured the
  core's speed against the phone and that the evidence (ZAP's load-use
  interlock, the kernel's 1.56-2.12 cycles an instruction, the 150 s boot
  from a save against the model's under 30 guest seconds, the Bluetooth
  driver's extra retries) points to a slower core, not the faster one the
  timing-fidelity plan assumed. So: measure first. The user has no real
  N-Gage QD; the references left are the firmware's memory-controller
  and flash constants (the phone's wait states), TI's ARM925T TRM for the
  cycle costs, and videos at best as a coarse check.
- `rtl/mister/dbg_counters.sv`: eight 32-bit counters latched once a
  second (dbg_tick, the second's last clock of the overlay's wall clock)
  on overlay rows y = 56..84: LCD frames (a RAMWR starting at page 0;
  lcd_panel's new frame_ev) and pixels written (pix_ev), instructions
  retired (the writeback taps that the trace used), clocks in
  wait-for-interrupt (cp15's WFI state, brought out as o_wfi through
  zap_core, zap_top and arm925t as dbg_wfi), clocks a CPU bus beat waited
  on the SDRAM (0x0A window), the flash (CS0-CS3) or elsewhere, and beats
  answered. `tools/mister_dbg.py` prints them (frames, px, M instr, idle
  %, bus wait % by target, beats). Lint clean; the whole-core boot bench
  identical to the clock (64,059,964). Not gated by DBG_TRACE: a few
  hundred ALMs, present in release builds too (the overlay is off unless
  the OSD switches it on).
- Zaparoo (the user's question): its captures read the scaler buffer in
  DDR3, where the flash images live and system code runs in place, so a
  capture is a brief hit on flash waits, not a steady slowdown; the flash
  wait row will show it. The injection path does not touch the core's
  memory.
- **First boot profile on hardware** (counters build NGageDbg, Alien Front
  launcher, captures every 2.5 s; times from the load on the MiSTer's
  clock, the CPU starts about 20 s later once the images are in):
  * 35-58 s: 10 M instructions/s, 10 cycles an instruction, 45-50 % of
    the clocks waiting on the bus (SDRAM 21 %, flash 25 %), 5 M bus beats/s:
    one beat per two instructions, the uncached bootstrap.
  * 60-108 s: 21.1 M instructions/s, 4.9 cycles an instruction, no bus
    traffic to speak of (65 K beats/s): a compute loop of 48 s with the
    pipeline stalling on its own. What it is, the trace will say.
  * 110-203 s: 8 M instructions/s, 12.5 cycles an instruction, 55 % of the
    clocks waiting (SDRAM 23 %, flash 32 %), 6 M beats/s: one beat per
    1.4 instructions for 93 s, with the kernel supposedly running cached.
  * 206 s on (the Time dialog): 11.56 M instructions/s, 9.0 cycles each,
    zero bus beats, idle 0 %: the idle thread spins instead of sleeping
    (WFI returns at once, or the firmware's idle does not use it), so the
    idle row cannot be trusted and this signature is "idle".
  * About 2 G instructions to the dialog, which matches the model's
    sub-30-second boot at 62.5 MIPS: the firmware does the same work, the
    core does it at 8-21 M instructions/s. Against the phone's 20-30 s
    boot the core is 6-8x slower, far beyond the assessment's estimate.
  Zaparoo is out of the measurement path: tools/mister_input.py (a uinput
  keyboard on the board, Main's own screenshot through its command pipe,
  native 176x208, a quarter second) replaces it; tools/boot_profile.py
  records a boot's counters, tools/jev_profile.py prints a run's timeline.
  Next: a trace build with time triggers (55 s and 130 s after the CPU
  start) to see the code of the compute phase and the memory-bound phase.
- **Trace of the slow phases** (trace build NGageTrc with time triggers 55
  and 130 s after the CPU start; dumps in build/hardware/trace/,
  tools/trace_hist.py):
  * The 48-second "compute" phase is the idle thread. It loops in
    ekern.exe at 0x5032bb58: call the variant's service 13 through the
    stand-in (0x5149e5e8, nine instructions, returns at once), test a
    flag, repeat; 25 instructions an iteration at 4.9 cycles each, no
    memory traffic, never a WFI. The same loop runs at the Time dialog:
    the "21 M instructions/s, 4.9 CPI, no beats" signature means idle,
    and the WFI counter is useless until the stand-in's idle service
    actually sleeps. What the boot waits 48 s for is not yet named; the
    kernel text shows the Bluetooth stack timing out on CBUS (KErrTimedOut
    -33, several retries).
  * The 93-second kernel phase is system-call traffic between EFile.exe
    (user Thumb), EUser.dll and ekern.exe: 25 SWIs per 1000 instructions,
    and 83 % of the clocks in stalls of 30 clocks or more. The bus ring
    shows what they are: a two-level page-table walk every 78 clocks, the
    same two translations over and over: the exception-vector page at
    virtual 0 (L1 at 0x0A074000 -> coarse table 0x0A073800 -> ROM page
    0x31B000) and the kernel's code pages at 0x50320000-0x50323000 (L1
    0x0A07540C -> coarse table 0x0A078400 -> entries at 0x0A078480). The
    small-page TLBs are 16 entries direct-mapped, indexed by VA[15:12]:
    virtual 0 and 0x50320000 share slot 0 and evict each other on every
    exception; the 4-entry section TLBs index by VA[21:20]. Nearly all of
    the phase's 2.9 M SDRAM reads a second are these walks (the three
    hottest lines are 134 of 800 beats), about 35 clocks each.
  * The flash reads of the phase (39 % of beats, 512 of 999, 73 distinct
    lines) are I-cache refills of the same kernel lines: the vectors page
    (VA 0) and the kernel code at 0x50320000 also share I-cache indices
    (VA[13:4]), so each exception evicts the kernel's first lines.
  * CP15: 20 of every 1000 instructions are `mcr p15, c7, c14, 2` (clean
    and invalidate a D-cache line by index: the kernel's flush loop) and
    cost about 38 clocks each, because the core drains and refetches the
    pipeline for every CP15 operation; the real part does these in a
    cycle or two. Three DACR writes (c3) in the same window.
  * The SWI path itself: entry about 68 clocks, the dispatcher's
    `msr CPSR` mode switches (31 in the window), the two walks above,
    and the 12-cycle mispredict on returns.
  So the slow boot is not the memory's speed and not the caches as such:
  it is the TLBs' organisation (small, direct-mapped, low bits as index)
  meeting a kernel that takes an exception every 40 instructions, plus
  the drain on every CP15 operation. Both are inside the CPU and
  specific.
- **Two independent plans for the speed** (the user's rule: mine first,
  then Codex from the facts alone; both under docs/consults/). They
  agree on the order of the first two items: (1) take the small-page
  TLB conflicts away (Codex: 64 entries indexed by VA[17:12] as the
  cheap experiment, then a victim TLB rather than associativity on the
  critical path; mine: 256 entries in M10K indexed by VA[19:12], and 64
  section entries); (2) CP15 maintenance without the universal drain
  and refetch (Codex points at zap_core.sv:591, zap_predecode_main.sv:625,
  zap_cache_tag_ram.sv:429; c7,c14,2 is D-only). Both put the 48-second
  wait outside the CPU: a startup service waiting out a timeout, the
  Bluetooth/CBUS link the leading suspect; a WFI in the stand-in's idle
  service ends the spinning, not the wait. Codex adds: the I-cache
  refetches need their eviction cause measured before a 2-way cache is
  built (a TLB miss does not invalidate a VIVT cache); the bridge already
  posts SDRAM writes (upp_bus.sv:451), so a CPU write buffer is worth
  6 % at most; MOV PC, LR's return pattern matches Rm = 15 instead of 14
  (zap_predecode_main.sv:504), a free fix; and the trace rings cover
  different windows, so the walk arithmetic and the flash share must not
  be added across them. It also asks for the kernel's tick rate to be
  verified, since every firmware timeout scales with it. Mine adds the
  timestamped kernel text to name what the 48 s waits for.
- **TLBs enlarged** (rtl/cpu/zap/zap_top.sv, both sides): small pages 16
  -> 256 entries (index VA[19:12]), sections 4 -> 64 (VA[25:20]), large
  pages 8 -> 32, tiny pages 32 -> 64. The TLBs are RAM blocks with a
  valid vector and the entry widths and tag compares derive from the
  counts, so it is the parameters only. 171 CPU tests pass (the MMU tests
  among them), the whole-core boot bench is identical to the clock (its
  window is the uncached bootstrap, so no change expected there), lint
  clean. Trace build with it: -0.150 ns at the slow 100C corner, +0.070
  at -40C (a measurement build). Hardware boot profile to follow.
- **The 48-second wait was a format of C: at every boot** (an Opus 5.5
  subagent in the model, with guest-time stamps it added to the model's
  logs: `log-time=on` in args.sh, kern.log/cbus.log lines prefixed with
  the guest second, erases in qemu.log, and `pc-sample=FILE` sampling the
  PC every guest millisecond). EStart asks HelperDrv's "auxstart" at
  every boot, up to seven times, not only when C: fails to mount; the
  stand-in answered 105 every time, so every boot erased all 71 sectors
  of C: (0.7 s each on the core = 50 s with the CPU idle; 20 ms each in
  the model, which is why it boots in 24 guest seconds). The Bluetooth
  stack's ten CBUS timeouts (1.5 s each) overlap it and gate nothing.
  Fix: the stand-in answers 105 only while C: is blank. Neither it nor the
  firmware can read the C: area at that point, so the core keeps the C:
  area's first word in a register as the loader and the chip write it
  (ddram_flash.sv) and exposes "erased" at HLE 0x0C1F0104 bit 0
  (upp_periph beside the date register); the model answers the same from
  its flash array. Model: a blank image formats once (142 erase lines), a
  formatted one never. Hardware (enlarged-TLB build, formatted save, the
  old RTL reads the register as 0 = formatted): no idle phase at all, the
  kernel phase runs 28-105 s and the Time dialog is up at about 110 s
  after the load, against 175-200 s before. The Time dialog still comes
  on this boot (the save had been formatted by the previous boot); a
  second boot from the written-back save will say whether it stays.
- With the enlarged TLBs (trace at 130 s after the CPU start): the
  vectors-page walk is one every 545 clocks instead of 78, the rest after
  the kernel's own TLB flushes; SDRAM waits in the kernel phase 23 % ->
  10-13 %, instructions/s 8.3 M -> 9.6 M. The flash is now 71 % of bus
  beats: I-cache line fills, with the user library (EUser at 0x503A1xxx)
  and the kernel (0x50321xxx) colliding at the same I-cache index (VA
  bits 13:4) on every system call.
- Second boot from the save the no-format boot wrote back: the Time dialog
  still comes (the firmware asks for the time at every start for a reason
  other than the format; the stand-in's RTC status stays the open item
  the README names). The boot itself again reached its end state about
  105 s after the load.
- Flash read cache 8 KB -> 128 KB (rtl/mem/ddram_flash.sv LINES_LOG2 12,
  in M10K; 224 blocks were free): a conflict miss in the direct-mapped
  I-cache then costs a few clocks instead of a DDR3 burst. The cache is
  also no longer emptied by the trace's and the kernel-text ring's writes,
  which share the loader port but go elsewhere in DDR3 (only writes into
  the flash images empty it): a debug-build artefact before.
- **The blank-C: register verified on hardware** (build with it, launcher
  on a copy of the pristine cs1.bin): the first boot formats (the idle
  stretch of erases at 25-85 s, the kernel phase after, the dialog at
  about 170 s), the second boot from the written-back save does not and
  reaches the dialog at about 105 s. A fresh image now formats exactly
  once, as a phone would.
- Flash cache at 128 KB: the trace rings (about 130 M10K) and the cache
  do not fit together, so measurement builds with it run without the
  rings (DBG_TRACE 0; the counters stay). Two fixes found by the cache's
  bench on the way: a reset of more than one clock made the cache sweep
  its tags twice, and the sweep of 4096 tags needs the bench's patience
  raised (a per-line invalidation on loader writes was tried, lost a
  write to DDR3 in the bench, and was taken out again: the sweep stays,
  and only writes into the images trigger it).
- Timing of the 128 KB-cache measurement build (one seed, counters, no
  rings): setup -0.470 ns at the slow 100C corner, the worst path the bus
  arbiter's grant into the CPU's Wishbone merger and the D-cache into the
  merger (the known family, this netlist's placement); hold -0.037 to
  -0.146 ns at every corner, all the SDRAM output pair p_dq_o ->
  sdram_dq_o again, which OPTIMIZE_HOLD_TIMING "ALL PATHS" did not cure.
  Fine for measuring at room temperature; a release needs that pair fixed
  structurally (the core register feeding the I/O register sees a
  different clock arrival; a deliberate delay or a dedicated clock phase
  for the output registers), not by seed luck.
- **128 KB flash cache on hardware** (formatted save, no format): the
  kernel phase's flash waits 36-40 % -> 29-34 % of the clocks, 10.0 -> 10.6
  M instructions/s, the boot's end about 98 s after the load against
  100-105. Less than the cache's hit rate would suggest, because a line
  fill from the flash model costs about 24 clocks even on a DDR3-cache
  hit: the chip port serves one 16-bit halfword at a time, two clocks
  each, and a 16-byte line is eight of them, against 15 clocks for an
  SDRAM line. So the conflict-miss rate is the lever (the 2-way I-cache),
  and a line path through the flash model the second one.
- **Two-way caches: the two plans** (mine first, Codex from the facts;
  both under docs/consults/). Same shape: two half-depth tag and data
  banks per cache read together (I: 512 sets x 2, index VA[12:4], tag
  VA[31:13]; D: 256 x 2, VA[11:4]), hit = either way's valid tag match,
  the word picked per bank before one 2:1 mux, the victim chosen outside
  the acknowledge path, (set, way) maintenance from bits 4 and 31 with
  TI's C bit selecting one way or both, the I-cache first and the D-cache
  after with its dirty victims, forwarding and the background-load lock
  made way-aware. Codex corrects my replacement policy: the TI925T uses
  fixed LRU (TI SPRU671, sections 3.1 and 4.1), the control register's
  bit 14 reads zero, so one LRU bit per set, updated on accepted hits and
  fills. It names the riskiest part (the D-cache's transaction identity
  across retimed completion, forwarding and replay) and the timing
  question (try the I-cache at today's latency; budget an extra
  registered stage for the D-cache, with the cycle costs it lists), and
  puts the gain at about 10.6 -> 13 M instructions/s on the kernel phase
  as a hypothesis, with a 1.45x ceiling from the flash waits alone. Its
  cheapest experiment is an I-index XOR with VA bit 19; two-way is the
  cleaner destination, and the user chose it for the part's geometry.
  Also noted for later fidelity: TI specifies no store-miss allocation
  and cache contents preserved across a cache disable, both unlike ZAP.

### 2026-10-22: the two-way instruction cache

- **The I-cache is 2-way set-associative with the TI925T's LRU**
  (rtl/cpu/zap/zap_cache_tag_ram.sv, parameter WAYS; the D-cache stays
  at one way for now). Each way is a tag RAM and a data RAM of 512 lines,
  both read at the set VA[12:4] of the next fetch, as the single RAM was.
  The tag compares moved from the cache FSM into the tag RAM (one per way,
  o_cache_hit), which also names the way of interest (o_cache_way: the
  way that hits, else the way a fill takes: an invalid way first, else
  the set's LRU bit) and presents that way's tag, line, valid and dirty
  bits, so the FSM still sees one line and its states are unchanged. The
  FSM buffers the way with the address across a fill and returns it with
  the tag write (i_cache_way). One LRU bit per set, the way to fill next:
  after a hit or a fill, the other way; cleared with the valid bits. Both
  updates are written a cycle behind through pending registers (as the
  valid bits' tag writes are), and the bit is read with the set and
  pipelined three deep with the updates in flight forwarded, like the
  valid bits, so the victim is one level of logic at the output. The
  whole-cache clean walks the lines of both ways ({way, set} as the dirty
  vector's index); a line operation by VA finds the way holding the tag,
  one by index takes a way input (the D-side's CP15 will drive it when
  the D-cache goes 2-way). Hit latency as before: the ways' data are
  muxed by the hit after the compares, no extra cycle.
- Macros: ZAP_VA__CACHE_INDEX/TAG and ZAP_CACHE_TAG__* now count the
  lines of one way (CACHE_SIZE/WAYS), so every module using them carries
  a WAYS parameter (default 1 = upstream ZAP); zap_top has
  CODE/DATA_CACHE_WAYS, arm925t.sv ICACHE_WAYS = 2, DCACHE_WAYS = 1, the
  bench's tb_cpu passes them through (`VEXTRA=-GICACHE_WAYS=1` builds a
  direct-mapped model for comparison).
- Verification: the new sim/cpu/tests/icache_rtl.S runs three code
  lines of one set in turn and rewrites them in memory behind the cache;
  which still returns its old code shows the two ways and the LRU choice
  (order of use, not of filling). It fails on the direct-mapped build at
  the "A still cached after B" check and passes on the 2-way one. The
  whole suite: 174 runs on the SystemVerilog sources and 174 on the
  generated netlist, 49 tests matching QEMU instruction by instruction.
  Cycle counts of the directed tests are identical between one and two
  ways (their code fits a way), as intended: only conflict misses differ.
  The firmware boot bench on the server (`make -C sim/cpu boot`, 2.7 G
  cycles of the real boot at zero bus latency): register, CBUS and all
  76,975 device accesses agree with the reference model, and the
  register and CBUS logs are identical to the direct-mapped run's;
  660.6 M instructions retired against 651.1 M in the same cycles (+1.5
  %: a miss costs little in the bench, the hardware numbers are below).
- Two things the netlist taught. Verilator 5.032 (the build server's)
  rejects a function call in the index of a nonblocking assignment's
  left side ("Multiple Write refs on LHS of NBA"); 5.052 on the Mac took
  it. And a variable index into a packed array whose element width is not
  a power of two (tag_q[sel], 47 bits) becomes `sel * 47` in sv2v's
  output, which Quartus mapped onto a DSP block: the first CPU trial had
  every worst path ending at that DSP's input register, -1.167 ns at 104
  MHz, with physical synthesis retiming the fetch PC register into the
  tag RAM through the 512:1 LRU read mux that sat on the same path. Both
  fixed structurally: explicit 2:1 muxes, and the LRU read pipelined.
- **CPU-only Quartus trial** (sim/cpu/quartus/run.sh, seed 1, 104 MHz) after
  the fixes: setup slack **+0.479 ns** at the slow 100C corner, +0.433 at
  slow -40C (the direct-mapped CPU's last trial: +0.112), the worst path
  now the D-cache's RAM forwarding. 14,483 ALMs (direct-mapped: 14,014),
  16,539 registers, 59 M10K, 4 DSP. Before the fixes: -1.167 ns, 14,751
  ALMs, 6 DSP.
- **Whole-core measurement build** (counters, no trace rings, the 128 KB
  flash cache, seed 2 with the fitter knobs): 32,538 ALMs (78 %), 40,233
  registers, 454 M10K (the 128 KB-cache build: 452; the split into two
  half-depth banks cost almost nothing), 43 DSP. Setup -0.098 ns at the
  slow 100C corner and -0.166 at slow -40C: the issue stage's stall into
  the memory source value, the fetch PC into the bus merger (the known
  CPU family) and one D-cache forwarding path at -0.014; hold +0.246 at
  the worst corner, the SDRAM output pair not in the top ten this time.
  Measured with at room temperature as the earlier builds were; a release
  needs a seed sweep. Kept as build/hardware/NGage-icache2.rbf and
  deployed as the debug core (_Console/_NGage/_Debug/NGageDbg_20261022.rbf).
- **On hardware** (tools/boot_profile.py, Alien Front launcher on the
  formatted save, the two builds back to back at a 2 s period; the
  10 s-period runs could not place the phase ends, and two 10 s runs of
  one build had agreed to 0.2 s, so the 2 s runs are the comparison):
  the 128 KB-cache build's kernel phase runs from 31 to about 95 s after
  the load, then a lighter tail to 106 s; the two-way build's from 30 to
  about 90 s, tail to 100 s. **The boot is 6 s shorter, 76 -> 70 s from
  the first to the last second of bus traffic.** Kernel phase: 11.5 ->
  12.6 M instructions/s, flash waits 31.0 -> 25.0 % of the clocks, SDRAM
  waits 12.5 -> 13.4 %, bus beats 205 -> 178 M over the boot (fewer
  refills), cycles an instruction 9.3 -> 8.4. Taking the waits out, the
  kernel code still costs about 5.2 clocks an instruction of pure
  pipeline: the CP15 drains, exception entries, mispredicts and load-use
  interlocks are now the larger part of the kernel phase, the flash's
  24-clock line fills the next (a quarter of the clocks), the D-cache's
  SDRAM misses after that. Profiles under build/hardware/boot/fcache-p2
  and icache2-p2.

### 2026-10-22: the two-way data cache

- **The D-cache is 2-way with LRU too** (rtl/cpu/arm925t.sv DCACHE_WAYS =
  2): the same tag RAM, 256 sets of VA[11:4] with 20-bit tags, a dirty bit
  per way, the victim's line and tag presented on a miss so that the
  D-FSM's clean-then-fill sequence writes the dirty victim back and fills
  its way, unchanged in its states. The FSM's only lookup-way write is
  the write hit in IDLE (the hit-under-miss macro is a no-op in this
  core), every other tag or line write uses the way buffered with the
  address; the clean's tag rewrite marks the way most recently used, but
  the fill into the same way follows at once, so the LRU bit ends where
  the fill leaves it. The CP15's index operand (TI format: set in bits
  11:4, way in bit 31) now names a way on a new output (zap_cp15_cb
  DATA_CACHE_WAYS, o_dcache_line_way through zap_core and zap_top into
  zap_dcache's i_line_way); with one way the way bit still selects one
  of the two lines that stood in for a set, as before. TI configuration
  C clear still runs the operation on both ways.
- Verification: sim/cpu/tests/dcache_rtl.S dirties three lines of one
  set in turn and reads memory back through an uncached alias: what was
  written back shows the two ways and the LRU victim (order of use, not
  of filling), then the index operations with C = 1 clean or flush the
  named way only, C = 0 both, and the whole-cache clean covers both
  ways. It fails on a direct-mapped D-cache (`VEXTRA=-GDCACHE_WAYS=1`)
  at the first "not written back" check. cache_rtl.S's way test holds as
  written (the line it flushes by index sits in way 0, allocated into a
  set the previous step had emptied); its stale comment is fixed. The
  set it uses, 0xE0, is one nothing else in the test touches: the
  checkpoints' signature pointer lives in set 0, which is why the first
  draft of the test, on set 0, could not have tracked the LRU.
- Suites: 177 runs on the sources and 177 on the netlist (the new test's
  three), 49 matching QEMU. The firmware boot bench on the server:
  register, CBUS and all 76,975 device accesses agree with the model,
  the logs identical to the I-cache-only run's; 661.5 M instructions in
  2.7 G cycles (660.6 M with the I-cache alone, 651.1 M before). That
  run took the netlist before the victim-select trim below; the run on
  the final netlist agrees with the model the same way, with logs and
  the instruction count identical to the first.
  CPU-only Quartus trials at 104 MHz: seed 1
  +0.041 ns at slow 100C and -0.082 at slow -40C, the worst paths way
  1's tag RAM through the compare; seed 2 of the same netlist +0.598 and
  +0.776, so the near miss was placement (the I-cache-only trial, seed
  1, had +0.479). 15,756 ALMs, 17,972 registers, 76 M10K (the D-cache's
  split into two banks of 256 lines costs 17 M10K: a byte lane of 256 x
  8 fills a quarter of a block), 4 DSP.
- One structural trim on top: the FSM's miss decision read the way of
  interest's valid and dirty bits, selected by the hit, with the tag
  compares in front of it; the victim is known from the valid bits and
  the LRU bit alone, so the tag, valid and dirty outputs are now the
  victim's (registers and one mux), the line stays the way of
  interest's, the hit way's dirty bit goes out on its own for the
  write-through hit, and both FSMs treat a hit as a hit whatever the
  valid bit says. Same cycles on every test, suites and QEMU as above.
  Its trial at seed 1: **+0.362 ns** at slow 100C, +0.444 at slow -40C
  (the same seed had +0.041 and -0.082 before the trim), the worst path
  now the D-cache's tag RAM forwarding into its FSM state; 15,608 ALMs,
  17,696 registers.
- **Whole-core measurement build** (counters, no rings, the 128 KB flash
  cache, both caches 2-way, seed 2 with the knobs): 33,361 ALMs (80 %),
  41,437 registers, 471 M10K (85 %; the I-cache build had 454), 43 DSP.
  Setup -0.170 ns at slow 100C and -0.129 at slow -40C, the top paths the
  debug overlay's scan line into the video output and the D-TLB's fault
  status into the data RAM's write, then the D-cache's tag forwarding;
  hold positive at every corner. Kept as build/hardware/NGage-dcache2.rbf
  and deployed as the debug core.
- **On hardware** (the same 2 s-period Alien Front boot as this morning's
  A/B, build/hardware/boot/dcache2-p2): the kernel phase runs from 30 to
  about 87 s after the load, the lighter tail to 96 s. **The boot is
  another 4 s shorter: 76 s before either cache, 70 s with the two-way
  I-cache, 66 s with both** (first to last second of bus traffic).
  Kernel phase: 13.0 M instructions/s (12.6 with the I-cache alone, 11.5
  before), flash waits 24.9 % (unchanged: those are the I-side's line
  fills), SDRAM waits 12.5 % (13.4), bus beats over the boot 157 M (178,
  205), cycles an instruction 8.1 (8.4, 9.3). The geometry work is done;
  what remains of the kernel phase is about 5 clocks an instruction of
  pipeline (CP15 drains, exception entries, mispredicts, interlocks) and
  a quarter of the clocks in the flash's 24-clock line fills.

### 2026-10-22: seed sweep 3, for a release with the two-way caches

- Sweep 3 from the tree at 8bcf36d (both caches 2-way, the 128 KB flash
  cache, the counters, no rings; seed 2 was the measurement build above
  at -0.170/-0.129): seeds 1, 3, 4, 5 on the server through
  tools/quartus_seeds.sh with `LANES=4` (the script now takes the lane
  count; it was fixed at two), seed 6 on the Mac from a detached
  worktree (../NGage_MiSTer-sweep).
- The overlay's render path was the measurement build's worst setup
  path (video_out's scan line into the pixel registers, -0.170): the 19-way
  row mux into the 32:1 bit select into the RGB mux, all in one clock.
  The row select and the word are now registered once (NGage.sv
  dbg_*_q); scan_x and scan_y hold for the 16 clocks of a pixel (video_out
  CE_DIV), so nothing changes on the screen. `make lint`, the video bench
  and the top bench pass. Later seeds carry it; the first five do not.
- Round 1 (seeds 1, 3, 4, 5 on the server, 6 on the Mac), worst setup at
  slow 100C / slow -40C, ns: 1 -0.346/-0.632, 3 -0.651/-0.602, 4
  -0.383/-0.232, 5 -0.401/-0.361, 6 (Mac) -0.478; hold +0.09 or better
  everywhere. With seed 2's -0.170/-0.129 that is six of six short by
  0.2-0.65 ns: not seed luck. The paths, across seeds: the D-cache's tag
  RAM output through the compare into the data RAM lanes' write enables
  (a store hit writes the line in the cycle the compare decides it) and
  into the valid, dirty and LRU forwarding chains; the D-FSM's state into
  the Wishbone merger's address; the self-test enable into the bus
  acknowledge; the overlay (seed 1, fixed above); predecode into decode.
- Two structural trims on the D-cache, both cycle-exact (every suite
  test's cycle count unchanged; 177 runs on the sources and on the
  netlist, 49 matching QEMU): (1) the valid, dirty and LRU chains take
  the live tag write only into their output stage (the lookup two behind
  the writer, which is at the output in the cycle after the write) and
  the pending, registered write into every stage; upstream forwarded the
  live enable, a function of the compare, into all three. A first draft
  with no live forwarding at all cost cycles: the lookup at the output
  the cycle after a fill saw a stale valid bit and the I-cache refetched
  a line it had. (2) A store's line and tag write is presented by the
  D-FSM whatever the compare says, and the tag RAM gates each way's
  write enables with that way's own compare while the FSM is idle (a
  store hit: the way that hits, none on a miss), the buffered way
  otherwise (fills, cleans, write-through updates). The lane enables are
  then one level past the compares instead of four (through the hit OR,
  the FSM's case, its way mux and the way compare).
  CPU-only trial of the trimmed netlist at seed 1: **+0.537 ns** at slow
  100C, +0.462 at slow -40C (the same seed: +0.041/-0.082 with the first
  two-way D-cache, +0.362/+0.444 after the victim select), the worst
  path now the load data itself, the tag RAM through the line mux into
  the memory stage; 15,389 ALMs, 17,539 registers, 76 M10K.
  The firmware boot bench on it: register, CBUS and all 76,975 device
  accesses agree with the model, logs and the instruction count
  (661,484,885 in 2.7 G cycles) identical to the untrimmed runs.
- Round 2 (seeds 7-10 on the server, from the overlay-fix tree 5ee8e16,
  before the D-cache trims; 11 on the Mac the same): 7 -0.289/-0.402, **8
  +0.047/+0.131, hold +0.142 and +0.246 at the slow corners, +0.106 and
  +0.132 at the fast: every corner met**, 9 -0.404/-0.599, 10
  -0.180/-0.244, 11 (Mac) -0.317. Seed 8: 33,037 ALMs (79 %), 41,534
  registers, 471 M10K, 43 DSP; its worst paths the D-TLB's walk state
  into the Wishbone merger's address (+0.047) and the D-cache's bus
  select into its data RAM (+0.054). The bitstream, md5
  f5e2391cef5c5a3747fcfcf8df1fc31a, is build/hardware/sweep3/NGage-s8.rbf
  with its reports beside it; it is the release candidate (one of twelve
  seeds, so still seed luck, with 0.05 ns to spare at slow 100C). Round
  3 (seeds 13-15) runs from the trimmed tree f48999c for a candidate
  with margin, and seed 12 on the Mac.
- Seed 8 on the MiSTer (as the debug core, the same 2 s boot profile):
  kernel phase 30-86 s at 13.1 M instructions/s, flash waits 24.8 %,
  SDRAM 12.6 %, the boot's bus traffic 30-96 s, the idle screen after:
  the same as the measurement build (build/hardware/boot/seed8-p2).
- Round 3, the trimmed tree f48999c (seeds 13-15 on the server, 12 on the
  Mac): 13 -0.052/-0.178, 14 -0.137/-0.326, 15 -0.277/-0.093, 12 (Mac)
  -0.108, 16 (Mac) -0.190;
  hold +0.08 or better everywhere. The store-write family is gone from
  the top of every report; what is left is the inherent two-way data
  path (the D-cache's tag RAM through the line mux into the memory
  stage, the I-cache's into the fetch stage, -0.05 to -0.14), the issue
  stall, the D-FSM's state into predecode and the merger. Still seed
  luck, now within 0.1-0.3 ns. The user asked for the sweep to restart
  once video_freak (aspect ratio, crop, scale; its own session) is in,
  so no further seeds of this tree.

### 2026-10-22: the framework's video options (video_freak)
- `sys/video_freak` sits between the mixer's DE and the framework's
  `VGA_DE` and drives `VIDEO_ARX`/`VIDEO_ARY`, as the NES and SNES cores
  wire it (NGage.sv, the end of the video section). The OSD gains
  "Vertical Crop" (status 9: Disabled, 180p(6x)), "Crop Offset" (13:10,
  0..10 and -12..-2 lines, the encoding every core uses) and "Scale"
  (15:14: Normal, V-Integer, Narrower HV-Integer, Wider HV-Integer);
  "Aspect ratio" stays at 122:121 and now hands video_freak the panel's
  own size, 176:208 upright and 208:176 turned (the scaler saw 11:13
  before, the same ratio). The crop cuts the upright 208 lines to 180,
  the 6x integer fit of 1080p (1056x1080 at the original ratio); it is
  offered only at 1920x1080 with the scandoubler off and the picture
  upright (turned, 176 lines are 6x already), greyed out otherwise through
  `status_menumask` bit 0. The NES and SNES offer theirs at 1920x1080
  only; a first build gated the same way had the entry greyed out on the
  MiSTer: `HDMI_HEIGHT` is not the display's height but the one Main lets
  the scaler fill (`UIO_SETHEIGHT` in Main's video.cpp), which under
  MiSTer.ini's `vscale_mode` 1-3 is the integer-scaled picture height,
  1040 for 208 lines at 1080p (the user's ini has vscale_mode=1), so the
  gate is the frame alone. The offset moves the 180-line window by that
  many lines from the centre (14 cut at each end); the offset labels are
  the lines they give (the NES and SNES labels say 8,10,12 for 6,8,10).
- The top bench runs the real video_freak (and sys/math's multiplier and
  divider) and checks it: the aspect pair 176/208 and 208/176 turned,
  [ARC2] as 2:0, V-Integer at 1080p as 880x1040 (bit 12 set), the crop
  as 176x180 frames carrying picture lines 14-193 and 24-203 with offset
  +10 (with Main's 1040 as the HDMI height), the cropped ratio 2288:2340
  (176*208 : 208*180 normalised), and a whole 208x176 frame turned with
  the crop set. `make lint` (the status
  waiver now spares bits 16-120) and the video bench pass.
- Quartus (seed 2, the committed qsf, the overlay's register stage in),
  the build with the frame-only gate: 33,795 ALMs (81 %), 42,371
  registers, 3,429,401 bits, 471 M10K, 43 DSP (seed 8's debug build:
  33,037 ALMs, 41,534 registers); setup -0.362 ns at slow 100C, -0.196 at
  slow -40C, hold +0.246/+0.150, the fast corners' hold +0.133/+0.086:
  the issue stall into the ALU source value, decode's shift source into
  the issue stall, the UPP DMA ownership into the on-chip RAM's write
  enable, the seed-luck family of sweep 3; nothing of video_freak in the
  30 worst paths (its multiplier and divider are serial; the framework's
  own sys_udiv is the second hold path, +0.248). The 1080-gated build
  before it: 33,359 ALMs, -0.469/-0.600, the I-cache's valid bits into
  the writeback PC. The bitstream is the debug core on the MiSTer,
  `_Console/_NGage/_Debug/NGageDbg_20261022.rbf` (md5 ace1d31e; the
  seed-8 one it replaced is kept at
  `/media/fat/NGageDbg_20261022.rbf.before-video_freak.bak`).
- On the MiSTer (NGageDbg-sonicn.mgl, the firmware at its Time dialog by
  170 s): Main's native screenshot, the scaler's input, is 176x208; with
  Vertical Crop set through the OSD (tools/mister_input.py: F12, seven
  downs, Enter) it is 176x180, the centre of the picture, and 176x180
  moved down ten lines with Crop Offset +10 (the OK softkey whole, more
  of the logo area gone). The OSD cursor does not skip greyed entries
  (Main's menu counts them), so the same key sequences reach the entries
  whether or not the crop is offered. The aspect ratio, the scaling and
  the crop's look on the TV are for the user to confirm: the native
  capture stops before the scaler (a Zaparoo screenshot is the Linux
  framebuffer, black under a core).

### 2026-10-22: seed sweep 4, from the tree with video_freak

- Restarted on the user's instruction once video_freak was in (ab63356;
  the sweep-3 candidate seed 8 predates it): seeds 1-4 on the server,
  5 on the Mac, from the same tree. Round 1, worst setup at slow 100C /
  slow -40C, ns: 1 -0.234/-0.007, 2 -0.362/-0.196, 3 -0.049/-0.008, 4
  -0.212/-0.499, 5 (Mac) -0.219; hold +0.03 or better. video_freak costs about 500
  ALMs (33,600-33,800). Round 2: seeds 6-8 on three lanes, the fourth
  left for the comment-trim session's synthesis check: 6 -0.428/-0.337,
  7 -0.534/-0.432, 8 -0.460/-0.574, 9 (Mac) -0.325, 10 (Mac) -0.110, 11
  -0.018/-0.100, 12 -0.175/-0.082, 13 -0.465/-0.440. Thirteen seeds, none
  clean; the best overall stays seed 3 (-0.049/-0.008), kept with the
  others under build/hardware/sweep4 (the Mac's) and the server's
  ngage-q-vf* directories.
  The worst paths differ from seed to seed: the SWI flag into the
  register file, the bus arbiter's grant into the merger, the D-cache's
  load data, the issue stall, the audio FIFO, the bus data into the
  D-cache RAM. That is a design uniformly 0.2-0.5 ns short at the slow
  corner with the device 80 % full, not one bad path; a clean seed is a
  one-in-ten draw, as sweep 3 showed.

### 2026-10-22: NGage.sv comments trimmed to the template's shape

- 8f56f08: the top's comments cut to the framework template's style, a
  short "why" with a pointer where a choice is not obvious (the CPU
  start's clock wait, the master-select register, the `DBG_*` triggers,
  the overlay layout in `tools/mister_dbg.py`, the crop gate); the history
  stays in this log. Comments only: the code lines are identical, `make
  lint` and the top bench pass, and a synthesis-only map of the trimmed
  tree (ubuntu `dev/mister/NGage_MiSTer-map`) matches the video_freak
  build's Analysis & Synthesis report table for table: 34,508 ALMs
  estimated, 51,253 ALUTs, 39,897 registers, 3,429,401 bits, 43 DSP, and
  the same per-entity, RAM and removed-register tables.

### 2026-10-22: structural timing work after sweep 4

- The user chose structural work over more seeds. Full-path reports of
  the three recurring families (build/hardware/sweep4/paths): in each,
  interconnect is two thirds of the 9.3 ns (the load path spends 1.7 ns
  reaching the 128-bit line mux, whose select `sel` has 131 loads, and
  1.8 ns reaching the memory stage; the bus path crosses four modules
  and the die from X39 to X55 and back; the issue path is the register
  file's read mux reached through the skid-index mux, 3.6 ns of routing,
  365 loads on the stall register). My plan first
  (docs/consults/2026-10-22-timing-plan-mine.md), then Codex's from the
  facts (docs/consults/2026-10-22-codex-timing-2.md). They agree on
  family 1 (word select before way select in both caches, the D-cache's
  load transform per way before the way mux with the live format, the
  victim's line register-selected for the write-back) and family 2 (the
  merger's mux after its registers, precomputed burst alternatives
  chosen by the acknowledge); Codex adds a direct derivation of the
  wrapper's CYC, corrects two of my claims (the TLB walker's addresses
  are already concatenations; the register file is 40 x 32, six-bit
  addressed, so the 64:1 reading was wrong), rejects my early register
  lock for family 3 (a lock can change while the instruction is
  stalled) and suggests a banked read mux, local copies of the stall
  register and forwarding priority split there, plus fitter experiments
  (ALM packing LOW, placement effort) before any RTL on family 3.
  LogicLock is probably not in the Lite edition. Order taken: family 1
  both parts, a CPU trial; family 2; family 3 only if it still tops.
- **Family 1 done** (eafc1a1): the tag RAM selects each way's word by
  the address bits (registers) and the hit chooses only between the two
  words (o_cache_words, o_cache_word_sel = the hit on way 1); the line
  output is the victim's for a write-back, register-selected. The D-FSM
  formats each way's word (ld_transform, the live i_ldfmt) in parallel
  with the compares and the uncached data from its register, so o_dat is
  the finished register value and the memory stage registers it as it is
  (zap_memory_main LOAD_FORMATTED, through zap_core from zap_top's
  ONLY_CORE; the transform stays for a core without the cache). The
  I-FSM takes the hit way's word the same way. The late select passes one
  32-bit mux instead of a 128-bit line mux, a 4:1 word mux and the
  transform, and `sel` loses its 131 loads. Cycle-exact: 177 runs on the
  sources and the netlist, 49 matching QEMU, every count unchanged.
  CPU-only trial at seed 1: **+0.618 ns** at slow 100C, +0.613 at slow
  -40C (+0.537/+0.462 before it).
- **Family 2 done** (2559a99): the merger registers both caches' NXT
  signals and chooses the side after the registers by its registered
  state (the same values as before, one mux later; 74 flops); the
  wrappers' next CYC is any manager's when the bus may change hands, else
  the current manager's (exact: the chosen manager has CYC whenever any
  has); the fill and write-back bursts of both FSMs and the tag RAM's
  clean walk present the current beat or the next, both from registers
  (address, CTI, write-back word), chosen by the acknowledge, instead of
  a counter increment and an address add after it. Cycle-exact the same
  way. The TLB walker was left alone (its addresses are concatenations).
  CPU-only trial at seed 1: +0.477 ns at slow 100C, **+0.785** at slow
  -40C; the bus paths are gone from the top, the worst is now the issue
  stage's forwarding (family 3), with that margin. Sweep 5 from this
  tree: seeds 1-4 on the server, 5 on the Mac.
- **Sweep 5 round 1 was worse**: 1 -0.222/-0.056, 2 -0.793/-0.640, 3
  -0.884/-0.914, 4 -0.382/-0.348, 5 (Mac) -0.216; 33,400-34,000 ALMs. The
  new worst paths end in the bus address on its way out: the merger's
  output mux (now combinational from its registers) into the arbiter's
  mux and upp_bus, with registers physical synthesis retimed and named
  after wb_adr, launched from the cache FSMs' and the TLB walker's
  states. That is the risk Codex named for moving the merger's mux
  after its registers: the outgoing side gets a level and the fitter
  spreads it. The merger is reverted to the upstream form (the side
  chosen by state_nxt into the registers); the wrappers' direct CYC and
  the acknowledge-chosen burst beats stay. Suites again, a CPU trial,
  and seeds 7-9 on three lanes beside it.
- **Family 3, first step** (Codex's 3a): the register file's read indices
  take their own copy of the issue stall register (`stall_idx_ff`,
  preserved) and of the skid's four index fields (`skid_idx`), same
  reset, clear and update, so the indices no longer come through the
  skid mux that the original stall register drives with hundreds of
  loads. Cycle-identical by construction.
- The reverted tree's CPU trial at seed 1: +0.214 ns at slow 100C, +0.279
  at slow -40C, the worst path the acknowledge into the merger's
  registered data through the wrapper and the FSM (the path 2b had
  shortened in the trial); the trial and the whole core disagree on
  the merger, so the whole-core seeds decide. Queued behind seeds 11-13
  (the 3a tree): the same tree with ALM_REGISTER_PACKING_EFFORT LOW
  (Codex's cheapest experiment), seeds 14-16.
- **Sweep 5 round 2, the reverted tree (376950d: families 1, 2a, 2c)**: 7
  -0.331/-0.048 (family 3 on top), **8 +0.043/+0.056, hold +0.153 and
  +0.249 at the slow corners, +0.134 and +0.091 at the fast: every corner
  met**, 9 -0.204/-0.333 (the merger's address into upp_bus's acknowledge,
  the outgoing side again, with the upstream merger); 33,700-33,850 ALMs,
  471 M10K, 42,057 registers. Seed 8 is the release candidate with
  video_freak in (md5 4980727e5a773274a807c000c690e3a1), kept as
  build/hardware/sweep5/NGage-s8.rbf with its reports; sweep 3's seed 8,
  without video_freak, remains the other clean one. Its margin is as thin
  as that one's; the 3a tree and the packing experiment, queued, may
  give a candidate with more. 6 (Mac, the merger variant) -0.170.
- Sweep 5's seed 8 on the MiSTer (the debug core, the 2 s boot profile):
  kernel phase 34-86 s at 12.8 M instructions/s, flash waits 25.4 %, the
  boot's bus traffic 34-98 s, the idle screen after: the same core as
  the two-way measurement build, with the video options in
  (build/hardware/boot/sweep5-s8-p2).
- **Seed 10 of the 3a tree (27a4152) on the Mac meets every corner too**:
  setup +0.078 ns at the worst corner, hold +0.223, 33,750 ALMs; kept as
  build/hardware/sweep5/NGage-s10-3a.rbf. A little more margin than seed
  8, from the latest tree.
- Seeds 11-13 of the 3a tree on the server all miss: -0.422, -0.019 and
  -0.214 ns at slow 100C (-0.232, -0.197, -0.168 at slow -40C), hold
  positive. Still seed luck; seeds 8 (376950d) and 10 (27a4152) stay the
  clean candidates.
- Seed 17 of the 3a tree on the Mac: -0.133 setup, +0.239 hold. Seed 18
  queued.
- The register-packing experiment (ALM_REGISTER_PACKING_EFFORT LOW, seeds
  14-16 of the 3a tree): -0.430, -0.401, -0.085 at slow 100C (-0.393,
  -0.595, -0.186 at slow -40C), 33,222-33,284 ALMs. No better than the
  default; dropped.
- The boot bench on the tree with families 1 and 2 (before 2b's revert):
  2.7 G cycles, 661,484,885 instructions, the register log and the bus log
  identical to the previous tree's.

### 2026-10-22: game speed on the hardware

- Measured in play with the overlay's per-second counters on seed 10 of the
  3a tree (`build/hardware/sweep5/NGage-s10-3a.rbf`, deployed as
  `_Debug/NGageDbg_20261022.rbf`), the keys scripted through
  `tools/game_keys.py` (tools/mister_input.py on the board, no model
  choosing anything); captures in `build/hardware/game/sonicn/` and
  `build/hardware/game/asphalt/`:
  - Sonic N, Neo Green Hill, running right and jumping (p0-p9): 7-12
    frames/s (whole 176x208 frames), 19.3-20.8 M instructions/s, CPI
    5.0-5.4, bus waits SDRAM 22-25 %, flash 8-9 %, idle 0 %, 5.0-5.4 M bus
    beats/s. The model: 30 frames/s (2 ticks). The Eggman cut-scene 8-10
    frames/s, the title 4-6.
  - Asphalt Urban GT, Cop Chase in Chernobyl, accelerating and steering
    (r0-r9): 10-12 frames/s, 21.0-21.3 M instructions/s, CPI 4.9, SDRAM
    22.4 %, flash 6.5 %, idle 0 %, 5.7 M beats/s. The model: 20.5 frames/s
    (3 ticks). The title 10 frames/s, the race select 18.
  - So the core plays Sonic at a third and Asphalt at a half of the rates
    the model (not CPU-bound; the phone's tick rates) shows, and both are
    CPU-bound throughout: never in wait-for-interrupt, 20-21 M
    instructions/s. The bus waits are about 30 % of the clocks; the
    pipeline itself takes about 3.5 clocks per instruction for the rest.
    The kernel phase of the boot is 13 M instructions/s at CPI 8, so the
    games get about 1.6x the boot's rate, not the 3-4x a real ARM9's CPI
    would give.
- The overlay is switched on through the core's config file now:
  `/media/fat/config/NGage.CFG`, 16 bytes with status bit 8 set, which
  Main reads at the core load (`jev_play.overlay_cfg`; the tools remove it
  at the end). The OSD key sequence during the launcher's file loads was
  not safe: in one run the core restarted for a file load in the middle of
  it, the enter landed on Rotate, and every capture came out sideways
  (208x176), undecodable (`build/hardware/boot/sweep5-s10-p2`, the seed 10
  profile that failed). `tools/boot_profile.py` keeps the key sequence
  only as the fallback when captures stop decoding.
- A build with the CPU's stall taps on the overlay (a91da1d: the data
  and code bus waits, the fetch FIFO empty, the issue, shifter and decode
  stalls, the ALU's and the writeback's flushes, the uops retired) is
  queued to see where the five clocks per instruction go in play.
- My own reading before the Codex consult:
  `docs/consults/2026-10-22-game-cpi-mine.md` (the load-use interlock
  first, the uncached LCD stores second, mispredicts third); Codex's,
  from the measurements and the RTL alone:
  `docs/consults/2026-10-22-codex-game-cpi.md`. Codex's two cheap finds
  held up on inspection:
  - **The BTB forgot its entries.** `zap_btb.sv` wrote the valid bit from
    `mem_wr_en` (= a branch's feedback) at the ALU stage's PC every clock,
    so every non-branch instruction cleared the entry at its own index:
    a branch more than the table's span (512 entries, 1 KB) away lost
    its entry within a few hundred instructions, and outside tight loops
    the BTB predicted nothing; every taken branch then paid the 12-clock
    flush from the ALU. Upstream ZAP's code (fc7bd75). Fixed: only the
    feedback writes the bit (a8ca165).
  - `MOV PC, LR` was never recognized as a return (the pattern ended in
    `4'd15`, MOV PC, PC), so those returns never used the return-address
    stack. Fixed (`4'd14`).
  - CPU suite with both: 177 runs pass, 49 QEMU comparisons agree, 4.3 %
    fewer cycles over the suite, 17-18 % on the cache test (CPI 3.88 ->
    3.18 at zero latency), 31 % on the compiled random tests; the GBA
    loops unchanged (inside the span). Whole-core build queued; the boot
    bench on the fixed tree to follow the running one.
  - Codex also pointed out that the overlay's retired count included
    replays (the writeback sending an instruction round again while the
    data cache fills; `dabt[1]`, no architectural effect), which the bench
    excludes; fixed with the same build, and replays are counted on their
    own.
- **The stall breakdown in play** (the counters build, a91da1d's tree, the
  old predictor; `build/hardware/game/{sonicn,asphalt}-stalls/`; the
  counters are clocks the signal was high, overlapping, so they do not
  add up; the flush counts are events a second):
  - Asphalt's race, steady: issue stall 36.5 %, fetch FIFO empty 32 %,
    code stall 20 % (the fetch waiting or the FIFO full behind the issue
    stall), decode 7 %, shifter 2.8 %, data stall 1.6 %; flushes from the
    ALU 310 K/s, from the writeback 650 K/s; 24.3 M uops for 21.1 M
    instructions (1.15 uops an instruction).
  - Sonic in Neo Green Hill: issue 31-32 %, FIFO empty 41-45 %, code
    15-18 %, decode 6 %, data 1 %; ALU flushes 280-370 K/s, writeback
    500-570 K/s; 22-23 M uops for 19-20 M instructions.
  - So: the uncached LCD stores are not the problem (data stall 1-2 %; no
    write buffer needed). The pipeline's clocks go to the issue stage's
    interlocks (a third), to the front end having nothing to decode (a
    third: after every flush and every taken branch's redirect, and the
    instruction misses), and the flushes themselves: 650 K writeback
    flushes a second in user code can only be the data cache's replays
    (an access arriving during a line fill is acknowledged with err2 and
    the writeback sends it round the pipeline again), about 9 % of the
    clocks at 14 each; the ALU's 310 K/s (mispredicts, 12 each) about
    3.5 %, to be cut by the BTB fix.
  - Changes in flight, one build each: the BTB fix (a8ca165), the memory
    stage's load forwarded instead of locked (95cd2fe), and the data
    cache holding an access that arrives during a fill instead of
    replaying it (CLEAN_SINGLE, FETCH_SINGLE, UNLOCK_REG, UNLOCK_WR: no
    acknowledge, served from IDLE after).
- Seed 18 of the 3a tree on the Mac: -0.330. The Mac stays out of the
  sweep while the speed work runs (the user: small misses do not matter
  until the games are quick).
- The hold change as I first wrote it (the four err2 acknowledgements
  simply removed) failed the smoke test (dcache_rtl, icache_rtl, ctrand1,
  crand1 wrong at every latency): the tag RAM's registered lookup of the
  held address is stale after the fill's tag write. Reverted; handed to
  Codex with the failure.
- **The predictor-fix build (a8ca165's tree, -0.153 ns) in play**
  (`build/hardware/game/{sonicn,asphalt}-btb/`): Asphalt's race 23.3-23.7
  M instructions/s (was 21.1), CPI 4.4-4.5 (was 4.9), 10-11 frames/s (was
  11-12); Sonic 21-22.4 M/s (was 19.3-20.8), CPI 4.6-5.0, 8-11 frames/s.
  The retired count now excludes replays, which are counted: 590-610 K/s
  in Asphalt, 500-520 K/s in Sonic, i.e. the writeback flushes were the
  replays, as read. The ALU flushes did not change (300-310 K/s, 1.3 % of
  instructions: the mispredict rate was already low in play; the BTB
  fix's gain here is the front end's bubbles, FIFO empty 32 -> 24.5 %).
  The issue stall is 41 % now that the front end feeds it more.
  **The frame rate is a staircase**: the games step by whole kernel
  ticks (1/64 s); Asphalt at 10.7 frames/s is 6 ticks a frame against the
  model's 3, Sonic 6-8 against 2, so a 10 % faster CPU shows no frame
  until a frame's work crosses the next tick boundary. The instruction
  rate is the measure to watch between steps.
- **Codex as the implementer** (the user's call; four `codex exec -s
  workspace-write` runs in their own worktrees, briefs in the session's
  scratch area, reports under docs/consults/2026-10-23-codex-*-report.md;
  the sandbox could not write the worktrees' git metadata, so the commits
  were made by hand from the prepared messages):
  - BTB looked up from the next PC: a predicted taken branch loses one
    fetch slot instead of three (f83073f). ctrand1 89,133 -> 76,785
    cycles at 0:0, crand1 -13.6 %, cache -1.8 %.
  - Late operand pickup (ab01d67): a plain ALU operand may leave issue
    with its load in postalu1/2 and pick the value up at the ALU, a
    shifted or store-data operand one stage earlier; 24 metadata bits,
    one 2:1 mux at each ALU input. cache 903,967 -> 838,321 (-7.3 %),
    the compiled tests -1 %.
  - I-cache early restart (aa35a4e): registered early responses into the
    FIFO while the line fills, with provisional FIFO entries held until
    every beat succeeds and precise late aborts; linear bursts kept.
    ctrand1 -3 % at 2:9, cache unchanged.
  - The hold (95fc919): no acknowledgement through the fill and unlock
    states, the held and the two younger set lookups restored before
    IDLE, stale LRU hit updates suppressed, a new dhold_rtl test and
    replay counts in the bench. cache -4 %, ctrand1 -2.9 %, crand1 -3.3 %.
  - All four merged into master (c68af0c), the netlist regenerated;
    lint clean. The smoke test of the merged tree and its build next;
    the full suite and the boot bench once the games are at speed.
  - The merged tree on the suite: every existing run passes, QEMU agrees
    on all 49 and on the 3 new references (Codex's tests built here:
    dhold_rtl, loaduse, loaduse_irq, btb_early, 12 runs pass); cycles
    before all of today's changes -> after the merge: cache 903,967 ->
    789,484 (-12.7 %, CPI 3.08 -> 2.69), ctrand1 89,133 -> 72,756
    (-18.4 %, CPI 5.52 -> 4.50), crand1 -18.3 %, dcache_rtl -18.3 %,
    mmu_page -17.6 %; the GBA loops unchanged. Building (b8).
- **The forwarding build (95cd2fe's tree: the BTB fix plus the memory
  stage's load forwarded, -0.406 ns) in play**
  (`build/hardware/game/{sonicn,asphalt}-fwd/`): Asphalt's race **14
  frames/s** (was 10-11), 23.3-23.6 M instructions/s, CPI 4.4, issue
  stall 37.5 % (was 41 % on the predictor-fix build), replays 670-680
  K/s; Sonic 9-12 frames/s, 22-23.3 M/s, CPI 4.5-4.7, issue 33 %.
  The first frame-rate step: Asphalt from six ticks a frame to about
  four and a half.
- Codex's SDRAM open-page policy (9d36431, merged 864e71a): one row open
  per bank, precharge only on a conflict or before a refresh; a row-hit
  first word 8 -> 5 clocks, a line 15 -> 12; the SDRAM, fault-injection,
  UPP and top benches pass. Quartus 17 rejected its inline genvar loop
  (fixed, 9bb4942). Codex's critical-word-first (3d440a4, merged 75cce2e):
  the burst starts at the requested word with wrapped order carried end
  to end, the loaded register written one edge after its beat; cache
  789,484 -> 760,787 cycles. Both merged on master; building (b9, b10).
- **The merged tree misses timing by 3 ns** (b8: -3.014 ns at slow 100C,
  -3.047 at slow -40C; the tree before the four changes missed by
  0.15-0.4). Two families, from the full-path report
  (session scratch, b8-timing/critical-paths.rpt): the BTB's registered
  decision now computed from pc_nxt, through the decode stage's stall and
  clear_btb (11.8 ns: f83073f did what its brief said not to), and the late
  operand pickup resolving the pending operand from the D-cache's live read
  data and the FSM's state into the ALU's operand mux (-3.0 to -2.7, many
  paths). Handed to Codex as a timing task (codex/timing worktree): resolve
  only from registered values, the BTB's read from a register, verified
  with the CPU-only Quartus trial. The merged build is on the board to see
  whether it runs at all at that miss.
- **The ARM9 pipeline project started** (the user: "kick off codex on the
  larger arm work now"; "the first game people will probably fire up will
  be sonic"): Codex on codex/arm9 with the brief in the session's scratch
  area (codex-impl-arm9.md): an ARM9TDMI-style five-stage core under
  rtl/cpu/arm9/ selected by a CORE parameter in arm925t.sv, ZAP's CP15,
  MMU, caches, bus, debug taps and verification kept, the TRM's chapter 7
  cycle counts as the specification, a timing trial of the execute stage
  before the core; milestones: the design document, the execute datapath's
  trial, the skeleton, the full set, the netlist and trial. Robert Peip's
  DS source turned out to be public (TinyRetroWarehouse/DSFPGA, GPLv3) but
  its ARM9 is his multi-cycle ARM7 design; MiSTfits-devel/Nitro_DarkSide
  (2026) the same lineage; both and his GBA ARM7TDMI are references for
  semantics and cycle counts, the TRM for the pipeline. The repository
  goes public and GPL code may be mixed in (the user).
- **The merged build in play** (b8, the four Codex changes plus the
  forwarding and the predictor fix, -3.0 ns; it runs: the user notes the
  Jaguar core works at -10 ns; `build/hardware/game/{sonicn,asphalt}-merged/`):
  - Sonic in Neo Green Hill: 26-27.8 M instructions/s (was 22-23.3 on the
    forwarding build, 19.3-20.8 at the start), CPI 3.7-4.1, **12-16
    frames/s** (was 9-12, 7-12). Replays 80-110 K/s (were 500-570 K), data
    stall 14-17 % (the held accesses now wait there instead of replaying),
    code stall 54-57 % (the FIFO full behind the issue stage), FIFO empty
    18-24 %, issue 36-41 %, shifter 5 % (the late pickup's holds count
    there), decode 8-10 %.
  - Asphalt: 27.8-28.4 M/s (was 23.5, 21.1), CPI 3.7 (was 4.4, 4.9),
    replays 130-146 K/s (were 670 K), shifter 15 %; 10-11 frames/s, which
    is not comparable: Instant Play picks a random race, and this run got
    the night-time Cop Chase in the city (as the first runs did) while the
    forwarding build's run got a coastal time attack with another car, so
    its 14 frames/s was a cheaper scene. The idle screen 39.9 M/s at CPI
    2.6. Instruction rate and CPI are the measures across builds; Sonic's
    frame rate is comparable (same level, same keys); Asphalt's needs a
    fixed race (the script will pick Cop Chase explicitly).
  - Against the start of the day: Sonic +35 % instructions/s, Asphalt
    +33 %; CPI 4.9 -> 3.7. Asphalt's 21 frames/s needs about 2.9, Sonic's
    32 about 1.5.
- **The SDRAM open-page build in play** (b9, -3.578 ns;
  `build/hardware/game/{sonicn,asphalt}-sdram/`): no measurable change.
  Sonic 25.4-27.5 M instructions/s, CPI 3.8-4.1, 13-15 frames/s; Asphalt's
  Cop Chase (chosen explicitly now) 27.9-28.1 M/s, CPI 3.7, 11-13
  frames/s; the SDRAM wait 19-23 % as before. The cache-line traffic
  evidently hits few open rows, or the saved clocks hide behind the
  pipeline's own waits. Kept (verified on the benches, no cost), but it
  is not a lever.
- **ARM9 project, session 1** (codex/arm9: 4c9fbfb, 39af807, 73e516b):
  docs/ARM9.md (the pipeline and timing decision, the cycle model as the
  specification, the cache's read path being three edges rather than two
  and what that does to the TRM counts, forwarding and interlocks, memory
  and CP15 integration, the multi-transfer and precise-exception plan, the
  verification plan and gates); the execute datapath under rtl/cpu/arm9/
  (arm9_shift, arm9_alu, arm9_forward, arm9_execute: a single execute
  stage with the shifter in parallel and direct N/Z from the arithmetic,
  582,272 checks) fitted at 104 MHz with +0.018 ns at seed 2, so the
  ARM9's one-stage execute does close here, barely; ZAP untouched (198
  runs, 52 QEMU). The report
  (docs/consults/2026-10-23-codex-arm9-report.md) ends at milestone 2 with
  the next steps: settle the cache's three-edge contract, then the
  selectable core (CORE in arm925t.sv), fetch through writeback with the
  bench's taps, the simplest tests first. Session 2 started from it.
- **The critical-word-first build in play** (b10, master with everything,
  -3.568 ns; `build/hardware/game/{sonicn,asphalt}-cwf/`): Sonic 26-27.8 M
  instructions/s, CPI 3.7-4.0, 13-17 frames/s; Asphalt's Cop Chase
  28.2-28.6 M/s, CPI 3.6-3.7, 12 frames/s. One to two percent over the
  SDRAM build: the memory-side changes together are nearly neutral in
  play; the clocks are in the pipeline (issue 33-41 %, the FIFO full
  behind it 54 %, the FIFO empty 16-23 %), which is the ARM9 project's
  case. This is the tree to carry forward; the Codex timing run is to
  bring its 3.5 ns miss back to the old few tenths before any sweep.
- **ARM9 project, session 2** (codex/arm9: ff544e5, 43ecfc7, bf91bad): a
  selectable ARM9 core (CORE = "ARM9" in arm925t.sv; the bring-up
  controller, retirement probes for the bench, the whole instruction set
  through the existing caches, MMU and CP15, blocking load retirement)
  that passes the whole suite (201 runs) and all 53 QEMU comparisons,
  with ZAP still the default and passing. Not yet pipelined: it
  serializes instructions and is slower than ZAP; the integrated fit
  fails at -2.704 ns with the path and a proposed fix in the report.
  Session 3 started: the overlap, the cycle model's counts
  (arm9_cycles.S), the timing fix with the CPU-only trial, and the cycle
  comparison against ZAP.
- **The boot bench with the predictor fixes** (a8ca165's tree): all
  76,975 device accesses agree with the model in order, the register and
  CBUS logs agree; 906,070,899 instructions in the 2.7 G cycles against
  661,484,885 before the fixes, so the firmware's boot runs 37 % more
  instructions in the same time (the BTB forgetting its entries hurt the
  kernel too). The bench on the whole merged tree is queued next.
- **Codex's timing fix** (codex/timing 2571ece: the BTB's lookup and
  decision from registers, the late load pickup resolved only from the
  registered memory-stage value): both path families gone from the worst
  ten over four CPU-only fits; the CPU alone at -0.117 ns (slow 100C) /
  -0.067 (slow -40C), the remaining paths in the cache/merger and the
  issue control; 198 runs pass, 52 QEMU agree. Cost: a predicted taken
  branch loses two fetch slots instead of one, an exposed late pickup one
  more cycle; cache 760,787 -> 793,607 cycles (+4.3 %), ctrand1 +6.5 %,
  the GBA loops +0.3 %. Merged into master for the build (b11) that
  decides between the slack and the cycles on the board.
- **Tony Hawk's Pro Skater on the current build** (b10;
  `build/hardware/game/thps-cwf/`): the model's key sequence works on
  the board (five 5s through the menus, the Warehouse, the tape
  challenges), and the Warehouse skates at 9-12 frames/s (whole frames)
  at 26-29 M instructions/s, CPI 3.6-4.0, SDRAM wait 20-22 %, flash
  9-12 %; the model's rate is 27.8. The tape-challenge load runs 22 M/s
  at CPI 4.7 with the flash at 17.5 %. Same shape as Sonic: about a
  two-fold gap to the phone, the ARM9 core's job.
- Real frame rates of the phone (web, 2026-10-23; no measurements exist):
  GameSpot's SonicN review, "quite a bit of chop, especially in areas
  where the speed of the game really picks up"; a 2021 retro review on
  hardware, "compared to the smooth GBA version, the low frame-rate is
  immediately striking"; Asphalt on hardware "absolutely rock-solid",
  Tony Hawk's "very smooth". So the phone did not reach Sonic's 32 (its
  2-tick cap) either: Sonic's target is the phone's own uneven rate, in
  the teens or low twenties; Asphalt's 21 and Tony Hawk's rate are the
  caps the phone met.
- **ARM9 project, session 3** (codex/arm9: 78c0cd2, e47c566, 06ed82f,
  0fbfc67): the fetch overlapped (an instruction queue fed by the cache,
  cancelled by epoch on branches and exceptions), the arithmetic
  overlapped with forwarding from M and W, the Thumb translation
  registered in the queue, and sim/cpu/tests/arm9_cycles.S with 69 timed
  windows, one per TRM table row, all at their expected counts; both
  cores pass 207 runs and 55 QEMU comparisons. The cache test 2,553,475
  -> 1,237,634 cycles at 0:0 (ZAP: 760,787), ARM9 ahead of ZAP on the
  GBA loops, behind on cache, dcache_rtl, ctrand1 and crand1 because the
  memory operations still serialize; the integrated fit -2.623 ns with
  the cache/Thumb-translation and execute-to-flags paths left. Session
  4 started: the memory overlap, beating ZAP at every latency, the
  remaining paths.
- ARM9 session 4 (f49d81c, 8c97686; six minutes): the held memory context
  with ordered retirement of the overlapped arithmetic, the scalar memory
  admission and completion bubbles removed; 210 runs, 56 QEMU, the 69
  windows; cache 1,237,634 -> 1,028,308 at 0:0. Memory requests still
  serialize, the streaming transfers and the load-use interlocks are
  unfinished, no trial ran. Session 5 started on the same list.
- **The timing-fix build** (b11, master with 2571ece): -1.151 ns at slow
  100C (from -3.0), hold +0.246. The worst ten are one family: the
  multiplier's FSM state (the shifter's stall) -> the predecode's uop
  sequencer -> o_stall_from_decode -> a predecode register, 9.9 ns with
  6 ns of interconnect; the eleventh o_stall_from_issue -> stall_idx_ff.
  Handed to Codex as timing round 2 (codex/timing2: the shifter's stall
  to reach predecode and decode from a register, cycle-identical if
  possible). The build is on the board for the three games.
  In play (`build/hardware/game/{sonicn,asphalt,thps}-timing/`): Sonic
  25-27 M instructions/s, CPI 3.8-4.2, 12-16 frames/s; Asphalt's Cop
  Chase 27.5-28.1 M/s, CPI 3.7-3.8, 11-12 frames/s; Tony Hawk's Warehouse
  25.4-27.5 M/s, CPI 3.8-4.1, 8-12 frames/s: two to three percent under
  the critical-word-first build, far less than the suite's 4-6 %, so the
  timing round stays in.
- ARM9 session 5 (78c9aeb, 51a60de, 8e83709, 56cb701, 60ec849; 26
  minutes): scalar and block memory accesses stream one a clock with
  ordered retirement and precise aborts, SWP and the critical-word
  continuation improved; 219 runs, 59 QEMU, 76 timing windows. At 0:0:
  cache 994,118 (ZAP 760,787), ctrand1 97,715 (ZAP 72,594), crand1 98,994
  (73,608); ahead of ZAP only on the GBA loops and align. The measured
  costs: load-use 3 clocks (the cache's three read edges: the RAM
  module's st1/st2/st3 forwarding pipeline), B/BL 6 (no predictor, the
  three-edge fetch), nine fixed clocks per LDM/STM, multiplies as a
  barrier. The integrated trial -3.970 ns, 16,353 ALMs. So with the
  caches as they are the ARM9 core is a nine-stage pipe without ZAP's
  predictor and late pickup; the project now hinges on a two-edge cache
  hit path (the RAM read and the compare, no forwarding stages) and a
  BTB in its fetch, which is the next session's brief.
- ARM9 session 6 (d765618, 8acb1f1; six minutes): an ARM9-only one-edge
  cache RAM with registered collision forwarding (ZAP's three-edge module
  untouched), the TLB lookup shortened, one ordered pipeline record
  removed: load-use 3 -> 2 clocks, an unpredicted branch 6 -> 5; both
  cores 225 runs, 60 QEMU, the 76 windows. Session 7 resumes the same
  Codex thread (`codex exec resume <id>`, the user's request for
  continuity) with the rest: the 4-clock branch, the BTB in the ARM9
  fetch, the block and multiply costs, the cycle gate against ZAP, then
  the trial.
- The full CPU suite on master (the ZAP tree with the first timing round,
  a801120's tree): 198 runs pass, 52 QEMU comparisons agree (the Mac).
- **Codex's timing round 2** (codex/timing2 4931516: the shifter's stall
  fan-out shortened without adding cycles): all 27 baseline runs keep
  identical cycle and instruction counts, 198 runs pass, 52 QEMU agree;
  the CPU alone -0.398 -> +0.196 ns at slow 100C, the targeted families
  out of the worst ten. Merged into master; the whole core builds on the
  Mac (b12), the server's lanes being the ARM9 fits.
- **ARM9 session 7** (the resumed thread; 9fef0be, 3355340, f238f14,
  0e4601f): the two-edge cache hits launched with the TLB and branches
  refilled in four clocks; the BTB reused from zap_btb with registered
  launch addresses and decisions, validated in E, the ARM9_PREDICTOR
  option on by default; block transfers streamed from E and multiplies in
  their slot (2+m, long 3+m); registered ARM fetch responses bypassed to
  D. **ARM9 beats ZAP on all seven workloads at all three latencies**:
  cache 639,745 / 764,132 / 1,097,644 (ZAP 760,787 / 888,787 /
  1,222,550), ctrand1 69,278 (72,594), crand1 70,348 (73,608); 234 runs,
  63 QEMU, 85 windows, the predictor on and off. The integrated fits of
  both cores are running (the slack and area gate).
- The MiSTer tidied (the user: one main core, a second only for a
  concurrent stream): `_Console/_NGage/NGage_20261023.rbf` is the latest
  ZAP tree (b11, the first timing round) with its 17 launchers, and
  `_Debug/NGageDbg_20261023.rbf` the same build as the measurement
  stream with its 14 launchers; the trace build and its launchers are
  gone (rebuilt when needed). New builds replace these, never
  accumulate.
