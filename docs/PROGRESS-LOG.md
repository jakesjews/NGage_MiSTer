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
- MiSTer SSH: the MiSTer accepts the 1Password agent key. Logins fail
  when 1Password is locked, because the agent doesn't sign. Unlock
  1Password before hardware tests.

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
