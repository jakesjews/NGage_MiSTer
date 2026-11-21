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
make -C sim coreboot CORE_ARGS='--devlog --progress 10000000 --cycles 400000000'
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

### Second clock lock and ASIC ROM

After calibration, stock QD 4.10 writes `0x2000` and `0x2490` to
`0x0C148000` and tests bit 0 at Thumb `0x5167AF8A`. The original
400-million-clock run read `0x2490` more than 3.9 million times.
NEM-4 uses the same programming sequence. The model now reports
immediate lock, as it already does for `0x0C149000`. The peripheral
bench passed both clocks and confirmed that adjacent storage still reads
normally. The checkpoint replay's first difference was the read returning
`0x2491`. NOS continued to `MTC:SU:main()`. A second run from reset
reached 338 million clocks with the same final 212 MMIO and exception
records, using the unchanged CS0 and CS1 files.

At clock 337,738,131 the instruction fetch for virtual `0x580003DE`
read physical word `0x0C0003DC`. The bus returned `0x18768E56`, which
matches halfword writes by the DSP upload to physical `0x0C0303DC` at
clocks 337,472,057 and 337,472,067. Both addresses fed the same 64 KiB
on-chip RAM in that build. Executing those bytes caused a data abort at
`0x580003EE`, followed by a kernel park at `0x5031E394`.

The original core models this ASIC ROM page with a Thumb return. QD's
call passes a 40-byte input and 32-byte output in communication RAM.
The instruction at `0x514C0274` overwrites `r0` immediately on return.
A diagnostic snapshot copied immediately before the fetch supplied the
same Thumb return at this single entry, allowing the original caller
to continue. This is evidence about the guest path following the call.
The actual ASIC ROM contents and its output-buffer behavior are unknown.

### External memory map from ngage-v5

The RTL now uses the `ngage-v5` mapping at `237117d4654d`. Reads of
`0x0C000000–0x0C000FFF` return the v5 Thumb `BX LR` model and writes
signal a bus error. The response is generated by logic. The rest of the
on-chip window has distinct physical offsets in the SDRAM above the
guest's 16 MiB main-memory aperture. This removes the 64 KiB on-chip
BRAM and keeps the ROM, communication RAM and DSP uploads independent.

| Guest address range | SDRAM byte offset | Use |
|---|---|---|
| `0x0C004000–0x0C004FFF` | `0x01004000–0x01004FFF` | Communication RAM and bootstrap flash routines |
| `0x0C030000–0x0C03FFFF` | `0x01030000–0x0103FFFF` | Main DSP upload |
| `0x0C06FF00–0x0C06FFFF` | `0x0106FF00–0x0106FFFF` | Auxiliary DSP upload |

The additional SDRAM aperture remains outside the guest SDRAM mirrors.
It has normal SDRAM power-on contents and preserves writes across a warm
reset. The ASIC response is a v5 device model. A verified mask-ROM dump is
still needed to qualify the underlying service and its side effects.

The memory bench reproduced QD's two halfword writes to `0x0C0303DC`,
then verified the ASIC ROM read and write fault, the separate RAM contents,
and their placement in the SDRAM model. The memory bench passed with bus
assertions under two seeds. The peripheral, SDRAM and whole-board tests
passed as well.

A cold run with these changes and the original QD 4.10 images reached
400 million clocks (3.846 simulated seconds). It passed the former ASIC
ROM abort and initialized PMM, with `PMMCAT` and 339 programmed bytes in
the top 64 KiB of CS0. It finished in the Symbian idle loop after NOS
programmed the CTSI compare. The paired checkpoint resumed to 401
million clocks with the same executable. Firmware hashes, logs and the
pair are in `build/qd-v5-memory.BpvwuF/`.

### Power and FBUS

The next busy loop, ARM `0x514A70B8`/`0x514A70BC`, counts down from
`0x00763A1E`. It ended around 353 million clocks and NOS resumed its
device writes. The later park at `0x514C2356` was a shutdown. After
five consecutive zero UEM ADC channel-12 results, NOS emitted
`MTC:SU:LOW_BATTERY` and entered the power-off path. A diagnostic run
with channel 12 at `0x0200`, the NEM-4 model's sample, passed that path
and reached the firmware's FBUS transmit-empty assertion. Channel 6
continues to supply 485 for the battery-size check.

