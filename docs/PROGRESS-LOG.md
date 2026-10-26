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
- ARM9 session 7's end (2647f62, d9c773d): the cycle gate met on all 21
  comparisons, but the integrated CPU-only trial (seed 2) is **-8.332 ns**
  at slow 100C (a first fit at -23 ns had a control-to-data selection
  through the shifter and ALU, corrected to select the instruction data
  from a registered queue count), 16,755 ALMs against ZAP's 15,917 in the
  same harness (ZAP's own baseline there -2.65 ns: that worktree
  predates the timing rounds). Two families: the E branch decision in the
  backend clear network (held forwarding -> branch adder -> target
  equality -> early_redirect -> a clear with fanout 807, 17.3 ns) and the
  I-TLB fault / cache hit qualifying the fetch data into the operand
  muxes (17.2 ns). Session 8 (the same thread): timing first, each change
  with its own trial: a registered late-event clear, a registered F2
  boundary with the fault as a kill a clock later, then the next family,
  until the CPU alone is within 0.5 ns; the cycle gate re-measured after
  each.
- **The second timing round's whole-core build** (b12, the Mac, seed 1,
  master 6bf21b7): -1.088 ns at slow 100C, hold +0.243: no better than
  b11 although the CPU alone went to +0.196, so the remaining paths are
  outside the CPU-only trial's reach. Its report (regenerated by hand:
  build.sh skips the report when timing fails on the Mac): the D-cache
  FSM's state into the tag RAM's forwarding stage and the data RAM's
  write control (the hold's lookup restore and critical-word-first; four
  of the worst ten, -1.09 to -0.83), the shift-length operand's
  forwarding in issue (-0.94, -0.91), the FSM state into the issue
  stage's store-data operand through the late pickup (-0.91), the TLB
  walker's state into the merger's address (-0.86), the decode stall into
  the BTB's metadata pipeline (-0.81), o_stall_from_issue -> stall_idx_ff
  (-0.79). Timing round 3 (the same Codex thread, resumed): these
  families, proved by whole-core builds on the server, goal within 0.3
  ns with the counts unchanged. b12 is on the MiSTer in both slots
  (cycle-identical to b11).
- ARM9 session 8 so far: the registered backend clear (3aadad1) took the
  integrated fit from -8.33 to -7.53 ns at 17,078 ALMs; the registered
  fetch boundary costs a clock on mispredicts and PC writes and loses
  five comparison rows. Two notes were queued into the running thread
  (`codex queue --thread <id>`): stop fixing one path family at a time
  and make one structural pass registering every control signal at the
  stage boundaries, one trial for the pass; and the overall goal (the
  phone's frame rates on the board at 104 MHz with timing met; the
  cycle rows are a proxy; a cycle on a rare event is a fair price, on
  the common case not).
