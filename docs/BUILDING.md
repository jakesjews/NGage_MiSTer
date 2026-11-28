# Building and testing

Everything on this page was last run on 2026-11-10 (macOS on Apple silicon,
Quartus 17.0.2 Lite on a Linux server), the tests and the core build also
from a fresh clone. No firmware is needed unless a section says so: the firmware is Nokia's
and is never in the repository.

## Tests

- `make lint`: Verilator lint of the RTL (Verilator 5; 5.054 was used).
- `make test`: the 18 benches of the board devices, the memory system and the
  whole core, about seven minutes (Verilator and a C++17 compiler). Some
  benches also replay recordings from `model/.out` when they are there and
  skip that part when they are not.
- `make -C sim flashcopy hps-read-test`: two more checks on the whole core, a
  flash-to-RAM copy by the CPU and the bench's disk adapter (arm-none-eabi
  binutils).
- `make -C sim dfill`: not a check but a measurement on the whole core: what
  a data line fill costs in clocks, from loops of loads timed with a UPP
  timer (`sim/harness/dfill.S`; arm-none-eabi binutils).
- `make -C sim/cpu bins model run`: the CPU's directed and random tests on
  the RTL, each at three bus latencies (arm-none-eabi binutils).
  `make -C sim/cpu qemu diff` compares them with QEMU (qemu-system-arm and
  arm-none-eabi-gdb). `make -C sim/cpu units` runs the unit benches of the
  pipeline's parts and two proofs.
- `make cpu-gen-check`: `rtl/cpu/arm925t_gen.v`, the netlist Quartus compiles,
  matches its sources (sv2v 0.0.13). `make cpu-gen` regenerates it.
- `make standin-check`: the binaries in `firmware-patches/bin` match
  `firmware-patches/nos-stub` (arm-none-eabi-gcc) for the historical control.
- `make scramble-check`: the flash scrambler's three copies agree
  (`tools/nos_scramble.py`, `model/hw/ngage_scramble.h`; the core's copy in
  `rtl/mem/ddram_flash.sv` is checked against the header by the `ddrflash`
  bench).
- `make pmm-check`: `releases/boot2.vhd` is the image `tools/mkpmm.py` writes.

`make help` lists the single benches.

## The core

The project is an ordinary MiSTer one. Open `NGage.qpf` in Quartus Prime
17.0.2 (the Lite edition is enough) and compile it, or run
`quartus_sh --flow compile NGage` in the repository root. The core is
`output_files/NGage.rbf`. Nothing else is needed: a fresh clone compiled this
way on the release's date gives the released file bit for bit (the date is
part of the core, see below).

- **The core does not meet its 104 MHz constraint yet.** Quartus finishes the
  compile without errors and with the critical warning "Timing requirements
  not met". The released build of 2026-11-20 has a worst setup slack of
  -1.32 ns with the fitter seed in `NGage.qsf` (`SEED`), the best of sixteen
  seeds, which gave -1.3 to -2.0 ns. The released core runs on the board.
- A build is reproducible: the same source, seed and date give the same RBF.
  The date (UTC) is the core's version string and part of the logic, so
  another day's build is another file and can fit differently: the release
  before, built again a day later with its own seed, went from -1.48 to
  -1.65 ns.
- `./build.sh` is optional, for a build server: it copies the tree to a Linux
  machine over ssh, runs the same compile there in Docker (image
  `theypsilon/quartus-lite-c5:17.0.2.docker0`) and fetches the core and the
  reports of `tools/report_timing.tcl` into `build/`:
  `BUILD_HOST=myserver BUILD_DIR=some/dir ./build.sh`. It needs zsh, ssh and
  rsync here and Docker on the server, and exits with status 2 while timing
  is not met.
- Start a GitHub build from **Actions → CI Build → Run workflow**.
  Choose the branch and enter the Quartus fitter seed. Leaving the field
  blank uses the seed in the selected branch's `NGage.qsf`.
  Negative setup, hold, recovery or removal slack at any analyzed corner
  fails the job. The RBF and available Quartus outputs and reports are
  uploaded even when the timing check fails.
- `./deploy.sh [host]` copies `output_files/NGage.rbf` to a MiSTer (default
  `root@mister`) and loads it.

### The measurement core

Uncommenting `VERILOG_MACRO "NGAGE_DEBUG=1"` in `NGage.qsf` adds the debug
overlay, its per-second counters and the trace triggers (about 1,700 ALMs).
The OSD then has **Debug overlay**, and `tools/mister_dbg.py` decodes a
screenshot of it. Every build without the macro is the plain core.

## With your own firmware

- `tools/mkimage.py phoenix RH2941.0C1 RH2941.021 -o build/coreboot` makes the
  flat flash images `cs0.bin` and `cs1.bin`: the core's `boot0.rom` and
  `boot1.rom` (the unpacker page makes the same two files), and the input of
  the firmware bench and the reference model. They are flash as the chips
  store it: CS0 `0xA000`-`0x2ACFFF` is scrambled and the core decodes it on
  reads. The output preserves the original NOS and integrity table. `--plain`
  writes CS0 decoded for a disassembler. To reproduce the historical patched
  control, pass `--patches firmware-patches/rom-patches.txt` explicitly.