QD's FBUS code reads halfword `0x0C150504`. It extracts status bit 4
and checks bits 6–8 against `0x01C0` before sending. The idle FBUS model
now exposes `0x01D0` over the configuration latch, matching the NEM-4
model. A diagnostic replay with that response advanced to the MBUS
system-type assertion, `Hw_mbus.c:742`. The QD routine at `0x514C2886`
reads `0x0C150002` and tests bit 6 for GSM, matching the NEM-4 model.
The latch now reports that strap while preserving the adjacent reset
reason. With the strap, Thumb `0x515B9188` repeatedly read `0x8000` from
the MBUS command register at `0x0C15021C`. The modeled command strobes
now read clear, preserving the other bits and `0x0C15021E`. The replay
then finished 200 calibrated delays and resumed NOR programming around
382 million clocks.

### CTSI deadline and idle

After the native PMM writes, the 395–460 million clock diagnostic replay
stayed in the Symbian idle loop at `0x503287C0–0x503287CC`, with timer 0
IRQs and no CTSI IRQ. NOS had read zero from `0x0C150116`, enabled bit 7
via `0x0C150012`, and programmed a deadline at `0x0352` in `0x0C150118`.
Delivering that one device event in a diagnostic replay caused the guest
to acknowledge bit 7 at `0x0C150100`, schedule `0x05DC` and run deferred
work.

The initial CTSI implementation advanced `0x0C150116` on calibration
counter wraps. At `0x514AF288`, the original firmware waits for a nonzero
calibration count before reading the slow count. This established that
both counters are used during calibration. The later boot work below sets
the NOS counter to an independent 64 Hz cadence. Replay traces and paired
snapshots are in `build/qd-stock-dpll.koexki/`.

### Symbian Supervisor waits for Timer 1

The saved stock 400-million-clock run has a `Supervisor` thread executing
the callback wait at `0x503287C0–0x503287CC`. The kernel stack records
native NOS return address `0x514A7D24`, a queued callback at `0x80403B50`,
and a zero completion word at `0x80403B44`. The callback at `0x50328768`
sets that word. Eight diagnostic CTSI deadlines acknowledged by the
guest left the callback queued and returned to the same wait.
The untouched continuation confirmed this at the first real CTSI match,
between 790 and 795 million clocks. NOS acknowledged bit 7 and programmed
the next compare, `0x0973`. The Supervisor wait persisted through the
845-million-clock cap, with zero user-mode instructions.

The kernel enabled Timer 1 with control 1 at `0x0C120A24`, cleared its
interrupt, enabled IRQ source 1, and wrote a zero one-shot count to
`0x0C120A30`. At 400 million clocks the modeled Timer 1 count was
`0xFF2C0BF9`, running with IRQ clear. The model wraps a zero count
through 32 bits, so the callback would wait about another 123 simulated
seconds under that model.

A separate diagnostic snapshot changed only the remaining Timer 1 count
to one. The existing RTL raised source 1. The firmware acknowledged
`0x0C120A28`, ran the callback at `0x50328768`, and returned to NOS at
`0x514A7D24`. This isolated the startup wait to the zero one-shot behavior.
The same experiment on the 845-million-clock checkpoint released the
wait after the real CTSI event had already fired. Both experiments used
the same RTL and stock images as the untreated replay.

The RTL now treats an explicit zero load on enabled one-shot Timer 1 as
one remaining tick. A cold run with that change reached the
`ecust.dll` ready check by 400 million clocks without advancing the
timer from the harness. The directed timer test covers the one-tick
expiry and the stopped zero count. Board timing is unmeasured.

### Native NOS notification and Symbian user mode

After the Timer 1 diagnostic, `ecust.dll` polled bit 1 at `0x50342B78`.
The getter returned `1` from `0x80404110`, leaving bit 1 clear. It stayed
there through an additional CTSI deadline. QD writes `0x1000` to
`0x0C150012` from `0x514C1BF2` to request deferred NOS work. A
checkpoint experiment delivered this through source 25. NOS handled it
and cleared it at `0x0C150010`, then returned to the ready check.

The same stock firmware initialized MDI control to `0x0500`, cleared
both ring pointers and enabled CTSI bit 10 during startup. In a separate
checkpoint experiment, the simulator published the original core's
device `0x7C` announcement to D2M and raised that bit. QD read all four
halfwords and advanced the D2M consumer to 4. Native EKIF logged
`MTC_STATE_INFO_IND` and accepted base time and kernel data requests.
The LCD displayed the Nokia logo by 405.5 million clocks. The first
user-mode thread entered `EFile.exe` at 435,573,254 clocks, and
`EStart.exe` entered at 484,032,665 clocks. The continuation reached
5,104,820 user-mode instructions by 560 million clocks and was executing
`ERam.fsy` through EFile. At 584.12 million clocks, EStart requested a
3,000,000 µs timer. NOS polled for interrupts while it waited. After the
timer completed, EStart launched the Symbian window server
`EwSrv.exe` at 898,535,861 clocks, then `FbServ.exe` at 914,979,083 and
`Starter.exe` at 931,334,068. The experiment used an erased C: and no
MMC. It changed timer and peripheral model state in an older checkpoint.
Both original NOR inputs remained byte-identical.

