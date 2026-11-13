# Building and testing

Everything on this page was last run on 2026-11-10 (macOS on Apple silicon,
Quartus 17.0.2 Lite on a Linux server), the tests and the core build also
from a fresh clone. No firmware is needed unless a section says so: the firmware is Nokia's
and is never in the repository.

## Tests

- `make lint`: Verilator lint of the RTL (Verilator 5; 5.054 was used).
- `make test`: the 17 benches of the board devices, the memory system and the
  whole core, about seven minutes (Verilator and a C++17 compiler). Some
  benches also replay recordings from `model/.out` when they are there and
  skip that part when they are not.
- `make -C sim flashcopy hps-read-test`: two more checks on the whole core, a
  flash-to-RAM copy by the CPU and the bench's disk adapter (arm-none-eabi
  binutils).
- `make -C sim/cpu bins model run`: the CPU's 351 directed and random tests on
  the RTL (arm-none-eabi binutils). `make -C sim/cpu qemu diff` compares them
  with QEMU (qemu-system-arm and arm-none-eabi-gdb).
- `make cpu-gen-check`: `rtl/cpu/arm925t_gen.v`, the netlist Quartus compiles,
  matches its sources (sv2v 0.0.13). `make cpu-gen` regenerates it.
- `make patchrom-check`: the firmware patch ROM (`rtl/mister/phoenix_patch.hex`)
  matches the patch list, `firmware-patches/rom-patches.txt`.
- `make standin-check`: the binaries in `firmware-patches/bin` match
  `firmware-patches/nos-stub` (arm-none-eabi-gcc).
- `make scramble-check`: the flash scrambler's three copies agree
  (`tools/nos_scramble.py`, `model/hw/ngage_scramble.h`; the core's copy in
  `rtl/mem/ddram_flash.sv` is checked against the header by the `ddrflash`
  bench).

`make help` lists the single benches.

## The core

The project is an ordinary MiSTer one. Open `NGage.qpf` in Quartus Prime
17.0.2 (the Lite edition is enough) and compile it, or run
`quartus_sh --flow compile NGage` in the repository root. The core is
`output_files/NGage.rbf`. Nothing else is needed: a fresh clone compiled this
way gives the released file bit for bit.

- **The core does not meet its 104 MHz constraint yet.** Quartus finishes the
  compile without errors and with the critical warning "Timing requirements
  not met". The worst setup slack was -1.6 to -2.4 ns over eight fitter seeds
  on 2026-11-10; `NGage.qsf` carries the best of them (`SEED`). The released
  core is such a build and runs on the board.
- A build is reproducible: the same source, seed and date give the same RBF.
- `./build.sh` is optional, for a build server: it copies the tree to a Linux
  machine over ssh, runs the same compile there in Docker (image
  `theypsilon/quartus-lite-c5:17.0.2.docker0`) and fetches the core and the
  reports of `tools/report_timing.tcl` into `build/`:
  `BUILD_HOST=myserver BUILD_DIR=some/dir ./build.sh`. It needs zsh, ssh and
  rsync here and Docker on the server, and exits with status 2 while timing
  is not met.
- `./deploy.sh [host]` copies `output_files/NGage.rbf` to a MiSTer (default
  `root@mister`) and loads it.

### The measurement core

Uncommenting `VERILOG_MACRO "NGAGE_DEBUG=1"` in `NGage.qsf` adds the debug
overlay, its per-second counters and the trace triggers (about 1,700 ALMs).
The OSD then has **Debug overlay**, and `tools/mister_dbg.py` decodes a
screenshot of it. Every build without the macro is the plain core.

## With your own firmware

- `tools/mkimage.py phoenix RH2941.0C1 RH2941.021 -o build/coreboot` makes the
  flat flash images `cs0.bin` and `cs1.bin` that the firmware bench and the
  reference model read. They are flash as the chips store it: CS0
  `0xA000`-`0x2ACFFF` is scrambled, the patches there included, and the core
  decodes it on reads. Images made before 2026-11-12 held the patches there
  as plain bytes and do not run on this core: make them again. `--plain`
  writes CS0 decoded, for a disassembler.
- `make -C sim phoenix-real PHOENIX_REF=build/coreboot` runs the core's
  loader over the two firmware files, in both orders, and compares the flash
  it writes with those images.
- The core recognises the firmware file (4.10's `RH2941.0C1`) and takes any
  of 4.10's language packs with it: the patches all lie in the firmware
  file. `RH2941.021` (the Romania variant, English first) is the pack the
  project runs; `RH2941.002` (Euro 1) has also booted in the model. `mkimage.py`
  wants `--force` for a pack other than `.021`.
- `make -C sim coreboot` boots the firmware on the whole core in Verilator.
  It runs for hours. Its CPU profile (`CORE_PROFILE=1`) is out of date and
  stops the bench when switched on.
- `model/build.sh` builds the reference model: QEMU 11.1.2 with the `ngage-qd`
  machine in `model/hw` (QEMU's build requirements and arm-none-eabi-gcc).
  `model/run.sh` runs it; its header lists the options.
- `tools/mkcard.py` makes card images, for the core (`.mmc`) and for the model.

## On the MiSTer

The core takes its files from `/media/fat/games/NGage/` as the
[README](../README.md) describes: MiSTer sends `boot0.rom` and `boot1.rom`
and mounts `boot0.vhd` when the core starts. The firmware has to arrive before
the language pack, which is why it is `boot0.rom` and not `boot.rom` (MiSTer
sends that one last).

A launcher can add a card to those files:

```xml
<mistergamedescription>
    <rbf>_Console/NGage</rbf>
    <file delay="1" type="s" index="1" path="sonicn.mmc"/>
</mistergamedescription>
```

Or name every file itself, with no boot files in the folder. The file indexes
are 1 for the firmware and 2 for the language pack, and the image slots are 0
for C: and 1 for the card (the other way round before 2026-11-10):

```xml
<mistergamedescription>
    <rbf>_Console/NGage</rbf>
    <file delay="2" type="f" index="1" path="RH2941.0C1"/>
    <file delay="1" type="f" index="2" path="RH2941.021"/>
    <file delay="1" type="s" index="0" path="my-c-drive.vhd"/>
    <file delay="1" type="s" index="1" path="sonicn.mmc"/>
</mistergamedescription>
```

## The firmware unpacker page

[web/](../web) is the page the README links to
(<https://ngage-mister.vercel.app/>): static files, no build step.
`web/unpack.js` reads Nokia's data package (a Microsoft cabinet that holds an
InstallShield cabinet) and accepts the two files in it by SHA-256.

- `node web/test.mjs RH-29_dp_emea_v_10_0_MCUSW4_60.exe` checks it against the
  real package.
- `vercel deploy --prod` in `web/` publishes it (project `ngage-mister`).
- `web/vercel.json` sends a content security policy that allows no
  connections: the page cannot send a file anywhere.
