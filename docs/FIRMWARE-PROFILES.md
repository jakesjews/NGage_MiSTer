# Stock N-Gage firmware integration

Target checkout `~/develop/ngage2`, branch `integration`, starting at
`bb05197`. The FPGA opens flat flash images. Assemble Nokia's MCU and PPM
service containers on the host, keeping the original scrambled NOS bytes
and the original ROM integrity table.

## Current QD run

The QD 4.10 service pair was copied from the MiSTer and matches the
documented `RH2941.0C1` and `RH2941.021` hashes. The unmodified images
are in `build/firmware-profiles/sim/qd-stock/`. Their lengths are 16 MiB
for CS0 and 8 MiB for CS1. Both original integrity entries match when
checked as the CPU sees them. The images include erased C: storage.
Local provenance and SHA-256 values are in
`build/firmware-profiles/manifest.json`.

To recreate and boot the stock QD flash in the existing offline simulator:

```sh
python3 -I tools/mkimage.py phoenix RH2941.0C1 RH2941.021 -o build/coreboot
make -C sim coreboot CORE_ARGS='--devlog --progress 10000000 --cycles 900000000 --stop-pc 0x514a6dcc --stop-pc-hits 64'
```

The bench preloads DDR and marks both raw flash images present using the
normal IOCTL indexes. Verilator runs the donor CPU, flash descrambler,
SDRAM controller, and peripherals. An integration RBF takes the same
arrays through OSD file indexes 3 and 4. A separate C: VHD can be mounted
on S0 after loading CS1. The direct flat-file bench uses the C: bytes in
CS1. MMC stays on S1.

The first native NOS clock routine writes `0x40` then `0x20` to control,
tests status bit 25, then writes `0x10` to control and `0x8000` to command.
QD firmware offsets are `0x00120004`, `0x00120020`, and `0x00120008`
within the peripheral window. Jake's earlier software-model run stopped
in this loop at `0x514A6DC4`. The original donor clock page supplied
`0x1C000000` at physical `0x0C120020`, which leaves bit 25 clear. NEM-4
4.03 executes the same sequence and its clock model supplies bit 25 after
those control writes.

The 2026-11-20 QD 4.10 RTL run with erased C:, no MMC, and no firmware
patches finished the ROM checks and reached `TRtcQueue::Add: 2`. Native
NOS wrote `0x40` and then `0x20` to physical `0x0C120004`. The next 64
reads of `0x0C120020` all returned `0x1C000000`. The original
`TST R0, #0x02000000` at ARM `0x514A6DCC` kept taking the loop back to
`0x514A6DC4`. The command write of `0x8000` never occurred. The bench
stopped at clock 337,064,561 (3.241 simulated seconds) on the 64th
retirement at the test instruction. See
`build/qd-stock-boot.yPeAmE/{run.log,clock-stall.log,stock/dev.log}`.
The whole-core and HPS regressions also passed, including rejection of
the former service-file indexes and C: mounting after a raw flash load.

### Clock fix and next fault

The [updated clock page](../rtl/upp/upp_periph.sv#L474) tracks control
writes and reports bit 25 while the control word holds `0x20` or `0x40`.
The peripheral regression covers the existing lock bits, partial
control writes, reset, and the transition to control `0x10`. The ready
response is immediate, as in the NEM-4 model.

The stock QD RTL rerun matched the first 37,934 device and exception
records exactly. The first difference was the native NOS status read,
which returned `0x1E000000`. NOS proceeded to write `0x10` to
`0x0C120004` and `0x8000` to `0x0C120008`, then detected Samsung
flash and logged flash type 11 and the 128+32 configuration.

The next failure is in delay-loop calibration at Thumb `0x514C2C7C`.
The trace records zero for the calibration window at `0x0C150114` and
the counter at `0x0C150112`. The original routine skips its counting
loop for a zero window and passes zero iterations and zero elapsed
ticks to its division thunk at `0x514C2D00`. The kernel wrote
`USER-EXE`, reason 3, to its fault record and parked at ARM
`0x5031E394`. It stayed there through the 390-million-cycle cap.
The fault words were read from the Verilator snapshot. See
`build/qd-clock-ready.uPs71F/{clock-and-fault.log,run.log,stock/dev.log}`.

### CTSI delay calibration

One CTSI/UIF block owns the counter at `0x0C150112` and the window at
`0x0C150114`. The neighboring halfwords still use generic storage.
The stock QD routine computes elapsed ticks as start minus current. If
current exceeds start, it adds window plus one, which implies a countdown
through zero with reload at the window. Use that direction and reload
rule. The NEM-4 model supplies the approximate 32.768 kHz rate and the
`0x0080` default window. Setting the window reloads the count while
preserving divider phase. The guest-programmable UPP timers and
host-adjustable UEM RTC keep their existing behavior.

The Verilator peripheral tests passed the reset window, byte and halfword
writes, neighboring storage, countdown rate, and inclusive wrap. The
stock QD RTL boot matched the prior run for 38,656 MMIO and exception
records. The first difference was the calibration window read returning
`0x0080`. NOS sampled the counter 1,772 times, waited for 64 distinct
ticks, and crossed one inclusive wrap. The original store at Thumb
`0x514C2D04` retired at 337,462,230 clocks with the nonzero calibration
factor `0x06EB`. The bench stopped at that instruction. See
`build/qd-ctsi-downcounter.RkGdQ3/{calibration.log,run.log,stock/dev.log}`.

## Bring-up after the first stop

1. **Qualify original QD NOS.** The clock sequence and native CTSI
   calibration now pass. Continue past calibration and follow the next
   wait or failed access using our
   UEM/CBUS, timer, RTC, SIM, DSP and Bluetooth models where the transactions
   match. Keep the firmware and its checksum unchanged.
2. **Identify and persist PMM.** Trace original QD NOR identification,
   catalog scan, and program/erase addresses before assigning a QD flash
   region or an image size. Qualify program, status, erase, dirty tracking,
   save drain and cold reload. Keep firmware array uploads and PMM storage
   separately owned so reloading firmware preserves PMM. NEM-4's verified
   64 KiB window at `0x007F0000–0x007FFFFF` has its own geometry and data.
3. **Enable the NEM-4 map.** Use the host-prepared three 8 MiB arrays in
   `build/firmware-profiles/sim/nem4/`, mapping CS0, CS1 and CS2 at
   `0x00000000`, `0x02000000`, and `0x04000000`. The original images
   write to CS2, which is empty in the QD configuration. The fixtures match
   the original core's 20,905,984 immutable flash bytes and use copies of
   the initialized 4.03 C: and PMM seed. Test seeded boot and erased-first-boot
   separately.
4. **Expose the firmware choice after both variants boot.** Use a single
   **Firmware** option with **QD 4.10** and **N-Gage 4.03**. Keep independent
   C: and PMM images. Host-prepared flash arrays can be staged into separate
   DDR regions for a switch without asking users to load MCU and PPM
   separately. Verify an automatic file layout with stock MiSTer Main
   before selecting names. Drain the outgoing writes and reboot the guest
   against the selected region. Verify game launch, C: and PMM writeback,
   and repeated switches on MiSTer.
