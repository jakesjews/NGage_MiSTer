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

`make help` lists the single benches.

## The core

The project is an ordinary MiSTer one. Open `NGage.qpf` in Quartus Prime
17.0.2 (the Lite edition is enough) and compile it, or run
`quartus_sh --flow compile NGage` in the repository root. The core is
`output_files/NGage.rbf`. Nothing else is needed: a fresh clone compiled this
way gives the released file bit for bit.

- **The core does not meet its 104 MHz constraint yet.** Quartus finishes the
  compile without errors and with the critical warning "Timing requirements
  not met". The released build of 2026-11-19 has a worst setup slack of
  -1.48 ns with the fitter seed in `NGage.qsf` (`SEED`), the one seed fitted
  for that tree; sixteen seeds of the tree before it gave -1.5 to -2.3 ns.
  The released core runs on the board.
- A build is reproducible: the same source, seed and date give the same RBF.
- `./build.sh` is optional, for a build server: it copies the tree to a Linux
  machine over ssh, runs the same compile there in Docker (image
  `theypsilon/quartus-lite-c5:17.0.2.docker0`) and fetches the core and the
  reports of `tools/report_timing.tcl` into `build/`:
  `BUILD_HOST=myserver BUILD_DIR=some/dir ./build.sh`. It needs zsh, ssh and
  rsync here and Docker on the server, and exits with status 2 while timing
  is not met.
- GitHub builds every push to master and every pull request the same way
  (`.github/workflows/ci_build.yml`) and keeps the core and the reports as
  artifacts. Its timing check accepts a setup slack down to -2.0 ns
  (`NGAGE_SETUP_FLOOR`, read by `tools/report_timing.tcl`; hold, recovery
  and removal must not be negative) and fails below that; the run's summary
  and the artifact's name say whether 104 MHz is met. Without the variable
  the script counts any negative slack as an error, as `./build.sh` does.
- `./deploy.sh [host]` copies `output_files/NGage.rbf` to a MiSTer (default
  `root@mister`) and loads it.

### The measurement core

Uncommenting `VERILOG_MACRO "NGAGE_DEBUG=1"` in `NGage.qsf` adds the debug
overlay, its per-second counters and the trace triggers (about 1,700 ALMs).
The OSD then has **Debug overlay**, and `tools/mister_dbg.py` decodes a
screenshot of it. Every build without the macro is the plain core.

## With your own firmware

- `tools/mkimage.py phoenix RH2941.0C1 RH2941.021 -o build/coreboot` makes the
  flat flash images `cs0.bin` and `cs1.bin` for the integration RBF,
  firmware bench, and reference model. They are flash as the chips store it: CS0
  `0xA000`-`0x2ACFFF` is scrambled and the core decodes it on reads. The
  output preserves the original NOS and integrity table. `--plain` writes
  CS0 decoded for a disassembler. To reproduce the historical patched
  control, pass `--patches firmware-patches/rom-patches.txt` explicitly.
- Use the reference pair for bring-up. `mkimage.py` requires `--force` to
  try language packs other than `RH2941.021`.
- `make -C sim coreboot` boots the firmware on the whole core in Verilator.
  It runs for hours.
- `model/build.sh` builds the reference model: QEMU 11.1.2 with the `ngage-qd`
  machine in `model/hw` (QEMU's build requirements and arm-none-eabi-gcc).
  `model/run.sh` uses the supplied flash images directly. Set
  `NGAGE_PATCHES=standin` on a stock image for the patched comparison.
- `tools/mkcard.py` makes card images, for the core (`.mmc`) and for the model.

## On the MiSTer

For an integration build, select the two host-prepared flash images in the
OSD. For persistent C:, mount its VHD after the CS1 image. A CS1 upload detaches
any previous C: mount. The raw flash indexes are 3 for CS0 and 4 for CS1.
The image slots are 0 for C: and 1 for the card. A launcher can supply all
four files in this order:

```xml
<mistergamedescription>
    <rbf>_Console/NGage</rbf>
    <file delay="2" type="f" index="3" path="cs0.bin"/>
    <file delay="1" type="f" index="4" path="cs1.bin"/>
    <file delay="1" type="s" index="0" path="my-c-drive.vhd"/>
    <file delay="1" type="s" index="1" path="sonicn.mmc"/>
</mistergamedescription>
```

## The firmware unpacker page

[web/](../web) is the page the README links to
(<https://ngage-mister.vercel.app/>): static files, no build step.
`web/unpack.js` takes `N-GageQD RH-29.zip` (the archive of the phone's data
packages, read in pieces: the package for 4.10 is picked out of it), that
package by itself (a Microsoft cabinet that holds an InstallShield cabinet),
or the two flash files, and hands out the firmware file (held to its
SHA-256) and a language pack for 4.10, with record checksums checked.
Use the extracted pair as input to `tools/mkimage.py` for an integration build.

- Of the eleven packages in the zip named for 4.10, two have both files:
  `RH-29_dp_emea_v_3_0_mcusw4_10-Oct19-151031.exe` (56 packs; the page takes
  `RH2941.021` from it) and `RH-29_dp_apac_v_3_0_MCUSW4_10.exe` (the same
  firmware file; the page takes `RH2941.067`). The other nine hold language
  packs alone or the 4.60 firmware file.
- `node web/test.mjs PACKAGE.exe ["N-GageQD RH-29.zip"] [other packages]
  [flash files]` checks it against the real files: the package and the zip
  must give the two files, everything else must be refused.
- `vercel deploy --prod` in `web/` publishes it (project `ngage-mister`).
- `web/vercel.json` sends a content security policy that allows no
  connections: the page cannot send a file anywhere.
