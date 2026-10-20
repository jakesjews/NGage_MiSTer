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