The integrated RTL ports the MDI ring protocol and the original core's
version-response peer. The 250-halfword rings share a reserved region
of MiSTer SDRAM at byte offset `0x01100000`. The CPU and MDI peer use the
same SDRAM arbiter path. CTSI handles the peer's consume and publish
events on bits 9 and 10, and software interrupts on bits 12 and 13.
The DSP version responses are synthetic. DSP instruction execution
and external D550 audio are outside this transport model.
The peripheral regression checks announcement and IRQ acknowledgements,
an RF version response across both ring wrap points, and byte writes
to the SDRAM; the memory regression checks the separate on-chip bank.

A cold run of the integrated RTL consumed the same four mailbox
halfwords, advanced the D2M consumer to 4 and displayed the Nokia logo at
3.829 simulated seconds. Stock `EFile.exe` entered user mode at
429,000,484 clocks, and `EStart.exe` entered at 477,533,361. This run
started from reset with no checkpoint or test-harness peripheral changes.
It saved a checkpoint pair at 520 million clocks. The final executable
restored the pair and saved again at 525 million. CPU and device traces
matched the replay with the original cold-run executable.

Probe commands, logs and checkpoint pairs are in
`build/qd-timer1.l6NC9k/` under `softirq-probe`, `mdi-probe`,
`mdi-continue`, `ui-trace` and `after-estart-delay`. The integrated
cold run is in `build/qd-stock-mdi.N5iBAE/`, with the executable and
stock image checksums stored beside its logs.

### C: initialization and Starter

The erased-C: checkpoint aborted at 944,762,857 clocks in
`EUser.dll` at `0x503A860C`, called from Starter through Bafl. The
faulting object had read the exception-vector word `0xE59FF044` as a
pointer. ekern wrote `0x200` to clock control and 4 to reset reason, then
stayed at `0x5031E394`. This matches the earlier QD blank-C: failure in
`PROGRESS-LOG.md`, where EStart fell back to D: and Starter failed in the
backup server cleanup. It gives a separate first-boot requirement after
the native Symbian startup path.

Two checkpoint experiments use the same stock ROM inputs. Holding
Call + * + 3 from the 423-million-clock checkpoint still returned
auxiliary start mode 100. The call at `0x503EA4D4` logged that value.
EStart needs 105 to take the immediate C: format branch, and the 4 MiB
C: region remained completely erased at 720 million clocks. This
test applied the keys after early kernel initialization.

The other experiment seeds the separate 4 MiB C: region with the QD
volume previously captured from the user's MiSTer. It contains 46 headers
with the QD signature
`0x503AEAE0`. NEM-4 captures use `0x503B3B60`, so the media is kept in
its own profile. The seeded flat CS1 retains the original first 4 MiB.
The seeded replay launched the ELocal filesystem thread and advanced
through C: reads and writes before EStart's three-second timer.
It started `EwSrv.exe` at 860,412,701 clocks and `FbServ.exe` at
877,662,142, passed the earlier fault, and launched `Starter.exe` at
894,393,109 and `SplashScreen.exe` at 904,912,666 clocks. QD's
`SplashScreen.mbm` draws the same Nokia logo as the kernel boot image.
The replay observed physical LCD transfers after the window server
started. Its traces and the prepared `cs1-with-qd-c.bin` are in
`build/qd-timer1.l6NC9k/seeded-c/`.

The replay and its continuation reached 1.25 billion clocks
(12.019 simulated seconds) without the Starter fault. A kernel heap
inspection found readable threads for 17 processes at 1.10 billion clocks
and 24 at 1.25 billion, including PhoneServer, database recovery and
Arena. The panel still showed the Nokia splash. Checkpoint pairs and
thread dumps are in `build/qd-timer1.l6NC9k/ui-handoff/`.

The next replay executed `Startup.app` at 1,336,179,258 clocks and
logged `CSysApAppUi::ConstructL: Start listening`. During that phase,
native EKIF handled `EKIF_READ_AUX_STARTUP_REASON` and reported the
record missing. The QD handler at `0x51663EF4` reads two bytes from PMM
record `0xD4`, group 3, and returns 100 on lookup result 17. The trace
establishes the firmware's default mode. The idle-screen handoff's
dependence on this record is unverified. The replay saved and restored
both files of the 1.50-billion-clock checkpoint at 14.423 simulated
seconds. The panel still showed the Nokia splash. Its 64 KiB CS0 PMM
extract has 386 bytes changed from the stock image. The pair, PMM extract
and traces are in `build/qd-timer1.l6NC9k/idle-screen/`.