- Use the reference pair for bring-up. `mkimage.py` requires `--force` to
  try language packs other than `RH2941.021`.
- `tools/mkpmm.py OUT` writes the PMM of a phone before its first start
  (`releases/boot2.vhd`); its header says what is in it and why.
  `--list FILE` prints the records of a PMM image.
- `make -C sim coreboot` boots the firmware on the whole core in Verilator.
  It runs for hours.
- `model/build.sh` builds the reference model: QEMU 11.1.2 with the `ngage-qd`
  machine in `model/hw` (QEMU's build requirements and arm-none-eabi-gcc).
  `model/run.sh` uses the supplied flash images directly. The model does not
  have the devices the original NOS needs: set `NGAGE_PATCHES=standin` on a
  stock image to run it with the stand-in, as earlier releases did.
- `tools/mkcard.py` makes card images, for the core (`.mmc`) and for the model.

## On the MiSTer

The core takes its files from `/media/fat/games/NGage/` as the
[README](../README.md) describes. When the core starts, MiSTer sends
`boot0.rom` and `boot1.rom` (the two flash images) and mounts `boot0.vhd`
(C:), `boot1.vhd` (a card, if there is one) and `boot2.vhd` (PMM). The CPU
starts once both images are in and their sizes agree.

- File indexes: 3 is CS0 and 4 is CS1 (**Load boot0.rom** and **Load
  boot1.rom** on the OSD's Firmware page). Image slots: 0 is C:, 1 the card,
  2 PMM.
- C: is the upper half of CS1 and PMM the top 64 KiB of CS0. A mounted file
  takes the place of that part of the image and gets the firmware's writes;
  without one the phone runs on what the image holds and nothing is kept.
  A flash image loaded later leaves a mounted C: and PMM as they are.
- The date: before every start of the phone, with a PMM file mounted and
  MiSTer's time in, the core writes today's date into the two date records
  of the PMM copy (`rtl/mister/pmm_date.sv`; the file is not written for
  it). The phone's time of day is MiSTer's through the UEMK's clock.
- A launcher can name every file itself, with no boot files in the folder:

```xml
<mistergamedescription>
    <rbf>_Console/NGage</rbf>
    <file delay="2" type="s" index="0" path="my-c-drive.vhd"/>
    <file delay="1" type="s" index="2" path="my-pmm.vhd"/>
    <file delay="1" type="f" index="3" path="cs0.bin"/>
    <file delay="1" type="f" index="4" path="cs1.bin"/>
    <file delay="1" type="s" index="1" path="sonicn.mmc"/>
</mistergamedescription>
```

- **Keeping a C: from an earlier release** (up to `NGage_20261120`): mount it
  with an erased PMM, `tools/mkpmm.py --erased boot2.vhd`, and not with
  `releases/boot2.vhd`, whose first start formats C:. The firmware fills the
  erased PMM in and asks for the time and date once more.
- Other firmware versions: the launchers in [docs/launchers](launchers) load
  a version's four files from a folder of its own (`games/NGage/410/`,
  `403/` and so on, as `boot0.rom`, `boot1.rom`, `c.vhd` and `pmm.vhd`). The
  original N-Gage's 4.03 is an 8 MiB `boot0.rom` and a 16 MiB `boot1.rom`
  (CS1 followed by CS2); the core picks the phone from the two sizes.
  [FIRMWARE-PROFILES.md](FIRMWARE-PROFILES.md) has the state of that work:
  4.03 has not been run through on a MiSTer.

## The firmware unpacker page

[web/](../web) is the page the README links to
(<https://ngage-mister.vercel.app/>): static files, no build step.
`web/unpack.js` takes `N-GageQD RH-29.zip` (the archive of the phone's data
packages, read in pieces: the package for 4.10 is picked out of it), that
package by itself (a Microsoft cabinet that holds an InstallShield cabinet),
or the two flash files. From the firmware file (held to its SHA-256) and a
language pack for 4.10 (record checksums checked) it makes `boot0.rom` and
`boot1.rom`, the two flash images, as `tools/mkimage.py phoenix` does. Made
with `RH2941.021`, they are held to the hashes of that tool's output.

- Of the eleven packages in the zip named for 4.10, two have both files:
  `RH-29_dp_emea_v_3_0_mcusw4_10-Oct19-151031.exe` (56 packs; the page takes
  `RH2941.021` from it) and `RH-29_dp_apac_v_3_0_MCUSW4_10.exe` (the same
  firmware file; the page takes `RH2941.067`). The other nine hold language
  packs alone or the 4.60 firmware file.
- `node web/test.mjs PACKAGE.exe ["N-GageQD RH-29.zip"] [other packages]
  [flash files]` checks it against the real files: the package and the zip
  must give the two files and the reference images, everything else must be
  refused.
- `vercel deploy --prod` in `web/` publishes it (project `ngage-mister`).
  The page and the released core change together: it makes the files the
  `.rbf` in releases/ takes. `python3 -m http.server -d web` serves it on
  localhost.
- `web/vercel.json` sends a content security policy that allows no
  connections: the page cannot send a file anywhere.