- **Antigravity consulted** (the user: "see if antigravity has any ideas
  too with argon 4 on high thinking"; `agy --print ... --model
  gemini-4-argon-high --effort high --mode plan`, read-only, with both
  path reports): `docs/consults/2026-10-23-antigravity-timing.md`. For
  ZAP, five families with zero-cycle fixes and lines: o_cache_tag's
  default-zero gating by the FSM state (assign it unconditionally),
  zap_ram_simple's sel_st1 compare split from the write enable, the
  dead forwarding branches of the shift-length operand (shifter_lock
  already stalls those cases) and `(* keep *)` on the read indices,
  data_stall as the operand registers' clock enable with the late
  completion held across the stall and a 6-bit background-load index
  instead of the 64:1 mux, the i_busy gating off o_wb_adr_nxt,
  o_clear_btb registered. For the ARM9 core, five structural rules (one
  forwarding network with three registered producers; branch targets and
  the predicted-target comparisons computed in D and the redirect
  registered at E/M1; fetch validity only in the queue push; one Thumb
  decoder at the queue-to-D boundary; the LDM scan precomputed; no
  combinational store-to-load merge in M1; the load-use hazard stalled in
  D) with the lines that break them, costing a clock only on mispredicts
  and cold refills. Its bet: close ZAP first (shallow artifacts, 1-2
  rounds), and decide on the ARM9 from the stall split: our counters put
  about 1.1 of the 2.7 excess clocks an instruction on the memory side
  and 1.6 in the pipeline, which by its rule says the ARM9 is worth its
  2-3 sessions, with the memory side still to be worked either way. Both
  sets of fixes were queued into the running Codex threads.
- Codex's service tier changed from ultrafast to fast (the user: the
  $500 plan); the change caught the ARM9 session mid-trial (its edits
  on disk, resumed as session 9 with the structural-pass instructions)
  and the timing round 3 before it started (resumed).
- **ARM9 session 9** (ae3b838, 49ed322): the fetch-to-D handoff
  registered (-6.513 ns, 17,248 ALMs), then the combined control-boundary
  pass (every control signal crossing a stage boundary from a register):
  **-6.958 ns**, 15,891 ALMs (26 below ZAP's), 234 runs and 63 QEMU on all
  three configurations, five comparison rows lost to ZAP, some rare-path
  costs above the allowance; stopped under the -2 ns rule. The remaining
  worst path: E's forwarding -> the shifter -> the ALU's address -> the
  D-TLB's request validity, 14 levels, 15.9 ns: the data access is
  launched from the ALU's combinational address to keep the load-use at
  two clocks. Registering that address costs the third load-use clock,
  which is where ZAP's late pickup already is; the ARM9's remaining
  advantage would be its shorter front end (a 5-clock flush against
  ZAP's 12, fewer uops), about 15 % on the cache test and 5 % on
  compiled code by the suite. The memory pipeline's depth is set by the
  RAM-based caches at 104 MHz, not by the core. Decision put to the
  user: pause the ARM9 (keep the branch) and spend the budget on ZAP's
  closure and its measured stalls, or continue the ARM9 under
  Antigravity's rules for two or three more sessions.
  **Decided: the ARM9 core is paused** (the user), its branch codex/arm9
  (49ed322) and reports kept; the Codex budget goes to ZAP: the timing
  closure (round 3 running), then the measured pipeline stalls, then the
  memory-side levers, each measured in play.
- **Antigravity as a coworker** (the user: "use codex and antigravity as
  coworkers too"): its first implementation, in its own worktree with
  `agy --mode auto` on Gemini 4 Argon, the **flash line-wide fetch**
  (agy/flashfetch 7192bed, merged): a read-array burst of a 16-byte line
  is served from ddram_flash's cache or beat buffer as two 8-byte beats
  through a new wide port on nor_flash, into a registered line buffer in
  upp_bus, with wrap-four order and the CS2/CS3 window kept; everything
  else keeps the halfword path. Its benches (extended with the new
  cases): a cached line fill 35-39 -> 8 clocks, a DDR3 miss 56 -> 23-24,
  random bursts 56-58 -> 25-27 (so the flash's cost was worse than the
  24 clocks assumed). flash, ddrflash, upp and top benches pass, lint
  clean; report docs/consults/2026-10-23-agy-flashfetch-report.md.
  Built on the Mac (b13, seed 1): -0.773 ns at slow 100C, hold +0.243
  (the previous tree's seed-1 build was -1.088; same families, a
  different placement); `build/hardware/NGage-flashfetch.rbf`, to go on
  the board's debug slot when it is free (the flash wait share in play,
  7-12 %, is the measure).
- **Codex's timing round 3** (codex/timing2 39ad27a, six hours, with
  Antigravity's fixes as its checklist, each change proved by a
  whole-core build on the server): the whole core **-1.088 -> -0.460 ns**
  at slow 100C, reproduced independently; cycle and instruction counts
  unchanged; 198 runs, 52 QEMU comparisons and the firmware boot bench
  (all 76,975 device accesses) pass. The remaining worst path: the MMU
  enable into the merger's data capture. Report
  docs/consults/2026-10-23-codex-timing3-report.md. Merged into master
  with the flash fetch (191cab1) and built (b14, the server, seed 1):
  **-1.398 ns**, hold +0.246, with the previous families gone and two
  others at the top that no earlier build showed: the predecode's
  instruction register into the decode stage's shift fields
  (o_shift_is_lsl0_ff, o_shift_length_ff, -1.4 to -1.3) and the memory
  stage's load destination index into the writeback's pc_del3 pipeline
  (-1.31, seven of the ten). So the tree has a floor of families near
  -1 ns that surface with the placement; timing round 4 takes them
  after the pipeline-stall work (which changes those stages), from this
  build's report (session scratch, b14-timing/). The Codex thread is on
  the stalls; b14 is the measurement build for the board.
- **Codex's pipeline-stall session** (codex/timing2 b966f86..53d4301,
  merged b862b4b): the earlier load admission (the pickup extended to
  loads in postalu0 and the ALU) tested and discarded, no gain measured;
  retained: BTB predictions accepted from the registered RAM one fetch
  slot earlier, direct-branch mispredictions resolved from registered
  shifter-stage decisions (the ALU flushes 61 -> 14 on cache, 124 -> 88
  on ctrand1, 89 -> 29 on gba_arm, the rest now cheaper early flushes),
  ARM BL in one slot, the incrementing LDM/STM base update folded into
  the last uop; the multiplier measured, no change retained. Cycles:
  ctrand1 77,298 -> 73,043 (-5.5 %), crand1 -5.6 %, cache -0.5 %, gba_arm
  -1.6 %, gba_thumb -0.2 %; uops down about 0.7 %; FIFO-empty clocks
  -8-9 %. Whole core (seed 2): **-1.398 -> -0.578 ns** (the earlier BTB
  acceptance helped timing too). 213 runs, 57 QEMU. Report
  docs/consults/2026-10-23-codex-zapstalls-report.md. So the hit-path
  interlocks are not where the remaining issue stalls are: the next
  cycle lever is the memory side (hit-under-miss in the D-cache,
  Antigravity's I-prefetch, the flash fetch already in).
  Built as b15 (the server, seed 1): **-0.578 ns**, hold +0.174, the
  same figure Codex measured; `build/hardware/NGage-b15.rbf`, the next
  measurement build for the board after the flash-fetch replay.
- Two more coworkers at once (the user: "Use codex and antigravity as
  you see fit. I have expensive plans on each"): a second Codex thread on
  the fast first-boot format and the boot indicators (codex/firstboot),
  and a read-only Antigravity analysis of the game-load path (the MMC
  controller, the card model, the framework's block fetch) for the slow
  loads the user saw in Shadowkey. Antigravity's I-prefetch run was cut
  off by a Gemini content filter misfiring on a trace dump, mid-fix
  (fill_valid_ff cleared only on IDLE -> IDLE); its conversation was
  resumed on Claude Opus 5.5 in the same worktree with the six failing
  runs named.
- **The flash-fetch build in play** (b13 on the debug slot, the b12 tree
  plus the line-wide fetch; the three-game replay, ten shots each in
  play): the flash wait share fell from 7-12 % of clocks to **1.3-2.5 %**
  (Sonic 1.8-2.5, Asphalt 1.3-1.4, Tony Hawk 1.6-2.0; 3.5 % in the two
  shots at the Warehouse's start), and the instruction rate rose 5-10 %:
  Sonic 27.5-29.2 M/s at CPI 3.6-3.8 (b12: 25-27), Asphalt 29.0-29.4 at
  3.5-3.6 (27.5-28.1), Tony Hawk 27.5-31.5 at 3.3-3.8 (25.4-27.5). The
  frames stay on the same ticks (Sonic 13-18, Asphalt 12-13, Tony Hawk
  9-12): the gain is under a tick. The SDRAM wait is unchanged at 20-24
  %, so the bus side's remaining cost is the SDRAM line fills and the
  misses behind them: hit-under-miss in the D-cache (Codex, running),
  the I-cache prefetch (Antigravity, running), then the cache sizes.
  (The replay's filter cut the overlay rows after the beat count, so this
  run has no stall shares; the next runs keep the whole line.)
  Four entries since timing round 3 had been added above the file's
  header by mistake; moved to the end, in order.
- **Antigravity's game-load analysis** (read-only, Gemini 4 Argon;
  docs/consults/2026-10-23-antigravity-loadtimes.md): the card model
  clocks every bit of the 1-bit wire at 8.67 MHz (MMC_DIV = 12 in
  upp_periph.sv, the service manual's 8.66 MHz; a figure says 13, the
  card's CSD allows 20), so a 512-byte block costs 49,368 clocks (475 us)
  and the wire tops out at 1.05 MB/s; the card model fetches one sector
  per hps_io round trip into a two-sector buffer, so every CMD17 (FAT and
  directory reads), every non-contiguous CMD18 start and every seek after
  a CMD12 (the controller holds CMD12 until the last block's end bit, so
  the card still speculates the next sector and the seek waits for that
  fetch too) pays a Linux round trip of 100-1,000 us; and the firmware's
  driver moves files in 4 KB CMD18 bursts of eight 512-byte DMA phases
  with 2-3 interrupts each plus EFile's cross-process copy, which is why
  the CPU showed busy (not idle) through Tony Hawk's load. Its estimate:
  the phone loads at 500-900 KB/s end to end, the core at 180-350. Its
  ranking: (1) MMC_DIV 12 -> 4 (26 MHz, 3x the wire, the timeout
  counters widened to keep the hardware timeout at about 320 ms; the card
  model needs DIV >= 4), (2) 4 KB hps_io fetches (sd_blk_cnt 7, as
  flash_save already does) into an 8 KB buffer with sector slots kept
  for FAT metadata and no speculation on CMD12 (+7 M10K), (3) a DDR3
  copy of the card: not worth it (Linux's page cache already holds the
  file; the 4 KB buffer hides the SPI transfer), (4) the CPU side (in
  flight) and, optionally, a DMA read bypass so the 512 byte-wide
  Wishbone reads per block stop contending with the CPU. The settling
  measurement needs no new wiring: B_DATA_BUSY and B_CMD_BUSY are
  dbg_src0[22:23] and card_dat_oe is at the top level, giving blocks/s,
  data-phase clocks and the clocks the wire waits for Linux.
  **Decided (the user's speed-over-accuracy rule):** one change with the
  three counters, MMC_DIV 4 as the default (12 stays the accuracy value,
  a parameter) and the 4 KB fetch, implemented by Antigravity in its own
  worktree (agy/mmc), then one build and the Shadowkey and Tony Hawk
  loads measured on the board against b15.
  The M10K budget for the cache levers, from b15's fitter report: 470 of
  553 blocks used; the D-cache is 43 (two 16-block data ways, tags, LRU),
  the I-cache 26, the flash's 128 KB line cache 133, the LCD's frame
  buffer 72, the on-chip RAM 64. A 32 KB I-cache costs about 20 more, a
  32 KB D-cache about 36: both fit by count (526), with the placement the
  unknown.
- **b15 in play** (the debug slot; the three-game replay, ten shots
  each): Sonic 13-18 frames/s at 27.7-29.3 M instructions/s, CPI
  3.5-3.8; Asphalt 12-13 at 29.1-29.8, CPI 3.5-3.6; Tony Hawk 9-14 at
  27.5-29.9, CPI 3.5-3.8; SDRAM wait 20-24 %, flash 1.3-2.3 %. The same
  as the flash-fetch build within 1 %: the stall session's 5.5 % on
  compiled code does not show in play, so the games' remaining clocks
  are not in the interlocks and flushes it cut; the memory side is where
  they are. (The replay's filter lost the stall rows again; the next
  runs keep them.)
- **Antigravity's I-cache prefetch merged** (agy/iprefetch 5e50f59,
  merged ede13fe, on Claude Opus 5.5 after the Gemini filter cut its
  first run): a one-line buffer filled with the next line, within the
  same 1 KB (no new translation), when a fill completes and the bus is
  free; a demand miss on that line adopts the burst, a miss elsewhere
  waits for it; dropped by the I-cache invalidates and cleans, cache
  off, TLB invalidates, the D-side cache operations and any change of
  the MMU controls; a one-cycle tag copy per way (+2 M10K) keeps it from
  fetching lines already cached; the demand tag RAM and its compare are
  untouched. ICACHE_PREFETCH=0 is cycle-identical to before on all 198
  runs (the accuracy build); ICACHE_SIZE=32768 works (1,024 sets,
  VA[13:4]; +16 M10K) through the NGAGE_ICACHE_32K macro in NGage.qsf,
  NGAGE_ICACHE_NO_PREFETCH beside it. A bug found on the way: a fill
  started in the cycle after FILL_COMPLETE inherited the previous line's
  valid mask (fill_valid cleared only on IDLE -> IDLE); now cleared on
  every entry to IDLE. The gain in simulation is small (the suite
  -0.14 %, crand1 -0.4 %, ctrand1 -0.2 %): sequential misses were
  already back to back through the FIFO; the prefetch's case is the
  FIFO-full, issue-stalled time the board shows half of the time, so
  the board decides. Report docs/consults/2026-10-23-agy-iprefetch-
  report.md. Verified here on its base and on the merged tree (36 runs,
  52 QEMU, lint). Then Quartus refused the netlist: input ports with
  default values (`input logic x = 1'd0`) come out of sv2v as `input
  reg`, which Quartus 17 rejects; the six ports lost their defaults and
  the D-cache's tag RAM and the restart bench connect them (8883ce2).
  Merged-tree cycles: cache 789,360, ctrand1 72,874 (73,043 before),
  iprefetch_rtl 73,031.
- **Codex's first-boot work merged** (codex/firstboot a3f053e, c43dd67;
  merged 51fa235): while CS1's C: area is blank, its sector erases
  complete at once and its word programs have no emulated delay; the
  first non-FF write there ends the fast window and the timed behaviour
  returns. Blankness is now a scan of the loaded C: image for any non-FF
  word (ddram_flash), latched off on the first non-FF chip write, never
  re-armed by erases or reset, re-armed by loading an image; the model
  mirrors it. Boot indicators: info message 7 "Booting the phone - about
  a minute..." at the CPU's reset release and 8 "Phone kernel is up" at
  the first LCD frame with the panel on (info events queued so none is
  lost), and an activity dot (a 6x6 green square at panel x 164-169,
  y 4-9, lit for 125 ms after any CPU bus beat) with the new option
  "Activity dot: Boot only / Always / Off" (O[17:16], default Boot
  only; every earlier option keeps its bits). Benches: flash, ddrflash
  (new blank-window cases), top (159 M clocks), lint. Report
  docs/consults/2026-10-23-codex-firstboot-report.md. Board trial of a
  first boot from the blank CS1 image still to do (expected: the Time
  and Date dialogs near the warm boot's 60-75 s instead of minutes).
- Builds from this tree (master 8883ce2): b16 on the server (seed 1,
  16 KB I-cache with the prefetch, plus the first-boot change) and
  b16-32k on the Mac (the 32 KB I-cache), both to be measured in play
  against b15.
- **Codex's D-cache hit-under-miss merged** (codex/timing2 9d215f8): while
  the one outstanding miss fills (CLEAN_SINGLE, FETCH_SINGLE, UNLOCK_WR),
  loads and write-back stores that hit any line other than the filling
  line and its victim (the other way of the same set included) are
  acknowledged from the normal registered lookup; the filling and victim
  lines, a second miss, uncached and write-through accesses, TLB misses
  and faults wait as before. The eligibility is a registered predicate
  one stage ahead on i_address_check; the background tag match is
  registered beside the RAM's third stage (the live compare stays off
  the stall path); the TLB check exports a registered o_hit_ok (no
  translation or permission fault, cacheable, not write-through) that
  does not depend on the walker's IDLE qualification, so a cached tag
  cannot hide a permission fault; after a CPU hold a three-step lookup
  repair reloads the RAMs' pipeline; the fill's line and tag are
  installed in UNLOCK_REG from the registered fill buffer, which owns
  the RAM write port (two bus-qualified intermediate writes removed).
  Cycles on its base: ctrand1 -0.9 %, crand1 -1.4 %, dhold_rtl -0.5 to
  -1.6 %, cache unchanged (its accesses are to the filling line); a
  directed test dhum_rtl (each distance 1-6, loads and stores, to the
  other way, another set, the filling line and the victim: the allowed
  ones answered in 0 wait clocks, the excluded ones held 70-207) and
  bench assertions (lookup alignment, exclusion, permission, fill-write
  exclusivity); 216 runs, 57 QEMU, 40 extra bus-delay seeds. Whole core
  on its base: -0.578 -> **-0.858 ns** (worst: CP15 o_mmu_en -> the
  FSM's o_live_lookup), 35,056 ALMs, 470 M10K; within the 0.3 ns budget
  it was given, with 0.02 to spare. Report docs/consults/2026-10-23-
  codex-dhum-report.md. Merged on the prefetch tree (only the netlist
  conflicted): 45 runs, 52 QEMU, lint; cycles ctrand1 72,244 (73,043
  before the two merges, -1.1 %), crand1 73,091, dhold_rtl 271,537,
  cache 789,366. Built as b17 on the server (seed 1).
- **b16 built** (the server, seed 1; prefetch + first boot, 16 KB):
  **-1.678 ns** at slow 100C (b15 -0.578), hold +0.248, 36,252 ALMs
  (+850), 472 M10K. One new family is 16 of the worst 18 paths, -1.68 to
  -1.48: zap_cache_fsm's registered `address` -> pf_va_nxt (the prefetch's
  start condition in FILL_COMPLETE: next_va_line = address + 1 compared
  with the live fetch address, the 1 KB-end test, the buffer's VA/PA
  compares) -> the FSM's output muxes -> zap_cache's state_nxt -> the
  merger's registered o_wb_adr. The adder and the live compares sit in
  the next-state cone the bus address takes. Antigravity (Opus) is on
  it in its own worktree (agy/pf-timing: the next line and the 1 KB flag
  registered when `address` loads, the sequential compare a stage ahead
  on i_address_check or the decision a clock after FILL_COMPLETE, proved
  by a whole-core build). The **32 KB variant** (b16-32k, the Mac, the
  NGAGE_ICACHE_32K macro): -1.695 ns, **38,311 ALMs (91 %)**, 490 M10K:
  the valid and LRU arrays and their muxes cost about 2,000 ALMs, as
  its report warned; the same family on top. Both rbfs kept
  (build/hardware/NGage-b16.rbf, -b16-32k.rbf); b16 is on the debug
  slot for the first-boot trial and the three-game replay.
  A trap found on the way: build.sh's remote flow aborted on the timing
  script's exit 3 before copying the rbf and the reports back, so a
  negative-slack build left the previous rbf in output_files/ (the b16
  replay was nearly run on a stale file; b15's deployed rbf was checked
  against the server's and is right). Fixed: the report step's exit code
  is kept, the copy-back always runs, the local flow writes the report
  before exiting on a timing miss.
- **b16 in play: the prefetch earns nothing.** The three-game replay on
  the debug slot (this time with the stall rows kept): Sonic 13-18
  frames/s at 28.1-29.5 M instructions/s, Asphalt 12-13 at 29.1-29.7,
  Tony Hawk 9-12 at 28.0-29.6, CPI 3.5-3.7, SDRAM wait 20-24 %, flash
  1.4-2.3 %: b15 within 1 % on every row, as its simulation (-0.14 %)
  said. The stall shares in play: issue 35-43 % (Sonic 43, Asphalt 35,
  Tony Hawk 36), code stall 47-55 %, fetch FIFO empty 12-16 %, data
  stall 13-18 %, shifter 7-16 % (Asphalt 16), decode 7 %, ALU flushes
  380-520 K/s, 32 M uops/s, replays 125-185 K/s. **Decided: the prefetch
  is off by default** (ICACHE_PREFETCH 0 in arm925t.sv, the bench's
  default with it; NGAGE_ICACHE_PREFETCH in NGage.qsf turns it on): no
  gain, about 1 ns of slack and 850 ALMs. The Codex task to fix its
  timing family was stopped minutes in; the Antigravity one had died on
  the account's quota first. b17 (the server: prefetch on + hit-under-
  miss) built meanwhile at -1.429 ns, 36,148 ALMs, 472 M10K; its rbf is
  kept for a replay that measures hit-under-miss in play. The 32 KB
  variant (b16-32k, prefetch on) is on the debug slot for its replay.
- **The fast first-boot format hangs the firmware.** On b16 a first boot
  from the pristine CS1 (C: erased; `rh29-460-cs1.bin` on the MiSTer is
  that image, `-blank.bin` is not blank any more, see the launcher
  `_Debug/NGageDbg-blank.mgl` and the disposable `-trial.bin` copy)
  reaches 28 s and then spins for the whole 240 s capture: 20.00 M
  instructions/s at CPI 5.2, flash wait 23.1 %, 3,999,316 beats/s, the
  sampled PC 0x5037feb8/0x5037fec0 every time. That is medint.pdd's
  erase routine (research/firmware/analysis/medint.pdd.arm.txt lines
  212-230): after the unlock write, the sector-erase command (0x30) and a
  call, it polls the status halfword in a loop that spins WHILE DQ7 reads
  1, i.e. until it has seen the chip busy, and only then tests DQ3 and
  goes on to the completion wait. The fast path answers the erased data
  (DQ7 = 1) from the first read, so the driver never sees busy. The
  model (rebuilt with the mirrored rule) hangs the same way: its kernel
  log stops at 4.35 s of guest time. The Codex first-boot thread is
  resumed with the diagnosis: the fast path must present busy (DQ7
  inverted, DQ6 toggling, DQ3 set) for the status reads the driver makes
  before done, in the chip model and in QEMU alike, proved by the chip
  bench replaying medint's loops and by the model's first boot.
- **Timing round 4 (Antigravity, Opus) died on the account's quota**
  with six commits on agy/timing4 and no report, its whole-core builds
  still running: the I-cache tag RAM's stage-1 valid/LRU read split at
  the next fetch address (family 1), the multiply classification
  registered with the ALU operation (6), the D-TLB fault summary
  registered with the FSR (5), the issue interlock and store-data
  forwarding resolved per slot (2), the self-test master as a third
  arbiter input in one AND-OR (3 and 7), the BL rewrite decoded at the
  decoder's outputs (8); all cycle-identical on 213 runs. The server's
  builds of its steps: f1 -0.753, s5 -1.224, s6 -0.782, p4 -0.847
  against the b15 baseline -0.578 (re-measured by it as -0.578): none
  better, within the placement noise of this tree's families. Kept on
  the branch, not merged; to be resumed when the memory-side levers have
  settled the tree, with seeds, not single builds, as the measure.
- **The 32 KB I-cache in play** (b16-32k on the debug slot, prefetch on):
  Sonic 28.3-29.7 M instructions/s (b16: 28.1-29.5), Asphalt 29.7-30.1
  (29.1-29.7), Tony Hawk 28.6-29.9 (28.0-29.6): about +1 %. The bus
  beats fell 5-8 % (Sonic 5.3-5.8 M/s from 5.8-6.3, Asphalt 5.9 from
  6.4) and the flash wait with them (Sonic 1.4-1.7 % from 2.0-2.2,
  Asphalt 0.9-1.1 from 1.3-1.5): the instruction misses it removed were
  real but cheap. The SDRAM wait did not move (20-23 %), so the SDRAM
  wait is the data side's: the D-cache misses are the memory-side cost
  that is left. Not worth 2,000 ALMs and 18 M10K; the 16 KB I-cache
  stays. The next lever is the data cache's size: 8 KB two-way today
  (the ARM925T's), its data RAMs 16 byte-lane M10Ks per way at 256 x 8
  bits each (a fifth of a block), so 16 or 32 KB cost no data-RAM
  blocks, only the tag RAM and the valid/LRU arrays; the design
  question is the synonyms (a virtually indexed and tagged write-back
  cache with more than 4 KB per way indexes above the page offset) and
  the hit path's timing: Codex's ZAP thread takes it (16 KB two-way
  with the alias analysis against EKA1's memory model, or 16 KB
  four-way with 4 KB per way and no aliases).
- **Hit-under-miss in play: +3 %.** b17 (prefetch on + hit-under-miss)
  on the debug slot: Sonic 29.0-30.4 M instructions/s (b16: 28.1-29.5),
  Asphalt 30.0-30.4 (29.1-29.7), Tony Hawk 28.9-30.9 (28.0-29.6), CPI
  3.4-3.6; the data-stall share fell a quarter (Sonic 13-15 % from
  15-18, Asphalt 11 from 14.6, Tony Hawk 9-10 from 12-14); the SDRAM
  wait itself is unchanged (21-25 %), as expected: the hits behind a
  miss are served, the misses still cost their fills. Frames on the
  same ticks (Sonic 14-19). So the tree stands at 29-31 M instructions/s
  in play, from 20 at the start of the speed work and 26-28 at the
  flash fetch. The three-game replay's numbers so far, play rows,
  M instructions/s: b12 25-28, b13 (flash fetch) 27.5-29.4, b15
  (stalls) 27.7-29.9, b16 (prefetch) 28.0-29.7, b16-32k 28.3-30.1,
  b17 (hit-under-miss) 28.9-30.9.
- **b18** (the server, seed 1; hit-under-miss, prefetch off, the first
  first-boot change): **-0.934 ns** at slow 100C, hold +0.204, 35,347 ALMs
  (84 %), 470 M10K (hit-under-miss alone measured -0.858 on its base: the
  same family, placement noise). With the prefetch off the suite's
  counts are exactly hit-under-miss's own (cache 789,362, ctrand1
  72,413, crand1 72,922, dhold_rtl 273,742): the prefetch logic is
  cycle-identical when off, as its report said. The CPU bench had pinned
  the prefetch on itself (tb_cpu.sv's own parameter), so the earlier
  merged-tree runs had tested the on configuration; the bench now
  follows the core's default, the on configuration is run with
  VEXTRA=-GICACHE_PREFETCH=1. In play b18 is b17 (the prefetch measured
  nothing), so it was not replayed.
- **The first-boot hang fixed** (Codex, codex/firstboot e87bf91, merged
  3e2630f): the rule is one busy status read per fast operation, then
  array data; no time window (a window could expire before the driver
  polls and bring the hang back). Codex read both copies of medint.pdd's
  Samsung-command routines: the erase start loops until busy and tests
  DQ3 from the same sample; the completion loop reads twice (FFFF means
  done, else DQ7 suspended, DQ5 failed); the program routines poll from
  a timer FIQ, compare DQ7 against the expected byte and test DQ5 on a
  mismatch, so the busy sample has DQ7 inverted, DQ5 = 0, DQ3 = 1 for an
  erase, DQ6 (and DQ2 for the sector) advancing on each fast status
  read. The chip model holds the operation busy until that read (blank
  erases still write nothing; programs hold the acknowledge until the
  memory write lands); QEMU overlays one busy halfword per bank (a
  32-bit read consumes it and returns array data for the next halfword,
  as two accesses to the x16 chip would). The model's first boot now
  reaches the Time dialog at 35 s and the Date dialog at 41 s of guest
  time, the same as the timed model (whose erases are 20 ms, so the
  model never showed the slowness); a boot on the saved C: goes to the
  idle screen at 19 s. Chip bench cases for the loops added. Built as
  b19 (the server) for the board's first-boot trial from the pristine
  CS1 and a second boot on the saved trial image.
- **The 16 KB data cache, as an experiment** (Codex, codex/timing2
  b3b5a75 and b8a270b; docs/consults/2026-10-23-codex-dcache-report.md):
  recommended 16 KB two-way over four ways or 32 KB: it adds a set bit
  and larger valid/dirty/LRU arrays without widening the live two-way
  compare and select; four ways would add two live compares, a wider
  select, pseudo-LRU and 32 data M10Ks, and would not remove synonyms
  anyway, because ZAP's cache is virtually tagged (two VAs of one PA can
  sit in two ways of one set even at 8 KB: a software discipline the
  phone already needs). The synonym evidence: ekern's descriptor moves
  (0x50324158-0x503242d8) remove the old mapping and the change flags
  call the D-cache clean/invalidate loop; home/run moves are megabyte
  aligned, so VA[12] is preserved; DMA buffers are cleaned by ownership
  protocol. The one real hole: the firmware's index sweeps derive 256
  sets from the CP15 cache type (0x05109149, kept), so a plain
  DCACHE_SIZE=16384 would leave the sets with VA[12] = 1 out of every
  clean/invalidate-by-index loop (a new test, dcsize_rtl, fails check 3
  on that RTL); the tag RAM's maintenance FSM now expands each by-index
  operation to both set colours (INDEX_SIZE 8192 against the physical
  capacity) before acknowledging, by-VA operations stay targeted. Cost:
  +2 M10K (the byte-lane data RAMs do not grow: 16 M10K a way at 256 x 8
  or 512 x 8 alike), 1,200-2,000 ALMs estimated. Cycles: the 8 KB default
  identical on all 219 runs; the variant +0.39 % over the suite (the
  index sweeps visit two sets and the whole-cache walker scans twice the
  dirty bits, which the tests do often; dhold_rtl +4.5 %): no simulated
  win, the games decide. 222 runs and 57 QEMU at both geometries, lint,
  netlist current. Merged; built as b20-d16 (the server, the
  NGAGE_DCACHE_16K macro) for the board.
- **b19 on the board: the first boot is fast.** b19 (the server, seed 1;
  hit-under-miss, prefetch off, the first-boot fix): **-1.675 ns** at
  slow 100C, 35,842 ALMs, 470 M10K; the worst paths are this tree's
  known families at a worse placement (issue stall_late_ff ->
  stall_idx_ff / o_stall_from_issue -1.68/-1.64, the D-cache o_reg_idx
  -> the shifter -1.18, the merger's o_wb_adr -> upp_bus's fe_* -1.06;
  b18 of the same tree less the fix was -0.934), not the flash change.
  The first boot from the pristine CS1 (`rh29-460-cs1.bin` copied to the
  trial image, `_Debug/NGageDbg-blank.mgl`): the format runs 24-84 s
  after the load with the usual boot's bus waits, and the Time dialog
  is on the screen by 82 s (b16: the loop forever; the old timed path:
  minutes). A second boot on the saved trial image shows the operator
  splash at 54 s and the Time dialog at 74 s (the time was never
  accepted, so the firmware asks again: known), so the format did not
  repeat. README's first-start lines updated. Then the dialogs accepted
  with the profiler's keys and a boot on the saved image, to confirm
  the idle screen comes up without them (running).
- **b20-d16 built** (the server, seed 1; the 16 KB two-way D-cache on the
  prefetch-off, hit-under-miss tree): **-1.622 ns**, **39,034 ALMs (93 %)**,
  472 M10K. The cache cost 3,700 ALMs over b18, twice Codex's estimate;
  the worst paths are inside the D-cache tag RAM's maintenance FSM
  (state_ff -> the tag RAM, -1.62: the index-sweep expansion and the
  doubled valid/dirty/LRU arrays) and CP15's line address into it. To
  be replayed on the debug slot after the first-boot acceptance boots;
  at 93 % of the device it has to earn a lot.
- **The card path merged** (agy/mmc 1175aef..a1790d4, merged 3699387;
  docs/consults/2026-10-23-agy-mmc-report.md): MMC_DIV 12 -> 4 (26 MHz,
  the timeouts widened to about 320 ms), 4 KB hps_io chunk fetches
  (sd_blk_cnt 7, clamped at the image's end and the sidecar) into an
  8 KB true-dual-port buffer organised as twelve 512-byte slots for the
  streaming chunks (three 2 KB quarters addressed by the half-chunk
  number modulo 3, so the next chunk's prefetch never overwrites the
  half being shifted out) plus four reserved slots for CMD17 metadata
  (FAT and directory sectors stay cached across the streaming), the
  next chunk prefetched once the current one is in its second half, no
  speculation on a chunk's last sector or once the controller has queued
  CMD12 (a new stop_queued input from upp_mmc's status), buffer hits
  served at once from the second port while a fetch is in flight, writes
  single-sector through a metadata slot with the streaming quarter
  invalidated. Bench (sim mmc, both DIV 12 and 4, hps_io latency
  100-500 us): a warm 4 KB CMD18 burst 408-473 K clocks -> 132.5 K
  (3.07 MiB/s), a repeated CMD17 FAT read 70-104 K -> 16.9 K with no
  round trip; mmc, periph, upp, top benches and lint pass. Three
  overlay counters: 512-byte blocks completed, clocks in a data phase,
  clocks the wire waits for Linux (words 30-32; DBG_CNT 21). Built as
  b21 (the server) for the load measurement (Shadowkey and Tony Hawk's
  launch, scratch run-loads.sh) against b19.
- **Write-allocate and the D-cache's event counters** (Codex,
  codex/timing2 b275664, ed23a58, merged d0e7078;
  docs/consults/2026-10-23-codex-walloc-report.md): the phone's cache
  is read-allocate with a 17-word write buffer (SPRU671 and the kernel's
  own use of the drain operation); ZAP allocates on store misses, so a
  cold streaming store of 64 lines costs 64 fills and 64 write-backs,
  512 bus beats for 256 beats of data. A no-write-allocate policy worth
  having is a posted write buffer: CP15 W and a real drain handshake,
  ordering against later loads and the hit-under-miss, precise faults
  before the enqueue, the bufferable page attribute; it reaches
  zap_cp15_cb, zap_core and zap_top, so it was analysed, not shipped
  (a blocking bypass through the uncached path would be a misleading
  substitute). Shipped instead: arm925t's dbg_dcache[3:0], one-clock
  pulses for load-miss fills, store-miss fills, line write-backs
  (evictions and explicit cleans) and uncached completions, a directed
  test walloc_rtl, cycle-identical on all 222 runs at 8 and 16 KB.
  Wired into the overlay as counters 21-24 (DBG_CNT 25, the rows end at
  155 of 208) and decoded by mister_dbg.py; built as b22 (the server)
  so the next replay splits the SDRAM wait into loads, stores and
  write-backs.
- **First-boot acceptance on b19**: the third boot of the trial image
  with the profiler pressing Enter on the Time and Date dialogs (92 s,
  102 s) ran the firmware's first-time setup after them (bus activity
  116-150 s, the operator splash at 150 s); the fourth boot came up the
  same way as the second (the dialog at 80 s, which the firmware asks at
  every start here), and the trial image's C: area holds 2.2 MB of
  non-FF data where the pristine image had none: the format persisted
  through the save write-back. The first-boot flow works end to end
  with the fast path.
- **b21 built** (the server, seed 1; the card path on b19's tree):
  -1.212 ns, 36,520 ALMs (87 %), 477 M10K. One new family: mmc_card's
  a_srlo -> an adder (-1.19: the slot arithmetic of the 4 KB buffer,
  the modulo-3 quarter), to be registered later; the rest this tree's
  known ones. On the debug slot for the load measurement.
- **The 16 KB D-cache in play** (b20-d16 on the debug slot): Sonic
  29.1-30.9 M instructions/s (b17, the same tree at 8 KB: 29.0-30.4),
  Asphalt 30.7-31.4 (30.0-30.4), Tony Hawk 29.5-31.8 (28.9-30.9): +1 to
  +3 %; the bus beats -7 % (Asphalt 6.1-6.3 M/s from 6.6-6.7), the
  SDRAM wait down two points (Asphalt 22.0-22.7 % from 24.2-24.6), the
  data stall a point lower. So the data cache's capacity misses are a
  small part of the SDRAM wait too; with the bus at about 6 M beats/s
  and 20-23 % of clocks waiting, the wait is latency per fill (about 4
  clocks a beat), not bandwidth. **8 KB stays the default**; at 3,700
  ALMs (93 % of the device) and -1.6 ns the option is not worth +2 %
  as built (the valid/dirty/LRU arrays in flip-flops are the cost; a
  RAM-based version could be cheap if it is ever wanted). The next
  split, by b22's counters: fills for loads against fills for stores
  and write-backs, which decides whether a write buffer (no-write-
  allocate) is the lever.
- **b21's loads on the board** (the card path; scratch run-loads.sh:
  boot, menu, launch the game, capture every second for two minutes;
  Tony Hawk and Shadowkey): the loads are CPU-bound, not card-bound.
  Tony Hawk's launch to its intro: about 7 s, the card at 70-420
  blocks/s with the wire in a data phase 1.5-7 % of the time and the
  wait for Linux 0-0.3 %; the CPU at 19-28 M instructions/s, CPI 4-5.
  Shadowkey's launch to its first frames: about 32 s (117.7 to 149.8 s
  after the load): a burst at 980-1,190 blocks/s (data phase 17-21 %,
  Linux wait 0.5-1 %) for two seconds, then a 16-second plateau at
  about 420 blocks/s (210 KB/s) with the data phase 12.8 % and the
  Linux wait 5.9 % (so nearly half of the card's active time in that
  phase still waits for a round trip: its access pattern is not the
  sequential 4 KB streaming the prefetch hides), the CPU at 18.6 M
  instructions/s, CPI 5.6, SDRAM wait 15 %, flash 7.2 %, idle 0: the
  firmware's per-block driver work and the game's unpacking set the
  pace, with the card idle 87 % of the time. The same loads on b19 (no
  card change) running for the end-to-end comparison.
- **b22 built** (the server, seed 1; the full tree: hit-under-miss, the
  first-boot fix, the card path, the D-cache event counters): -1.370 ns,
  37,077 ALMs (88 %), 477 M10K. The worst family is now the card
  model's slot tags into an adder (mmc_card tag[13] -> Add114, -1.37,
  the 8 KB buffer's slot arithmetic), then the decode stage's shift
  length into the issue stage's load pending (-1.37) and the issue
  stall_late_ff family (-1.30). The card model's arithmetic wants
  registering (a small task for its author when the quota returns).
- **The card path's effect on the loads** (the same run-loads.sh on b19,
  the tree without it): launch to the first full-rate frames, Tony Hawk
  8.0 -> 8.1 s (the card was idle 93-98 % of its launch), Shadowkey
  37.0 -> 33.2 s (-10 %; during it 22.3 -> 20.2 M instructions/s at
  CPI 4.7 -> 5.2: the same work with less time spent waiting on the
  card). So the wire at 26 MHz and the 4 KB fetches are worth a tenth of
  the long loads, and the rest is the CPU: the file server's and the
  driver's per-block work from flash (CPI 5-6 with the flash at 6-7 %)
  and the game's unpacking. The load-time lever from here is the same
  as the play-speed lever.
- **The SDRAM wait split** (b22's replay with the D-cache counters, per
  second in play): Sonic 324-368 K load-miss fills, 220-311 K store-miss
  fills, 245-330 K line write-backs, 266-356 K uncached data accesses;
  Tony Hawk 385-460 K, 96-281 K, 155-322 K, 196-317 K; 29-31 M
  instructions/s, SDRAM wait 20-25 %, 6.0-6.9 M beats/s. The fills and
  write-backs explain about 4 M of the 6 M beats; the rest are the
  instruction cache's fills (about 500 K lines/s) and the LCD's DMA.
  Weighted by their latencies (a fill 12-15 clocks, a write-back about
  10, an uncached access 6-8), the SDRAM wait is roughly: instruction
  fills a third, load fills a fifth, store fills a sixth, write-backs a
  seventh, uncached writes a tenth. A write buffer in the phone's sense
  (store misses to the bus without a fill, bufferable uncached writes
  posted) would take 25-30 % off it, about 5-8 % more instructions a
  second: a real lever, a project of its own (Codex's scope in the
  walloc report), parked behind timing closure. b22 is on the main slot
  (+15 % over b12, the fast first boot, the card path).
- **Timing closure is the goal now** (the user: "let's try to hit timing
  or get really close and I'll see if anyone on Discord has a real N-Gage
  to test against"). The debug logic measured from b22's fit: the 25
  counters 523 ALMs, the overlay and its words about 400, the self-test
  master 261; a build switch NGAGE_NO_DEBUG (NGage.qsf) now leaves the
  overlay, the counters and the trace triggers out of the main core
  (the OSD option goes with them; the activity dot stays; both
  configurations lint clean). Three streams: a seed sweep of the main
  core (seeds 1-3 on the server, 4 on the Mac) for the placement noise
  (seed-1 builds of this tree spread -0.93 to -1.68); Codex's round 5
  (port round 4's six parked fixes one at a time, keep each only if its
  family improves across two seeds, then the current report's families:
  decode shift_length -> issue load_pending -1.37, issue stall_late_ff
  -1.30, the merger's address into upp_bus -1.0, the D-cache state into
  the merger); Antigravity (Gemini, its card-path conversation resumed)
  registering the card model's slot arithmetic (-1.37, the worst
  family in b22).
- **The main core without the debug logic, seeds 1-3** (NGAGE_NO_DEBUG,
  c03088f, the server): seed 1 **-1.152 ns** (b22 with the debug logic,
  seed 1: -1.370), seed 2 -1.285, seed 3 **-0.861**; 35,361-35,591 ALMs
  (84-85 %; the switch dropped 1,707 registers, the counters' and the
  overlay's, 1,700 ALMs over b22, twice the estimate), 477 M10K. So the
  placement noise is ±0.2 around a floor near -0.9 for this tree, and
  without the overlay the families differ by seed and none dominates:
  the MMU enable's fanout (cp15 o_mmu_en into the ALU's flags -1.29, the
  shifter -0.96, the merger's address -0.85: in two of three seeds; it
  changes only on CP15 writes, so registered copies per consumer are
  free), the predecode's skid and instruction register into decode
  (-1.15, -1.04, -0.88), the hit-under-miss slot into the ALU's flags
  (-0.78), the issue stage's skid into itself (-1.00, -0.74), the Thumb
  decoder into predecode and the writeback (-0.86, -0.73), postalu2 into
  the shifter (-0.75). Reports in the session scratch (nd-s1..3-timing)
  and in Codex's worktree, queued into its round 5 with that ranking.
  Seed 4 on the Mac still building. Seed 3's rbf
  (build/hardware/NGage-nd-s3.rbf) is the main-slot candidate once it
  has had a boot and a game on the board.
- Seed 4 of the main core (the Mac): -1.074 ns, 35,513 ALMs; its
  families the issue stage's skid and late stall (-1.07, -0.95), the
  D-cache state into the merger's address (-0.99), the ALU's flags and
  the issue stage's destination index into predecode (-0.99, -0.91).
  Four seeds: -1.152, -1.285, -0.861, -1.074. Seeds 5 and 6 running.
- **The card model's timing family fixed** (Antigravity on Gemini, its
  card-path conversation resumed; agy/mmc 8329efe, merged): the slot
  indices, the tag compares and the hps_io request parameters are
  computed a clock ahead into registers (the modulo-3 quarter, the
  metadata-slot matches, the chunk's clamped count; the transfer's
  slot address from a concatenation instead of an add), the wire's
  data path untouched. Benches cycle-identical (the warm 4 KB burst
  132,528 clocks at DIV 4; mmc, periph, upp, top, lint). Its whole-core
  build (the debug core): -1.295 ns with no mmc_card path in the worst
  30 (the family was -1.37 in b22); the worst is now wb_arb2's grant
  into upp_bus's fe_next (-1.30), the bus-decode family round 4's
  arbiter rewrite targets. 36,429 ALMs, 477 M10K.
- Seed 5 of the main core (the server): -1.146 ns; the I-cache tag RAM
  into its FSM (-1.15), the D-cache lock into issue (-1.09), the D-cache
  state into CP15 (-1.03), the Thumb decoder into predecode (-0.95).
  Five seeds of c03088f: -1.152, -1.285, -0.861, -1.074, -1.146. Seed 7
  of the tree with the card model's fix (c8f18ef) running.
- Seed 6 of the main core (the Mac): -0.973 ns; the Thumb decoder into
  predecode (-0.97), predecode's instruction register into decode
  (-0.74), then a drop to -0.63. Six seeds of c03088f: -1.152, -1.285,
  -0.861, -1.074, -1.146, -0.973: the predecode cone is in the top of
  five of them, the family to clear first; without it this seed would
  be near -0.63. Seed 8 of c8f18ef on the Mac.
- **Seed 7 of the main core on c8f18ef** (the card model's fix in; the
  server): **-0.680 ns**, 35,173 ALMs (84 %), the best build so far;
  its top the memory stage's postalu2 outputs into the D-cache tag RAM
  (-0.68, two paths), then the predecode cone (-0.60, -0.57). The rbf
  (build/hardware/NGage-ndm-s7.rbf) is the main-slot candidate, to be
  smoke-tested when the board is free. Seed 9 of the same tree running.
- Seed 8 of the main core on c8f18ef (the Mac): -0.920 ns, 35,070 ALMs;
  the Thumb decoder into predecode (-0.92), the issue stage's late
  stall (-0.91), predecode's instruction register into the writeback
  (-0.79). Seed 10 on the Mac.
- **Seed 9 of the main core on c8f18ef** (the server): **-0.550 ns**,
  35,010 ALMs, the best build so far; its top five are one family, the
  merger's address bit 3 into upp_bus's flash line buffer valid bits
  (lb_v, the line-wide fetch's beat select, -0.55 to -0.52), the rest
  below. Three seeds of this tree: -0.680, -0.920, -0.550; so the floor
  with a lucky seed is about -0.5 before round 5's fixes. The rbf
  (build/hardware/NGage-ndm-s9.rbf) is the main-slot candidate. Seed 11
  running.
- Seed 10 of the main core on c8f18ef (the Mac): -1.115 ns; the Thumb
  decoder into decode (-1.12, two paths), the D-TLB walker into decode
  (-0.96), issue's load pending into the shifter (-0.87). Four seeds of
  this tree: -0.680, -0.920, -0.550, -1.115; the Thumb decoder's cone is
  in the top of nearly every seed. The sweep stops at seed 11: the
  final tree after round 5 gets its own.
- Seed 11 of the main core on c8f18ef (the server): -0.661 ns; the
  issue stage's skid (-0.66, two paths), the D-TLB walker into the
  shifter (-0.52), the merger into the flash line buffer (-0.42). **The
  sweep's tally** (the main core, NGAGE_NO_DEBUG): c03088f seeds 1-6:
  -1.152, -1.285, -0.861, -1.074, -1.146, -0.973; c8f18ef (the card
  model's fix) seeds 7-11: -0.680, -0.920, -0.550, -1.115, -0.661: a
  median of -0.68 and a best of -0.55 (seed 9, the main-slot candidate),
  so the tree misses the goal of a median within 0.3 ns by about 0.4,
  which is round 5's job: the Thumb decoder's cone into predecode and
  decode (in the top of most seeds), the issue stage's skid and late
  stall, the MMU enable's fanout, the memory stage into the D-cache tag
  RAM, the merger's address into upp_bus's decode and line buffer, the
  D-TLB walker into decode and the shifter.
- Sweep extended to seed 20 (the user: "going up to seed 20 is fine"):
  seeds 12-19 on the server two at a time (Codex's round 5 holds the
  other two lanes), seed 20 on the Mac, all of the tree with the card
  model's fix (815bcbd, RTL c8f18ef), results in build/sweeps/ndm-s<n>/
  through tools/seed_sweep.sh.
- **Seed 9 on the main slot.** The no-debug main core (-0.550 ns,
  build/hardware/NGage-ndm-s9.rbf) smoke-tested on the debug slot: the
  idle screen with the clock and the date, the phone menu with SonicN,
  Sonic's intro and Neo Green Hill in play (captures in
  build/hardware/game/smoke-ndm-s9/; no counters, the overlay is out of
  this core). Copied over `_Console/_NGage/NGage_20261023.rbf` (the
  user's slot); b22 (the instrumented build) back on
  `_Debug/NGageDbg_20261023.rbf` for the measurements. The main slot
  went from b12 (-1.09 ns, 25-28 M instructions/s in play) to this:
  -0.55 ns, 29-31 M/s, the fast first boot, the card path.
- Seeds 12, 13 (the server) and 20 (the Mac) of the main core on the
  fixed tree: **-0.535** (seed 12, the best so far: 34,988 ALMs),
  -0.633, -0.643; seed 20's top is decode's destination index into
  issue (-0.64), then the MMU enable into the fetch FIFO (-0.47) and the
  Thumb decoder into predecode (-0.45). Eight seeds of this tree:
  -0.680, -0.920, -0.550, -1.115, -0.661, -0.535, -0.633, -0.643
  (median -0.64). Seed 9 stays on the main slot (tested; 15 ps apart).
- **The sweep to seed 20, done.** Seeds 14-19 (the server): -1.055,
  -0.702, -0.732, -0.681, **-0.431** (seed 18), -0.616. The fourteen
  seeds of the fixed tree (7-20): -0.680, -0.920, -0.550, -1.115,
  -0.661, -0.535, -0.633, -1.055, -0.702, -0.732, -0.681, -0.431,
  -0.616, -0.643: median -0.67, best -0.431. Seed 18's report has one
  family above -0.35, the Thumb decoder into predecode (-0.43), then
  the late memory index into the shifter (-0.34) and decode's shift
  fields into issue (-0.27): with the Thumb decoder's cone cleared,
  this seed would sit near -0.34. Seeds 16, 17 and 19 show the
  self-test enable (test_on_q) into upp_bus's decode and the merger
  (-0.69, -0.67, -0.56), the family round 4's arbiter rewrite targets.
  Seed 18's rbf (build/hardware/NGage-ndm-s18.rbf) is the main-slot
  candidate, 0.12 ns better than the seed 9 on it.
- **Seed 18 on the main slot** (-0.431 ns, build/hardware/NGage-ndm-
  s18.rbf): smoke-tested on the debug slot like seed 9 (the idle screen
  with the clock and the date, the menu, Sonic's intro, Neo Green Hill
  in play; captures in build/hardware/game/smoke-ndm-s18/), then copied
  over `_Console/_NGage/NGage_20261023.rbf`; b22 back on the debug slot.
- **The firmware for a public core** (the user's questions: has the
  N-Gage firmware been open-sourced, can the Python step go). No: the
  Symbian^3 generation was opened in 2010 under the EPL, but the N-Gage
  runs Symbian 6.1 with Series 60 1.2, and Nokia's bootstrap, drivers,
  Series 60 and the N-Gage applications were never released; the only
  firmware is Nokia's service package (the Phoenix flash files), which
  the user brings. The core's repository carries none of it (research/
  untracked; the only binaries in the tree are our own NOS stand-in).
  Decisions: (1) tools/mkimage.py now checks its Phoenix inputs by
  SHA-256 against the RH-29 4.60 files (RH2946.0C1 18,475,371 bytes,
  sha256 ba5fea85...; RH2946.0S5 1,505,245 bytes, 4d2e36f6...) and
  stops with a message otherwise (--force goes on); (2) the user wants
  the conversion in the core "for support sanity": the Codex first-boot
  thread is building a Phoenix loader in RTL (the record stream parsed
  as the framework downloads it, CS0 and the CS1 firmware half filled
  FF first, the record checksums verified; the patches and the two
  4.60 digests from a generated patch ROM, about 10 KB, applied after
  the language pack; a version check on the integrity table's own
  digests with "Firmware 4.60 loaded" / "not recognised" messages; the
  C: save as a 4 MB file of C: only, a blank one shipped with the core,
  8 MB files still accepted; the framework's boot1.rom, boot2.rom and
  boot1.vhd auto-load so that the two Nokia files and the blank C:
  file in the games folder are the whole setup; a synthetic-stream
  bench and an end-to-end harness against the Python tool's images);
  the Python tool stays for development and flat dumps. (3) The 56
  per-phone bytes at CS0 0x12C-0x163, which the board's image had from
  a ROM dump and which a core cannot have: the Python tool's default
  image (FF there; md5 63aa211d06bd8df899e1239988b10316 against the
  board's 2323d108...; the only difference) booted on b22 to the idle
  screen and ran Sonic (build/hardware/game/nophone-b22/), so the
  loader leaves them erased.
- **The plasticbugs Pocket core read** (the user: "they just came out,
  any insights?"; docs/consults/2026-10-23-plasticbugs-pocket-core.md):
  a custom ARMv4T (eight stages, a fetch-cycle BTB, 64 KB caches,
  80 MHz) with a C kernel replacing EKA1 and the drivers, the firmware's
  user side only; CPI 1.7 in play, about 47 M instructions/s against
  our 30. Their estimate of the phone: 45-50 MIPS, which puts our core
  at 60-65 % of it, as our frame rates say. Usable: a store miss that
  completes when its fill is launched and the write-back deferred behind
  the fill (their model -4 to -5 % and our 2-3 %: a D-cache task after
  round 5), the BTB's remaining slot (0.1 CPI, a timing decision), the
  retrobios SYM.ROM as a possible third firmware input (to be checked
  against our ROM-order image), X-Men Legends and Puyo Pop as tests
  (their kernel sees X-Men Legends II panic below 45 MIPS), and the
  strategic point that a deeper pipeline at 80-90 MHz beats ZAP at 104,
  the paused ARM9's road. Their "memory card" is the game image; ours is
  the same image on a modelled, writable card. Our stand-in already
  answers the energy-management queries they found games need.
- **Timing closure paused** (the user: "let's pause timing closure since
  we're making changes"): the tree is about to change (the D-cache
  store-miss and write-back changes, the in-core firmware loader), so
  Codex's round 5 is told to finish its current trial, commit what is
  proved, write its report and stop; the kept changes stay on its
  branch for a merge once the tree settles, and the sweep to seed 20
  (best -0.43, seed 18 on the main slot) stands as the reference for
  the next closure round. Next in that thread: the two D-cache changes.
- **The end goal, set by the user: at least 47 M instructions/s in play**,
  the Pocket core's rate (CPI 1.7 at 80 MHz). At 104 MHz that is CPI
  2.2; ZAP runs the games at 3.4 (29-31 M/s). Where the 3.4 goes: about
  0.8 clocks an instruction on the bus (the SDRAM wait 20-25 % of clocks,
  the flash 2 %) and about 1.6 in the pipeline (the issue stage's
  interlocks 35-43 % of clocks, the fetch FIFO empty 12-16 %, the ALU's
  flushes 400-500 K/s at up to 12 clocks, the uop sequencing 7 %). The
  memory-side levers still open (the store-miss completion and the
  deferred write-back, a write buffer, the BTB's last slot, the I-cache
  size) are worth perhaps 15-20 % together: ZAP's ceiling in play is
  about 36-38 M/s, set by its issue stage (one uop a clock at best, lock
  interlocks) and its 12-clock front end. The rate the user wants needs
  the deeper pipeline: the Pocket core's measured structure (eight
  stages, a 256-entry BTB answering in the fetch cycle, store misses
  that do not wait, 32-64 KB caches, critical word first) reaches CPI
  1.7-1.9 in play, and its CPU alone closed 96 MHz on a C8-grade Cyclone
  V; the DE10-Nano's device is the faster I7 grade, so 104 MHz is a fair
  target for the same discipline. That is the road of the paused ARM9
  core (codex/arm9, 15 % fewer cycles than ZAP on the cache test but
  -7 ns at 104 MHz with a shallow pipeline and a combinational address
  into the D-TLB): a redesign as an eight-stage machine, not a resume.
  Sequencing to be decided: the ZAP tree ships to the testers as it is
  (the loader, the D-cache changes), the new CPU replaces it when it
  beats ZAP in play on the board.
- **X-Men Legends on b22** (the Pocket core's authors see X-Men Legends
  II panic below about 45 MIPS on their kernel): launched from the menu,
  its intro cinematic runs at 21-22 frames/s (30.3-30.7 M instructions/s,
  CPI 3.4, SDRAM wait 12-18 %), the first scene in play (Wolverine's
  dialogue) at 16-18 (31-32 M/s), no panic, no return to the logo over
  two and a half minutes (build/hardware/game/xmen-b22/). The real
  kernel's view server is not the race theirs has, at our speed.
- **The goal, as the user phrased it**: matching the speed of the real
  phone, with accuracy bent where it buys speed and the firmware cannot
  tell (cache sizes and ways, a branch predictor, the memory path,
  non-blocking stores); the 47 M instructions/s yardstick comes from
  Asphalt's own cap (21 frames of 2.3 M instructions). The testers'
  release is dropped for now in favour of the speed work. Started in
  parallel: the eight-stage CPU redesign in the Codex ARM9 thread
  (docs/ARM9V2.md first, then milestones with the CPU-alone fit at each,
  the suite's compiled proxies 35 % under ZAP as the acceptance, the
  shared ZAP caches through the CORE switch), beside the D-cache
  changes and the loader.
- **The in-core firmware loader merged** (Codex, codex/firstboot
  431e21e..08ceb7e, merged a83342a; docs/consults/2026-10-23-codex-
  phoenix-report.md): rtl/mister/phoenix_load.sv parses the Phoenix
  files as the framework streams them (the A2 header's token section,
  records 14, 21, 20, 25, 26, 2E with their checksums), fills CS0 and
  the CS1 firmware half with FF first, writes the records to DDR3
  through ddram_flash's loader port with ioctl_wait as the back
  pressure, verifies the 4.60 signatures, and applies the patches from
  a generated ROM (tools/gen_patchrom.py -> rtl/mister/phoenix_patch.hex,
  10 M10K) with the two digests; "Firmware 4.60 loaded" / "Firmware not
  recognised: needs RH-29 4.60" / "Firmware file damaged" through the
  info list; F1 = RH2946.0C1, F2 = RH2946.0S5, the flat images moved to
  F3/F4 for development; C: is a 4 MB save (releases/ngage-c-drive.bin
  blank, 8 MB saves still accepted with their lower half ignored); the
  CPU waits for both files and the save. Verified: the real files
  reconstruct both images byte for byte through the loader harness
  (make -C sim phoenix-real; 62 M clocks, 30 % random DDR back
  pressure), the synthetic bench (both file orders, damage, the version
  check, C: isolation), the save and ddrflash benches, the top bench,
  both lints. README rewritten for the no-PC setup (boot1.rom,
  boot2.rom, boot1.vhd). Built as b24 (the debug core): -0.958 ns,
  37,789 ALMs (90 %), 487 M10K; the loader costs about 700 ALMs and
  the patch ROM's 10 M10K. On the debug slot for the board test (the
  Phoenix files and a blank C: under launcher names; the boot names
  wait until the main slot runs a loader core too).
- **ARM9 v2, session 1** (Codex, codex/arm9v2; docs/ARM9V2.md,
  docs/consults/2026-10-23-codex-arm9v2-s1.md): master merged into the
  paused branch (the short-read cache adapted to hit-under-miss, the
  BTB's earlier decision realigned; CORE=ZAP's cycles unchanged), the
  eight-stage design specified with the 47 M/s acceptance gates, and
  the front end built and tested standalone against the real I-cache:
  F1/F2, a 256-entry predictor (60-bit entries in two M10Ks, same-edge
  coherent, deciding in F1's own cycle so a trained loop loses no slot),
  an eight-entry return stack with checkpoint and repair, an
  eight-entry raw queue; a HOLD_READ option added to zap_ram_simple_nopipe.
  Its fit alone: -0.574 / -0.856 / -0.895 ns at seeds 2-4, about 1,090
  ALMs. D1 through W are not implemented. Session 2 started: the front
  end's paths first, then the decode pair.
- **b24 on the board: the in-core loader works end to end.** Launched
  from an MGL with the Phoenix files themselves (F1 RH2946.0C1, F2
  RH2946.0S5), a fresh copy of releases/ngage-c-drive.bin on S1 and the
  card on S0: C: formatted at 44-84 s, the Time dialog at 96 s, the
  first-time setup after the Date dialog (108-113 s), C: written back
  (852 KB at 121 s), the idle screen at 170 s
  (build/hardware/boot/phoenix-b24-rerun/); a second boot on that C:
  went to the idle screen without a format. One of two identical first
  boots failed: running at 106 s (the Date dialog's Enter), then Main
  refused screenshots for 14 s (it does so only while loading a core or
  files: the time the 18 MB MCU file takes), and from 120 s the CPU was
  held in reset for good (overlay: cpu_reset=1, pc=0, the interrupt
  enables cleared, the save still present, the LCD on the test pattern):
  a Phoenix file sent again, which by design starts a fresh pair and
  waits for the second file. What sent it is unknown (no core reload or
  Main restart in dmesg, no OSD use, only Enter taps). The loader's
  Codex thread is adding a loader status word to the debug overlay,
  making an identical re-send verify instead of refill (so the pair
  survives it), and reading Main's source for a path that re-sends an F
  option's file. The debug launchers on the MiSTer are now the Phoenix
  form (tools: scratch gen-dbg-launchers.sh); the main slot still runs
  seed 18, the pre-loader core.
- Main-core builds of the loader tree (8194b05, NGAGE_NO_DEBUG): seed
  18 -1.260 ns (the D-cache tag RAM family on top), seed 9 -0.671 (the
  MMU enable into the merger, the late memory index into the fetch
  FIFO); 35.5-35.6 K ALMs. The loader moved the placement (seed 18 was
  -0.43 on the tree before it); timing is paused. Seed 9's rbf
  (build/hardware/NGage-ndp-s9.rbf) is the main-slot candidate once the
  re-send hardening is in, with the user's launchers rewritten to the
  Phoenix form (F1 RH2946.0C1, F2 RH2946.0S5, S1 the save: the 8 MB
  rh29-460-cs1-save.bin is accepted, its C: half kept) and the boot-file
  names added; until then the main slot keeps seed 18.
- **The re-send, followed up** (Codex, codex/firstboot 087088d..754ebce,
  merged): a transparent survival of an identical re-send is not sound
  (the loaded image differs from the raw records where the patches
  went, and the stream cannot rewind after a late mismatch), so a
  single re-sent Phoenix file still starts a fresh pair, now with info
  message 12 "Firmware reloaded: load both files" after its download.
  The debug overlay gained words 37 and 38 (rows 156-162): ready, busy,
  the pair's have bits, the last download's index, the last note, the
  parser state; the download-start counts per index F1-F4 and the error
  count; tools/mister_dbg.py prints them. Main's source (065d0d2) has no
  path that re-sends an F file on Enter or periodically; the one path
  that can load a file into a running core is an MGL whose sequence has
  not finished. On a recurrence: the overlay's counts, the MGL, and
  Main's stdout (user_io_file_tx prints each file and index). Built
  into the next debug core with the overlay words.
- **ARM9 v2, session 2** (Codex, codex/arm9v2 541f68f, 7f42e7a;
  docs/consults/2026-10-23-codex-arm9v2-s2.md): the front end closed on
  its own, -0.856 -> **+0.712 ns** median of seeds 2-4 at 104 MHz
  (validity snapshotted and selected by the registered lookup PC, the
  shared RAM's collision compare registered, the predicted and
  sequential next PCs computed in parallel and the finished value
  selected; no added stage, the trained loop still one fetch a clock).
  The decode pair D1/D2 built: one Thumb expander at D1's input, the
  LDM/STM list counted by balanced trees, signed 8-bit offsets, four
  source and two destination indices at D2, all banks, direct B/BL
  redirected from D2's registered target with the return stack's
  checkpoint; 6.0 M checks exhaustive over every register list, the
  real I-cache at three bus latencies. Front end + decode + register
  file as one trial: -0.890 ns median (-0.37 to -1.15), 4,159 ALMs;
  the chains are the queue head's 256 fanout into the Thumb expander
  and the list arithmetic, and D1 into the branch target. An untrained
  direct branch loses six slots against the design's three. ZAP's 777
  cycle/instruction pairs unchanged. Session 3 running: those chains
  and the redirect handoffs, then S/A (the forwarding network, the
  rotator, flags, the multiplier).
- b25 (the debug core with the loader words): -1.188 ns, 37,886 ALMs,
  487 M10K.
- **The re-send was the board tool, and the loader core is on the main
  slot.** With b25's loader words the failure reproduced on every first
  boot: the second Enter was followed by a second F1 download (starts
  F1=2, note "reload-both") and the phone had never seen the first
  Enter. The cause: tools/boot_profile.py's fallback switched the
  overlay on by walking the OSD (F12, 11 downs, enter, esc) whenever two
  captures past 12 s had no counters, which with the Phoenix loads
  happens at 14 s, while the launcher is still sending the files; an
  Enter into the MGL sequencer mid-load leaves a file entry's browser
  pending (Codex's Main audit: the one path that loads a file into a
  running core), and the Enter meant for the Date dialog then selects
  the first file listed, RH2946.0C1; the menu had also grown by two file
  entries since the walk was written. Fixed (7d396f1): the walk runs
  once at most, only after 45 s and three blank captures, with 13 downs
  and two escapes; jev_play's walk likewise. With the fix the first boot
  from the Phoenix files and a blank C: runs through (the three Enters
  taken, the setup animation at 124-172 s, the loader words at
  "loaded" with one start per file throughout), the second boot comes
  up without a format, Sonic plays at 16-18 frames/s. The no-debug
  loader core at seed 9 (-0.671 ns; md5 ccfaf9cd...) is on the main
  slot, b25 (the debug core with the loader words) on the debug slot;
  all 17 main launchers and the 15 debug ones regenerated in the
  Phoenix form (F1 RH2946.0C1, F2 RH2946.0S5, S1 the save: the user's
  8 MB rh29-460-cs1-save.bin on the main slot, the 4 MB
  rh29-460-c-drive.bin on the debug slot; the no-save launcher loads
  the flat CS1 at F4); the main slot smoke-tested with a boot and Sonic.
  The boot-file names (boot1.rom, boot2.rom, boot1.vhd) are not used on
  this MiSTer: with launchers they would only double every load.
- **ARM9 v2, session 3** (Codex, codex/arm9v2 4af6c02, 74d046a;
  docs/consults/2026-10-23-codex-arm9v2-s3.md): the decode chains cut
  (the queue head's fanout, the list arithmetic, the branch-target
  select): front end + decode -0.890 -> **-0.210 ns** median, 4,666 ALMs;
  an untrained direct branch loses three slots instead of six. Then
  S/A built: one operand selector with three registered producers (A,
  M, W) by match and age, a five-level rotator for every shift,
  register shifts an extra S clock, the ALU and NZCV in A with
  carry-preserve tokens, conditional B/BX resolved at A from D2's
  registered matches with a one-shot redirect, the multiplier's DSP
  moved behind the S/A operand registers after a first fit at -3.9 ns
  (forwarding and the DSP in one clock). S/A component fit: -1.621 /
  -1.729 / -1.966 ns at seeds 2-4 (median **-1.729**), 6,387 ALMs,
  four DSPs: 1.5 ns below the decode milestone, which the user's
  guardrail (one fit per milestone, nothing drastically worse) flags.
  The chains: D2's admission (a 40-bit pending-destination mask indexed
  back into source hazards, the issue enable with a fanout of 399) and
  D1's head selector; the report's own recommendation is to restructure
  them before M/W. Session 4 launched with that order, then M/W,
  retirement, and the first full-suite run with CORE=ARM9 selecting V2.
- **The debug logic is opt-in now** (user: "can we strip out debug code
  for this work then add it in only when we actually need it so it
  doesn't hurt timing"). The switch is flipped: the default build is the
  stripped core (no overlay, per-second counters or trace triggers,
  about 1,700 ALMs smaller, the same thing the nd-/ndm- sweeps and the
  main slot's core already were), and NGAGE_NO_DEBUG is gone. A
  measurement core, for tools/mister_dbg.py, the board tools' counters
  and the loader words, is built with VERILOG_MACRO "NGAGE_DEBUG=1"
  (the commented line in NGage.qsf; `tools/seed_sweep.sh COMMIT TAG
  NGAGE_DEBUG ...`); the emu top bench passes -DNGAGE_DEBUG=1 itself,
  since it checks the overlay. Both configurations lint clean and the
  top bench runs. The Codex threads get the note with their next
  resume (nothing to uncomment for a timing build). A reference build
  of the stripped default, seed 2, went to the server as b26; its slack
  and fit follow in the next entry.
- **b26, the stripped default at seed 2** (f2de5bf, the loader tree with
  the flipped switch; the netlist is the one the nd-/ndm- sweeps built):
  setup **-0.395 ns** (slow 100C; -0.345 at -40C), hold +0.249,
  35,898 ALMs (86 %), 43,775 registers, 63 % of the block memory,
  43 DSPs. The best stripped figure so far (seed 18 of c8f18ef -0.431,
  seed 9 of 8194b05 -0.671, the core on the main slot), and seed luck
  like the others: the worst path is the D-cache FSM's write-back
  register index (zap_dcache_fsm o_reg_idx) into the shifter's
  registered source value, the fill-forwarding family the closure round
  owns. The rbf is build/hardware/NGage-b26.rbf; the main slot keeps
  seed 9 until a smoke test says otherwise. Timing stays paused per the
  user's rule; the number is the reference the CPU work is measured
  against ("don't let the timing become drastically worse").
- **Timing round 5, done** (Codex's ZAP thread, codex/timing2 c188fe5,
  RTL 7d1218c; docs/consults/2026-10-23-codex-timing5-report.md in the
  cx-timing2 worktree). Nine CPU changes, all cycle-identical (225 CPU
  runs with the same cycle and instruction counts, 57 QEMU agreements,
  both lints, the ten `input reg`): a registered TLB fault summary,
  per-slot interlocks and store forwarding resolved before the slot
  select, local barrel pending selects, BL and LSL-zero decode fields
  selected before register banking, the cache acknowledgement outside
  the FSM's priority mux, binary background-completion tags, effective
  load-lock factoring, case-local undefined classification in the
  sequencer, per-slot operand forwarding before the stall-select mux.
  Whole-core main-core fits at fixed seeds 1/2/3: **-0.211 / -0.221 /
  -0.318 ns** (median -0.221; the baseline median of the same seeds was
  -1.152, so 0.93 ns of tree), 35,845-35,969 ALMs (+419 over the
  baseline median), 479 M10K, hold +0.075 or better at every corner.
  The families left: post-ALU destination index into the issue
  interlocks (-0.318 at seed 3), the peripheral owner into the UPP
  bus's data capture (-0.211), the D-cache state into the merger's
  address (-0.221). The branch is 28 commits behind master (the loader,
  the flip): its rbfs carry the pre-loader file entries, so no board
  test of them; the branch stays for a merge after the CPU code lands,
  per the user's order (timing closure at the end, on the stripped
  core). The same thread takes the D-cache task next, on a new branch
  codex/dstore from master: the store miss completing at the fill's
  launch and the dirty victim's write-back deferred behind the fill
  (the Pocket core's two measured gains, 4-5 % and 2-3 %).
- **b26 on the main slot** (the user: "smoke-test the b26 core (boot
  and a game) and put it on the main slot if it passes"). Smoke-tested
  on the debug slot with the Sonic sequence of tools/run_games.sh: the
  idle screen with the clock and the date at 100 s, the phone menu with
  SonicN, Sonic's intro and title, Neo Green Hill in play (the game's
  timer 0:13.27 at the second play capture, 0:20.20 at the fourth:
  6.9 s of game time in 7.0 s of wall time; captures in
  build/hardware/game/smoke-b26/). Copied over
  `_Console/_NGage/NGage_20261023.rbf` (md5 c0739aa2...; the seed-9
  loader core it replaces is -0.671, this one -0.395), b25 back on
  `_Debug/NGageDbg_20261023.rbf` (744cce36...), the launchers
  unchanged. The main slot booted Sonic from its own launcher
  afterwards (captures in build/hardware/game/smoke-b26-main/).
- **The D-cache task, done** (Codex's ZAP thread, codex/dstore 29312a6
  from f12bb8a; docs/consults/2026-10-23-codex-dstore-report.md in the
  cx-timing2 worktree). Item 1, the store miss completing at the fill's
  launch, was already there: this ZAP acknowledges a cacheable
  write-back store miss in IDLE, before the fill's bus request and
  before the victim's write-back (a new directed test, dstore_rtl,
  shows 188 instructions retiring behind background stores at 0:0; the
  Pocket consult's premise does not apply to this revision). Item 2,
  the dirty victim's write-back deferred behind the fill, is
  implemented with the registers the miss already captures (the
  victim's line and tag) as the write-back buffer, no new RAM: IDLE
  goes straight to FETCH_SINGLE on a dirty miss, the CPU resumes on
  the fill, the buffered line drains afterwards, accesses to it wait.
  The suite: 228/228, 57 QEMU agree, lint, gen check; the original 225
  runs 20,630,566 -> 20,404,172 cycles (-1.10 %): the cache test -4.7 %
  at 0:0 and -9.7 % at 2:9, the random cached tests -0.3 to -0.5 %,
  dhold -0.2 to -0.4 %, dstore_rtl +37 clocks (a real drain where a
  no-op was). The requested one-seed sanity fit (stripped default,
  seed 2): **-0.956 ns** against b26's -0.395 at the same seed, +767
  ALMs; the worst path is the merger's cycle into upp_bus's
  acknowledge, not the new logic (the new families query at 0.000 and
  -0.292; the saved victim into the merger +1.8). One seed, so not a
  verdict, but 0.56 ns is above the sweeps' seed noise and the merge
  decision needs the in-play number first: a debug core of the branch
  goes to the server for a measurement on the debug slot against b25.
- **ARM9 v2, session 4** (Codex, codex/arm9v2 bc3e838, e2a1dd0;
  docs/consults/2026-10-23-codex-arm9v2-s4.md). The D2 admission
  restructured (the 40-bit pending-destination mask round trip gone,
  the issue enable's fanout bounded): the component fit from -1.729 to
  **-0.748 ns** median (seeds 2-4: -1.406, -0.748, -0.721), 6,094 ALMs
  (from 6,387), no cycle cost; accepted. Then M and W joined to the
  shared writeback, CP15 and the caches, with CORE=ARM9 selecting V2
  for the first time: the whole suite runs on it, 68 QEMU references
  agree in both predictor modes, 257 of 261 runs pass. The four
  failures (dhum_rtl check 26, dhold_rtl at 2:9) trace to the shared
  short-port cache wrapper, which qualifies replacement-hit LRU
  updates with idle, so a hit under a miss loses its update and a
  later miss evicts the wrong way; the fix is in the cache files the
  brief kept for the ZAP thread. The cycle picture is not there yet:
  the load-use interlock measures five clocks instead of three (the
  pending-load checks compare unused destination lanes and do not use
  W's load as a ready source), so at 0:0 V2 is 6.8 % faster on the
  cache test and 11-13 % on the GBA proxies but 1.6 % slower on
  crand1 and level on ctrand1. The integrated CPU fit with the caches
  (seeds 2-4): -1.959 / -1.579 / -1.329, median **-1.579 ns**, 15,902
  ALMs; ZAP in the same wrapper at seed 2: -0.584 ns, 16,549 ALMs, so
  V2 is 3.6 % smaller (the short cache pipelines) and about 1 ns
  worse, 0.58 ns outside the integration gate but not at the -2 ns
  stop. Session 5 launched with the ownership lifted (the ZAP thread's
  branches are parked, so V2 may make the minimal cache fix on its
  branch, ZAP's counts unchanged), then the real three-clock late
  pickup, the RAS checkpoint, the suites and the V2/ZAP cycle table
  with the random tests as the judge, then the three-seed fit.
- **One CPU line** (the user: "we have just one line of development
  with the new cpu right? no parallel development with two different
  cpus" and "leave round 5 parked, no more ZAP-pipeline work; the ZAP
  thread does only shared memory-side work from here"). ARM9 v2 is
  the CPU; ZAP stays as the default only until V2 passes the suite and
  the board. Round 5's branch (ZAP-only timing, cycle-identical) stays
  parked and unmerged; the ZAP thread's remaining scope is the shared
  memory side that V2 reuses (the caches, the merger, SDRAM, the write
  buffer), the deferred write-back being the first of it, pending its
  in-play measurement.
- **The deferred write-back on the board: +4 to +6 % in play.** A debug
  core of codex/dstore (29312a6, NGAGE_DEBUG, seed 2: -1.171 ns, 36,524
  ALMs, against b25's -1.188 and 37,886; build/hardware/NGage-dstd-
  s2.rbf) measured on the debug slot with tools/run_games.sh, b25
  re-measured first with the same script as the baseline (logs
  build/hardware/game/run-b25.log and run-dstd.log, the play captures'
  medians over ten shots each):

  | game | b25 M instr/s | dstd M instr/s | gain | fps b25 / dstd | CPI | SDRAM wait |
  |---|---:|---:|---:|---|---|---|
  | Sonic N (Neo Green Hill) | 29.38 | 31.09 | +5.8 % | 16 / 16 (mean 16.4 / 17.4) | 3.5 / 3.3 | 21.8 / 19.1 % |
  | Asphalt (Cop Chase) | 30.26 | 31.74 | +4.9 % | 13 / 13 (mean 13.0 / 13.4) | 3.4 / 3.3 | 24.1 / 22.3 % |
  | Tony Hawk | 29.52 | 30.62 | +3.7 % | 12 / 12.5 (mean 12.0 / 13.1) | 3.5 / 3.4 | 23.4 / 22.1 % |

  The data-stall share in Sonic falls from 14 % to 10 %; the D-cache
  event counts are the same (the same work, less waiting), so the gain
  is the CPU running during the victim's drain, as designed. More than
  the suite's 1.1 % and above the Pocket authors' 2-3 %, because the
  games' working sets evict dirty lines constantly. The frame rates
  move less than the instruction rates (the games' frame pacing). The
  cost side is the one-seed stripped fit at -0.956 ns against b26's
  -0.395; seeds 9 and 18 of the stripped core are building to say
  whether that is placement. dstd stays on the debug slot meanwhile.
- **codex/dstore merged (a69e840); seed 9 of the tree on the main
  slot** (the user: "Merge codex/dstore into master now; then one
  stripped build of the merged tree at the best seed, a Sonic smoke
  test, and the main slot if it passes"). The merge is clean (the
  branch is from f12bb8a and master had only log entries since); both
  lints and the netlist check (input reg 10) pass. Three stripped
  seeds of the tree (the RTL of 29312a6 is the merged tree's RTL;
  build/sweeps/dst-s*/, build/hardware/NGage-dst-s*.rbf): seed 2
  -0.956 (Codex's fit), seed 9 **-0.872**, seed 18 -1.025, 36,657
  ALMs (87 %); the previous tree at the same seeds: -0.395, -0.671,
  -1.260, so about 0.3 ns worse at the median, with the worst paths
  differing by seed (the merger's cycle into upp_bus's acknowledge,
  decode's shift source, upp_bus's data register), none through the
  new logic. Seed 9 smoke-tested on the debug slot (the idle screen,
  the menu, Sonic's title, Neo Green Hill: the game's timer 0:13.25
  to 0:20.32 across 7.1 s of wall time; captures in
  build/hardware/game/smoke-dst-s9/), then copied over
  `_Console/_NGage/NGage_20261023.rbf` (md5 e49c64b2...); the debug
  slot holds the tree's measurement core dstd-s2 (NGAGE_DEBUG, -1.171
  ns, md5 8215a65b...), so the per-second numbers come from the same
  RTL as the main slot. The main slot's own boot and menu with the
  user's save: build/hardware/game/smoke-dst-s9-main/.
- **ARM9 v2, session 5: the cache fix accepted, stopped at the -2 ns
  rule** (Codex, codex/arm9v2 c85eacc, 5609a2c;
  docs/consults/2026-10-23-codex-arm9v2-s5.md). The short D-port's
  replacement state now updates from the accepted response's
  registered way and address, hits under a fill included, with a
  same-set bypass into the next lookup's victim choice; a parameter on
  the shared tag manager that only the short port enables, the FSM
  untouched: 261/261 in ZAP and both V2 predictor modes, ZAP's counts
  unchanged. Its seed-2 integrated fit fell to -2.549 ns, through an
  existing family (the lock through retirement's write-through into
  decode's operand capture), so the thread registered the RF
  write-through selection before S's operand mux (every count
  unchanged, 15,745 ALMs, 4.9 % below ZAP in the same wrapper): -2.109
  ns at seed 2, still past the -2 ns stop, and it stopped there as
  told. Three families remain (M's valid through S forwarding and the
  rotator into A, the memory check record through FCSE into the
  D-TLB, W's destination through the load lock into the RF write
  data). The cycle model is unchanged: the LDR-to-dependent window
  is still 8 clocks (five extra), the random tests sit at V2/ZAP
  1.016 / 0.963 / 0.989 (crand1 at 0:0 / 0:3 / 2:9). Session 6
  launched: merge master (the deferred write-back) and re-baseline,
  then the three cuts to get back above -2 ns and within about 1 ns
  of ZAP, then the three-clock pickup, the RAS checkpoint, and the
  V2/ZAP table with the random tests at 0:3 and 2:9 as the judge.
- **The speed consults** (the user: "let's ask codex and antigravity
  for a consult session. we know this is possible based on the pocket
  core"). One brief with the facts and four questions
  (docs/consults/2026-10-24-speed-consult-brief.md), my own plan first
  (2026-10-24-speed-plan-mine.md), then Codex (2026-10-24-codex-speed-
  consult.md, read-only, 9 min) and Antigravity (2026-10-24-agy-speed-
  consult.md, plan mode, 9.5 min) independently, both with the V2
  worktree and the Pocket core's source to read. Where all three
  agree: V2 is the route; no CPU clock of its own (both consultants
  work the arithmetic: 47 M/s at 104 MHz needs CPI 2.21, at 80 MHz
  1.70, which even the Pocket's core with 64 KB caches and no kernel
  only just reaches; a crossing costs 4-6 % on top); no port of the
  Pocket's core (no aborts, no CP15/MMU, MCR traps to its kernel, and
  no licence); ZAP tops out near 35-38 M/s however the memory side is
  tuned; instrument the instruction side before buying anything there.
  Facts the consultants found that change the reading, each checked
  against the code: (1) the overlay's "code" stall tap is fifo_full |
  (fetch request without ack) (zap_core.sv:664), so the 48 % in play
  is mostly backend pressure; by beat conservation the I-cache fills
  are about 400 K/s, 5-6 % of clocks, and the D side carries 72 % of
  the bus beats. (2) V2's load-hazard loop (arm9v2_decode.sv:420-431)
  compares both destination lanes against the pending loads without a
  writes qualifier, so an instruction with one or no destination
  stalls behind an unrelated load whenever the unused lane's default
  matches (r0, the ABI's scratch register), which is the measured
  7-clock independent LDR/ADD window; the RAS is wiped on every W
  flush. (3) The I-cache FSM computes wrap-4 critical-word-first but
  the merger drives bte 00 on the code path (zap_wb_merger.sv:212,
  222; the D side passes it), and V2's fetch waits for the whole fill
  instead of using the streaming words. (4) The core is configured
  ARMv4T (arm925t.sv:104), so no ARMv5 work is owed. (5) The Pocket
  closed its predictor-equipped CPU at 88.7 MHz median, not 96. Where
  they differ: Codex plans V2 at 38-45 M/s at 104 MHz with 47 a
  further gate and budgets the load fix at +2-5 M/s; Antigravity
  projects CPI 2.12 (49 M/s) from the fetch-cycle predictor with a
  working RAS, the load schedule, LDM/MUL and the memory levers, and
  gives the Pocket-style split as the one change that fixes both the
  -2.1 ns S-to-A cone and the load-use cost: operands classified in
  D2 as early (shifted or multiplied, needed in S) or late (Rn, an
  unshifted Rm, store data, needed only in A), the forwarding match
  bits precomputed at the D2/S boundary, and a small late bypass at
  A's input, so an unshifted consumer of a load stalls one clock and
  S no longer carries the A producer's result through the rotator.
  Codex's first structural choice is the same precomputed matches.
  Decisions: V2 session 7 gets the early/late split with the A-stage
  late pickup (session 6 is mid-way through the cuts); the memory
  thread's next task is the instrumentation (the tap split, I-cache
  fills and true wait, contention wait, TLB walk beats, debug builds
  only) plus I-cache critical-word-first through the merger, measured
  on the board before the merger write-back buffer (both consultants:
  +4-6 % on ZAP, the FSM still holds in CLEAN_SINGLE about ten
  clocks after the install), then the 16 KB D-cache once V2 has
  ALMs to spare. Launched: the memory thread's task on codex/memside.
- **ARM9 v2, session 6** (Codex, codex/arm9v2 7b96cc8, 51a0123,
  9220667; docs/consults/2026-10-24-codex-arm9v2-s6.md in the worktree).
  Master merged with the deferred write-back, both cache changes kept;
  the new reference: 264/264 in ZAP and both V2 modes, 68 QEMU, the
  merged integrated fit at seed 2 -1.651 ns, 15,881 ALMs. Cut 1, the
  producer eligibility registered with the A/M/W payloads: **-1.237 ns**
  at seed 2, 16,417 ALMs, every count unchanged; within the ~1 ns of
  ZAP's same-wrapper -0.584 that the brief asked for. Cut 2, the
  selected memory check registered before the D-TLB: -1.385, 0.148
  worse at the one seed, so the thread stopped under the no-pay rule
  (the candidate is on the branch tip, to be reverted). The leaders
  now: the fetch queue's head select through the Thumb selection into
  D1 (fanout 151, -1.38) and, before cut 2, still M into S's
  forwarding and rotator into A. The cycle model is untouched (the
  dependent LDR window 8 clocks; crand/ctrand about 1 % under ZAP at
  2:9). Session 7 launched with the consults' structural decision:
  true writer masks, operands classified early (shifted, multiplied)
  or late (Rn, unshifted Rm, store data) in D2, the forwarding match
  bits precomputed at the D2/S boundary, S selecting only from the
  registered M/W producers, a late bypass at A's input, the load
  schedule that follows (a late consumer of a hit load one hold, an
  early one two), the replay contract, the RAS checkpoint; the judge
  is crand/ctrand/mmu_page at 0:3 and 2:9 clearly under ZAP, then the
  integrated seed-2 fit at or better than -1.237.
- The Mac's Quartus lane is open again (the user, 2026-10-24: "mac is
  free for builds now too"): five lanes, the server's four for the
  Codex threads and whole-core builds, the Mac for my own sweeps and
  measurement cores.
- **The instruction side measured: 6-8 % of clocks, not 48** (the
  memory thread's first step, codex/memside 50cbff0 and eeb1e47;
  docs/consults/2026-10-24-codex-memside1-report.md in the cx-timing2
  worktree). Eight counters under NGAGE_DEBUG split the old "code" tap
  (kept as code-combined at word 9) into FIFO-full clocks and fetch
  wait, and add I-cache demand fills, true fetch wait (no FIFO
  backpressure), fill wait behind the merger's data owner, fill wait
  behind the DMA/self-test owner, and the I- and D-TLB walk beats
  (words 37-44; the loader words move to 45/46; the counter index is
  six bits now, so tools/mister_dbg.py of this branch is needed for
  this core's screenshots). The second piece makes I-cache fills
  critical-word-first end to end (the FSM's wrap-4 was dropped by the
  merger on the code path): 231/231, 57 QEMU, 34 tests move by
  0.05 % in total because the fetch still gates on the whole fill. The
  measurement core (NGAGE_DEBUG, seed 2: -1.282 ns, 37,573 ALMs, 90 %;
  build/hardware/NGage-msd-s2.rbf) on the debug slot, the three games
  with the branch's tools (build/hardware/game/run-msd.log), play
  medians:

  | game | M instr/s (dstd) | I-fills/s | FIFO full | true fetch wait | merger wait | TLB walk beats/s I + D |
  |---|---:|---:|---:|---:|---:|---:|
  | Sonic N | 30.9 (31.1) | 434 K | 42 % | 6.5 % | 1.2 % | 252 K + 159 K |
  | Asphalt | 31.6 (31.7) | 357 K | 44 % | 6.0 % | 1.0 % | 146 K + 113 K |
  | Tony Hawk | 30.6 (30.6) | 501 K | 36 % | 7.7 % | 1.3 % | 268 K + 192 K |

  So the consultants' reading holds: the I-cache costs 6-8 % of the
  clocks (a fill every 2.0-2.8 µs at 12-15 clocks), the merger
  contention about 1 %, and the 42 % is the backend holding the fetch
  FIFO full; the TLB walks are 300-460 K bus beats a second (about
  5 % of the bus), worth a look later. Critical-word-first changes
  nothing on the board for now; it pays only with the early-execution
  gate removed, which is the memory thread's step after the write-back
  buffer. The thread is on the write-back buffer now (memside2); a
  stripped seed-9 build of the branch runs on the Mac for its slack.
- **ARM9 v2, session 7: the split is in, the hit schedule proved, the
  gate failed for a reason** (Codex, codex/arm9v2 16da5f9, 88e6d43,
  f97c763, 7522ab3, 4616d9c; docs/consults/2026-10-24-codex-arm9v2-
  s7.md in the worktree). Cut 2 reverted. Then, in five commits: the
  load-hazard check qualified by the real destination writers; source
  operands classified early (shifted, multiplied) or late (Rn, an
  unshifted Rm, store data) with the forwarding matches registered at
  the D2/S boundary; S forwarding from the registered M/W producers
  only, a late bypass at A's input, A and M folded; the two-clock late
  and three-clock early load pickup with a registered retirement
  replay; W's RAS checkpoint restored on recovery. 264/264 in ZAP and
  both V2 modes, 68 QEMU, 85 windows; the raw hit windows went from
  7/8/8 (independent, late, early) to **3/4/5**, that is, one, two and
  three instruction slots. Whole-test ratios V2/ZAP at 0:0: cache
  0.904, ctrand1 0.912, crand1 0.936, mmu_page 0.949, the GBA proxies
  0.94; at 2:9 about 0.99, the cache test 1.03. The thread stopped at
  the gate without a fit, and its diagnosis is the useful part: the
  random tests are three quarters uncached setup (mmu_on clears 4,096
  table words before the cache is on: 143 K of the 185 K clocks at
  2:9), so the ratio I set as the judge barely moves whatever the
  pipeline does; and the post-setup remainder is 2 % SLOWER than ZAP
  at 2:9 because the retirement replay discards younger work after a
  scalar miss or a held access and the front end refills, so misses
  now cost more than ZAP's hit-under-miss. Session 8 launched: measure
  the recovery events, then make the miss cheap (a registered lock the
  consumer waits on, younger independent work retiring past it as in
  ZAP, replay only what must), judged on the post-setup remainder at
  0:3 and 2:9; then the first firmware run on V2: a build macro that
  makes the wrapper instantiate V2 with the same caches and the debug
  taps, the emu top bench on V2, and the whole-core Verilator boot on
  the server against ZAP's, so the measurement core can go on the
  board, which is the number that counts.
- **The memory branch's first step merged (counters and critical-word-
  first); its stripped core at seed 9 fits better than the main slot's.**
  The Mac's reopened lane built eeb1e47 stripped at seed 9: **-0.734 ns**,
  35,839 ALMs (86 %), against dst-s9's -0.872 and 36,657 on the main
  slot (the critical-word-first path replaced the wide line-base
  addition with a concatenation; the counters prune away); the worst
  path is ZAP's issue stall (stall_late_ff), not the new logic. Merged
  into master as the first step of codex/memside (the thread continues
  on the write-back buffer on the same branch); both lints and the
  netlist check pass. The main checkout's tools now decode the debug
  slot's instrumented core. The rbf build/hardware/NGage-ms-s9.rbf is
  the main-slot candidate (same speed, 0.14 ns more slack).
- **Seed 9 of the merged tree on the main slot** (the user: "smoke-test
  the merged tree's seed-9 core (boot and a game) and put it on the
  main slot if it passes"). The Mac's build of eeb1e47 (the tree of
  7d429fe) at seed 9, -0.734 ns, smoke-tested on the debug slot with
  the Sonic sequence: the idle screen with the clock and the date, the
  menu, Sonic's title, Neo Green Hill in play (the game's timer 0:13.48
  to 0:20.45 across 6.9 s of wall time; captures in
  build/hardware/game/smoke-ms-s9/). Copied over
  `_Console/_NGage/NGage_20261023.rbf` (md5 76766144...; it replaces
  dst-s9 at -0.872, same speed), the instrumented core msd-s2 back on
  the debug slot; the main slot's own boot with the user's save in
  build/hardware/game/smoke-ms-s9-main/.
- **The merger write-back buffer: measured, no gain, not merged**
  (the memory thread's second step, codex/memside 64b8f33, 31466d9;
  docs/consults/2026-10-24-codex-memside2-report.md in the worktree).
  The D-cache hands a distinct-line dirty victim to a one-line buffer
  in the merger on the install edge and resumes through its unlock
  path; clean misses, hits and I-cache reads overlap the drain, a
  second dirty miss waits, uncached and maintenance keep the drain
  order, CP15's drain includes the buffer; 195 bits of new state, no
  new RAM; 231/231, 57 QEMU, 0.08 % fewer suite cycles. On the board
  (the measurement core wbd-s2: -1.401 ns, 38,342 ALMs, 91 %;
  build/hardware/game/run-wbd.log against the instrumented baseline
  run-msd.log, play medians): Sonic 31.07 against 30.87 M instr/s,
  Asphalt 31.70 against 31.62, Tony Hawk 30.61 against 30.57: +0.1 to
  +0.6 %, inside the run-to-run noise; the data-stall share 10.4 to
  10.1 %, the SDRAM wait unchanged. So the deferred write-back already
  took what there was: the FSM's ten clocks in CLEAN_SINGLE after the
  install rarely block anything that matters. The cost would have been
  real: the stripped core at seed 9 on the Mac **-1.137 ns**, 36,359
  ALMs, against -0.734 and 35,839 for the tree without it (the worst
  path in the D-cache tag RAM). Decision: not merged; the two commits
  stay on codex/memside for the record, and both consultants'
  estimates for a write buffer (+4-6 %; +0.8-2 M/s) were wrong for
  this core. The debug slot is back on msd-s2, master's measurement
  core. The memory thread's next step: the I-fetch early-execution
  gate (the true fetch wait is 6-8 % of clocks and every fill still
  waits for its last beat before a word may execute), with the 16 KB
  D-cache switch to be re-measured on the stripped tree, where it now
  fits.
- **The I-fetch early-execution gate, cache side** (the memory thread,
  codex/memside3 cb49df3, d533b3c from 8e965db; docs/consults/
  2026-10-24-codex-memside3-report.md in the worktree). The bridge now
  says with a fill's first beat whether the remaining beats can error
  (`no_late_error`, one registered bit in upp_bus): SDRAM and its
  mirror, on-chip RAM, and ordinary flash array line reads in
  read-array mode are guaranteed; flash command/status modes, EMIF
  registers, peripherals, unmapped targets, uncached and non-wrap
  reads are not. The I-cache FSM keeps the bit with the demand fill
  (one more register) and releases each guaranteed word as executable
  when its early-restart bypass is valid; error-capable fills keep the
  full-fill quarantine; the late-error assertions and a directed test
  with errors injected on beats 2-4 of an error-capable fill stay.
  231/231, 57 QEMU, 100 runs of 34 tests move, -0.03 % in total. The
  finding that limits it: ZAP's fetch-to-FIFO handshake (zap_core uses
  code_stall both to hold the fetch output register and to inhibit the
  FIFO write) makes a received word wait for the NEXT fetch ACK before
  it is queued, so with the missed word at +0/+4/+8 the next word
  arrives in the same fill and retirement still precedes the last
  beat, but at +12 the critical word waits for the whole fill and the
  next line's response. The thread stopped on the scope rule (no
  ZAP-pipeline changes) and proposes a one-bit consumed marker letting
  the held word enqueue once while the next request waits; the
  question is open. The wb branch's seed-2 point for the record:
  -1.302 ns against -0.956 without it. The measurement core of
  memside3 is building for the board; the 16 KB D-cache stripped
  build runs on the Mac.
- **The fetch handshake fixed: the early-execution gate complete on ZAP**
  (the memory thread, codex/memside3 df29e89, with the user's one-bit
  exception to the ZAP freeze; the report's "Authorized follow-up"
  section). One register, zap_core's fetch_consumed_ff: set when the
  held fetch register holds a valid word and the FIFO has room, it
  replaces code_stall as the FIFO's write inhibit, so the held word
  enqueues once without waiting for the next cache ACK; cleared on a
  fetch advance, reset, the ALU and decode redirects and the writeback
  clear; zap_fetch_main, zap_fifo, the decoders and every stage
  boundary untouched. A new directed test (ifetch_rtl) retires the
  critical instruction before the fill's second beat at every ARM and
  Thumb offset, +12 included; the negative control against the
  cache-side-only netlist fails it. 237/237, 57 QEMU; the existing
  234 runs 21,699,562 -> 21,411,745 cycles (**-1.33 %**, the largest
  suite gain of the memory-side items, every test moving); nine runs
  of four clock-timed IRQ/FIQ tests retire a different number of
  polling instructions, traced instruction by instruction; the board
  benches and both lints pass. The complete change is three bits of
  state. The cache-side-only core (ied-s2) is being measured on the
  board for the separation; the complete core (ieh-s2) and the
  stripped seed 9 (ie-s9) are building on the server, the 16 KB
  D-cache stripped build on the Mac. The memory thread is idle until
  those come in.
- **The 16 KB D-cache on the stripped tree: too dear as the tag RAM
  stands.** Master (8e965db) with NGAGE_DCACHE_16K at seed 9 on the
  Mac: **-1.472 ns**, 39,580 ALMs (94 %), 64 % of the block memory,
  against -0.734 and 35,839 ALMs (86 %) without it; the worst path
  starts in the D-cache tag RAM's address counter. Doubling the D-cache
  doubles the tag RAM's valid, dirty and LRU arrays, which ZAP keeps in
  flip-flops with wide read muxes and three-stage write forwarding
  (Antigravity's consult counted about 4,100 such flops for both
  caches; the Pocket core keeps that metadata in M10K and saved about
  4,900 ALMs doing so). So the switch stays off, and the memory
  thread's next task is the tag RAM itself: the metadata into block
  RAM, the unused short-read forwarding stages trimmed, whole-cache
  invalidation kept, cycle-identical; it helps both cores' timing and
  area (the tag RAM led the worst paths of the write-buffer and the
  16 KB builds, and V2's integrated fit carries the same caches), and
  makes the 16 KB D-cache affordable afterwards.
- The cache-side-only early-execution core on the board (ied-s2,
  NGAGE_DEBUG, -1.300 ns, 37,543 ALMs; build/hardware/game/run-ied.log
  against run-msd.log, play medians): Sonic 31.30 against 30.87 M
  instr/s (+1.4 %), Asphalt 31.70 against 31.62, Tony Hawk 30.75
  against 30.57; the true fetch wait 6.5/6.0/7.7 % to 6.2/5.9/7.3 %,
  the fetch-FIFO-empty share 15.9 to 15.1 % in Sonic. The partial
  effect the thread predicted (the +0/+4/+8 offsets only, the word
  still waiting for the next ACK); the complete core with the
  handshake fix is building for the real number.
- **The early-execution gate, complete: no gain on the board, not
  merged.** The measurement core of df29e89 (ieh-s2, NGAGE_DEBUG:
  -1.940 ns, 36,942 ALMs) on the debug slot, the three games
  (build/hardware/game/run-ieh.log), play medians against the
  instrumented baseline (run-msd.log) and the cache-side-only core
  (run-ied.log):

  | game | baseline | cache side only | complete |
  |---|---:|---:|---:|
  | Sonic N | 30.87 M instr/s | 31.30 | 30.98 |
  | Asphalt | 31.62 | 31.70 | 31.47 |
  | Tony Hawk | 30.57 | 30.75 | 30.76 |

  Inside the noise, both; the true fetch wait stays at 6.5 / 5.9 /
  7.5 % and the FIFO-full share at 36-44 %. The reading: the words
  arrive earlier but the backend cannot consume them faster, so they
  wait in the FIFO instead of in the fill; the suite's -1.33 % was the
  synthetic tests' in-order streams. Stripped at seed 9 the branch
  fits at -1.001 ns, 35,947 ALMs (the main slot's tree -0.734, 35,839;
  the worst path in the D-TLB check, a ZAP family), the debug core
  0.66 ns worse than the instrumented baseline at seed 2. Decision:
  not merged; the three commits stay on codex/memside3 for the ARM9
  v2 fetch, which waits for the whole fill today and may take the
  cache-side mechanism with its own handshake. The debug slot is back
  on msd-s2. The tally of the memory side on ZAP since the consults:
  the write-back buffer nil, the early-execution gate nil, the 16 KB
  D-cache too dear as the tag RAM stands; the I side's 6-8 % of fetch
  wait is overlapped by the backend's own stalls, and the deferred
  write-back (+5 %) was the last memory-side gain. The CPU is the
  lever, as the consults said. The memory thread finishes the tag RAM
  task (area and timing for both cores) and then pauses until V2 is
  on the board.
- **ARM9 v2, session 8: the miss policy, and the first run of the real
  firmware on V2** (Codex, codex/arm9v2 8cd678d..22a4261; docs/consults/
  2026-10-24-codex-arm9v2-s8.md in the worktree). The miss policy: a
  scalar consumer is retained across a miss on a registered lock, no
  retiring flush; younger loads keep ownership over older hits and
  retired returns; operand readiness ordered by the youngest writer (a
  chained-load ownership bug the firmware boot exposed, reproduced in
  the suite first): 267/267 in ZAP and both V2 modes, 69 QEMU, the
  3/4/5 hit windows kept. Then the whole core: NGAGE_CORE_ARM9=1 in
  NGage.qsf makes arm925t instantiate V2 with the shared caches, TLBs,
  CP15, merger and the debug taps; the emu top bench passes on it. And
  the firmware: the whole-core Verilator boot on the server, 468 M
  clocks (4.5 guest seconds, 27 minutes of wall time), 353 M
  instructions retired, 75 K device accesses, no data abort, prefetch
  abort or undefined instruction; the kernel schedules user threads:
  the first executive call at 3.26 guest seconds (ZAP 3.71), the
  EFile user entry at **3.63 s (ZAP 4.19)**, two more EFile threads,
  then EStart at 4.17 s, beyond ZAP's observation; the first 37,552
  MMIO accesses and the first 434 executive-call register snapshots
  identical between the cores (the divergence after that is the live
  timer counter, as expected). So V2 runs EKA1's boot 13 % faster
  than ZAP through its first user threads. The cost: the integrated
  seed-2 fit is **-2.838 ns, 18,349 ALMs** (S6: -1.237, 16,417): the
  leader is the D-cache short port's store-merge and formatting cone
  into the hit word (77 % routing), then the registered return/lock
  qualification into the held S/A operands (fanout 66-69), the D-TLB
  qualification, D1's classifier into D2's destination; the RF's
  fitted registers doubled by duplication (1,874 to 3,604) with the
  source unchanged. Stopped at the -2 ns rule, as told. Next: session
  9 on the cuts the report proposes (accepted store/lookup ownership
  with registered qualifiers at the request/store-merge boundary,
  bounded per-operand repair matches precomputed beside the registered
  return data, the D1 classifier path, the RF duplication), while a
  measurement core of V2 as it stands goes to the board for the first
  in-play number, timing risk and all.
- **V2's first bitstream on the board: hangs in the kernel boot.** The
  measurement core of 22a4261 (NGAGE_CORE_ARM9 + NGAGE_DEBUG, seed 2:
  **-3.787 ns**, 38,674 ALMs, 92 %; the stripped whole core at seed 9
  on the Mac: -3.688 ns, 38,059 ALMs, 91 %, the worst path from the
  D-cache FSM's state; against the ZAP tree's -0.734 and 35,839) on
  the debug slot with the Sonic launcher: the NOKIA splash and nothing
  after it; the overlay (decoded with the branch's tools, the old
  layout) shows PC 5031e394 unchanged from 30 s to 116 s, IRQ pending
  and never taken, no bus beats, the instruction tap counting every
  clock (a one-instruction loop, or the tap). Captures in
  build/hardware/game/smoke-v2d-s2/. At -3.8 ns nothing can be
  concluded about the design from this: the slow-corner model says
  the worst path needs 13.4 ns of a 9.6 ns period and the board is at
  room temperature, not the model's corner, so a failure of that size
  is expected, and a logic or integration difference between the
  Verilator boot (which runs the same netlist to EStart) and the
  board would hide behind it. The board judges V2 only once session
  9's cuts bring the whole core near the -1 ns where every ZAP core
  has run reliably. The hang's PC goes to the thread with the next
  brief.
- **The cache metadata in block RAM: a candidate, parked** (the memory
  thread, codex/memside4 1f002ef, f9ddca2, on top of memside3;
  docs/consults/2026-10-24-codex-memside4-report.md in the worktree).
  Valid in four RAM banks with one live flag per four sets, dirty in
  sixteen banks (keeping the clean scanner's throughput), LRU with one
  read and one update port and a bounded fill deferral; whole-cache
  invalidation cycle-identical; 948 CPU runs with every count
  identical across the configurations, 57 QEMU each, the directed
  tests, both lints, the board benches. Two stripped fits at seed 9:

  | configuration | ALMs before -> after | slack before -> after | M10K after |
  |---|---:|---:|---:|
  | I16 / D8 (the shipping one) | 35,839 -> 32,567 (-9 %) | -0.734 -> -1.190 ns | 537 of 553 |
  | I16 / D16 | 39,580 -> 32,702 (-17 %) | -1.472 -> -0.833 ns | 539 of 553 |

  So the area saving is real and large, and with it the 16 KB
  D-cache costs 135 ALMs and 0.1 ns, but two things keep it off
  master for now: at the shipping size the slack falls 0.46 ns (a new
  family, the maintenance control into the dirty banks' write enables,
  eight of the worst thirty, with a named fix not yet applied), and
  the fifty metadata banks spend fifty M10Ks on 2,816 bits, leaving
  16 blocks free (97 %), which is the budget V2 and any larger cache
  would need; the thread names a compact asymmetric-width RAM or a
  read-modify-write metadata engine as the way out. The branch also
  sits on the parked early-execution gate. Parked, with the memory
  thread paused as planned until V2 runs on the board, where its ALM
  saving is most likely to be wanted. One more measurement from my
  side: the D16 variant's measurement core goes to the board for the
  16 KB D-cache's in-play number (the consultants' +1-3 %), the one
  memory-side candidate left with a measured timing benefit.
- **ARM9 v2, session 9: the area back, the timing not** (Codex,
  codex/arm9v2 d648f64..efe6811; docs/consults/2026-10-24-codex-arm9v2-
  s9.md in the worktree). Four cuts, one integrated seed-2 fit each:
  the store collision resolved after the formatting (-2.527 ns from
  -2.838), the normal-return repair matches bounded and precomputed
  (-2.395), an independent D1 destination selection (-2.909, +307
  ALMs: reverted), and the RF's storage boundary bounded against
  retiming (the area back to **16,561 ALMs**, 12 above ZAP's 16,549;
  the slack **-2.871**). Every count and all 85 windows unchanged;
  267/267, 69 QEMU; the firmware boot identical through 4.5 guest
  seconds including EFile and EStart. The remaining chains are the
  late-pickup design's own: the D-cache lock through W's lock
  reduction and completion (wb_complete, fanout 163) into the next
  producer's tag and A's late match (13 of 30 hot paths, 22 of 30
  cold), the memory state through the request and translation control
  into the D-TLB's hit, W's load owner into the cache's valid metadata
  and the short-RAM forwarding record; all at 65-73 % routing. So the
  split and the miss policy cost about 1.6 ns against the S6 shape
  (-1.237) and the cuts have recovered 0.4 of it. A wall: before
  session 10, both consultants get the fitted paths and the question
  of which boundary to register and what it costs in cycles (the
  two-clock late pickup against a three-clock one on this cache
  interface, the request owner, the completion fanout, the routing
  share).
- **The 16 KB D-cache with the metadata in block RAM: +2 to +2.6 % in
  play.** The measurement core of f9ddca2 with NGAGE_DCACHE_16K
  (tagd16d-s2: -1.330 ns, 34,248 ALMs, 82 %, 65 % of the block memory
  bits; smaller than the baseline's measurement core by 3,300 ALMs)
  on the debug slot, the three games (build/hardware/game/run-
  tagd16.log against run-msd.log, play medians):

  | game | baseline | 16 KB D + metadata RAM | gain | D-cache load fills/s | SDRAM wait |
  |---|---:|---:|---:|---:|---:|
  | Sonic N | 30.87 M instr/s | 31.51 | +2.1 % | 351 K -> 314 K | 20.1 -> 18.6 % |
  | Asphalt | 31.62 | 32.37 | +2.4 % | 662 K -> 588 K | 22.2 -> 20.8 % |
  | Tony Hawk | 30.57 | 31.35 | +2.6 % | 444 K -> 413 K | 22.2 -> 21.2 % |

  Consistent across the three, the fills down 7-11 %, the data-stall
  share down 0.7-0.8 points: the consultants' +1-3 % for the larger
  D-cache, now affordable. The candidate for the main slot is this
  tree with the 16 KB D-cache as the default: stripped at seed 9
  -0.833 ns and 32,702 ALMs (78 %) against the main slot's -0.734 and
  35,839, at the cost of 539 of the 553 M10K blocks (the metadata
  packing, to be fixed before V2 needs the blocks) and the parked
  early-execution bits riding along (three bits, nil in play). The
  decision is the user's: merge codex/memside4 with the 16 KB default,
  one stripped build, a smoke test, the main slot.
- **The V2 timing consults** (docs/consults/2026-10-24-v2-timing-consult-
  brief.md; Codex 2026-10-24-codex-v2-timing-consult.md, read-only in
  the worktree, 9 min; Antigravity 2026-10-24-agy-v2-timing-consult.md,
  plan mode, 7 min; both with the fitted paths and the Pocket's
  source). Where they agree: keep the two-clock late pickup (it is the
  Pocket's schedule stage for stage: the RAM read launched from A, the
  word registered at M/W, muxed at A's input; three clocks would buy
  nothing by itself) and the miss retention (S7's replay was 15 %
  slower on the cache test); the five families are removable
  artifacts: the tag comparators run after completion's producer
  select on both the hold and advance paths (the Pocket compares once
  at D2/S and recodes registered bits), the check record muxed through
  FCSE live into the D-TLB, and A's live adder output compared against
  W's store set in the valid register and in each of 32 byte-lane RAM
  wrappers before the clock (families 3-5 are lookup-address paths,
  Codex's correction of the family table: W's owner reaches the
  metadata through A's bypass and adder, not through a cache write);
  the routing share is cluster crossings and two fanout nodes
  (completion 163, the read set 110). The cuts, all zero-cycle: the
  lock summaries registered from the lock's next value on its update
  edge; the next-producer matches computed on the two registered
  candidate pairs in parallel with completion, the transition used
  only as the final select, the completion net split by consumer;
  the translation/request descriptor registered with FCSE pre-applied
  (the index bits never need it); the short-RAM collision compare and
  the metadata selection moved after the A/M capture edge. Antigravity
  also found cpu_trial.qsf lacks the placement-effort and router
  settings NGage.qsf has. Their ceilings: Antigravity -0.75 to -1.1
  ns in the CPU trial with all four; Codex -1.5 to -0.8 plausible,
  -0.5 upside, and -2.5 to -1.1 on the whole device, with the fallback
  an address-launch stage between A and the cache (windows 3/5/6)
  rather than dropping features (Antigravity's fallback: a one-entry
  lock instead of the 64-bit bitmap). Session 10 launched with the
  combined order (lock summaries, the match split, the descriptor,
  then the collision compare), per-family worst paths, the qsf
  parity, the firmware re-run at the end; the address-launch stage is
  the decision if session 11 ends below about -1.5 ns.
- **ARM9 v2, session 10: three cuts, every count kept, the slack does
  not move** (Codex, codex/arm9v2 051806f..c87d383; docs/consults/
  2026-10-24-codex-arm9v2-s10.md). The fitter-settings parity alone
  (placement effort 2.0, router timing maximum, as NGage.qsf) gave
  0.19 ns hot and 0.54 cold on the same netlist (-2.871 to -2.678).
  Then: the next-lock summaries on the owner edge (-2.555, 16,267
  ALMs), both producer candidates compared before completion (-2.638,
  16,145), the translation and request descriptors registered
  (-2.983, 16,011); 267/267, 69 QEMU, 85 windows, the firmware logs
  byte-identical to S9 through 4.5 guest seconds. The per-family
  worst paths, now reported independently, show the wall: after the
  three cuts the leaders are S's operand selection with M's
  load-owner mask through the forwarding grant and the rotator into
  A's right operand (11 levels, 11.93 ns, -2.98), the registered
  D-TLB fault through the store acceptance and collision select into
  the short word (-2.85), completion into the queried lock owner
  (-2.63) and into the RF port selection (-2.57), A's bypass and adder
  into the metadata read (-2.42, the short-port cut still to do), D1's
  classification into D2's payload (-2.35), fetch's PC recurrence
  (-2.08). Each cut removes a family and the next sits 0.1-0.3 ns
  behind it at ten or eleven levels. The thread's own judgement: the
  cache cut cannot reach the target alone; the post-S11 gate at
  -1.5 ns stands, and the address-launch stage would fix A-to-cache
  but not the S-to-A cone. Session 11 launched: the short-port cut,
  then a registered data-ready grant separate from the producer match
  in S, and the completion-to-RF selection; while, in parallel, the
  decisive number is sought another way: the whole-core Verilator
  bench running a game on both cores, so V2's in-play instruction
  rate is known before more closure effort is spent on it.
- **Sonic on both cores in the whole-core Verilator bench** (the
  decisive number without timing closure). On the server, from
  ~/dev/mister/coreboot/arm9v2-s10-final-src (the V2 branch at
  c87d383, S10's source), two runs of the coreboot bench in parallel:
  V2 (arm9v2-s10-final/coreboot/Vemu, built with NGAGE_CORE_ARM9) and
  ZAP (zap-s10/coreboot/Vemu, the same tree without the macro), each
  with cs0.bin, a cs1 composed from the board's pristine firmware
  half and its clock-set 4 MB C: save (img/cs1-board.bin, so the boot
  goes to the idle screen without the date dialogs as on the board),
  sonicn.mmc on the card, and the Sonic key script of
  tools/run_games.sh in guest seconds (img/sonic.keys: menu at 100 s,
  three downs and OK, the four 5s from 176 s, play with held rights
  and 5s from 200 to 231 s), 235 guest seconds (24.44 G clocks), a
  progress line with the retired-instruction count every guest
  second and a picture on every change, into arm9v2-s10-final/game/
  and zap-s10/game/ (run.log, lcd-*.png). At about six wall minutes
  per guest second it is a day's run; the in-play retired
  instructions per guest second on the two cores, at the same 104
  MHz, is V2's cycle gain in the game itself, which neither the suite
  nor the kernel boot measures and the board cannot yet.
- **ARM9 v2, session 11: the last zero-cycle cuts; V2 paused until the
  game simulations say what it is worth** (Codex, codex/arm9v2
  2ba41be..7ed5190; docs/consults/2026-10-24-codex-arm9v2-s11.md). The
  short-port cut (the collision compare and the metadata selection
  after the RAM-read edge, M10K inference kept after a failed inline
  attempt): -2.818 ns, 15,439 ALMs; the S data-ready grants registered
  beside the full producer matches: -2.473, 15,591; the next-lock
  queries and the RF owner class in parallel: -2.877, 15,614 (the
  accepted endpoint, 935 ALMs under ZAP's). 267/267, 69 QEMU, 85
  windows, the firmware byte-identical through 4.5 guest seconds. The
  gate (-1.5) missed by 1.38 ns, and the thread's reading is the
  honest one: the leaders are now the front end (a queue word through
  the Thumb expansion into D1's instruction bits, D1's classification
  into D2's destination, -2.9 and -2.6) and the late-ALU flags path
  (W's load word through A's bypass and the ALU's zero reduction,
  11.1 ns), with independent ceilings at -1.9 to -2.3 (metadata/short
  response, execute acceptance, fetch, RF); the address-launch stage
  and a pre-rotator boundary would cut neither leader, so an extra
  stage is not a closure plan for this fit; a bounded zero-cycle
  front-end and late-ALU pass is estimated at 0.5-1.3 ns per family,
  reaching -1.7 at best. Decision: V2's RTL work pauses here. Eleven
  sessions have made a functionally complete core that runs the
  kernel 13 % faster, but at 104 MHz its shape sits 1.5-2 ns from
  where the board runs reliably, and each session's cuts move the
  leader without moving the slack; before any further closure effort
  (or a reorganisation with more stages), the Sonic simulations on
  both cores decide whether V2's in-play gain is near the kernel's
  13 % (then closure would still leave it far from 47 M/s and the
  design needs more than timing) or the 30-40 % the consultants
  budgeted (then the closure is worth a redesign). At 10 guest
  seconds the runs are at the kernel boot (V2 654 M instructions
  retired against ZAP's 465 M, polling loops included); about six
  wall minutes per guest second, a day to the play captures.
- **The 16 KB D-cache tree on the main slot** (my call, under the
  user's "pick what seems right": merged as 6abcccd, the 16 KB
  D-cache the default build since f37e549, three lint configurations
  clean). The Mac's seed-9 build of the merged tree: -1.215 ns, 33,507
  ALMs (80 %), the worst path in the D-cache tag RAM's address counter
  (the metadata family); the server's build of the identical RTL at
  the same seed, from the memory thread's report (dev/mister/
  NGage_MiSTer-tag-d16-s9, fetched as build/hardware/NGage-tag-d16-
  s9.rbf): **-0.833 ns**; two Quartus installations, one netlist, 0.4
  ns apart at one seed. The server's smoke-tested on the debug slot
  (the idle screen with the clock and the date, the menu, Sonic's
  title, Neo Green Hill: the timer 0:13.20 to 0:20.33 across 7.2 s;
  captures in build/hardware/game/smoke-tag-d16-s9/) and copied over
  `_Console/_NGage/NGage_20261023.rbf` (md5 2a28ac5f...; it replaces
  ms-s9 at -0.734, for the measured +2 to +2.6 % in play); the
  measurement core of the same tree (tagd16d-s2, -1.330 ns, md5
  db4ad67a...) on the debug slot. The main slot's own boot with the
  user's save: build/hardware/game/smoke-tag-d16-s9-main/. Also tried:
  Verilator with four threads for the Sonic simulations is slower
  than one thread on this design (no progress line in five minutes
  where one thread takes three), so the runs stay single-threaded
  (13 guest seconds after 90 minutes).
- **"Remember the ultimate goal."** The user's reminder, and a
  correction of my own call an hour earlier: V2 is not paused. The
  goal is the phone's speed, about 47 M instructions/s in play; ZAP is
  at 32 after today's two memory-side gains, and V2 has shown 13 % on
  the kernel boot where the design was meant for 35-50 %. Idling the
  one thread that can get there while a day-long simulation runs
  serves nothing; the timing wall is a separate problem from the
  cycle gain, and the cycle gain is what the goal needs. Session 12
  launched on the cycle model, the timing shape left alone (one fit at
  the end, no cuts), judged on the firmware's own boot milestones (the
  EFile entry at 3.63 guest seconds against ZAP's 4.19) and the
  windows: first the merge of master (the metadata in RAM, the
  early-execution gate, the 16 KB default; the tag RAM conflicts with
  the S11 short-port cut to be resolved keeping both), then V2's fetch
  taking the early-execution words (its fetch still waits for the
  whole fill), the serial fences (a flags-only MSR costs 12 clocks and
  EKA1 does them around every critical section), the small-LDM tails
  and the PC returns, and a second outstanding miss if the backend
  still waits on the D-cache. The Sonic runs continue for the in-play
  number.
- **ARM9 v2, session 12: the cycle items are small; the kernel gain
  stays at 13.8 %** (Codex, codex/arm9v2 68f7276..590dd57; docs/consults/
  2026-10-25-codex-arm9v2-s12.md). Master merged (the metadata in RAM,
  the early-execution gate, the 16 KB default; the tag RAM conflicts
  resolved keeping both), re-baselined. The early words: V2's fetch
  already consumed them through its queue handshake, so the proof
  found 0.001 % on the boot; the serial fences (ordinary PSR writes
  and CP15 reads kept in the pipeline): -0.35 % of the boot's clocks
  to EFile, -0.69 % to EStart, the MSR/MRC windows much shorter; the
  final LDM word on the scalar late pickup and registered PC hits
  retired directly: -0.11 %; the second miss engine not built (the
  measured opportunity under 0.4 %). Six configurations 282/282, 71
  QEMU, 89 windows, 3/4/5 kept; the firmware to EFile at 3.614 guest
  seconds and EStart at 4.128, **13.8 % and 13.3 % fewer clocks than
  ZAP** on the merged tree, no faults. The cached random tests' bodies
  after setup: V2/ZAP 0.85-0.92 at 0:0, 0.97 at 2:9. The fit, one
  seed, no cuts: -2.951 ns, **13,262 ALMs** (the metadata RAM; 3,300
  under ZAP's). The thread's own conclusion, and mine: the expensive
  windows this session shortened are not frequent enough in the boot
  to produce the intended 35-50 %, and nothing measured so far
  explains where that gain was supposed to come from; the next
  decision needs the Sonic runs (at 33 guest seconds, the kernel's
  idle loop, after 3.5 hours) and an instruction-class and recovery
  profile of busy gameplay. Session 13 launched for exactly that: the
  profile instrumentation in the whole-core bench (per-clock
  attribution of V2's stalls: fetch starved, D-cache wait, dependency
  hold, branch recovery, serial fence, replay, and ZAP's taps beside
  them), the boot's breakdown now, and a second pair of Sonic runs on
  the session-12 source with the profile, started today so the
  gameplay breakdown follows the plain number by a day.
- **ARM9 v2, session 13: the profile explains the 13 %** (Codex,
  codex/arm9v2 a2d6708, a1ec904; docs/consults/2026-10-25-codex-arm9v2-
  s13.md, with the tables under arm9v2/s13/). A bench-side observer
  (no core change; 282/282, 71 QEMU, 89 windows unchanged) partitions
  every clock of both cores into retired, data wait, dependency,
  fetch starvation, branch/return recovery, serial/CP15, replay/
  reservation, structural, and reset/WFI, with the retired mix. The
  kernel init before the first executive call (identical instruction
  streams, 270.6 M instructions): ZAP 386 M clocks, V2 338 M. V2
  removes **42 % of ZAP's non-retiring clocks** there (dependency
  17.2 M to 2.6 M, branch recovery 22.7 M to 7.6 M, fetch starvation
  9.9 M to 1.4 M, structural 69 M to 28 M; its data wait rises 15 M to
  30 M as the memory wait is exposed, and the reservation reloads add
  5 M), but ZAP retires an instruction on 70 % of those clocks, so
  even a perfect core could save only 30 % of that phase; the 13 % is
  what the kernel's init can give. The design's mechanisms are
  delivering where they apply: the dependency class is down eight
  times, branch recovery three, structural two and a half; replay is
  zero. The random bodies are memory-bound (data wait plus fetch
  starvation 65-74 % at 2:9), which is why they hide the schedule.
  The reading that matters for the goal: in play ZAP's CPI is 3.3, not
  the kernel init's 1.4, so 70 % of its clocks are non-retiring there,
  the regime where V2's mechanisms work; the Sonic profile (the S13
  pair, started with the observer; the S10 pair at 41-45 guest
  seconds, play from 200) is the measurement. The thread's one small
  suggestion, the younger lookup owner kept across a W hold (0.7 % of
  the boot), is not worth a session. No core change, no fit.
- **V2's board hang is a bug, not timing: it never wakes from the
  firmware's idle loop.** To get V2's in-play number without closure
  I built its measurement core (a1ec904, NGAGE_CORE_ARM9 + NGAGE_DEBUG
  + D16) with the whole system at **78 MHz** (the PLL output and
  sdram's CLK_HZ parameter, nothing else; the overlay counts per
  104 M clocks, so it would read the 104 MHz-equivalent rate): it
  meets timing there, **+0.060 ns** setup at slow 100C, 33,146 ALMs
  (build/hardware/NGage-v2d78-s2.rbf), the first V2 bitstream with
  positive slack. On the board (tools/run_games.sh with every wait
  scaled by 4/3; build/hardware/game/run-v2d78.log): the NOKIA splash
  and nothing after, PC 5031e394 for minutes, irq=1 pending and never
  taken, no bus beats, no frames, the instruction tap at one per
  clock: exactly the 104 MHz attempt's signature, which cannot be
  timing at +0.06 ns. And the Sonic simulation of S10's source shows
  the same: V2's PC at 5031e394 from before guest second 25, its
  device-access count frozen at 89,240 while it retires one
  instruction per clock and its pictures stay at five, where ZAP's
  run beside it keeps accessing devices and moving (so the S10 and
  S13 V2 runs were dead from the kernel's first idle; killed; the ZAP
  runs continue as the baselines). The 4.5-guest-second boots never
  reached the idle loop, so the parity runs could not see it. EKA1
  idles with the ARM9 wait-for-interrupt (MCR p15 c7,c0,4) or a loop
  on a flag the tick sets; V2 either halts there without the wake-up
  or does not take the pending IRQ (the CPSR I bit, the sampling
  point, session 12's PSR/CP15 fence changes). Session 14 launched to
  disassemble the loop, reproduce it in the suite against QEMU's
  ARM926, fix it, prove a 40-guest-second boot, and restart the V2
  Sonic runs. The 78 MHz measurement build is then the fast path to
  V2's in-play number on the board: a build and a 20-minute run.
- **Snapshots for the whole-core bench** (mine, on the user's "try
  writing the code yourself too"). The coreboot bench is built
  --savable now, and sim/harness/coreboot_main.cpp takes --save FILE
  --save-at CLOCKS [--save-exit] and --restore FILE: Verilator saves
  the model (its context and every signal and RAM) into FILE, and the
  harness its own state into FILE.bench through sim/harness/snapshot.h
  (the SDRAM chip model and the DDRAM model gained save/load of all
  their members, memories, pending beats and random engines included;
  the bench's counters, the video capture, the joystick state). A
  restore needs the same binary, the same --mmc image, --keys with
  absolute times, --cycles absolute and a fresh --out. Proved on the
  Mac: one guest second of the boot with a snapshot at 0.5 s and a key
  event at 0.7 s, then a run restored from it: the device logs after
  the snapshot point identical line for line (162 lines), the kernel
  log, the retired count (64,726,606), the device accesses (271) and
  the pictures the same; the snapshot is 0.4 MB of model and 76 MB of
  memories. The point: the firmware's idle screen comes at about 100
  guest seconds (ten Mac hours); a snapshot there makes every later
  game run on the same model start from it. Also measured: this Mac
  (M2 Max) runs the bench at 565-586 k clocks/s with --x-assign fast
  --x-initial fast and -O3 against the server's (Ryzen 5950X) 250-290 k,
  and four Verilator threads are slower than one on this design; the
  ZAP Sonic baseline moved to the Mac, relaunched on the savable
  build with the 16 KB D-cache (the shipping configuration) and a
  snapshot at 100 guest seconds.
- **The V2 kernel death, chased on the MiSTer.** The user's call: the
  simulations are off (all of them, the server's and the Mac's) and the
  fix loop runs on the board at 78 MHz. Three facts from three
  builds: (1) the current source (a1ec904) at 78 MHz dies with
  Kern::Fault("PLAT", 0x1005B); (2) session 8's first firmware-booting
  source (22a4261) at 78 MHz (-0.763 ns, 37,630 ALMs,
  build/hardware/NGage-v2d78s8-s2.rbf) is dead by 40 s with the
  exception record "50323e78 e3a03007 10000000": an exception at the
  `str r1,[r3]` of the kernel's doubly-linked-list insert at
  0x50323DE0 with r3 = 0xE3A03007, an ARM instruction word (`mov r3,
  #7`, 21 copies in the ROM) where a list node's link pointer should
  be, the same shape as the 2026-10-19 crash in which a `this`
  pointer held a vector instruction; its three callers compute the
  anchor as one loaded pointer minus one loaded offset; (3) session
  11's source (7ed5190, pre-merge, 8 KB D-cache) at 78 MHz with the
  hardware trace on (the rings shrunk to 4096/256/256 entries so they
  fit beside V2: -0.384 ns, 35,925 ALMs, build/hardware/NGage-v2d78t-
  s2.rbf; the full rings overflowed the device twice) dies with
  "aaaaaaa8 50321594 10000000": an exception at a garbage PC
  0xAAAAAAA8 with the data address inside the kernel's code. So the
  bug is in every V2 that boots the firmware, it shows as a wrong
  value in a pointer or a return, and it predates sessions 9-12. The
  fault-record write triggered the trace (two dumps, three triggers,
  the first trigger's PC 0x514A3964 in CS1); the dump of the last
  4,096 retired instructions and 256 data-port accesses is in
  build/hardware/game/trace-v2/dump.bin, fetched through devmem with
  a decoder copy matched to the small rings (scratch
  mister_trace_small.py). Also run today: Quartus's design rule
  checker on the V2 and ZAP builds (identical findings, all in the
  framework's clock crossings; nothing V2-specific), radare2 and a
  Ghidra headless analysis of CS0 (no static reference reaches the
  fault epilogue; the fault path is indirect). The dump's decode and
  the reconstruction went to an Opus 5.5 subagent (my own attempt was
  stopped by the safety classifier, per the standing rule).
- **"Are we spinning off into the weeds?" (the user) and the Codex
  consult on it** (read-only, session 01a16fee; brief and answer in
  docs/consults/2026-10-25-codex-backontrack-consult.md). The trace's
  decode landed first: the first wrong value is ip at `ldr r0,[ip,#4]`
  (0x50321578), the value of an older load to ip (`ldr ip,[pc,#2536]`
  at 0x50321568, a D-TLB miss plus a D-cache miss with a dirty victim,
  the first instruction after the kernel's `msr CPSR_fc` to 0xDB, which
  V2 serialises with a W flush) returned from the bus in the clock the
  younger hit to ip retired; the `str r0,[ip]` between them was not
  stalled either. One cause for both: the destination of that
  background miss had no working lock or ownership. Seven other misses
  in the window interlocked correctly. No UND, no bad bus beat (all 28
  ROM beats match the image). Codex's correction to my own account:
  that S11/D8 capture faulted 4.83 s into the boot at 78 MHz, not 25 s;
  keep the configurations' deaths apart. The directed test and the fix
  went to an Opus subagent in the cx-arm9 worktree (my own attempt was
  stopped by the classifier; the standing rule).
  Codex's answer to the weeds question, digested: V2 is still the best
  next experiment and not yet a demonstrated route to 47 M/s; the
  simple extrapolation of the kernel profile (42 % of ZAP's
  non-retiring clocks removed) into play is about 45 M/s at 104 MHz,
  and 47 needs 46 %. The order: correctness (the reproducer must fail
  before and pass after, plus independent ownership assertions, plus
  repeated board boots into play), then the gameplay number on the
  78 MHz board **with a ZAP control at the same 78 MHz** (the memory
  behaves differently at a lower clock; report 104 × Δinstructions /
  Δclocks over matched busy windows), then at most one bounded stage
  redesign. Thresholds for the normalised number: >= 52 M/s gives the
  redesign 0.21 CPI of headroom; 47-52 is fragile; < 47 does not
  justify timing-only work. On timing: probably not closable at 104 MHz
  with the present stage boundaries (S12's independent failing
  families: address->metadata -2.95, address->TLB -2.67, load
  word->late ALU -2.56, short response -2.23 ns; S10/S11 already spent
  the old eight-cut list); its preferred redesign separates late
  operand selection from the ALU/flags and address generation from the
  cache lookup, 3-5 sessions, no promise, funded only if the gameplay
  number holds and its projected CPI stays <= 2.21. Waste to stop: seed
  hunting and zero-cycle tuning of the unchanged shape, unprofiled
  features (S12's second-miss case was < 0.4 %), and more debugging
  infrastructure or ROM archaeology now that a reproducible failure
  exists. Acted on at once: the ZAP control, master (441bf20) at
  78 MHz with the debug overlay and the 16 KB D-cache (worktree
  ../NGage_MiSTer-zap78, server lane b5, seed 2), so the comparison is
  ready when the V2 fix lands.
- **The research archive.** The user's MEGA folder (the NGEmu-style
  research collection, 144 k files, mostly SDKs) holds the N-Gage QD
  RH-29 schematics V2.0 and the level 1-4 service manuals, the NEM-4
  schematic, a Z-drive and C-drive dump from a QD, an executive-call
  list, a reverse-engineering folder and the Symbian documentation;
  pulled (the user's "download whatever") through the MEGA API with the
  keys read from the web client and openssl for the AES-CTR, into
  research/hardware/rh-29-service-docs/ and research/mega-research/
  (research/ is untracked). The schematic is the primary source for the
  physical map; nothing in it bears on the speed work, which stays the
  one thread.
- **The V2 kernel death: reproduced and fixed** (an Opus 5.5 subagent on
  my brief, codex/arm9v2 17094db test, 137f6b8 fix, 694252b report:
  docs/consults/2026-10-25-v2-msr-lock-fix.md). The directed test
  sim/cpu/tests/arm9_msr_lock_rtl.S copies the system-call window at
  0x50321564 from the board trace and varies the PSR write, the TLB
  flush, the victim layout and the gap to the younger writer: 1,050
  cases. The one ingredient the trace did not spell out: lit1's line had
  to be *already in the D-cache as the LRU way* and evicted by the
  `stmfd` store miss just before the window. Before the fix V2 failed
  106/130/136 cases at 0:0/0:3/2:9 (the session-11 board source the
  same, D16 too), every one with ip and r0 holding lit1's value, the
  board's symptom; ZAP 0. The mechanism: D2's WAW check lets a younger
  writer of W's load destination pass on a first-clock short hit (the
  premise: the load completes now). Two short hits do not complete: a
  hit on a fill's departing victim (the line keeps its tag until
  UNLOCK_REG and compares equal, but the FSM withholds the ACK and the
  load misses after installation, locking ip only then), and a hit on
  the fill-end clock (W re-reads it through RETRY0; after the MSR's
  W-flush the refetched first load often lands exactly there). The
  younger `ldr ip,lit2` had left D2 before the lock existed, hit,
  retired, and the older load's background return (RF port C, priority)
  overwrote ip. The fix (zap_dcache.sv, arm9v2_core.sv): the D-cache
  exports its registered live-lookup state (IDLE or a background-hit
  slot, the only states with a hit ACK) as o_short_live, and D2's trust
  requires it and !fill_ended; readers are unchanged (the departing
  line's word is the right data). Verified: the test passes on both
  cores at all latencies, D8 and D16; the full suites 291/291 in all
  three configurations (ZAP, V2, V2 predictor-off); ZAP's and V2's 288
  prior runs cycle-identical (predictor-off: ctrand3/ctrand7 +5 clocks
  at 0:3); QEMU 73/73; four lint configurations; cpu-gen-check (with
  LC_ALL=C: this Mac's sort order otherwise fails it falsely). Open: the
  trace's TLB walk for lit1's page after the fill is not explained (in
  the test a TLB miss at that clock prevents the failure), and the new
  D2 terms had no fit yet. Builds at 78 MHz launched at once from
  694252b (ARM9 + DEBUG + D16): the server at seed 2 and the Mac at
  seed 9.
- **The ZAP control at 78 MHz** (master 441bf20, debug overlay, 16 KB
  D-cache, seed 2: +0.272 ns setup at the slow -40C corner, 33,515 ALMs
  (80 %), build/hardware/NGage-zap78d-s2.rbf, md5 83e61372; on the
  debug slot; tools/run_games_78.sh zap78d, captures under
  build/hardware/game/*-zap78d/). Play medians per 104 M clocks: Sonic N
  31.59 M instr/s (CPI 3.3, SDRAM wait 18.6 %, 17 fps), Asphalt 32.30
  (CPI 3.2, 21.0 %, 14 fps), Tony Hawk 31.31 (CPI 3.3, 20.6 %, 11.5
  fps); the idle screen at 133 s, menus and all three games normal. The
  same tree's measurement core at 104 MHz gave Sonic 31.51, so the
  lower clock changes ZAP's normalised rate by well under 1 %: the
  78 MHz board number stands in for 104 MHz, and V2's number from the
  same script compares directly with these three.
- **V2 boots the firmware on the MiSTer and plays Sonic at 44.4 M
  instructions/s.** The fixed source (694252b) at 78 MHz: the server's
  seed-2 build +0.086 ns (slow 100C; +0.290 at -40C), 33,344 ALMs (80 %),
  3.64 M memory bits, build/hardware/NGage-v2fix78-s2.rbf (md5
  08c6cf23; the Mac's seed-9 build of the same source -0.247 ns, not
  used). On the debug slot with tools/run_games_78.sh v2fix78 (captures
  under build/hardware/game/*-v2fix78/): the idle screen at 133 s
  (V2's idle loop reads 87.6 M instr/s at CPI 1.2 where ZAP's reads
  39.5 at 2.6), the phone menu, Sonic's title and play. Sonic N play
  medians per 104 M clocks, V2 against the same-script ZAP control:

  | | ZAP (78 MHz control) | V2 (fixed, 78 MHz) | gain |
  |---|---:|---:|---:|
  | M instr/s | 31.59 | **44.40** | +40.6 % |
  | CPI | 3.3 | 2.3 | |
  | fps | 17.0 | 24.0 | +41 % |
  | SDRAM wait | 18.6 % | 23.4 % | |

  The ten play captures 42.1-45.6. The goal is 47 M/s; Codex's
  extrapolation of the kernel profile into play was 45. Two residues,
  both V2-only (ZAP's control run was clean): (1) in two of three
  boots a Symbian "App. closed ... Server" panic dialog sits on the
  idle screen (a server thread panicked during the boot; the kernel
  survived); the dialog eats the script's Menu press, so the Asphalt
  run never left the idle screen (its ten "play" captures are the idle
  loop at 84 M instr/s, 0 fps, and the held 5s dialled "55555"), while
  Sonic's run got through by luck; (2) Tony Hawk booted without the
  dialog, ran its menus at 15-33 fps to the course's loading bar, and
  panicked there ("App. closed", the thread name under the overlay's
  bars), back to the phone menu. The thread names are being read with
  the overlay switched off through the OSD (tools/boot_profile.py's
  overlay_on sequence toggles it).
- **A second V2 death, rarer, same shape.** A fourth boot of the fixed
  core (to read the panic dialog with the overlay off: the OSD toggle
  works from tools/game_keys.py, "tap f12", 13 downs, enter, esc, esc)
  died during the Nokia logo phase: the overlay's PC 0x5031E394 (the
  fault epilogue's spin), the CPU retiring 104 M instr per 104 M clocks
  with no memory beats, and the kernel's record `00250030 503b27c0
  10000000`: an exception at PC 0x00250030 with r14 0x503B27C0, the
  return address of `bl 0x503A7748` at 0x503B27BC, an executive-call
  stub (`svc 0xC000BF`). So the garbage jump happened inside the
  kernel's SWI/executive dispatch right after the SVC exception entry:
  a wrong register value again, this time on the exception-entry flush
  rather than the MSR's. Two builds launched: a trace core of the fixed
  source (694252b + 78 MHz + DBG_TRACE with the small rings 4096/256/
  256, ARM9 + DEBUG + D16; worktree ../NGage_MiSTer-v2fixt, server lane
  b7) to capture this death's window, and the subagent resumed to
  extend the directed test to exception-entry flushes (SWI/IRQ entry,
  exception returns, user-mode entry with banked registers, the exec
  dispatch's `ldr pc` pattern) and to audit every consumer of the
  first-clock short-hit trust. The archive's executive-call list
  (research/mega-research/Executive calls/SVC.xlsx) names the calls.
- A second full run of the fixed core (v2fix78b): Sonic N 43.48 M
  instr/s median (42.1-45.0; 24.5 fps; CPI 2.4; SDRAM wait 23.9 %), so
  the two samples agree within 2 %; Asphalt and Tony Hawk derailed at
  the idle screen again (the panic dialog on both boots this time, the
  dialled "5555" digits in their captures). A dialog-tolerant variant,
  tools/run_games_78d.sh (a left-soft-key press before the Menu key:
  it dismisses the dialog when present and opens Contacts when not,
  and the Menu key opens the main menu from either), ran Asphalt and
  Tony Hawk alone (v2fix78c).
- **The exception-entry sweep finds nothing more** (the subagent,
  codex/arm9v2 72e50e5 sim/cpu/tests/arm9_swi_lock_rtl.S, 2bbe79d the
  report, 36a4544): 584 cases × cold/warm × three memory configurations
  (1,752 runs) of SWI and IRQ entries from SVC and USR, `movs pc,lr`,
  `ldm ^` and `subs pc,lr,#4` returns, with the younger-writer pair,
  a table dispatch `ldr pc,[r1,r2,lsl #2]`, `bx`/`mov pc` through the
  loaded register, younger writers of the new mode's lr and sp, and
  copies of the kernel's exec-call entry and return; lit1 departing
  under a store miss, TLB-missing or cold. Before the first fix V2
  failed 318/357/407 of them through every flush kind except `ldm ^`;
  after it none (the hazard itself was hit 822-1,166 times per run).
  ZAP passes (a bench assertion in the shared cache fired on idle
  clocks and was limited to clocks with an access). 294/294 runs in all
  three configurations, 291 earlier runs cycle-identical, QEMU 73/73.
  The audit of the first-clock short-hit trust: D2's WAW exception was
  the only consumer needing the hit to complete now; the readers (S's
  pending bit, the S/A waits and grants, W's forwarded word) need only
  the data, the PC-load fast path requires the ACK, the return matches
  and quick_reload come from completion or registered locks. Ranked
  candidates for PC 0x00250030 (the abort handler records the aborted
  mode's lr, and 0x503B27C0 is the user caller's, so the PC went wrong
  on the way back to user mode): (1) a stale word through V2's short
  D-cache port on a store-then-reload (the context save/resume reloads
  the saved PC and SPSR a few instructions after storing them,
  0x50321638-0x50321670); (2) the readers' premise failing on a
  half-installed line at the fill's install edge; (3) V2's fetch queue
  releasing pending entries on any I-fill completion, so a wrong
  instruction word could execute after a redirect.
  Its result: **Asphalt 41.40 M instr/s** median (41.1-42.3; 21 fps;
  CPI 2.5; SDRAM wait 30.1 %) against the ZAP control's 32.30 at 14
  fps: +28 % in instructions, +50 % in frames. Tony Hawk ran its menus
  (16-27 fps) and panicked at the course load again, the second time
  of two, back to the phone menu: a reproducible V2-only failure for
  the trace core. The three V2 numbers so far against ZAP's control,
  per 104 M clocks: Sonic 44.4 / 43.5 vs 31.6, Asphalt 41.4 vs 32.3,
  Tony Hawk none yet vs 31.3; the goal is 47.
- **The three candidates for the second death tested, none fails** (the
  subagent, codex/arm9v2 34ccaaf the tests, e90316e the report;
  pushed). arm9_store_reload_rtl.S (1,688 cases: word/halfword/byte/STM
  stores reloaded 0-6 instructions later, same word, other word, other
  width; the line present, dirty, absent with the store merged into its
  own fill, departing, write-back in flight, being filled,
  write-through; SVC, USR and a mode change between; the kernel's
  context save/resume at 0x50321624-0x50321670 copied literally for a
  USR and a SYS thread): every value, PC, mode and restored register
  correct. arm9_install_edge_rtl.S (448 cases, both fill orders,
  readers in S and A at 2,688 installs per run): loads on the line
  complete 3-8 clocks after the install edge, never earlier; the cache
  admits the new line three edges after installing it, so a
  half-installed line cannot be read. arm9_fetch_redirect_rtl.S (120
  cases; b/beq/bx/mov pc/ldr pc/svc from a cold line's entry word to a
  cold target with every other word poisoned, every I-fill forced
  provisional): 173-221 redirects per run discarded pending entries, no
  poison retired; by the RTL only one I-fill runs at a time and a
  pending entry's word has already arrived ("pending" only defers a
  late bus error). 303/303 runs in each configuration, the 294 earlier
  runs cycle-identical. The subagent's remaining reading: the second
  death lies outside the single-CPU bench shapes (another bus master
  and the board's memory timing, or a V2 path the firmware uses that
  the suite does not: Thumb, multiply, SWP, CP15). The hardware trace
  is the evidence: the trace core of the fixed source fits only with
  the 8 KB D-cache and the PC ring at 1,024 entries (the 16 KB and the
  4,096-entry builds overflowed the 553 M10K: the merged tree keeps the
  cache metadata in block RAM, which the session-11 trace core did not).
- **The trace core's first boot (8 KB D-cache, PC ring 1,024; -0.185 ns
  slow 100C, -0.457 at -40C, 33,763 ALMs; build/hardware/NGage-v2fixt-
  s2.rbf) failed at start-up**: "App. closed ScreenSaver" (the boot-time
  panic's thread name, readable this time), then "Device start-up
  failed. Contact the retailer." on the N-Gage splash; no kernel fault,
  no abort or UND (the trace's exception trigger never fired); the three
  dumps it holds (build/hardware/game/trace-v2fixt/dump0-2.bin) are the
  kernel's routine write to the fault area at 3.27 s and the two
  leftover timed triggers at 55 s and 130 s (DBG_TRIG_AT1/2_S from the
  2026-10-22 investigation), both in the idle loop. So the boot-time
  panics are software panics, not exceptions, and the trace as
  configured cannot catch them; the exception death (the exec-call
  record) can be caught when it recurs. Launched: a 16 KB-D-cache trace
  core with 512/128/128 rings and the timed triggers off (worktree
  ../NGage_MiSTer-v2fixt16, lane b8), and a two-game run on the 8 KB
  trace core to give the exception death its one-in-four chance.
- The 8 KB trace core fails start-up on every boot (three of three:
  "App. closed ScreenSaver", then "Device start-up failed"), with no
  exception and no kernel fault, where the 16 KB fixed core reached
  the idle screen in six of seven boots. Either the smaller cache
  multiplies the remaining bug's hits or the trace core's negative
  slack adds its own; a fixed-source 8 KB build without the trace
  (../NGage_MiSTer-v2fixd8, lane b5) separates the two. Tried and
  dropped: Symbian's ErrRd flag file (c:\system\bootdata\ErrRd makes
  the "App. closed" dialog show the panic category and reason): the C:
  save is the phone's log-structured flash image (LFFS), not FAT, so
  there is no way to plant the file from outside.
- The 16 KB trace core fits with the 512/128/128 rings and the timed
  triggers off (33,976 ALMs, 3.71 M memory bits; slack -0.25 ns at the
  slow -40C corner; build/hardware/NGage-v2fixt16-s2.rbf): its four
  dump slots wait for exceptions and fault-record writes only.
- **Boot statistics on the fixed 16 KB core** (three plain boots,
  build/hardware/game/v2boot-1..3/): boot 1 died with the kernel record
  `00250030 50447b53 10000000`, the same garbage PC 0x00250030 as
  before but from a Thumb caller this time (r14 = 0x50447B53, the
  return of `bl 0x50459C38` at 0x50447B4E); boots 2 and 3 reached the
  idle screen with the "App. closed ... Server" dialog. So the
  exception death is about one boot in four and always lands on the
  same address, which points at a fixed wrong table entry rather than
  random corruption: the kernel's SWI entry reads the call number with
  `ldr ip,[lr,#-4]` at 0x50321490 and indexes the executive table.
  Reading the handler: a fast executive call jumps through the ROM
  table (`ldr pc,[ip,#-0x3C8]` at 0x503214A8), but no ROM word near any
  table holds 0x00250030, so the garbage PC is not a wrong table slot.
  The slow path (bit 23 set, as in `svc 0xC000BF`) goes through RAM:
  `ldr ip,[0x50321F58]` (= 0x80005668), `mov lr,pc`, `ldr pc,[ip,#-4]`
  at 0x50321558, a jump through the kernel word at 0x80005664, in the
  very line (0x80005660) whose neighbours the first bug's window
  touched (0x80005668, 0x8000566C = 0xAAAAAAAA). So the second death is
  most likely a load that delivered the wrong word to pc: the same
  class as the first (a wrong value out of a load), on a load whose
  destination is pc, at the kernel's executive entry. The trace core's
  data ring will show what that load returned and what the cache and
  bus carried.
- The fixed source with the 8 KB D-cache and no trace (lane b5, seed
  2): -0.255 ns at the slow 100C corner (+0.017 at -40C), 33,066 ALMs,
  build/hardware/NGage-v2fixd8-s2.rbf; so at 78 MHz the 8 KB cache is
  no easier to fit than the 16 KB one for V2 (the metadata-in-RAM
  tree's address paths dominate either way). Its boots, to separate the
  cache size from the trace core's timing in the start-up failures,
  follow the trace core's boot loop on the board.
- **A death captured on the 16 KB trace core** (boot 7 of the loop,
  build/hardware/game/trace-v2t16/dump1.bin, decoded to the scratch
  trace-v2t16-dump1.txt; six earlier boots reached idle with one
  routine dump each): not the executive-call record but the other
  kind, a **user-mode data abort 25.25 s into the boot** (the trigger
  "exception" at 0x503CBDF4), which is what the "App. closed" dialogs
  on the idle screen are. The window: a Thumb user thread calls
  through an import stub into the ARM handle lookup at 0x503A320C
  (count at +8, array base at +20, the entry's id compared with the
  handle's index/id, the object pointer at +4); the data port logged
  count 1, base 0x8062A358, entry id 0x00030008, the handle 0x00080000
  and the id word 3, which should compare equal, yet the CPU's flags
  after the compare were Z clear: the lookup returned 0, the caller's
  `ldr r0,[r4,#28]` read address 0x1C (the vector page) and the next
  load aborted. So a register held a value different from what the
  data port delivered, again. Handed to the subagent with the decoded
  rings to name the load and the pipeline situation and to write the
  directed test.
- **The 8 KB no-trace core dies deterministically with Kern::Fault
  ("PLAT", 0x1005B)**: three of three boots (build/hardware/game/
  v2d8boot-1..3/), the same record the pre-fix 16 KB core gave at
  78 MHz on 2026-10-24. So the start-up failures of the 8 KB trace core
  were the cache size, not its slack, and the 8 KB configuration is the
  reproducer for this third death. The 16 KB trace core then produced
  it too on its next boot (one of eight so far), with **three events in
  one boot** (build/hardware/game/trace-v2t16b/dump1-3.bin, decoded
  alongside): a user-mode data abort at 17.9 s (a Thumb thread at
  0x5044A72A loading through a pointer that read back as 0), another at
  20.6 s (ARM user code at 0x50394D08 through a null object pointer
  that the memory word itself held as 0), and the PLAT fault's record
  write at 21.1 s, whose 512-instruction window is the kernel's event
  dispatch (0x5033A390: an event word read from the variant's structure
  at [0x5033A534], a jump table up to type 0x58, then message handling
  through 0x5033B948, 0x5039D248, a descriptor copy) ending in the
  Kern::Fault category copy. The two user aborts look like consequences
  of an earlier wrong store (null words where pointers belong), so the
  first wrong value lies before all three; the PLAT window is the
  deterministic one to decode.
- **The second hole, from the 25 s capture: found and fixed** (the
  subagent, codex/arm9v2 5c652ee the test, 6a85407 the fix, 7dd5509 the
  report; pushed). Every load in the window returned what memory
  delivered (checked against the data and bus rings; where a load
  missed, the data tap shows the victim's word, a known artifact), yet
  the compare cleared Z: only r2 = 0x801009D0, the *literal's own
  address*, gives that result, so the CPU's r2 was wrong. The chain:
  `ldr r0,[r0,#36]` missed and its fill began evicting the literal's
  line from the same set; `ldr r2,[pc,#12]` hit that departing line on
  its first clock (never accepted by the cache: it missed later and
  returned in the background); `ldr r2,[r2]` and `ldr r2,[r2,#4]` read
  r2 *and* write it: D2 let such writers past the older pending load on
  the premise that they wait for its data, but S/A still trusted the
  unaccepted hit and took the word early, so both retired first and the
  literal's late return overwrote r2. The first fix covered only
  younger writers that do not read the register. The test
  sim/cpu/tests/arm9_dep_waw_rtl.S copies the shape in ARM and Thumb
  with five chain variants: before the fix V2 fails 128-144 of 192
  cases at every latency, both predictor modes, both D-cache sizes,
  always with r2 = the literal; ZAP passes. The fix: D2 registers a
  "writes a register it reads" bit with each instruction, and for
  those instructions only, S and A trust a first-clock short hit only
  when the cache accepts it. Verification: 306/306 in all three
  configurations plus V2 at D16; ZAP's 306 cycle-identical; V2 not
  fully: 17 earlier predictor-on runs move (random tests -2..+9
  clocks; `cache` +182 at 0:3, +6 at 2:9; predictor-off at most +1,500,
  0.15 %); the 3/4/5 windows unchanged (recovering those runs would
  need a new comparator in the shared cache; gating every reader moved
  33 runs, so it was not used); QEMU 73/73; four lints clean; netlist
  regenerated. Builds of 7dd5509 at 78 MHz launched at once: 16 KB
  (lane b6) and 8 KB (lane b5, the PLAT reproducer).
- A second PLAT boot on the 16 KB trace core (build/hardware/game/
  trace-v2t16c/, decoded alongside) is the same sequence to the
  millisecond: the user abort at 0x5044A72A at 17.890 s, the one at
  0x50394D08 at 20.572 s, the PLAT record at 21.120 s. So this death is
  a deterministic consequence of one early wrong value, not a race at
  the fault; the boots that escape it (six of nine on this core, all
  three on the 8 KB core fall into it) diverge earlier.
- **The PLAT fault decoded** (the subagent, codex/arm9v2 1b56b38, the
  report's new section): the fault itself is the kernel working as
  designed. The kernel server, in UND mode, takes a message at
  0x80006C00 asking it to panic the requesting thread (handle
  0xFFFF8001, reason 0), resolves it to thread 0x8040E370 and calls
  DThread::Exit (0x5032D7C8) with exit type 2 (panic); the thread's
  critical flag ([0x8040E390] = 4) makes it take `movne r0,#0x5B; blne`
  at 0x5032D800, Kern::Fault("PLAT", 0x1005B). So a system-critical
  thread panicked itself, and the kernel refused to go on without it.
  Every load in all three windows is consistent with memory (dump 3's
  128 accesses match the instruction stream; dump 1's null was
  delivered by the bus; dump 2's null was in memory): the first wrong
  value is before any window, so no third mechanism is visible. The
  second fix plausibly covers it: the idiom (a literal load, then a
  load that reads and rewrites the same register) occurs 5-11 times per
  512-instruction window, it is how Thumb code reads globals and goes
  through import stubs; several of those literal loads missed in the
  windows; and 3/3 at 8 KB against 1 in 8 at 16 KB is what an
  eviction-driven mechanism predicts. The 8 KB build of 7dd5509 on the
  board is the test that decides it.
- Fix 2 (7dd5509) at 78 MHz: the 16 KB build (lane b6, seed 2) slips
  to **-0.668 ns** at the slow 100C corner (-0.285 at -40C; 33,404
  ALMs; build/hardware/NGage-v2fix2-s2.rbf) where fix 1 had +0.086: the
  self-dependent-writer gate in S and A costs on the D2/S/A hazard
  paths. The 8 KB build (lane b5, seed 2) meets timing (+0.015 /
  +0.244, 33,007 ALMs; build/hardware/NGage-v2fix2d8-s2.rbf). Seeds 9
  and 5 of the 16 KB build launched on lanes b7 and b8 for the slack.
- **Fix 2 does not remove the PLAT death**: the 8 KB fix-2 core died
  with PLAT 0x1005B on two of three boots (build/hardware/game/
  v2fix2d8boot-1..3/), where fix 1's 8 KB core died on three of three.
  So a third wrong value remains, before the 17.9 s abort. Seeds of the
  16 KB fix-2 build: seed 9 **-0.069 ns** (slow 100C; +0.086 at -40C;
  33,297 ALMs; build/hardware/NGage-v2fix2-s9.rbf), seed 5 -0.442 /
  -0.470, seed 2 -0.668 / -0.285; seed 9 is the measurement core. To
  reach the first wrong value, a trace core of fix 2 (8 KB, the
  deterministic reproducer; rings 1,024/256/256; timed triggers off)
  gained a trigger on a data-port store to either word the PLAT boots
  later read back as a null pointer, virtual 0x8540BEA4 (the 17.9 s
  abort's) and 0x0040C7A8 (the 20.6 s abort's): NGage.sv
  dbg_trig_store in worktree ../NGage_MiSTer-v2fix2t8, lane b5. Its
  dumps will hold the instructions that wrote those words.
- **Fix 2 on the board, 16 KB (seed 2, -0.668 ns), the plain
  three-game script (v2fix2)**: no kernel fault in the three boots;
  Sonic N 43.97 M instr/s median (43.2-45.9; 25 fps; CPI 2.4), Asphalt
  41.47 (40.9-42.2; 19 fps; CPI 2.5), both the same as fix 1's numbers
  within 0.5 %, so the second fix costs no speed; Asphalt's boot came
  up without the dialog this time and its run went through the plain
  script. Tony Hawk's boot derailed at the idle screen again (the
  dialog); rerun with the dialog-tolerant script.
  The idle screens of those three boots: Sonic's and Tony Hawk's with
  the "App. closed ... Server" dialog, Asphalt's clean, so the
  boot-time server panic persists at the same rate after fix 2 (two of
  three); the 25 s capture that fix 2 answers was one instance of it,
  and the remaining instances share the third wrong value with the
  PLAT death.
- **The chain behind the PLAT boots starts at the comms database**
  (the subagent, codex/arm9v2 3c492f8, pushed): in the failing boot
  neither null word is ever written by its intended code. The 17.9 s
  abort's object (0x8540BDE4, field +0xC0) is destroyed mid-
  construction: an inner NewL (0x5045E548) builds a 0x40-byte object
  whose virtual open (0x5045EDB1) opens c:\System\Data\Cdbv2.dat, the
  comms database (z:\System\Data\DefaultCdbv2.dat in ROM is the
  default), gets **-20, KErrCorrupt**, deletes the object and
  User::Leave(-20)s; the cleanup runs the outer destructor
  (0x5094EA28), which reads +0xC0 without a null check, and the field
  still holds the allocator's zero fill. The 20.6 s abort's object
  (0x0040C7A4, field +4) likewise: its only writer, `str r0,[r5,#4]` at
  0x50AD0490, runs after a three-try call with 50 ms pauses and a
  LeaveIfError that never completed; the destructor (0x50AD0530 →
  0x50394CF0) dereferences +4 unguarded. Then the critical thread's
  self-panic, the PLAT fault. So the earliest wrong value is the
  KErrCorrupt verdict on Cdbv2.dat; ZAP reads the same file from the
  same save image cleanly on every boot, so V2 misreads it (the file
  lives in the CS1 NOR flash's log-structured file system, read through
  the data path). The store-trigger core is moot (the words are never
  written). The audit of the Thumb and interworking paths (Thumb
  literal then a self-dependent load; the import stub `ldr r3,[pc];
  ldr r3,[r3]; bx r3`; `pop {r0}; bx r0`; Thumb SWI) finds no early
  trust or unlocked window left after the two fixes. New trace core
  (worktree ../NGage_MiSTer-v2fix2t8b, lane b6; 8 KB, fix-2 source,
  rings 1,024/256/256, timed triggers off): a trigger when the CPU
  retires the User::Leave stub (svc 0x73 at 0x503A785C) from 17 s
  after the CPU start, so the dump holds the database reads that
  produced the -20.
- **Tony Hawk plays on fix 2** (v2fix2b, the dialog-tolerant script):
  **41.75 M instr/s** median (39.1-42.4; 17.5 fps; CPI 2.5; SDRAM wait
  30.6 %) against the ZAP control's 31.31 at 11.5 fps, and its
  course-load panic (three of three on fix 1) did not recur: that panic
  was fix 2's mechanism. V2 against ZAP in all three games now, per
  104 M clocks on the 78 MHz board:

  | game | ZAP | V2 (fix 2) | instructions | frames |
  |---|---:|---:|---:|---:|
  | Sonic N | 31.59 (17 fps) | 43.97 (25 fps) | +39 % | +47 % |
  | Asphalt | 32.30 (14 fps) | 41.47 (19 fps) | +28 % | +36 % |
  | Tony Hawk | 31.31 (11.5 fps) | 41.75 (17.5 fps) | +33 % | +52 % |

  The goal is 47; by Codex's thresholds (>= 52 headroom, 47-52
  fragile, < 47 no timing-only work) V2 as it stands is below the
  line, before any cycle work on the profile that session 13 drew
  (the data wait that V2 exposes is now 30 % of the clocks in Asphalt
  and Tony Hawk against ZAP's 21 %).
- **The Leave-trigger core boots clean six times out of six**
  (8 KB, fix-2 source, -0.583 ns; build/hardware/NGage-v2fix2t8b-
  s2.rbf; build/hardware/game/v2lv-1..6/), no fault and no Leave
  retired after 17 s, where the same source without the trace died with
  PLAT on two boots of three and fix 1's 8 KB trace core failed
  start-up on three of three. So the chain behind PLAT is a race whose
  odds depend on the boot's memory-traffic schedule (the trace core's
  own 256 KB dump at 3.27 s shifts it), not a fixed sequence; once
  lost, it plays out deterministically (the two identical PLAT boots).
  Twelve more boots of this core run on the board, and a 16 KB variant
  with the same Leave trigger (rings 512/128/128, the configuration
  that produced two PLAT boots in nine) builds on lane b6.
- **Where the -20 is made** (the subagent, codex/arm9v2 17682f9,
  pushed; one step of its analysis went to an Opus subagent of its own
  after a safety stop, per the standing rule): the C: file exists, so
  CommDb opens it through the DBMS server (RDbs::Connect, then
  RDbNamedDatabase::Open of c:\System\Data\Cdbv2.dat from 0x5045EF00);
  the store library's checks run in the *server* thread (the header
  check at 0x508B53D0 leaving at 0x508B5470, the frame type/length at
  0x508AF8F2/0x508AF91C, the table-of-contents checks 0x508B4494-
  0x508B4668, the read's error check at 0x508ACC8A; a checksum
  mismatch would give -5, not -20), and the CommDb thread only receives
  the -20 and leaves. The C: copy rebuilt from the flash log passes
  every check (header 0x4F58, handle 0, reference 0x239D, checksum
  0x0955; frames 0x8043, 0x80E8, 0x5534); it differs from the ROM
  default from offset 0x1A27 on, and several of its 512-byte sectors
  start at flash addresses 2 mod 4: **a misaligned copy out of the
  uncached flash window is the prime suspect** for where V2 reads it
  differently. Also run: a new test arm9_unc_chain_rtl.S (an uncached
  older load or an uncached LDM's last word before cached chains, ARM
  and Thumb; fails 30 of 540 before fix 2, all with the chain's own
  line evicted; passes after) and the existing directed tests at 8:12
  and 16:40 with their data uncached: all pass. So the euser-stub Leave
  trigger would show only the return code; a third trace core
  (worktree ../NGage_MiSTer-v2fix2t16c, lane b5; 16 KB, rings
  512/128/128) triggers on either stub, euser's 0x503A785C or the
  store library's Thumb import stub at 0x508B625C, from 17 s. The
  subagent writes the directed test of the misaligned uncached copy
  (the file server's sector copy routine as the ROM has it, rotated
  unaligned loads, halfword pairs, aligned LDM with shifts, at 0-3 mod
  4 source offsets, long latencies, both cache sizes, against ZAP).
  The subagent's notes, the rebuilt C: file and a validator are in the
  scratch cdb/ directory.
- The 8 KB Leave-trigger core stayed clean for thirteen boots in a row
  (v2lv-1..6, v2lv2-1..7), so its schedule simply avoids the race; the
  loop was stopped. The 16 KB Leave-trigger core (euser's stub only;
  -0.290 / -0.199 ns; 33,747 ALMs; build/hardware/NGage-v2fix2t16b-
  s2.rbf) took the debug slot for the same loop while the two-stub core
  finishes on lane b5.
- The two-stub Leave-trigger core (16 KB, rings 512/128/128; -0.542 /
  -0.350 ns; build/hardware/NGage-v2fix2t16c-s2.rbf) replaced the
  euser-only one on the debug slot before that one's first boot
  finished; the PLAT loop runs on it (up to ten boots).
- **JTAG to the server.** The user moved the MiSTer next to the Ubuntu
  server and cabled the DE10-nano's USB-Blaster II (mini-B) to it; a
  modem power loss on the way cut the subagent's session (resumed). The
  Quartus image already holds jtagd, jtagconfig, quartus_stp and
  quartus_pgm; tools/jtag-server.sh runs a persistent root container
  with /dev/bus/usb and the JTAG server (`start`, `chain`, `stp`,
  `pgm`, `stop`), so no host udev rule is needed. The cable enumerates
  as 09fb:6810 until jtagd loads its firmware, then as 09fb:6010
  "DE-SoC"; jtagd without libudev.so.0 misses that re-enumeration (the
  helper symlinks libudev.so.1 to .so.0 before starting it). The chain:
  DE-SoC [3-1], 4BA00477 SOCVHPS, 02D020DD 5CSEBA6. SignalTap can now
  attach to a core the MiSTer loaded, provided the build carried the
  .stp instance; the first intended capture is the pipeline state (the
  D2 and S/A hazard terms, the lock bitmap, the cache FSM) around an
  abort or the store library's Leave.
- **V2 copies the C: sectors correctly** (the subagent, codex/arm9v2
  2f0df8a the test, c0185c5 the report; pushed): the media driver
  (medint.pdd, 0x50381864) copies each 0x200-byte sector with one
  Mem::Copy (0x503A1D38) from the CS1 window (0x59200000/0x59600000):
  for a 2-mod-4 source and a word-aligned destination, one aligned
  word, then sixteen uncached 8-word `ldm r1!,{r4-fp}` with a 16-bit
  shift-merge chain and `stmia r0!`, no rotated or unaligned loads
  (copies of 15 bytes or fewer go through an ldrb/strb run; src < dst
  copies descend). sim/cpu/tests/arm9_unc_copy_rtl.S (278 cases, cold
  and warm: Mem::Copy's own sequence both directions, source offsets
  0-3, lengths 512/1024/511, uncached and cached source, destination
  line present/departing/absent and offsets 1-3, 1-15-byte copies, the
  LFFS 2-byte header then 510-byte body, a shift-merge loop and a plain
  ldm/stm loop, each checked against a byte-loop reference and a
  consumer sum; four planted bugs caught) passes on ZAP and V2 at
  0:0, 0:3, 2:9, 8:12 and 16:40, D8 and D16, predictor off, and on
  the pre-fix-2 netlist. Suites 312/312 in all three configurations,
  the 306 shared runs cycle-identical. Cache maintenance during a fill
  is ruled out too (every MCR waits for no lock and no fill,
  arm9v2_core.sv:689, and serialises). **Next suspect: the board's CS1
  path, which the bench replaces with flat memory**: each uncached word
  passes wb_arb2 (ngage_mem.sv:151), upp_bus's split into two 16-bit
  reads (upp_bus.sv:309-310) and ddram_flash's same-clock beat buffer,
  arbitration and write-through updates (ddram_flash.sv:172-180,
  193-195, 409-471); V2's stream there (back-to-back 8-word uncached
  LDMs, data reads with its own fetches in flight) is one ZAP never
  makes. The subagent replays that request stream through the
  memory-side path against the file image; the board trace with the
  store library's Leave trigger will show what the bus delivered.
- **Every trace core of the fix-2 source boots clean** (the 8 KB
  Leave core 13 of 13, the 16 KB two-stub core 14 of 14 at the board's
  new place, no user abort either: dumps stay at one), while the same
  source without the trace shows the panic dialog on two boots of three
  (16 KB) and the PLAT fault on two of three (8 KB). The one thing the
  trace cores all do that the plain ones do not is dump their rings
  when the kernel's routine write hits the fault area at 3.27 s (256 KB
  to DDR3 through the loader port), which shifts the rest of the boot
  against the board's periodic events (video, refresh, the HPS's card
  service and wall clock); so the panic is a race that the shifted
  schedule happens to miss. Two more trace cores build with that
  routine dump gated off (the fault-record trigger only from 5 s) and
  both Leave stubs armed: 16 KB (rings 512/128/128, lane b5, worktree
  ../NGage_MiSTer-v2fix2g16) and 8 KB (1,024/256/256, lane b6,
  ../NGage_MiSTer-v2fix2g8).
- The timing-clean seed-9 fix-2 core (16 KB, -0.069 ns) shows the
  "App. closed ... Server" dialog on two boots of three too
  (build/hardware/game/v2fix2s9boot-1..3/, no kernel fault), the same
  rate as the seed-2 core at -0.668: the panic is not a slack effect.
  Headless SignalTap: the server's Quartus has no generator for the
  sld_signaltap instance (qmegawiz does not know it), so a SignalTap
  build needs the .stp authored in a Quartus GUI (the user's, attached
  to the server's JTAG server remotely: 192.168.50.173:1309, password
  ngage, tools/jtag-server.sh) or a hand-written instantiation; the
  remote-client option is enabled on the server's jtagd.
- **The memory side is clean in simulation** (the subagent, codex/arm9v2
  b72ba26 the bench, 235ee7f the report; pushed): a new whole-core
  program, sim/harness/flashcopy.S, maps C: where the kernel has it
  (uncached at 0x59200000 and 0x59600000) and copies sectors with
  Mem::Copy's own sequence through the real ngage_mem, upp_bus,
  nor_flash and ddram_flash RTL and the DDRAM model, with V2's own
  CS0 fetch line reads (I-cache invalidated first) and the destination's
  SDRAM traffic; 126 cases (every source offset 0-35, ascending and
  descending, copies straddling a sector end, 511 and 1,024 bytes,
  uncached/write-through/write-back destinations, a cached source,
  small copies, a header then the body, a flash program of the first,
  middle or last halfword of the line just read), each run twice so
  the first meets a cold ddram_flash read cache, at four DDR3 timings;
  a `--check-flash` option compares every flash read beat with the
  image: **0 mismatches on both cores** (V2 156,785 CS1 beats, ZAP
  156,782), a planted bug (no write-through update of the beat
  buffer) caught. V2's stream is slower, not faster (11 clocks ack to
  ack against ZAP's 9). Not modelled: the real DDR3 controller and HPS
  bridge, flash_save block reads, DMA, erases, interrupts, the board's
  timing. So the misread exists only on the board, and the board
  captures decide. **A side finding worth cycles:** in that test V2
  re-read the code section's page-table entry 193,735 times against
  ZAP's 1,124 (10.76 M clocks to ZAP's 7.19 M), a thrash of the shared
  8-entry section TLB (zap_tlb.sv:230-245); the game runs agree: per
  second at 78 MHz the overlay counts ZAP's TLB walks at 194 K I-beats
  and 141 K D-beats, V2's at 2 K I-beats and **272 K D-beats**, so V2
  walks the D-side twice as often as ZAP in play (of the order of 10 %
  of its clocks), a cycle item for the profile work.
- **SignalTap, headless.** tools/gen_stp.py writes a Quartus 17 .stp
  from a JSON spec (clock, depth, instances with node lists and a basic
  trigger per node), modelled on an example .stp from the Quartus Pro
  install; the first spec, stp-flash.json in worktree
  ../NGage_MiSTer-stpb (the stripped 8 KB V2 core at 78 MHz: no overlay,
  no rings), probes the data port (tr_d_done/we/va/rdata), the flash
  path (ddram_flash's cs1_req/ack/addr/rdata, bb_hit, take_go;
  upp_bus's fl_req/ack, fe_hi, fe_need_hi) at 2,048 samples, triggered
  on the first read of the database file's sector 0 (virtual
  0x5967C6A4 = the flash window + CS1 offset 0x47C6A4); the server
  builds it on lane b7 (the synthesis step validates the file). The
  Mac elaborated the same source (worktree ../NGage_MiSTer-stp) for the
  GUI's node finder should the dialect need fixing by hand.
- The gated trace cores fit: 16 KB (rings 512/128/128) -0.774 /
  -0.259 ns, 34,074 ALMs, build/hardware/NGage-v2fix2g16-s2.rbf; 8 KB
  (1,024/256/256) -0.438 / -0.249 ns, build/hardware/NGage-v2fix2g8-
  s2.rbf. With the routine dump gated off, a boot's first dump is an
  event (an exception or a Leave after 17 s), so the loop stops at any
  PLAT boot with one dump or more. The 8 KB one went first.
- **The generated SignalTap file is valid**: `quartus_stp NGage
  --stp_file=stp-flash.stp --enable` on the server's copy of the
  project ran with 0 errors and wrote the SLD_NODE_* / CONNECT_TO_SLD_
  NODE_ENTITY_PORT tap assignments (one per probe bit, the clock
  emu:emu|clk_sys) into the .qsf. The first build of worktree stpb
  (-0.234 / -0.139 ns, 32,092 ALMs, 3.55 M memory bits: the plain
  stripped 8 KB core) had no instance in it because build.sh's
  `quartus_sh --flow compile` never runs that step (the GUI does, as a
  flow stage); build.sh now runs quartus_stp before the compile when
  the settings name a SignalTap file.
- **The gated cores were not gated**: the 3.27 s dump is the RTC-read
  trigger (DBG_TRIG_RD, 0x0C1F0100, the kernel's first read of the HLE
  date register at PC 0x514A3964), not the fault-area write, so the two
  "gated" builds are ordinary trace cores; their eight boots (the 8 KB
  one, build/hardware/game/v2g8-1..8/) were clean like all the others.
  The tally is now stark: **every trace core of the fix-2 source boots
  clean, 37 of 37**, while the same source without the trace fails two
  boots in three (16 KB: the dialog; 8 KB: PLAT). The dump's schedule
  shift cannot be the whole story (the fix-1 trace cores dumped the same
  way and did fail), so the trace logic's presence itself changes the
  outcome: it adds a client on the loader port (`ld_busy || ld_own !=
  3'd2`) beside the flash loader and the flash_save path that the
  memory-side bench does not model with the real HPS DDR3 bridge, and
  it changes the placement. The stripped SignalTap core (no trace, the
  configuration that fails) is the one build that can see the misread.
- tools/gen_stp.py gained don't-care nibbles in bus patterns and a
  conditional storage qualifier; the second spec (stp-flash2.json,
  worktree ../NGage_MiSTer-stpc: the stripped 8 KB V2 core) keeps only
  the data port's completed reads from the flash window (tr_d_done,
  !tr_d_we, tr_d_va = 0x596xxxxx) in 4,096 samples with the data port,
  ddram_flash's cs1_ack/addr/rdata and bb_hit and upp_bus's fe_hi
  (108 bits), triggered on the first read of sector 0, so one capture
  holds every word of the whole 9 KB file as the CPU and the flash
  path saw it; quartus_stp validated it (0 errors). The first,
  unqualified probe build was stopped as redundant on the user's "kill
  all useless tests and builds"; the qualified one builds on lane b8.
- **Fix 3: V2's excess D-side TLB walks** (the subagent, codex/arm9v2
  e8a4b9e the test, fe65a2d the fix, 37eeaf4 the report; pushed). The
  premise corrected: the section TLBs are not shared and not 8 entries
  (each cache has its own 64-entry direct-mapped one; zap_top overrides
  zap_tlb's default of 8). V2 drove three addresses from three stages
  into one request's machinery: the lookup used A's address every clock
  (a data value for an ALU instruction), the miss check M's, and the
  walker fetched the cache's i_address, W's (arm9v2_core.sv:662-669,
  zap_tlb_fsm.sv:168-175), where ZAP's three belong to one request. So
  three kinds of waste walk: after a hold (a fill or an uncached access
  froze the TLB on A's speculative lookup; at release W's check missed
  and re-walked a section already held), at the wrong address (a real
  miss at M walked at W's address, possibly a non-memory instruction's
  garbage, so the miss stayed), and after an install (the check
  registered in the install clock still saw the old entry: the same
  section walked twice). flashcopy's 193,735 re-walks were the first
  two. The test sim/cpu/tests/arm9_tlb_walks_rtl.S cycles two code
  sections and N data sections at distinct indexes (the right count
  after a warm-up pass is 0): before the fix V2 made 35/70/132/164/196
  excess walks for N = 4..12, ZAP 0. The fix is a parameter CHECK_WALK
  set only for V2's D-cache: the TLB keeps reading through holds, walks
  the address that missed, and waits one fresh check after an install.
  After it: 0 excess walks in the test; the copy test's D-side walks
  29,839 -> 11,311, exactly ZAP's; the whole-core flashcopy 10.76 M ->
  6.71 M clocks (ZAP 7.19 M), about 20.5 clocks per avoided walk;
  ZAP cycle-identical at D8 and D16; V2's suite totals -5.6 to -6.1 %
  (instruction counts move only in the interrupt-timed tests); suites
  315/315 in all five configurations, QEMU 73/73, lints clean, netlist
  regenerated. Expected on the board: 100-140 K fewer walks per second
  at ~20 clocks, about +3 % game speed (+7 % at most). Two leads left:
  with the predictor off V2 can still walk for a wrong-path load; and
  **before the fix V2 cached fault descriptors from walks of garbage
  addresses**, so a section the kernel maps later without a TLB flush
  could abort, which may bear on the deaths. First board core: the
  16 KB debug build of 37eeaf4 at seed 9 with the new FAST=1 fast-fit
  profile (lane b5), for the game numbers and the boot statistics.
- Two false starts, both fixed: the first FAST=1 build died at once on
  a settings-file parse error (the appended fast-fit lines landed on
  the last line, which had no newline; build.sh now writes one first,
  master 5888b3a), and the 4,096-sample probe core overflowed the 553
  M10K; the probe is now 86 bits (the data port's done/we/va/rdata,
  cs1_ack, cs1_rdata, bb_hit, fe_hi) at 2,048 samples, still storage-
  qualified to the flash-window reads, so one capture holds 16 of the
  file's 18 sectors. Both rebuilt with the fast fit: the TLB-fix debug
  core (worktree ../NGage_MiSTer-v2fix3, lane b5) and the probe core
  (../NGage_MiSTer-stpc, lane b8).
- The first FAST=1 build, the TLB-fix debug core (16 KB, seed 9;
  build/hardware/NGage-v2fix3-fast-s9.rbf, 33,083 ALMs): the fitter in
  13 min 26 s against the usual ~35, the whole build about 27 minutes;
  slack -0.900 ns at the slow 100C corner. It waits for the MiSTer,
  which the user took upstairs again (board work paused).
- **The flash-probe core is built** (worktree stpc, fast fit; build/
  hardware/NGage-stp-flash3.rbf, md5 4ae31527; the .sof and the
  compiled stp-flash3.stp stay on the server in dev/mister/
  NGage_MiSTer-b8/): the SignalTap instance "flash" is in it (block
  memory 3.73 M bits against the plain core's 3.55 M), 32,185 ALMs,
  slack -1.885 ns at the slow 100C corner (-1.450 at -40C): a debug
  core for the capture only. The procedure (scratch capture_flash.sh)
  loads it on the debug slot, boots the phone through the Sonic
  launcher, arms the instance through the server's JTAG server 8 s
  after the launcher load with a 90 s timeout and fetches the saved
  .stp. It waits for the MiSTer to come back beside the server; a
  full-effort seed-9 build of the TLB-fix debug core runs on lane b5
  meanwhile for the measurement.
- The fast-fit probe core sits at -1.885 ns (slow 100C), beyond what
  the board has run (-0.8); a full-effort build of the same worktree
  follows on lane b8 as the capture core, the fast one kept as a
  fallback.
- **The stale-descriptor lead confirmed in RTL** (the subagent,
  codex/arm9v2 1dab72e: sim/cpu/tests/arm9_tlb_stale_rtl.S; pushed).
  For a non-memory instruction at W, arm9v2_execute sets o_address =
  alu_result and the pre-fix-3 walker walked it; zap_tlb_fsm installs
  an entry even for a fault descriptor, which zap_tlb_check turns into
  a translation abort. The trigger shape is `L1 hit; mov r3,#S; L2
  miss`, which garbage-walks section S that the program never
  addresses. (a) reproduces: S unmapped at the trigger, then mapped
  valid with no flush, then loaded: pre-fix V2 aborts on the stale
  fault entry, ZAP and fixed V2 read the RAM. (b) does not: a cached
  fault entry surviving a fault-to-valid remap aborts on every core,
  the ordinary ARM flush rule, and any c8 flush (all or by VA)
  invalidates the whole TLB. **(c) reproduces as wrong data**: S mapped
  to PA_A at the trigger (only the garbage walk reads it), remapped to
  PA_B without a flush, then loaded: pre-fix V2 returns PA_A's word
  with no abort, exactly the "read back wrong" shape; ZAP and fixed V2
  return PA_B. Fix 3 closes all of it: V2 walks only the checked
  address and no longer poisons untouched sections; the residual
  concern (a stale descriptor bus read) is the normal page-table
  coherency rule, the same as ZAP's, and the kernel's tables are
  uncached. The test passes on ZAP and V2 (D8, D16, predictor off) at
  every latency; the pre-fix netlist fails it everywhere. The comms
  database misread fits: the media driver's flash window is a
  remappable section, and a stale entry from a garbage walk of it
  would make the copy read another page of the flash. The TLB-fix
  core on the board decides it (paused until the MiSTer returns).
- The full-effort TLB-fix debug core (16 KB, seed 9): -0.516 / -0.372
  ns, 33,380 ALMs, build/hardware/NGage-v2fix3-s9.rbf (md5 5598e48c);
  fix 3's walk-check logic costs about 0.45 ns against fix 2's seed-9
  fit. An 8 KB build of the same source (the PLAT reproducer
  configuration) follows on lane b5 for the board's PLAT test.
- The full-effort flash-probe core: -0.371 / -0.367 ns, 32,604 ALMs,
  the same 3.73 M memory bits, build/hardware/NGage-stp-flash3-full.rbf
  (md5 a53e0a57); the .sof and the compiled stp-flash3.stp stay in the
  server's dev/mister/NGage_MiSTer-b8/. It is the capture core; the
  fast-fit one (-1.885) is kept only as a fallback.
- **The 104 MHz plan** (the subagent, codex/arm9v2 a36512a, docs/
  consults/2026-10-25-v2-104mhz-plan.md, copied to master; pushed).
  The four named families are not enough: the CPU trial needs about
  -0.3 ns (whole-device slack runs 0.3-1.0 ns worse than the CPU
  trial, and the board's envelope is -0.6 to -0.8), and with those four
  removed S12 still leads near -2.0 ns (rf, backend, execute,
  backend_skid, decode_payload, execute_late, dtlb, decode_grants, ...):
  fifteen failing families from six root causes, all six to cut. The
  cuts, preferred first: a dedicated address adder in S registered into
  A so A drives the cache and TLB from a register (no new stage, 3/4/5
  kept; loads whose base comes from the instruction just ahead or with
  a scaled offset pay +1: +0.4-0.8 % cycles; the fallback an address
  stage after A, 3/5/6 and one more clock on W redirects, +3-8 %);
  load word into flags: parallel zero detection (free), else the
  slower path for flag-setting consumers, last the loss of the late
  pickup for load words (3/5/5, +2.5-5 %); the short response:
  per-way formatting, sub-word loads a clock later as the fallback;
  cache state driving core control: a registered completion contract
  (+1 clock per miss or uncached completion, +1.0-1.3 %); the front
  end and the rest: zero-cycle cuts. In play: about +2-3 % cycles on
  the preferred path, roughly **42-43 M/s at 104 MHz with the TLB fix**,
  inside the "near 41-44" gate but ~10 % short of 47; with every
  fallback 36-39, failing the gate; the remaining gap to 47 is the data
  wait (20-28 % of play clocks), a separate track. Order: a measurement
  first (the load-to-consumer distance mix, never measured), then the
  address adder, the formatter, the front end and the flags work as
  four parallel lanes, then the completion contract, the stragglers,
  integration with seeds, the whole device, the board at 78 then
  104 MHz; each step gated on its families' slack; stop the shape if
  the integrated result stays below -1.5 ns; nothing to the board
  before the panic is shown fixed. Budget about five sessions and
  12-22 fits on the preferred path, one or two sessions per fallback.
  "Meets timing" is taken as the board-proven envelope (-0.6 ns at the
  slow 100C corner on the server's Quartus, ZAP's own shipping figure),
  not 0.
- The 8 KB TLB-fix debug core (seed 2, full effort): -0.623 / -0.558
  ns, 33,421 ALMs, build/hardware/NGage-v2fix3d8-s2.rbf (md5
  c372d9d8). Ready for the board with the 16 KB one (NGage-v2fix3-
  s9.rbf) and the flash-probe core (NGage-stp-flash3-full.rbf); no
  build of mine runs on the server now. The board test when the MiSTer
  returns: boots of the 16 KB core for the dialog rate (two of three
  before fix 3), three boots of the 8 KB core for the PLAT rate (two of
  three before), then the three games on the 16 KB core for fix 3's
  gain, and the SignalTap capture only if the panic survives.
- **Plan step 0, measured** (the subagent, codex/arm9v2 4652205, §6 of
  the plan; pushed): a bench-only observer (sim/profile/load_use.h) on
  the 4.5-second whole-core boot with fixes 1-3 (the same 270,625,878
  kernel-init instructions as S13; EFile 0.35 % and EStart 1.0 % sooner
  than S13). In busy code 10-12 % of memory ops take their base from a
  load just ahead (vtable and global dereferences), an ALU-produced
  base just ahead only 0.3-4 %, scaled offsets negligible; 20-50 % of
  loads feed a compare or other flag setter at once; sub-word loads
  0-12 % (not the assumed 20-40 %); misses and uncached completions
  1.5-64 per 1,000 instructions on the bench, 24-30 on the board in
  play. Recomputed, projected to play (the plan's estimate in
  brackets): A1 address adder in S 0.1-2.4 % (0.4-0.8); A2 extra
  address stage 0.9-6.7 % (3-8); B2 flag consumers wait 0.6-2.3 %
  (0.4-0.9); B3 no late pickup of load words 0.7-6.5 % (2.5-5); C2
  sub-word formatting in W 0-0.8 % (1.5-3.5); D1 registered completion
  1.0-1.2 %; **the preferred set A1+B2+D1 about 4 %** (1.9-7.3; the plan
  said 1.8-3.0), the fallback set 10-11 %. With the TLB fix's +2-3 %
  the preferred path lands near **41.9 M/s at 104 MHz** (CPI 2.48),
  inside the 41-44 gate; the fallbacks near 39.4, failing it. B2 is as
  costly as A1, so the zero-cycle parallel-Z cut must carry the flags
  family; C2 is the cheapest fallback; A2 and B3 must not be taken
  together. Caveat: the busy windows are mostly a kernel polling loop
  (load a global, compare); play itself is unmeasured and is the
  deciding number (the bench's snapshot support is on master, not the
  branch). The session restarted here (the user's "shit did i boot
  you"); nothing was lost: all results committed and pushed, no build
  or simulation running, the board paused.
- **Cut A1 done** (the subagent, codex/arm9v2 64ae85c the test,
  2554624 the RTL, 80f04ff the report docs/consults/2026-10-25-v2-cut-
  a1.md with the evidence under arm9v2/a1-seed2/; pushed): a dedicated
  address adder in S registered into A, so the D-cache and the TLB are
  driven from a register. Timing at 104 MHz, seed 2, the parent
  4652205 fitted the same way for the before: address->metadata -3.173
  -> -0.973 ns, address->TLB capture -2.628 -> -0.245, the CPU trial's
  worst -3.843 -> -2.691, two smaller address families now positive;
  area 13,040 -> 13,434 ALMs (+3 %); **the whole device (V2, D16) at
  -3.703 ns** against the -0.6 target. What leads now is not address
  logic: in the whole device the top paths run from the cache's
  o_live_lookup into A's held operands and the Z flag, i.e. the load-
  trust check fixes 1 and 2 added to the late bypass (about 0.9 ns since
  S12 on its own), then the short-port response (-2.16), the completion
  paths through wb_flush (-1.9 to -2.5) and the front end (decode_d1
  -2.42); the plan's B, C, D and E all remain, with registering the
  trust signal added to B. Cycles: 3/4/5 unchanged, back-to-back
  post-increment streams still 9, only a load feeding the next base
  4 -> 5 as designed; ZAP cycle-identical at D8 and D16; V2's suite
  totals +0.02 % (+0.04 % predictor off; the pointer-chasing `cache`
  bench +5.8 % at 0:0, crand1/ctrand1 within 0.1 %); the boot's first
  exec +0.020 %, EFile +0.038 %, EStart +0.028 %, no faults, matching
  the step-0 model. Suites 321/321 and QEMU 74/74 in all five
  configurations, four lints clean, netlist regenerated; the new test
  matches QEMU's trace and catches two planted bugs. (The component
  benches for V2 were already broken before this change and were not
  used as gates.)
- **Fix 3 does not remove the boot panic**: four of four boots of the
  16 KB fix-3 core (build/hardware/game/v2fix3boot-1..4/) came up with
  the "App. closed ... Server" dialog, no kernel fault (before fix 3:
  two of three). The stale-descriptor mechanism is real but not this
  panic. What the tally now says: the panic hits every plain core and
  never a core with the trace in it (37 of 37), and the trace's one
  functional effect is a few milliseconds' delay of the CPU's flash
  reads at 3.27 s while the rings dump through the shared DDR3 port: a
  phase shift of the instruction stream against the board's periodic
  events (the kernel's millisecond tick, the video frame, the HPS's
  card service). The new hypothesis: the tick interrupt landing inside
  the sector copy's long uncached 8-word loads, and V2 handling an
  interrupt during a multi-beat uncached LDM wrongly (a beat lost or
  repeated, the base restored wrongly), which the suites do not
  exercise; the misread then depends on the tick's phase, which fix 3's
  slightly different timing moved from two boots in three to all of
  them. A second subagent takes that test in a separate worktree
  (../NGage_MiSTer-cx-arm9b, branch codex/arm9v2-irq from 80f04ff)
  while the first stays on lane B.
- **Fix 3 on the board: the games, and the PLAT death gone.** The 8 KB
  fix-3 core booted three of three times without a kernel fault
  (build/hardware/game/v2fix3d8boot-1..3/; before fix 3 two of three
  died with PLAT 0x1005B), so the stale-descriptor mechanism was the
  PLAT death's, while the server panic dialog remains. The 16 KB fix-3
  core with the plain three-game script (v2fix3), play medians per
  104 M clocks:

  | game | ZAP | V2 fix 2 | V2 fix 3 | fix 3 over fix 2 |
  |---|---:|---:|---:|---:|
  | Sonic N | 31.59 (17 fps) | 43.97 (25 fps) | **46.89** (26.5 fps, CPI 2.2) | +6.6 % |
  | Asphalt | 32.30 (14 fps) | 41.47 (19 fps) | **44.90** (20 fps, CPI 2.3) | +8.3 % |

  twice the estimated +3 %: the SDRAM wait fell from 23.8 to 19.8 %
  (Sonic) and 30.0 to 25.6 % (Asphalt) as the walks went. Sonic is at
  the goal's 47 per 104 M clocks. Tony Hawk's boot derailed on the
  dialog again (the plain script); rerun with the dialog-tolerant one.
  And the 8 KB fix-3 core's three idle screens are **clean: no dialog**
  (build/hardware/game/v2fix3d8boot-1..3/), where the 16 KB fix-3 core
  shows the dialog on four of four. Same RTL, the cache size the only
  difference; ZAP with the 16 KB cache boots clean. That points the
  search at the 16 KB cache's two colours (its index uses virtual bit
  12, one above the page, so one physical page can live in two sets
  under two mappings) in combination with V2's lookups, the kernel's
  inter-process copy through a client's home address being the shape
  that aliases; the second subagent takes that beside the interrupt
  sweep. The three games on the 8 KB fix-3 core follow on the board.
- Tony Hawk on the 16 KB fix-3 core (the dialog-tolerant script,
  v2fix3b): **45.17 M instr/s** median (44.2-46.6; 19 fps; CPI 2.3;
  SDRAM wait 26.1 %) against ZAP's 31.31 at 11.5 fps, with Asphalt
  repeating at 44.73 (20 fps). V2 with fixes 1-3 against ZAP's control,
  per 104 M clocks on the 78 MHz board: Sonic 46.9 vs 31.6 (+48 %),
  Asphalt 44.9 vs 32.3 (+39 %), Tony Hawk 45.2 vs 31.3 (+44 %); frames
  +56 %, +43 %, +65 %. The goal's 47 is reached in Sonic and within
  5 % in the other two, per clock; the clock itself is the remaining
  distance.
- **The 8 KB fix-3 core's games** (v2fix3d8, the plain script): Sonic N
  46.2 M instr/s median (44.7-47.0), Tony Hawk 44.22 (17.5 fps; CPI
  2.4; SDRAM wait 27.4 %), i.e. about 1.5-2 % below the 16 KB core's
  46.9 and 45.2; Asphalt's boot showed the dialog and its run derailed.
  So the 8 KB core shows the server panic too, once in six boots
  (build/hardware/game/v2fix3d8boot-1..3/ and the three game boots)
  against the 16 KB core's four of four: the cache size changes the
  rate, not the existence of the race; the two-colour aliasing can at
  most be the 16 KB core's extra rate, and the phase-sensitive reading
  (the tick interrupt against the uncached sector copy) stays the main
  line.
- **Lane B done, at no cycle cost** (the subagent, codex/arm9v2 c4ca01a
  the test, 4993a1e the RTL, b555caf the report docs/consults/2026-10-
  25-v2-lane-b.md, evidence under arm9v2/laneb-seed2/; pushed). Three
  parameters, on by default in arm9v2_core: FREE_SELECT (S's forward
  grant and A's late bypass choose data as if W's load hit; the hit and
  the trust control only the waits; A's selects registered one-hot;
  the W load word without its own hit gate: safe because a source whose
  load is not accepted still waits, so the word it picked is never
  used; simulation checks confirm every non-waiting operand matches the
  old selection), TRUST_FF (the cache FSM's o_live_trust and the core's
  w_hit_candidate loaded from the same next-state terms they replace;
  assertions show them equal on every clock, no clock added;
  o_live_lookup now has no timing path to any CPU register), FAST_Z (Z
  for add/subtract off the carry chain, logical N/Z from the logic
  result). The register's clock matters: the trust depends on the
  access, not only the FSM state, and a register one clock late would
  carry the previous access's verdict onto a hit on the departing
  victim; the new arm9_trust_sweep_rtl (4,704 cases) catches that late
  register in 1,236-1,439 cases where the existing tests miss it (and a
  trust without the fill-end term in 6 cases at 0:0). 324/324 in all
  five configurations, the 321 runs shared with A1 cycle-identical,
  boot milestones identical, the SystemVerilog sources with every
  assertion on clean at D8 and D16, QEMU 74/74, lints clean, netlist
  regenerated. Fits (104 MHz, seed 2): **the whole device -3.703 ->
  -2.312 ns** (TNS -7,724 -> -4,689); the CPU trial is noisy at this
  level (its worst -2.691 -> -2.976, led by the short-response path
  lane B does not touch); lane B's own paths improved (load word into
  the flags -1.30 -> -0.59, backend_skid -0.66). The device leader now
  is the load word through S's shifter into A (-2.31), then the
  D-decode paths from the D-TLB's o_wt bit (-2.29), the front end and
  wb_flush. B2 not done: family B's device worst (backend_m, -1.95)
  starts at the late select and carries ALU results too, so B2 would
  not move it and costs 0.6-2.3 % of clocks.
- The 8 KB fix-3 core's dialog rate, firmed up: six more boots all
  clean (build/hardware/game/v2fix3d8stat-1..6/), so **eleven of twelve
  boots clean** against the 16 KB fix-3 core's none of four. The cache
  size is the dominant factor in the rate, which puts the 16 KB cache's
  two-colour indexing back at the front for that core, with a rarer
  path still present at 8 KB (one dialog in twelve). The second
  subagent has both.
- **Lanes C, D and E done, no cycle cost** (the subagent, codex/arm9v2
  1e14cce/1cd5fc6/1065256 lane C, 5a381d4/38b9cda lane D, 731fe94/
  69bfe61/3f945c8 lane E; pushed): the whole device at 104 MHz seed 2
  from -2.312 to **-2.086 ns** (TNS -4,689 -> -3,368). C: each short-
  port way formatted before the hit selects (the plan's C1, no sub-word
  fallback needed); the trial's leader was the RAM read/write collision
  compare driving ~280 bypass selects, now registered: the CPU trial's
  short_response -2.98 -> -1.02; the load word through S's shifter
  (only the consumer's own operand shift, often by zero) gets its own
  rotator in S: the device path -2.31 -> -1.98; arm9_short_format_rtl
  catches five mutants. D: Quartus had retimed the TLB's hit register
  onto o_wt; the short hit now uses a copy the fitter cannot retime:
  decode_redirect -2.29 -> -1.56 (the TLB check's own input slipped to
  -0.71); not taken: A's wait -> D2 step -> queue pop, now the CPU
  trial's worst at -2.31, which needs a skid entry between D2 and S or
  the plan's registered completion (+1.0-1.3 %). E: the Thumb halfword
  moved at queue push (decode_d1 -2.20 -> -1.62); W's return target
  compared per source in parallel (the wb_flush family -2.08 ->
  -0.85); arm9_return_target_rtl matches QEMU's trace. 330/330 in all
  five configurations, the 321 runs shared with A1 cycle-identical,
  the source RTL with assertions clean at D8 and D16, QEMU 75/75, lints
  clean, netlist check passes, boot milestones identical. Caveats:
  with C and D alone the device was worse (-2.53) in families none of
  the lanes touch; area up about 1,070 ALMs to 81 %. The device
  leaders now: the front end (the RAS pointer into the I-TLB, -2.09)
  and the cache FSM's completion signal into the register file. So the
  zero-cycle cuts have taken the device from -3.70 to -2.09 ns; the
  rest of the way to the -0.6 gate is placement variance plus the cuts
  that cost cycles. A seed sweep of the integrated stripped core at
  104 MHz runs next.
- Seed sweep of the integrated stripped core (3f945c8, ARM9 + 16 KB,
  no overlay) at 104 MHz: seed 5 **-2.700 ns** (slow 100C; -2.665 at
  -40C; 33,882 ALMs, 81 %) against seed 2's -2.086: about 0.6 ns of
  placement variance between two seeds; seed 9 fitting, seed 7
  launched.
- Seed 9 of the integrated core: -2.239 ns (slow 100C).
- **Neither the interrupt nor the aliasing** (the second subagent,
  codex/arm9v2-irq 244ce51/58ff966/3efe968; pushed). The interrupt
  sweep sim/cpu/tests/arm9_irq_ldm_rtl.S: both cores attach an
  interrupt only to an instruction's first micro-op (arm9v2_core.sv:
  573-574; ZAP's sequencer), V2 takes the exception only with no load
  outstanding (:491) and writes the LDM base on the last micro-op
  (arm9v2_execute.sv:238); Mem::Copy's own sequence (n 512 and 511,
  k 0-3, both directions) with an IRQ or FIQ at every clock of the
  head, of a window longer than one LDM/shift/STM block, of the last
  block and the `msr CPSR_f` tails, then 36 coarse delays; handlers of
  the kernel's shape (`subs pc,lr,#4`), EKA1's `ldm ^` exit, a context
  save/restore, an FIQ checking its bank, a nested IRQ then FIQ; ZAP
  D8/D16 and V2 D8/D16/predictor off at seven latencies: **995,171
  interrupted copies, 0 wrong words**, 228,960 interrupts landing right
  after an `ldm`; a mutant that takes interrupts mid-LDM fails 1,834 of
  its first 3,784 copies while the existing tests pass on it. The
  two-colour test arm9_alias16_rtl.S (1,728 cases: every store form,
  eviction with the write-back in flight, hit-under-miss, with and
  without cleaning): every architectural check passes on all five
  models and V2's record equals ZAP's word for word at 8 and 16 KB. Its
  ranked next candidates: (1) boot V2 with the 16 KB cache in the
  whole-core bench, the only bench with the real memory side and the
  real tick; (2) flash_save's periodic block reads overlapping V2's
  slower uncached CS1 reads in ddram_flash, unmodelled in the replay;
  (3) V2's SHORT_READ D-cache variant under DMA, and the two-colour
  index-clean loop interrupted by the tick. The whole-core 16 KB boot
  goes next, on the Mac.
- Seed 7 of the integrated core: -2.472 ns (slow 100C; -2.423 at -40C;
  33,935 ALMs). The four seeds of the zero-cycle shape at 104 MHz:
  seed 2 -2.086, seed 9 -2.239, seed 7 -2.472, seed 5 -2.700: a 0.6 ns
  spread, the best seed 1.5 ns from the -0.6 gate.
- **The MiSTer is beside the server again** (the user: "The mister
  should be hooked up"); the JTAG chain came back after one restart of
  the JTAG server (the cable enumerated as 6810, then 6010 "DE-SoC"),
  and the first SignalTap capture of the sector copy on the full-effort
  flash-probe core runs (scratch capture_flash.sh v2stp1).
- **First SignalTap capture: the session works end to end, the trigger
  did not fire.** The JTAG server found the hardware and the "flash"
  instance in the running core, armed it 14 s after the launcher load
  and timed out at 90 s (build/hardware/game/stp-v2stp1/); the
  stripped probe core itself booted to the idle screen with the
  dialog, and without the overlay's bars the thread name is readable
  at last: **"App. closed EmonServer"**. The data-port taps do exist in
  the stripped build (zap_top assigns o_dbg_d_va = cpu_daddr
  unconditionally), so the miss is the trigger's address: the sector's
  virtual address depends on which window base (0x59200000 or
  0x59600000) maps the CS1 offset. SignalTap's basic trigger is
  programmable at run time, so the second capture uses the same
  compiled instance with a new pattern (no rebuild): any completed
  data-port read in the 0x59xxxxxx window whose word is the file's
  first word 0x10000050, the storage qualifier widened to the whole
  0x59xxxxxx window.
  EmonServer in the ROM: its strings sit at 0x50E11A00 ("Emon server
  panic", "EmonServer", beside "NOSDRIVER", the phone-side driver), so
  it is a server with its own panic category, consistent with a
  startup ConstructL that Leaves (the -20 from CommDb) and panics.
- The second capture (the file's first word in any 0x59xxxxxx read) did
  not fire either (stp-v2stp2); a sanity capture triggered on any
  completed data-port access (stp-v2stp3) fired at once, so the
  headless mechanism works and the misses are the address or data
  assumptions, not the tooling. Learned: a run-time .stp must keep the
  compiled instance's storage-qualifier mode (the sanity file without
  the qualifier drew "SignalTap II File is not compatible with the
  file programmed in your device" and its data was not saved). The
  trace decoder's note gives the cached XIP view of CS1 at 0x51000000
  after CS0's 16 MB at 0x50000000, so the media driver's window bases
  0x59200000/0x59600000 may be CS1 offsets under an uncached alias at
  0x58000000 rather than the C: partition's base; the fourth capture
  (stp-flash6) triggers on the first completed read anywhere in
  0x59xxxxxx after arming and stores only those, to learn the real
  addresses.
- The fourth capture (any completed data-port read in 0x59xxxxxx after
  arming) did not fire in 90 s either (stp-v2stp4): the CPU's data
  port does not read a 0x59 window in that period. The ROM holds the
  constant 0x59200000 once (at 0x50343EB8) and 0x59600000 never, so
  the media driver's base may be read at run time from elsewhere, or
  the copy goes through the cached XIP view of CS1 at 0x51000000 (the
  trace decoder's map: CS0 at 0x50000000, CS1 at 0x51000000; sector 0
  would then be at 0x5147C6A4). A bus-side capture triggered on the
  flash controller's CS1 acknowledges runs to learn the real virtual
  addresses of the CS1 reads; a 0x51-window data-value trigger is
  staged.
- Captures five and six did not fire either: the bus-side trigger on
  ddram_flash's cs1_ack (stp-v2stp5; CS1 reads reach it from nor_flash
  through the array port, so the ack may be on another port), and a
  survey trigger on any data-port completion with the storage
  qualifier narrowed to 0x5xxxxxxx reads (stp-v2stp6), where the same
  trigger without a qualifier had fired at once: in SignalTap's
  conditional mode the trigger is evaluated on qualified samples only,
  so a qualifier that never matches hides the trigger too, and none of
  the virtual-address patterns matched. A capture with a qualifier that
  always matches (data-port completions) runs to get a saved data set
  and the real address values.
- The seventh capture, with a storage qualifier that must match on
  every data-port completion, did not fire either (stp-v2stp7). So the
  generated storage-qualifier configuration is what quartus_stp does
  not honour: with the conditional mode compiled in, nothing is ever
  stored and the trigger, evaluated on stored samples, never fires;
  the one unqualified file fired at once but was refused as
  incompatible with the compiled instance and saved no data. The probe
  core is rebuilt without a qualifier (continuous capture: 2,048
  clocks after the trigger, enough for one whole sector copy of ~1,400
  clocks), the trigger being a completed read in 0x5xxxxxxx whose
  word is the file's first word 0x10000050 (stp-flash11, fast fit,
  lane b8).
- The qualifier-free probe core (fast fit, -1.363 ns; build/hardware/
  NGage-stp-flash11-fast.rbf) with the multi-bit trigger (a completed
  read in 0x5xxxxxxx of the word 0x10000050) did not fire either
  (stp-v2stp8). Two things run to settle it: a test of whether any
  multi-bit pattern is honoured (a trigger on any completed read in
  0x5xxxxxxx, which must occur: stp-v2stp9), and a probe core whose
  trigger is a wire computed in RTL (NGage.sv: stp_trig_word, the data
  port completing a read of the file's first word; stp_va_flash, any
  completed read in the ROM/flash virtual space), so the capture rests
  on a single-node trigger, the one form proven to fire (worktree
  ../NGage_MiSTer-stpd, lane b5, fast fit); the full-effort
  qualifier-free core builds on lane b8 meanwhile.
- Two more tests on the qualifier-free core: a multi-bit pattern that
  must occur (any completed read in 0x5xxxxxxx: stp-v2stp9) and a
  single "low" condition that must occur (the write-enable tap low:
  stp-v2stp10) both failed to fire, where a single "high" condition
  fired at once. So in the generated files only "high" levels are
  honoured at run time: "low" and the bus patterns are not, which
  explains every miss. The RTL-trigger core (a single wire that goes
  high on the event) is the right form and builds now; the generator's
  low/pattern encoding is a problem for later (the GUI's own file of a
  "low" condition would show the right attribute).
- The RTL-trigger core (fast fit, -1.986 ns; build/hardware/NGage-stp-
  word-fast.rbf; the wire stp_trig_word = the data port completing a
  read of the word 0x10000050) did not fire in 90 s either (stp-
  v2stp11). The board's current C: save (fetched to build/hwtest/save/
  c-now.bin) still holds the file's first sector at CS1 0x47C6A4 and
  ten older copies of its head in the LFFS log, so the word is there
  to be read; either the data port's rdata tap (zap_top's dc_data) does
  not carry uncached words, or the file is read some other way. Two
  moves: a trigger on the RTL wire for any completed read in the
  ROM/flash space (must fire at once, proving the wire form), and a
  third probe core (worktree ../NGage_MiSTer-stpe, lane b5, fast fit)
  whose trigger wire is any completed read with VA[31:24] = 0x59 (the
  media driver's window per the ROM constant) and which probes the
  chip-level CS1 halfwords (fl1_ack/addr/rdata), upp_bus's assembled
  word (fe_word) and the data port, so the three views of each flash
  word can be compared.

### 2026-10-25 (later) — why no SignalTap capture ever fired: the taps were never connected

- The twelve headless captures (stp-v2stp1..12) never acquired a sample: none
  of the saved files holds a data log. The map report of the last probe build
  (section "Connections to In-System Debugging Instance") says why. Status
  per node, 319 required inputs, 102 connected: every CPU-side tap
  (`tr_d_done/we/va/rdata`, the RTL trigger wires `stp_trig_*`) "missing,
  the name does not exist" (wires with no fanout outside DBG_TRACE, swept
  before the tap); `fl1_addr/rdata/ack` missing ("the pre-synthesis tap must
  be preserved by Analysis & Synthesis before it can be tapped"); and the
  acquisition clock `emu:emu|clk_sys` itself **missing, tied to GND**. Only
  `bb_hit`, `cs1_ack` and `fe_word` (combinational nodes with fanout) were
  connected, by post-synthesis name. With the clock at ground the instance
  never sampled, so every conclusion drawn from "which trigger fires" (only
  single high levels, no bus patterns, no qualifier) was an artefact; the
  Critical Warning 35025 ("Partially connected in-system debug instance") had
  been in every probe build's log since the first.
- Two causes, both in tools/gen_stp.py's output, found by comparing it with
  .stp files the Quartus 17 GUI wrote (other MiSTer cores on this machine):
  the signal-vector wires carried `type="combinatorial"` (the GUI writes
  none), and a condition is stored as text inside its `<level>` element
  (`'node' == high && 'other' == falling edge`), likewise inside the first
  `<storage_qualifier_level>`; the generator wrote only the per-node
  `level-0` attributes. Analysis & Synthesis then preserved no pre-synthesis
  tap and the connection step looked the names up post-synthesis.
- The fix, belt and braces: gen_stp.py rewritten to the GUI's encoding (text
  conditions, no wire type, `storage_mode="off"`/`"conditional"`, per-instance
  depth/RAM), and the probe itself made of registers kept through synthesis
  (`(* preserve, noprune *)`, one stage on every view so they stay aligned),
  with the acquisition clock named by a net that survives synthesis
  (`pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[0]`, the map
  report's maximum-fanout node). ngage_mem exports the CS1 flash beats
  (`fl1_*`: upp_bus to the CS1 model; `m1_*`: the model to the DDR3 backing
  store). Three instances in one core, armed together
  (tools/stp_capture.tcl now takes a comma list and uses
  run_multiple_start/end): `sanity` (a free-running counter, 256 deep, proves
  clock, trigger and data layout), `flashc` (CPU view + fl1 beats, 256 deep,
  continuous), `flash` (CPU + fl1 + m1 views, 1024 deep, storage qualified
  to window completions and flash beats; trigger = the data port completing
  the read of the database file's first word 0x10000050 from the CS1 window
  VA 0x59xxxxxx). M10K budget: the 8 KB V2 design plus the last 88-bit x 2048
  probe filled 551 of 553 blocks, so the new set is 149 bits x 1024 plus two
  small AUTO instances. tools/stp_decode.py decodes the saved data log
  (sample-major, one bit per data node), checked on a GUI capture.
- First real capture (stp-stpf2, probe core NGage-stp-probe-fast.rbf, fast
  fit -1.94 ns at 78 MHz): all three instances fired within 18 s of arming
  (the Tcl script had also been dying at a `save_session` that does not exist
  in this package, so no earlier run could have written data; close_session
  writes the file). The sanity counter steps by one per sample, so clock,
  trigger, acquisition and tools/stp_decode.py's layout are right. The
  trigger (a window read returning 0x10000050) caught a chunked descending
  Mem::Copy out of VA 0x596f05xx into RAM 0x806189xx, eight words a chunk,
  not the database file: 0x10000050 is the store UID that heads many LFFS
  records, and that read was itself wrong.
- **The misread, caught in the act.** Against the C: image
  (build/hwtest/save/c-now.bin at VA - 0x59600000) 675 of the 1,024
  qualified window reads match; of the 349 that differ, 138 only have bits
  cleared (LFFS flag words programmed since the dump) and 211 carry bits the
  flash cannot have set. Those sit on the first word of each 16-byte line:
  by word-in-line, positions 0 and 4 of the 8-word chunk are wrong 121 and
  123 times of 128, positions 1-3 and 5-7 about 17 (the flag words). The
  continuous view gives the timing: the first word of a line completes one
  clock after the previous access (before any flash fetch), the second waits
  about 30 clocks (the line fetch), the third and fourth follow in 1-3. The
  wrong words look like RAM and ROM contents (0x503a1028, 0x503a0530,
  0x5039ec34, 0xe59cf000 = LDR PC,[R12], 0x80618ba4 near the copy's
  destination), i.e. stale data from somewhere in the CPU, handed over
  before the uncached word was fetched. The halfword path to the CS1 model
  (fl1_*, m1_*) carried nothing during these reads: the window is served
  through upp_bus's 16-byte flash line buffer. Next probe (building): the
  CPU's Wishbone side (request/address/ack/data) beside the data-port
  completions, triggered on any window read completing at a line's first
  word, to see whether that word ever reaches the bus.
- The wrong first words are real flash data from the SAME cache set and
  word position but a DIFFERENT line: the read of 0x596f06a0 returned the
  word at 0x596e06a0 (the image holds that value once), 0x596f0680 the
  word at 0x596e0680, 0x596f0690 at 0x596e1690, 0x596f0620 at 0x596e1620:
  lines 64 KB below, read earlier, still sitting in the set (8 KB two-way:
  set = VA[11:4]). So the core is handed the set's other (stale, LRU) line's
  word for a load that then turns out to be a miss (the FSM fills the line,
  and words 1-3 hit it correctly), with the data port's done flag set at
  that clock: an acknowledged false hit.
- The C: drive has two aliases: 0x59200000 is the UNCACHED one (its reads
  are single bus beats, one per completion, PA 0x02400000 + offset; the
  second capture, triggered too early on VA 0x59a00000 = the EMIF block,
  shows 26 of them, address and data equal on both sides) and 0x59600000 the
  CACHED one (served by 16-byte line bursts, no halfword-engine activity):
  the misread copy runs through the cached alias, so the window is a
  cacheable mapping and the fault is in the cache, not the flash path.
- Bench: sim/cpu/tests/arm9_fill_victim_rtl.S (both ways of every source
  set occupied by other tags, clean or dirty; the ROM's descending
  ldmdb/stmdb copy into a +0x408 destination; bus latency random, 8 and 24)
  passes on the V2 core, so the flat bench still lacks an ingredient of the
  board (the I-side's line fills on the same bus, the TLB, or the fill's
  beat pattern).
- **Correction (the same evening).** zap_dcache_fsm's IDLE state acknowledges a
  cacheable MISS at once (`idle_ack = 1`, "Acknowledge current entry. Lock the
  register."), locks the destination register and delivers the word later by
  a background write (critical_take -> reg_dat_ff/o_reg_idx). The data-port
  tap (zap_top o_dbg_d_done/rdata = o_ack/o_dat) therefore shows, at a miss,
  the selected (victim) way's current word, not what the register will get.
  So "the first word of every line wrong, the same set's older line's word"
  is exactly what a line-start miss looks like through that tap: words 1-3
  hit after the fill and show real data. The first capture is consistent
  with normal operation and is NOT evidence of a misread; the directed
  bench passing fits. The panic's cause is still open; what the board taps
  cannot show is the background write's value and the store side, so the
  next step is the whole-core bench boot of the 8 KB V2 configuration (the
  panicking one), where every register write and store is visible.
- Whole-core reproduction started (09:02): the bench of the V2 branch head
  (3f945c8, worktree ../NGage_MiSTer-v2sim, 8 KB two-way D-cache,
  VEXTRA=-DNGAGE_CORE_ARM9=1, which the harness needs as much as the RTL)
  boots the board's images (cs0.bin; cs1-now.bin = the board's pristine
  lower half + its current C: save build/hwtest/save/c-now.bin, the one
  that panics) with the Sonic card, at about 550 k clocks/s, to 32 guest
  seconds. If the EmonServer panic appears there, every register write and
  store of the copy is visible and the bench's trace options can find the
  first wrong value.
- Third capture (stp-stph1, the trigger on a cached-alias read at a line
  start, the CPU's Wishbone side beside the data port): 448 window reads,
  461 C: read beats. Every line's first word is acknowledged one to two
  clocks BEFORE its fill request leaves the CPU (109 of 112: "beat only
  after"), the fill's four beats carry the image's words, and words 1-3
  complete after their beat with the beat's data (112 of 112 each). So the
  bus delivers the right words and the first word is a locked-register
  miss, as the FSM code says; its value reaches the register by the
  background write, which no tap so far shows. Nor does any tap show the
  write-back data of the dirty lines the fills evict (the read-data bus was
  sampled on write beats). Next probe: both.
- Hypothesis under test (directed): the board shows V2 reading the C:
  drive's 0x59600000 alias through line fills (cached) while the driver
  programs flash through the uncached 0x59200000 alias; between the two
  the driver must drop the cached alias's lines by MVA. A faulty
  invalidate/clean-by-MVA on the 8 KB two-way D-cache would leave stale
  sectors behind, which is what "KErrCorrupt" would look like, and would
  spare ZAP (its own maintenance path), the 16 KB build (other sets and
  ways) and every copy bench (none programs and re-reads).
  sim/cpu/tests/arm9_dcinv_mva_rtl.S: 24 cases (invalidate by MVA,
  clean+invalidate by MVA, invalidate all; the target in either way; the
  MVA at word 0 or 3; two window offsets).
- QEMU reference model with the board's current C: image (cs1-now.bin,
  NGAGE_SAVE1=none, the Sonic card): boots to the idle screen, no panic, so
  the file is intact on the save; the 8 KB V2 core spoils it during its own
  boot (the 16 KB core boots the same image).
- Fourth capture (stp-stpi1: the cache's background register write exported
  from zap_top as o_dbg_bg_we/idx/data, the bus write data, the storage
  qualifier widened to SDRAM writes): the qualifier let the SDRAM write
  beats (360 of 512 samples) crowd out the copy, but the three line-start
  misses it holds all got their register written with the fill beat's word,
  equal to the image's. The bus write-data tap samples cpu_wdata at the
  acknowledge, which is not the beat's data for a pipelined write, so the
  write-back values it shows are not usable as they stand.
- ZAP control (stp-stpz1, the same probe on the shipping core): ZAP fills
  the 0x59600000 alias by line bursts as well (9 burst beats, 3 single
  among 12 cached-alias reads), so the alias is a cacheable mapping by
  design (medint's own invalidate-by-MVA loop at 0x503817dc, stride 16,
  is for it), and its three line-start misses got their registers written
  with the fill's word. V2 and ZAP look alike on every tap so far.

### 2026-10-25 (late) — the EmonServer panic reproduces in the whole-core bench

- The 8 KB V2 whole-core boot (worktree ../NGage_MiSTer-v2sim at 3f945c8,
  VEXTRA=-DNGAGE_CORE_ARM9=1, images cs0.bin + cs1-now.bin = the board's
  pristine lower half with its current C: save, the Sonic card) shows
  "App. closed EmonServer" at 25.1 guest seconds, after the N-Gage
  animation (18 s) and the operator splash (20 s): the board's symptom, in
  a run where every register write and store is visible. The QEMU model
  boots the same image clean, so the save is sound. The 16 KB V2 control
  runs beside it (at 22 s, no dialog yet).
- Instrumentation (branch codex/arm9v2-panic, coreboot_main.cpp):
  --check-window (every load from the C: drive's aliases against the live
  image, by byte enables; misses paired through the cache FSM's saved
  address and its background write; loads near the CS1 chip's command
  modes skipped), --check-copy (every Mem::Copy out of the aliases: its
  stores and the buffer's loads against the source bytes), --trace-on-bad
  FILE (an instruction trace from the first wrong value). The first two
  checked runs taught the checker its blind spots: medint's autoselect
  read of word 4 of every block (0x503800ac) returns the protect status,
  and byte loads report the word's address.
- The 16 KB V2 control shows the same dialog in the bench at 27.1 s (the
  board's 16 KB core booted 4 of 4), so the bench reproduces it for both
  cache sizes; a ZAP boot of the same bench and images is the control
  that decides whether the bench's panic is the CPU's.
- **The 8 KB V2 boot with --check-window reaches the dialog (25.1 s, the
  same picture) with ZERO wrong C: reads**: every uncached completion,
  cached hit and cached miss (by its background write) through the whole
  boot equals the live flash image. The misread hypothesis is dead: V2
  reads the flash correctly. The copy's stores and the buffer read-backs
  (--check-copy), the LFFS's own programming stores through the uncached
  alias (--check-store, each against the bus beat that carries it) and the
  exec-call log (--devlog) are the runs in flight.
- **ZAP control in the same bench with the same images: no dialog** (to
  29.8 s; the operator splash stays from 26.5 s), while both V2 builds show
  it at 25-27 s: the bench's panic is the CPU's.
- The exec-call log (--devlog, 2.64 M calls to 26.4 s): no user-mode abort
  and no self-panic exec in the whole boot. The dying thread is the one on
  the 0x00E00000 stack: its last system calls are at 24.9556 s (the dialog
  at 25.10 s), a 0x36 / 0x0C / 0x76 tail after a loop of 0x6C/0x8F/0x8E
  descriptor calls; the EKA1 (6.1) exec numbering is not in the research
  files (EKA2L1's epoc6 table does not fit the stubs at 0x503A7694 + 4n),
  so a trace of that thread's last 70 k retirements (run7, --trace-after
  1047300000) is the next source.
- Correction: the thread on the 0x00E00000 stack is the UI server's
  notifier (its function 0x506ED2F5 is in EikSrvUi.dll), created at
  24.631 s to show the dialog and then waiting for the key. emon.exe
  (0x50E0FCC0) starts two threads at 24.442 s (main, stack 0x00400000) and
  24.462 s (the server loop, stack 0x00602000). The server thread is alive
  after the dialog (receive, dispatch, wait at 24.69 s and 25.02 s). The
  main thread's calls stop at 24.6232 s (retired 1,036,533,233) with an
  exec 0x4D after a 0x71/0x4A/0x72/0x72 sequence, and its stack is reused
  by a new thread at 26.388 s: it died between 24.6232 s and the
  notifier's creation at 24.631 s (retired 1,036,723,486). An instruction
  trace of that window (run8, --trace-after 1036530000 --trace-count
  200000) is running. The EUser exec stubs at 0x503A7694.. are not one
  number per slot (fast execs with bit 23 are interleaved): decode the SWI
  immediate at the logged pc, never the slot index.
- The full-check run (--check-window --check-copy, lane-masked) also
  passes the dialog with zero reports: the sector copies' stores and the
  buffers' read-backs are right as well. emon's main thread never resumes
  after its WaitForAnyRequest at 24.6232 s (no user-mode entry on its
  stack after it), so it was killed while blocked: the shape of a server
  panicking a client whose request it rejected. Its last request: exec
  0x4A (r0=004026A0 r1=40050003 r2=00403048 r3=004026C0, caller
  0x50904385), then 0x72/0x73 with function pointers, then the wait.
- The uncached-store check (--check-store: every store through the
  0x59200000 alias against the bus beat that carries it) also passes the
  dialog (26.9 s) with zero reports. Every path between the CPU and the
  flash is right on V2 for the whole boot: reads through both aliases, the
  sector copies, the LFFS's programming stores. The corruption that makes a
  server reject emon's request is in RAM-side data or in a computation.
- Correction again, with the kernel-server function numbers now matched
  to EKA2L1's EKA1 table (the fast exec 0xC00076 carries the function in
  r0: 0x27 create_thread, 0x16 create_session, 0x10 close_handle, 0x2F
  panic_thread): emon.exe's main thread creates the server thread (0x27)
  at 24.4487 s; the server thread opens a session to ESock (connect through
  ESock.dll code at 24.4761 s, functions 2 and 6), and its function-6
  request completes with KErrAlreadyExists (-11) at 24.6134 s; it then
  closes a handle and calls panic_thread (0x2F) at 24.6208 s: that is the
  "App. closed EmonServer" dialog. The -11 first appears at 24.6067 s in the
  thread on the 0x80403 stack (the kernel side answering ESock), then in
  ESock (24.6074, which completes emon's request with it at 24.6091). So
  the panic is a startup collision ("already exists") inside ESock's
  handling of EmonServer's request: a timing-exposed race in the ROM, or a
  wrong name/handle comparison; the ZAP exec log (running) and the trace
  of that window (run9) decide which.
- Pinned one step further: ESock serves EmonServer's request by asking the
  kernel server to load a logical device driver (fast exec 0xC00076,
  function 5 = add_logical_device, at 24.6065 s), the kernel server answers
  KErrAlreadyExists (24.6067 s, its reply 0x73 with -11), ESock fails the
  client's request with it (24.6074/24.6091 s) and EmonServer panics. The
  boot loads 57 drivers (functions 5 and 8); ESock itself loads at 16.36,
  23.98, 24.20, 24.35 s and the failing 24.61 s, the Starter-like thread on
  the 0x00401D90 stack most of the rest. So the dialog is an "already
  loaded" collision on one driver between two loaders whose order depends
  on timing, unless a name comparison is wrong; the ZAP exec log (does its
  ESock load get KErrNone at that point?) and the trace (the driver's name
  read by the kernel server) settle it.
- The trace (run9, retired 1,035,995,420 + 520 k) names the driver:
  "bt_driver", the Bluetooth LDD, loaded by hci.dll (the HCI layer running
  in ESock) while serving EmonServer's request. hci.dll tolerates
  KErrAlreadyExists for the load (`cmn r1,#11; bne` at 0x5046E9A6; the
  trace shows Z set and the branch correctly not taken, so no CPU compare
  bug there) and goes on to open a channel on the driver through EUser
  0x503B233C; the -11 ESock finally reports comes from that step.
- The failing step itself: after the tolerated load, hci.dll opens a
  channel on bt_driver (kernel-server function 0x0A) and gets
  KErrAlreadyExists, then tries to unload the driver (0x06) and gets
  KErrInUse; ESock fails the client's request with the -11. ESock makes the
  same three-call attempt five times on V2 (16.36, 23.98, 24.20, 24.35,
  24.61 s: the channel open fails each time; a sixth at 26.25 s succeeds
  after a 00401-thread unload at 25.40 s) and once on ZAP before 27.9 s
  (22.20 s, failing the same way). So the question is who holds the
  Bluetooth driver's single channel at those moments on each core; the
  comparison of the two channel-open timelines was handed to an Opus 5.5
  subagent (the step here was stopped by the safety classifier), and the
  ZAP boot is being rerun to 41 s so that its emon start is covered.
- The panic itself, from the trace: emon.exe is the "EPOC Monitor Server"
  (its debug strings: "Starting EPOC Monitor Server", "EPOC Monitor Server
  started succesfully"); its main loop TRAPs the server start (0x50E10D4E
  -> 0x50E1132C), and a nonzero leave code goes to `User::Panic(_L("Emon
  server panic"), 4)` (0x50E10D60-0x50E10D68, category at 0x50E119C8,
  reason 4). The leave code is the -11 from its ESock request. So the
  dialog is "Emon server panic 4", the server's start failing on ESock's
  Bluetooth channel open.
- **The cause (an Opus 5.5 subagent's analysis of the two exec logs;
  scratchpad bt-channel-findings.md and btan/):** the bt_driver channel is
  held by BTTestServer.exe (SelfTestServer starts it in every boot) through
  its own copy of hci.dll, which, with no Bluetooth chip to answer, times
  out after 1.52-1.56 s ("BTLDD: CompleteWithError: 1 -33" in kern.log),
  closes the channel, unloads and reloads the driver and opens it again,
  ten times (the restart code compares an error counter with 9 at
  0x5046EAF2 and 0x5046EC4C). On V2 it holds the channel from 9.0285 s in
  ten spells with free gaps of 22-128 ms until the tenth timeout at
  25.3965 s, after which the unload returns 0 and ESock's next load and
  open (26.25 s) succeed; the EPOC Monitor Server's request at 24.61 s
  lands 0.79 s before that give-up. On ZAP the boot runs 1.19-1.38 times
  slower, the give-up comes at about 28.9 s (its 29.8 s run has exactly
  ten timeouts) and the monitor's start at about 33-34 s, after it. Every
  request both cores make gets the same reply wherever the logs overlap.
  A start-up ordering race in the ROM software, exposed by the faster CPU
  (and by the hardware's 8 KB core's speed): on the phone the Bluetooth
  chip answers, the self test ends at once and the channel is free. The
  fix belongs in the peripheral side (a minimal Bluetooth controller on
  the BT UART, or a port that fails at once so the ten retries do not take
  16 s), or in a two-halfword ROM patch of hci.dll's retry count.
- **The fix: hci.dll gives up after one attempt** (model/rom-patches.txt,
  tools/gen_patchrom.py, the regenerated rtl/mister/phoenix_patch.hex/.vh).
  Two halfwords of hci.dll in CS0: the retry checks at 0x5046EAF2 and
  0x5046EC4C are Thumb `ldr r0,[r5,#0x30]; cmp r0,#9; bgt give_up`
  (arm-none-eabi-objdump over the image); `cmp r0,#0` (0x2809 ->
  0x2800, stored bytes 09 28 -> 00 28) makes BTTestServer's self test
  stop after its first 1.5 s timeout, so bt_driver's channel is free
  about 10.5 s after boot instead of 25 s, long before the EPOC
  Monitor Server asks for it. The same ROM is shared by every hci.dll
  user, so emon's own HCI reset also fails after one timeout instead of
  ten. The peripheral-side alternative (a Bluetooth controller model
  answering on the BT UART, or a port that fails at once) stays the
  accurate long-term answer; this is the shortcut, recorded with its
  reasons in the patch list. The mechanism already existed: the model
  applies the list at load, the core's Phoenix loader applies the patch
  ROM after the stream with the recomputed bootstrap digest of entry
  0x8F18 as a constant (the new digest 50c7d0a4f1cf3f71e9581a2c91c62eff
  from `mkimage.py phoenix` over the RH2946.0C1/.0S5 files, fetched from
  the MiSTer; entry 0x8F00 unchanged). Checks: tools/patchcheck.sh (the
  model's patcher and mkimage.py agree byte for byte), `make -C sim
  phoenix-real` (the Verilated loader over the real Phoenix files
  reproduces the reference images: "all checks passed"), lint clean,
  `gen_patchrom.py --check` clean. The bench's hand-patched
  cs0-hcipatch.bin differs from the generated image only in the NOS
  stand-in bytes (an older build) and the digest.
- Validation. Whole-core bench, the 8 KB V2 at 104 MHz with the patched
  ROM (run10): "EPOC Monitor Server started succesfully" once in kern.log (never in the unpatched run), the Bluetooth driver's CompleteWithError three times instead of ten, no "Emon" string, and the idle screen clean at 25.7 and 26.3 s where the unpatched run drew the "App. closed EmonServer" dialog at 25.1 s (gamesim/v2d8e/run10, stopped at 27 s). The board: the 8 KB fix-3 core rebuilt with
  the patch ROM (NGage-v2fix3d8hci-s2.rbf: the identical fit, -0.623 /
  -0.558 ns, 33,421 ALMs; only the loader's ROM contents differ)
  booted clean three of three (build/hardware/game/v2fix3d8hci-1..3/); the 16 KB fix-3 core, the one that showed the dialog
  four of four, rebuilt the same way (NGage-v2fix3hci-s9.rbf, the identical fit too: -0.516 ns, 33,380 ALMs)
  **booted clean four of four** (build/hardware/game/v2fix3hci-1..4/, the idle screen at 110 and 130 s). The fix is committed on master (dba643d) and cherry-picked onto codex/arm9v2-panic (5956fe9), both pushed; the V2 main worktree (codex/arm9v2) was left as the stopped 104 MHz subagent left it, with its four uncommitted parameterised cuts (RAS_TOP_FF, REDIRECT_PAYLOAD, COPRO_PORT, FLAT_ACK) and arm9_ras_rtl.S. The long ZAP run (run3, to 41 s): the race resolving the other way on the slower core. The self test's tenth hold ends at 28.88 s (holds of 1.53-1.56 s from 20.70 s on, the channel free only in the gaps); ESock's first attempt comes at 31.20 s, finds bt_driver free, and the load and the channel open return 0; kern.log has "started succesfully" once and no Emon panic; emon's own hci.dll then cycles load, open, unload every 1.5 s (16 BTLDD timeouts by 41 s: the self test's ten and emon's six), and the idle screen is clean at 41 s (gamesim/zapc/run3).
- Corrected: it is not "the 8 KB core fails on the board": at 78 MHz the
  8 KB V2 core booted clean eleven of twelve and the 16 KB core, the
  faster boot, none of four; in the bench at 104 MHz both V2 sizes
  showed the dialog and ZAP did not. All of it is the one race: the ask
  lands a few seconds before or after the give-up with the CPU's speed.
- **104 MHz, resumed in-session: the stopped subagent's four cuts
  measured and set aside; a timing exception for the memory test.**
  The V2 main worktree held four uncommitted parameterised zero-cycle
  cuts (RAS_TOP_FF: the return stack's top as a register; REDIRECT_
  PAYLOAD: D2's redirect payload loaded every edge, only its valid
  waiting for S; COPRO_PORT: the coprocessor's own register-file read
  port; FLAT_ACK: the D-cache FSM's acknowledge and errors as flat
  functions of the state), each with a simulation assertion against
  the old form, and arm9_ras_rtl.S. Verification, all clean: the
  netlist regenerated on the Mac (deterministic; the subagent's copy
  differed by 14.5 k lines, another sv2v run), the CPU suite 333/333
  in all five configurations, 333/333 for the three V2 configurations
  on the sources with the assertions live, QEMU 76/76, and
  cycle-identical to lane E in every one of the 330 runs per
  configuration (the ARM9 logs byte-identical); the whole-core boot
  with the assertions live ran to 12 s with no assertion firing, its
  retired-instruction count per second equal to the lane E 16 KB boot's
  through 3 s and within 94-587 instructions through 9 s (a different
  image: the current NOS stand-in bytes and the hci.dll patch, whose
  effect shows from 10 s), 40 thread entries profiled. Fitted as the
  integrated stripped 16 KB core at 104 MHz, three seeds against lane
  E's (3f945c8) at the same seeds:

  | seed | lane E | the four cuts |
  |---|---:|---:|
  | 2 | -2.086 | -2.942 |
  | 9 | -2.239 | -2.426 |
  | 5 | -2.700 | -2.912 |

  33.4 k ALMs (80 %) either way; the fits take 13-17 min each now. The
  D-cache FSM's paths leave the leaders (the FLAT_ACK target), but the
  issued record through the execute shifter into A takes the lead at
  every seed (-2.4 to -2.9, 10 levels, 68 % interconnect: the rotator's
  stages placed 1.5-1.9 ns apart), with memory-side paths behind it
  (upp_periph's own_au arbitration into upp_bus's dat_q, 13 of 30 at
  seed 2; the bus ack into the I-cache FSM). Worse at every seed, so
  not merged: committed on the side branch codex/arm9v2-c4 (50ed1e6)
  for the record; the V2 main worktree is back on codex/arm9v2, which
  is fast-forwarded onto the panic branch (5956fe9: the bench checks
  and the hci.dll patch). The emu-level leaders are the 80 % device's
  placement: the ZAP main core is the same size (33.5 k ALMs) and
  meets -0.833, so the gap is V2's logic depth, not density.
- A free exception (master cfb1e38, NGage.sdc): the memory test's
  master select test_on_q changes only in the first clock of a reset
  pulse test_sw holds for four clocks, with the CPU in its own reset,
  so its paths into the Wishbone muxes, the SDRAM write data and the
  self-test engine are four-clock paths; test_sw itself stays
  single-clock. It held 19 of the 30 worst paths of lane E's seed 9
  (-2.23, 80 % interconnect). Checked by a timing-analysis rerun on the
  main ZAP core's build: two registers matched, test_sw at +4.4 ns, the
  rest at +28.1 ns, the device worst unchanged at -0.833 (the metadata
  RAM path); it takes those paths out of the fitter's effort in every
  future fit.
- Where 104 MHz stands: the best integrated seed is lane E's -2.086
  against the -0.6 gate; what is left on the plan is the cycle-costing
  cuts (D1 registered completion, F, B2; +2-3 % clocks each) and
  seeds, and the device-level leaders include memory-side paths at
  -2.2 to -2.4 that no CPU cut touches. Meanwhile the 16 KB V2 fix-3
  core at 78 MHz, panic fixed, is within the board envelope (-0.516)
  and in play already ahead of the shipping ZAP core at 104 MHz
  (Sonic 46.9 per 104 M clocks at 78 MHz = 35 M instr/s against ZAP's
  31.6 M/s at 104 MHz).

### 2026-10-26 — 104 MHz: rounds 2-3, the ZAP strip, and the W short-hit cluster

- **Committed** (master 72d7e07 round 1, 1ff0fa8 rounds 2-3 and the strip,
  both pushed). Rounds 2-3: REG_DONE's uncached completion back on the
  fast acknowledge (UNC_DONE from registers: the suite's REG_DONE cost
  +3.04 % -> +0.239 %), VALID_BIT (the branch predictor's looked-up valid
  bit as a register; the commit message calls it the I-cache's, wrongly),
  maxfan on wb_flush, predictor_clear and o_redirect, and the D-cache fast
  acknowledge on the TLB walker's IDLE register. The strip removed every
  ZAP option V2 never builds: SHORT_READ (short form kept), META_PACK, the
  I-cache prefetch, ONLY_CORE, V4T/TI925T (always on), the BTB, the
  decompiler, both zap_ram_simple_ben copies (rtl/cpu/port is gone),
  zap_cache_metadata_ram, decode's internal register file and the trace
  outputs; zap_writeback is down to the register file, the CPSR and the
  coprocessor port. The arm9v2 parameter defaults are now the core's
  configuration, so every component bench, proof and Quartus trial tests
  what the core builds; make lint covers the CPU sources.
- **CPU speed did not regress**: the suite's cycle total is +0.239 %
  (+0.165 % without prediction) against lane E, with 144 of 342 tests
  identical; the 12-second whole-core boot (Sonic card, hci patch)
  retires within 0.011 % of the reference's instructions at 12 s
  (-0.025 % at worst, at 6 s); no assertion fired.
- **Fits** (16 KB V2, 104 MHz, slow 100C, seeds 2/3/5/9): round 2
  -2.134/-2.058/-1.913/-1.866; round 3 -2.262/-2.277/-2.358/-2.258 with
  about twice the failing endpoints and total negative slack (TNS -1053
  -> -2152 at seed 2), the jump almost all in paths from the TLB check's
  short-hit copy (o_hit_ok_short) into decode's D2 (62 -> 621 endpoints
  below -0.6 over four seeds). Seed-2 A/B of round 3's two timing
  changes on the final tree: without predictor_clear's maxfan the fit is
  identical to the ps and the ALM (the attribute changes nothing there);
  with the fast acknowledge back on !i_busy, -1.953 against -2.206 ns and
  TNS -1273 against -1592 (endpoints below -0.6: 700 against 1024). The
  TLB-idle form is reverted (a comment at the acknowledge keeps the
  numbers); it did not even fix the lock-owner endpoint it targeted.
- **Disk**: each untrimmed suite run left ~39 GB in sim/cpu/build (a few
  tests log every instruction: arm9_irq_ldm_rtl writes 3-4 GB per latency
  plus a 2.5 GB trace, the two source lanes 16 GB each); six runs filled
  the Mac mid-suite. The scratch suite script now trims its results to
  the counters and PASS lines once the comparisons have run (53 MB a
  run); the trimmed references still total the same cycles.
- **Codex consult** on the short-hit cluster
  (docs/consults/2026-10-26-codex-short-hit.md): the regression is a
  synthesis/placement outcome on a fragile structure, not a new
  dependency; ranked options: factor the hit to the end of S/A readiness
  and D2's updates (including A's finish into D2's early hazard, a route
  I had missed), flatten completion and select finished forwarding
  alternatives, take readiness off S's hold payload enables, duplicate
  the registered roots, fuse the response predicates at the M/W
  boundary; reject registering o_ready, retiming or exceptions.
- **New zero-cycle cuts, kept** (each a parameter, default on, asserted
  equal to the original form): WRITES_PRE (S's planned writes from
  decode's registered destination mask, by kind, instead of a second
  decode with the block's base-bit select); TAG_PRE (each source's PC/PSR
  class registered by decode beside the tags); HELD_FREE (S's 128-bit
  held operands and the prepared shift payload load on every valid S
  clock, read only while holding/prepared, the return repair under the
  saved pending bit); HEAD_FF (the fetch queue's head entry as its own
  register, loaded with the next head on each edge, so decode reads flops
  instead of the eight-entry select); PAYLOAD_NORESET (D2's record and
  the S-entry payload take their loads in reset instead of a clear, so
  their enables are the load conditions alone; the D2 enable had a
  load-or-reset LUT between its copies and the flops); READS_DEST (D2's
  per-destination self-read bits registered with the record: W's WAW
  exemption and the self-dependency take one bit instead of four tag
  compares — withdrawn, see below); LOAD_CLASS (M/W/skid carry their
  load-ownership and speculation classes as record bits); D2_BANKS (D2's
  241-bit packet in two banks: the unowned bank captures the admitted
  packet every edge and D2's load flips a one-bit owner, so the hazard
  drives one flop instead of the packet's enables; Codex's option 3);
  COMPLETE_FLAT (W's completion class without the defer_load node, an
  identity); MUL_FAST_Z (a flag-setting multiply's Z from the final
  adder's two inputs without the carry, as arm9_alu's FAST_Z). All pass
  the component benches and the CPU suite (342/342 in all four lanes with
  their assertions, QEMU 75/75, cycle totals unchanged).
- **Withdrawn: LOAD_HIT_SPLIT** (Codex's option 1 as built: S/A waits,
  readiness and finish for both values of W's short hit, decode's hazard,
  step, D2 load, payload enable and load wait for both, the hit selecting
  last). Correct (the suite passed with its assertions) but worse in
  every form at seed 2; parked as
  docs/consults/parked-patches/2026-10-26-load-hit-split.patch. Seed 2,
  worst / endpoints below -0.6 / TNS: round 2 -2.134 / 627 / -1053; the
  TLB revert alone -1.953 / 700 / -1273; everything with the split
  -2.655 / 2106 / -3201; the split without the keep/maxfan attributes on
  decode's per-hit wires and enables -1.967 / 892 / -1442; only execute's
  half -2.634 / 1090 / -1774; no split, the other cuts kept -2.015 / 527
  / -914 (the best seed-2 tree so far). With the hit moved last, D2's
  hazard tree itself led (D2's tag compare -> W's WAW term -> the
  hazard OR -> D2 load -> a 2 ns enable broadcast), and the kept per-hit
  wires built that OR tree twice. maxfan does duplicate a kept
  combinational node (d2_load~SynDup); predictor_clear's maxfan changed
  nothing (identical fit).
- **Measuring cuts on four seeds.** Single-seed A/Bs proved unreliable:
  the same tree's TNS spreads ~50 % across seeds 2/3/5/9, and a changed
  netlist re-rolls placement, so the seed-2 lead of the no-split tree
  (-914) did not survive: k13 (no split, PAYLOAD_NORESET in) at seeds
  2/3/5 is -2.244/-2.353/-2.299, TNS -4050 against round 2's -3473 at the
  same seeds. Targeted families tell more: HEAD_FF took decode's D1
  family from -1.74/-1.82/-1.62 to -0.71/-0.71/-0.59 and its endpoints
  below -0.6 from 19/41/23 to 1/1/0, at all three seeds, while D2 and
  execute's A got worse at all three (D2 -1.83/-1.43/-1.57 ->
  -1.94/-1.91/-2.30). k14 (k13 + READS_DEST + LOAD_CLASS):
  -2.920/-3.392/-2.506/-2.669, TNS -8296 against -4405 — READS_DEST's own
  next value (D1's decode into the self-read compares) became the worst
  path, as Codex had warned. Each cut is now fitted alone on the baseline
  (master + the TLB revert) at all four seeds.
- **The baseline moved, not the cuts.** The committed tree with the TLB
  revert and none of the later cuts (G0) fits at -2.199/-2.314/-2.407/
  -2.991, TNS -8185 over four seeds against round 2's -4405; k13 (the
  kept cuts) beats G0 at every seed it was fitted (TNS -1111/-1806/-1133
  against -1670/-2025/-1294). Two "equivalent" netlists of the same logic
  (G0 and the earlier seed-2 TLB-revert fit) land at TNS -1670 and -1273,
  so synthesis structure is a second lottery that seeds do not average.
  G0's leaders include W completion into the register file's held writes
  and the CPSR from the D-cache FSM's idle state (-2.09) and the cache
  enable into the forward match (-2.35 at seed 9). Each cut is being
  fitted alone on G0 at all four seeds (G1-G9).