The same replay left the Nokia logo at 15.05 simulated seconds and drew
“Device start-up failed. Contact the retailer.” The N-Gage background
appeared behind the note on the next frame. The firmware kept executing
through 1.88 billion clocks (18.08 simulated seconds). Left soft key and
OK events after 17.4 seconds did not change the frame. The captures and
checkpoint pairs are in `build/qd-timer1.l6NC9k/after-splash/` and
`build/qd-timer1.l6NC9k/note-dismiss/`.

The native NOS self-test registry at guest `0x800239E4` had the same
results at 1.50, 1.81 and 1.88 billion clocks. The MTC state byte at
`0x8001044C` held 8 in all three snapshots. QD NOS sets state 8 in the
fatal severity-12 case at `0x514C3400`. The replay also reached the
`Startup.app` failure-note routine at `0x50BBA436`, 14.965 simulated
seconds, before the note appeared on the LCD. The registry entries and
hardware transactions identify these discrepancies:

| QD test | Original result | Register behavior added |
|---|---|---|
| UPP register version | 1 | Revision field at `0x0C14B000[7:4]` reads 8. |
| Backup battery | 1 | UEM device 1 register `0x1F` reads bit 11 set and bit 5 clear. Bit 1 still follows the power key. |
| Ear and TX IDP loopbacks | 6 | GENIO1 and GENIO3 follow GENIO0 and GENIO2 while their respective UEM routes are enabled. |
| SIM clock and SIM I/O control loopbacks | 6 | Both tests use GENIO17 with the UEM SIM route and the GENIO16 and GENIO18 outputs. |
| MBUS receive/transmit loopback | 6 | `0x0C15021E[6]` follows output bit 7. |

The integrated peripheral bench covers the revision field, UEM battery
and power-key readback, GENIO routing and set/clear, and MBUS readback.
The revision-only cold replay read `0x80` at the native self-test and
recorded result 0 for the UPP version test at 440 million clocks. Adding
the backup-battery bit gave result 0 for that test too. MTC still held
state 8 in both runs, and the five loopback results remained 6.
The combined cold boot uses the original CS0 and the QD-formatted C:
volume in the upper half of CS1. It exercises the integrated RTL from
reset. At the 440-million-clock checkpoint, all five loopback results
are 0 and the MTC startup byte is 1. The Nokia logo appeared at 4.079
simulated seconds. EFile executed in user mode by 458,240,418 clocks,
and the kernel's user-thread entry for EStart ran at 506,293,789 clocks.
The checkpoint pair restored to 442 million clocks with the frozen
simulator. Both runs and the executable are in
`build/qd-native-selftest.3qDi1Y/`. The older post-splash replay used
the diagnostic MDI checkpoint.

The combined run reached its configured 1.70-billion-clock limit
(16.346 simulated seconds) with the Nokia splash still on the LCD.
The window server, Starter, Startup, SysAp and Phone had executed, and
the previous startup-failure dialog did not appear in this window.
Native NOS sent the RF version request `127C00F10006012420A00255` and
consumed reply `12007CF10006240120A10103`, matching the master trace.
The focused trace is in
`build/qd-native-selftest.3qDi1Y/cold/rf-exchange.log`. This verifies
the RF exchange through MDI. The later DOS test result and idle-screen
handoff remain open. The last saved checkpoint is at 440 million clocks.

#### SIM receive path and resumed run

In the completed native QD trace, NOS wrote 1 to `0x0C150808` four times
to start SIM reception and enabled bit 2 at `0x0C15000A`. The native
status collector read zero from both `0x0C150800` and `0x0C1500B8`.
There were no reads from the receive register `0x0C15080C`. These
addresses used generic register storage before the SIM port.
The `ngage-v5` SIMIF supplies the response and FIQ on the same
register interface when its test card is present.

QD 4.10 `Startup.app` checks System Agent SIM state
`0x100052E9` for 7 and security state `0x100052F0` for 0
at `0x50BBAD06`–`0x50BBAD26`. The missing receive path is a
blocker to native SIM readiness and normal startup. The specific UI
wait at the 1.70-billion-clock cutoff remains unverified. The native
startup self-test registry has 21 entries and no NEM-4 external ADSP
test 36.

The replay resumed from the verified 440-million-clock pair in
`build/qd-continue.1OxfqT/`. It saves and resumes automatically across
segments, including a retained 1.70-billion-clock pair when reached.
`simif-transactions.log` records the original hardware accesses and
`inspect-sim.py` reads the QD SIM state from an available host snapshot.

The user reported **Insert SIM card** on the integration RBF. A direct
comparison of `integration` at `f616880` with `ngage-v5` at `f2d9c04`
shows the missing connection. QD enables FIQ source 26 with
`0x04000000` at `0x0C1201C8`. The pre-port integration left source 26 at zero.
`ngage-v5` connects `ngage_simif` to that FIQ source and enables
`ngage_test_sim` in the MiSTer wrapper. Its unmodified board test passed
all four card configurations, including the same receive-start write,
ATR `3B 00`, interrupt acknowledgement and SELECT response.
The test logs are in `build/v5-simif-check.IDoCbP/build/sim/unit-simif-board/`.
Integration now uses that SIM controller and test card, including the
single-write reply FIFO, byte pacing, and receive acknowledgement. The
UPP bus waits for the card between transactions. Source 26 appears only
on the FIQ plane. The integrated peripheral test checks mask and
acknowledgement, a fresh ATR after reset, and the SELECT procedure byte
and status. The peripheral and interrupt-controller benches and RTL lint
passed.

The simulator's standard restore rejects pre-port checkpoints because the
Verilator model layout changed. The local diagnostic in
`build/qd-simif.5PgQga/` converts the 440- and 800-million-clock checkpoint
pairs using the two generated serialization layouts. It preserves shared
RTL state and the complete host snapshot, initializes the new SIM/card
state from reset, and transfers the three SIM configuration words from
the old register storage. The next firmware receive-start write still
drives the ATR. The original checkpoint pairs are untouched.

The 440-million-clock differential matched 20,000 instruction trace
entries and all 84 device-log entries over the next two million clocks.
The 800-million-clock differential matched all 91,868 device-log entries
over the same interval. Both matched the original core's retired count
and PC at the stop. Runs from both converted checkpoints and a separate
cold boot use the same SIM-enabled executable.

Both resumed runs and the cold boot took the native SIM FIQ and read
ATR `3B 00` and SELECT DF-GSM status `9F 16`. The cold boot did so on the
first receive-start write after 420 million clocks. All three runs have
474 identical SIM data-register transfers from ATR onward, including
266 received bytes. The firmware read IMSI and access class and received
`94 04` for `6F14` and `6FC6`, matching the `ngage-v5` test card.
Compact bus evidence is in `late-retry/simif-native.log` under the run
directory above.
The original QD transition table at `0x516DBED4` maps event `0x070D`,
reason `1` to serving state 8. The resumed run registered for system
state notifications in `Startup.app`, completed the native RF exchange,
and read the SIM's BCCH, LOCI, Kc and FPLMN files successfully. At
1.94 billion clocks (18.654 simulated seconds), the saved QD state was
`SIM_Server` 8, with MTC status bytes `1, 1`. The unmodified guest then
left the Nokia splash, played the N-Gage animation, and drew the native
Time prompt at 20.842 simulated seconds. A separate replay accepted the
default Time and Date through left-soft-key presses and drew the QD
Phone screen at 22.790 seconds. Its 2.42-billion-clock checkpoint still
has `SIM_Server` 8 and MTC status bytes `1, 1`. The run used the seeded
QD C: image and original QD 4.10 firmware. The Time and Phone captures
are in `build/sim/screens/qd-native-sim/`.

A second replay restored the Phone checkpoint and drove the normal
Menu input from 23.400 to 23.600 simulated seconds. Through the saved
2.56-billion-clock pair (24.615 seconds), the Phone frame remained
on-screen and the firmware kept executing. `phone-live/` continues
from that pair to capture later UI activity.

The original cardless control reached `SIM_Server` state 5 by its
1.50-billion-clock checkpoint and reproduced **Insert SIM card** at
17.679 simulated seconds. The control capture is
`build/sim/screens/qd-native-cardless/insert-sim.png`. Both runs continue
across checkpoint pairs. The SIM-enabled pair at 1.94 billion clocks
is retained in `serving/` under the run directory above. The `late-retry`
folder lists the rolling pair in `latest-checkpoint.txt`. Restore either
with the same frozen `Vemu` in the run directory.

#### NEM-4 master history for this stage

`NGage_MiSTer` `master` commit `383d915` established the revision and
loopback fix on the NEM-4 startup tests in the simulator model.
`fb55330` ported the GPIO and MDI behavior to RTL. The QD port uses the
same routing and set/clear behavior. The later NEM-4 keypad fix in
`1dd285e` preserved the routed GENIO1 low level when the idle rocker
would otherwise pull it high. QD's modeled routes already deliver both
levels in the cold-run register trace.

The next historical NEM-4 gate was MTC startup-group activation
(`d7a1462`). The timer and MDI announcement in `89982cf` let native
EKIF see the startup indication and EFile and EStart run. QD has the
corresponding timer and MDI paths. The source repair in `646ac68` taught
the DSP peer to accept native media `0x12` on RF version requests. QD's
peer already accepts it. QD emitted the `F2/0A` setup message documented
before the RF request in NEM-4's `docs/rf-native-media.md`, with a
different trailing byte. The subsequent QD RF exchange matched the
master trace. NEM-4's `940c0f6` qualified native ADSP
test 36 and reached MTC NORMAL/READY with the bounded D550 startup
response, as recorded in `docs/adsp-native-link.md`. `a413b1e` and
`docs/native-startup-hdl.md` index the native SIMIF and UART work.

### Firmware submenu and launchers

Both version directories use `boot0.rom`, `boot1.rom`, `c.vhd`, and
`pmm.vhd` under `games/ngage/`. The ROM lengths determine the map.

| Firmware | `boot0.rom` | `boot1.rom` | CPU-visible PMM |
|---|---|---|---|
| 4.10 QD | 16 MiB CS0 | 8 MiB CS1 | `0x00FF0000–0x00FFFFFF` |
| 4.03 NEM-4 | 8 MiB CS0 | 8 MiB CS1 followed by 8 MiB CS2 | `0x007F0000–0x007FFFFF` |

CS0 and CS1 retain their bases at `0x00000000` and `0x02000000`.
NEM-4 adds CS2 at `0x04000000`. C: remains at `0x02400000–0x027FFFFF`.
The 4.03 NOR behavior uses the `ngage-v5` identification responses and
16 KiB PMM sectors. Each half of C: ends with four 16 KiB sectors.
CS0 retains the ROM's own descramble header
(`0xA000–0x2B3000` for 4.03). The CPU stays in reset while the ROM sizes
disagree or a required upload is incomplete.

The `.mgl` launchers use F3/F4 for the ROMs and S0/S2 for C: and PMM.
MiSTer Main finds the shortcuts on the top OSD page before both ROMs load.
The Firmware submenu remains available throughout the session. Both
launchers mount the saves before the ROMs. An attached PMM lives in a
dedicated DDR window (`0x33200000`) that overlays the selected CS0 tail
and survives a ROM reload. With S2 empty, the guest uses the PMM bytes
embedded in CS0. S1 remains the MMC slot.

### Observed QD PMM layout

The unmodified NOS in the ASIC diagnostic replay scanned the eight 8 KiB
sectors at physical `0x00FF0000–0x00FFFFFF` and programmed PMM headers
using its native NOR command sequence. The 370-million-clock snapshot
contains 84 changed CS0 bytes, all in that top 64 KiB. Each sector starts
with `F0 F0`; sectors at `0x00FF0000` and `0x00FFC000` have `PMMCAT` at
offset `+6`. The initial raw CS0 image was erased throughout that range.
Slot S2 restores a 64 KiB PMM into that window. It writes changed blocks
back automatically via the same mechanism as C:, or in response to
**Save C: and PMM now**. A firmware reload preserves a mounted PMM window.

### Stock audio and RTC alarm

The native MDI transport now routes internal DSP resource `0xE8` to the
`ngage-v5` PCM responder. It reads 8 or 16 kHz signed mono from the
handset SDRAM and resamples it to the MiSTer outputs. The D2M ring and
CTSI status bit 10 publish playback responses and refills. IRQ source 5
belongs to Timer 5. The historical stand-in audio MMIO remains documented
as a software-model interface.

The UEM register `0x35` (device 1, register `0x15`) follows the alarm
acknowledgement fix from `ngage-v5` commit `237117d`. Its alarm bit is
latched and clears when NOS writes bit 3. An unrelated write and the
power-key bit leave the alarm state alone. This removes the forced status
that sent the observed Bomberman session through the RTC hardware-reset
path on power-off. The upstream shutdown request in that session was
unattributed.

### Simulation results

The whole-core bench loaded a mixed pair and verified that the CPU stayed
in reset. Completing the 4.03 pair released it and let a guest program read
CS2, its mirror, and the mounted PMM through the NEM-4 addresses. The save
benches checked program, erase, and writeback in both PMM layouts, including
the interior 16 KiB C: geometry on NEM-4.

The peripheral bench exercised PCM start, submit, refill, and stop through
the original MDI frame format. It observed signed samples from both SDRAM
halves and checked MDI publication and Timer 5 ownership. The CBUS test
checked alarm acknowledgement, the power-key bit, and the one-shot alarm IRQ.

Unmodified 4.03 passed the stock MD5 check and reached NOS user execution
at clock 267,386,198. The run stopped at its 400-million-clock budget
with the CPU still executing and one captured frame. The whole-core
monitor checked 9,305,681 array read beats across the three flash chips
with zero mismatches. A 150-million-clock checkpoint is available with
the simulator executable used for the run. Reassembling the three
decoded flash spans in the firmware table's order produces the stock
core MD5 `2c09c86ff047484fdcc0e226f49c44a9`.

### 4.03 external DSP startup stall

The stock 4.03 run resumed from the 150-million-clock checkpoint using
the same emulator binary. At 5.000 and 9.615 seconds the display was black
and the firmware's RF `0x1E` and ADSP `0x36` self-tests both held result
`0x03` (pending). The result bytes came from the guest SDRAM backing the
native result array at `0x80024388`.

A separate 20 ms trace from the one-billion-clock checkpoint observed
63,030 reads of physical `0x0C150514`, all returning zero. The original
`euart1.pdd` at `0x510E8A14` tests bit 2 and branches back if it is clear.
The `ngage-v5` EUART model reports that bit when its transmit queue and
current batch have drained. The baseline integration build exposes the
FBUS status at `0x0C150504` and lacks the NEM-4 EUART status path. The
original run completed exactly 60.000 seconds (6,240,000,000 clocks)
and was still in that loop. The screen stayed black throughout and both
tests were pending at the cutoff. CPU and host checkpoint pairs are
preserved at each billion-clock milestone and at the final cutoff in
`build/nem4-60s/`.

The NEM-4 startup port from `ngage-v5` at `7b10754` adds EUART1, the
D550 boot peer, the D551 signature model, and the N501 codec control
transaction. EUART1 derives transmit idle from its FIFO and batch
state. The byte link starts only after the UEM control writes and EUART
receive enable. UART status shares the upper halfword of `0x0C1500B8`
with SIMIF below it, and both sources use FIQ 26.

The integrated peripheral bench verified the initial transmit-idle
read, FIFO drain, shared status and IRQ handling, both D0 startup frames,
and a checksummed diagnostic 42 exchange. The QD peripheral regressions
and top-level lint passed. This port models the external DSP startup
protocol. The MiSTer PCM output still comes from the internal MDI path.

A separate stock 4.03 cold boot reached
`RAdspServerSession::Construct` before 9.615 seconds. Its checkpoint
recorded 1,031,158 device accesses versus 4,908,492 at the same clock
in the polling baseline. The display was black and the RF and ADSP
self-tests were still pending at this checkpoint.

By the 19.231-second checkpoint the ported run had reached
`CSysApAppUi::ConstructL`, with RF `0x1E=00` and ADSP `0x36=03`. The
stock ADSP caller asserted at `FIG/St_product.c:3570` while checking
`pResp_adsp->message_id == ST_ADSP_RUN_RESP`, then parked in the kernel
loop at `0x50324294`. The display stayed black. The same assertion was
observed in the NEM-4 reference history when a late response reached the
shared waiter. A read-only replay observed NOS queue the ADSP request
for resource `0x82` at clock 1,332,538,693. The generic dispatcher
published the late Bluetooth self-test response to the common slot at
clock 1,369,716,554. It pointed at the payload at `0x800266C8`, whose
cached frame was `000000590600233908020100ffffffff`, with resource
`0x59`, message `0x02`, and test number `0x08`. The original ADSP caller
loaded `0x02` at `0x516A628A` at clock 1,369,720,969 (13.170 seconds)
and expected `0x8B`. The EUART trace from 9.615 seconds to that load
recorded D0 bootstrap and control traffic, with zero diagnostic 42
requests or replies in that window. The failing message matches the
original `ngage-v5` capture byte for byte.

A seven-millisecond replay of the saved lead-up to the assertion traced
the reply back to `SelfTestServer.exe`. It built test `0x08` with result
`0x01` at `0x5037240A`, then called the PhoNet send path at `0x5037242C`.
PhoNet wrote source object `0x39`. NOS then published and consumed the
same frame through the common response slot.

The same trace shows the 4.03 Bluetooth stack completing a CBUS write
of HCI command `0xFC03` with parameters `00 01 00 00 07`. It acknowledged
both Bluetooth interrupts through `0x0C150102` and read an HCI Command
Status event `04 00 0F 04 01 01 03 FC`. The existing QD controller
returns `0x01` (Unknown HCI Command) for this vendor opcode. This is a
measured NEM-4 compatibility gap. Its effect on the self-test deadline
still needs verification.

The UART trace and the dispatcher replay are in
`build/nem4-d550/reply-probe/` and `build/nem4-d550/dispatch-probe/`.
The dispatcher replay saved a checkpoint pair at 13.163 seconds, shortly
before the wrong response reached the slot. The sender trace is in
`build/nem4-d550/late-bt-probe/`.

### Reference boot comparison

`ngage-v5` displayed the stock 4.03 Nokia logo by two billion clocks in
its frozen service-firmware simulation. On MiSTer, `2d9605f` seed 44
reached Phone and a populated Menu after the normal Time and Date prompts.
That boot used the production D550 startup peer, the serialized SIM
reply FIFO, the mandatory SIM files `6F74`, `6F20`, and `6F7B`, and an
initialized six-profile C: image. See `docs/display-bringup.md` and
`docs/sim-mandatory-files.md` in the reference repository. The reference
also recorded the `59/02` assertion on other runs with the same D550
peer, so its successful boot does not establish that the race was fixed.

Integration already contains the corresponding DSP startup behavior, SIM
FIFO and mandatory SIM files. The simulation's initial C: region matches
the reference Menu boot's `4a75e4cb…` image. Its initial PMM is the
`c7075d00…` AAN seed, while the reference used `71189f7f…`. The reference
leaves the LRB-2 peer disconnected. The earlier integration run served
CBUS device 5 through the QD Bluetooth model, which produced the `0xFC03`
status event above.

### Porting the remaining reference startup behavior

The NEM-4 profile now routes CBUS device 5 to unmodeled register backing
with no Bluetooth IRQ producer. This follows the disconnected LRB-2 in
`ngage-v5`. The QD profile still selects its existing Bluetooth controller.
The peripheral bench verifies a CBUS request under each profile.

The old 4.03 trace reads calibration window `0x009F`, which made the
prior wrap-based NOS counter run at about 205 Hz. Both profiles now
advance the NOS comparator at exactly 64 Hz at the 104 MHz system clock.
The existing calibration prescaler supplies the slow tick every 512
calibration ticks. Programming the calibration reload cannot change its
period. NEM-4 general timers use 26 MHz, matching the separate timer
clock in the reference. The QD general timers use their existing divider.
The timer and peripheral regressions check the compare IRQ, acknowledgement,
and profile-specific general timer cadence.

NEM-4 sends packed LCD commands `15`, `75`, `5C` and `AF` under header
`0x09200000`, and RGB444 pairs under `0x8924xxxx`. The QD byte serializer
does not recognize the NEM-4 command header. The port uses the
`ngage-v5` full-width row-band decoder for NEM-4 and writes both profiles
into the same RGB565 framebuffer. The peripheral bench writes a full
native frame, verifies pair order and scanout, and exercises a row-band
DMA update. The QD LCD regressions and top-level lint also pass. Both
stock 4.03 cold boots with the native panel display the initial white
clear at 0.333 seconds. The run using the SD card's saves displays the
stock Nokia logo at 3.129 seconds. The capture is
`build/sim/screens/nem4-v5-media/to-1000000000/lcd-00003129.png`.

Cold boots using the combined changes run with the previous simulation
inputs under `build/nem4-native-panel/` and with the C: and PMM from the
SD card's `games/ngage1` under `build/nem4-v5-media/`. The latter preserves
the stock code bytes and places the two existing saves into their native
flash windows in private input files. The SD PMM contains a native group
50, record 1 entry. The three-record AAN simulation seed lacks it. The QD
control uses the same binary under `build/qd-nos64/` with the previously
tested stock 4.10 and seeded C:.

At the 1.5-billion-clock checkpoint (14.423 seconds), the stock 4.03
run with the SD saves has native RF `0x1E=00` and ADSP `0x36=00`. These
results were read from the original NOS array with resident CPU cache
data applied. The previous `St_product.c` assertion did not recur in
that interval. The checkpoint retains the Nokia splash and the run
continues into SIM and UI startup.

At two billion clocks (19.231 seconds), stock 4.03 has `SIM_Server`
state 8, MTC state 1, and both RF and ADSP results still `00`. Stock
4.10 also has SIM state 8 and MTC status `1, 1` at the same checkpoint.
4.03's packed LCD decoder has accepted an original full-width row
update since the splash. The most recent visible frame remains Nokia.

The stock 4.03 run with the SD saves then plays the N-Gage animation
and displays the Phone home screen at 22.640 seconds. The clock appears
in the status area and the soft keys are Contacts and Messaging. The run
used the simulator's default RTC and displayed neither a Time nor a Date
setup prompt before reaching Phone. No key events were supplied. The
capture is `build/sim/screens/nem4-v5-media/to-2500000000/lcd-00022640.png`.
The shell, C: save and both PMM profile regressions pass.

## Remaining validation

Verify complete 4.03 and 4.10 boots on MiSTer, then check game audio,
Bomberman, and C: and PMM writeback when switching launchers.
