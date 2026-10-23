# Direct Phoenix firmware loading — 2026-10-23

The core now accepts RH2946.0C1 at F1 and RH2946.0S5 at F2, constructs the
flash images in DDR3, verifies the unpatched 4.60 signatures and applies the
project's NOS patches. C: is a separate 4 MB save. No PC firmware conversion
is needed. The development flat-image route remains at F3 (CS0) / F4 (CS1).
No existing OSD status-bit position changed.

Implementation commits on `codex/firstboot`:

- `431e21e`: streaming loader, generated patch ROM and standalone real-file harness.
- `d924760`: C:-only save layout, blank save, DDR loader readback and save/DDR tests.
- `a96c368`: shell integration, OSD/reset gating, indexes and whole-core tests.

README and this report are a separate documentation commit. Nothing was pushed.

## Implementation

`rtl/mister/phoenix_load.sv` is a streaming parser and patch engine, connected
to the existing DDR3 loader port through `NGage.sv`. A new pair fills all
16 MB of CS0 and only the lower 4 MB of CS1 with FF. This is a dedicated
64-bit fill counter in the loader, not a NOR sector erase or a CPU operation.
It runs before parsing the first file of the pair, so language-first loading
works without a later MCU fill destroying the language data. Record payloads
use byte enables on the same port. Firmware records targeting C: or crossing
an allowed chip range are rejected.

The two files may arrive in either order. Selecting a file already completed
in the current pair starts a fresh pair; a damaged file invalidates the pair.
Reload both after either a completed pair or a damaged-file error. Loading
firmware never detaches the C: save. The CPU stays reset during parsing,
verification and patch writes, then waits for C: (a completed save mount or
a development F4 load) and the existing RTC condition. The flat route needs
both flat chips because mounting S1 no longer loads CS1's firmware half.

`ioctl_wait` backpressures the existing WIDE=1 HPS transport during fills,
DDR stalls, verification and patching. A small input queue retains one byte
of lookahead for odd-length files; both supplied files have odd lengths.
There is no whole-file buffer. The DDR arbiter retains each stalled command
unchanged. `ddram_flash` now accepts single-beat loader reads, drains previous
chip/bulk read responses first, and routes the response to Phoenix even while
the phone is in reset. The normal flash-cache and save paths retain their
existing DDR ordering.

## Record handling and damage checks

The parser follows `tools/fls2bin.py`:

| Record | Header and action |
|---|---|
| A2 file | BE u32 token-section length; BE u32 token count; ordinary u8 lengths, F3 u16 lengths, the zero/u8 extended-length form, and section padding |
| 14 | 10 bytes: address at +1 (BE u32), data checksum +5, length +6 (BE u24), header checksum +9; map data to NOR |
| 21 | 16 bytes: six opaque prefix bytes, address +7, data checksum +11, length +12, header checksum +15; map data to NOR |
| 20 | 6-byte Bluetooth header, BE u16 length at +3; skip payload |
| 25 | Type, u8 payload length, payload; skip |
| 26 | Fixed 10 bytes including type; skip |
| 2E | 10-byte mass-memory header; verify header/data checksums and skip, never map it into NOR |

Checksums are the complemented 8-bit byte sum. Header 14/2E checks cover
bytes 1–8; header 21 covers bytes 7–14. The latter rule is confirmed against
the real record (fls2bin leaves that header check unspecified). For 14 and
21 data, accept the complement or complement-plus-one convention: the supplied
MCU/language files use plus one, which fls2bin reports as `d_fix == 1` for 14.
2E uses the strict complemented sum. Types 20/25/26 have no checksum in the
reference parser. Their lengths are still enforced.

A saturating 16-bit `errors` counter counts failures within each file and
resets at the next download. Unknown types, malformed/truncated structures,
invalid address ranges and checksum failures prevent completion. Data may
already have reached DDR before a checksum fails; the CPU remains held and
the next pair begins with a fresh fill. Info message 9 is **Firmware file
damaged**. Existing messages 1–8 retain their numbers; 10 is **Firmware 4.60
loaded**, and 11 is **Firmware not recognised: needs RH-29 4.60**.

## Version check and generated patch ROM

The signatures were obtained with `python3 -I tools/mkimage.py phoenix ...
--no-patches` and checked in the unpatched CS0 image. Four DDR read beats
compare the 32 digest bytes at these positions before any patch write:

| Integrity entry | Digest address | Unpatched digest | Patched digest |
|---|---|---|---|
| 0x8F00 | CS0 0x8F08 | a4e51308de06c2145c2ac9f801dc6099 | a4e51308de06c2145c2ac9f801dc6099 |
| 0x8F18 | CS0 0x8F20 | 2f00b1ff1b8f03f0592c4355f3177651 | fc2658343cc56fd28cdd2c2125b359d2 |

A mismatch leaves the loaded image unpatched and the CPU held in reset.
These are version signatures read from the image, not newly computed hashes
of its whole contents.

`make patchrom` runs `tools/gen_patchrom.py`. It reads `model/rom-patches.txt`,
resolves file patches against the committed `tools/standin/` binaries, and
writes `rtl/mister/phoenix_patch.hex` and `phoenix_patch.vh`. The encoded
records are chip u8, offset BE u24, length BE u32, then payload; FF terminates
the table. Both fixed digest records are appended at entry + 8. The current
ROM is **9,590 bytes**: 8,333-byte NOS DLL, 1,192-byte NOS stub, 32 digest
bytes, four 8-byte headers, and one terminator. It uses a synchronous ROM
read; FPGA memory packing/resource use remains for Quartus to measure.

`make patchrom-check` verifies the committed generated files. A SHA-256
fingerprint of the encoded patch payload prevents silently reusing the fixed
MD5 constants after changing the stand-ins or patch list. Such a change must
first regenerate the reference images/digests with mkimage, then update the
constants and fingerprint. Neither the patch ROM nor the supplied save file
contains Nokia firmware. The 56 per-phone bytes at CS0 0x12C–0x163 remain FF,
exactly as in the supplied reference image.

## C: layout and compatibility

`flash_save` maps only CS1 0x400000–0x7FFFFF, DDR3 0x32400000–0x327FFFFF:

| Save file | Read/write LBAs | Mapping |
|---|---|---|
| 4,194,304 bytes | 0–8191 | File offset 0 = CS1 0x400000 |
| 8,388,608 bytes, legacy | 8192–16383 | Lower 4 MB ignored on load and never written |

Loading uses 1,024 requests of 4 KB. Dirty marks from the CS1 firmware half
are filtered before the bitmap, queue and write-back scheduling. The physical
C: block numbers remain unchanged internally; only the file LBA is translated.
The existing delayed/forced saves, read-only mounts and reset retention remain.

The C: blank scan now re-arms at the first byte of a **C: load**, not a CS1
firmware load. Any loaded/programmed non-FF C: byte clears it. Firmware fills
and reloads therefore cannot accidentally re-enable the first-boot fast path
on a formatted save. NOR timing logic itself was not changed in this task.
`releases/ngage-c-drive.bin` is exactly 4 MB of FF, MD5
`2b7a70fa59f8173635bcbe956bad56c6`; copy it for each new profile.

## Validation

All simulation uses Verilator 5.052. Tests run one bench at a time. The real
firmware inputs were read, without modification, from the adjacent main
worktree's `research/firmware/images/rh29-4.60-dp/inner/products/RH-29/`.

- `make patchrom-check`: passed.
- `make -C sim ddrflash`: passed, 393,030 clocks. Adds loader readback both
  under reset and behind chip reads with randomized DDR stalls, plus the
  revised C: blank/reload rules. Existing cache/read/write checks also pass.
- `make -C sim save`: passed, 24,124,618 clocks. Exercises both file sizes,
  firmware preservation, first/last C: block write-back at LBAs 0/8191 for
  the 4 MB file, legacy offsets, firmware dirty-mark filtering, read-only
  mounting, reset retention, save-now and concurrent changes during write-back.
- `make -C sim phoenix`: passed. Synthetic token forms, all six record types,
  both data-checksum conventions, odd transport padding, both file orders,
  FF gaps, every patch payload, unknown version, bad header and data checksums,
  error counts, retry after damage, C: address rejection and truncated input.
- `make -C sim phoenix-real PHOENIX_DIR=/Users/jacob/dev/fpga/mister/NGage_MiSTer/research/firmware/images/rh29-4.60-dp/inner/products/RH-29`:
  passed. 61,978,674 simulated clocks and 22,394,085 DDR writes with 30%
  randomized backpressure. The MCU has 2,229 type-14, 854 type-20 and one
  type-21 record; the language file has 185 type-14 records. Both files pass
  their checksum checks. C: starts from the separate all-FF save fixture.
- `make -C sim top`: passed. The new Phoenix shell cases take 22,198,573
  clocks: synthetic MCU/language records through ioctl, full DDR fill and
  patch comparison, version/damage OSD messages, CPU held until the pair and
  save finish, a tiny ARM program starting afterwards, reverse file order
  with a mounted save, and C: isolation/blank detection. The existing shell
  regression also passes in 150,622,764 clocks (video, keys, rotation/crop,
  activity/boot messages, F3/F4 flat loads, legacy save and memory self-test).
- `make lint`: passed across all listed module tops, including Phoenix.
- `verilator --lint-only -Wall --top-module emu -f lint/rtl.f`: passed.
- `verilator --lint-only -Wall -DNGAGE_NO_DEBUG=1 --top-module emu -f lint/rtl.f`:
  passed. No new lint suppressions were added.

The real-file harness compares every byte against `build/ref/cs0.bin` and
`build/ref/cs1.bin`, then emits `sim/build/out/phoenix-cs0.bin` and
`phoenix-cs1.bin`. Both comparisons pass:

| Image | Bytes | Reference and RTL output MD5 |
|---|---:|---|
| CS0 | 16,777,216 | 63aa211d06bd8df899e1239988b10316 |
| CS1 | 8,388,608 | db6a465764970f08d5ed7a16aa3ec500 |

Input MD5s also match the supplied identities: MCU
`d75d37cb4a3cffe48c881c1754de5810`, language
`d65fdde7287947efb66cec137f1378e7`. Inputs, reference images and emitted
firmware are ignored build/research artifacts, not committed files.

## MiSTer setup and handoff

[README.md](../../README.md#setup) has the complete no-PC setup and MGL example.
Place renamed MCU `boot1.rom`, language `boot2.rom`, and a writable copy of the
blank C: file as `boot1.vhd` in `/media/fat/games/NGage/`. Pick the card in the
OSD, or put its image there as `boot0.vhd`. Main sends the numbered ROMs before
the numbered mounts; this matches its current
[user_io.cpp startup path](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/user_io.cpp).
An explicit launcher uses type `f` indexes 1/2, type `s` index 1 for C:, and
`s` index 0 for the card (the README includes valid XML).

Board handoff: boot those files from a fresh C: copy, accept the Time and Date
dialogs, make a setting change, use Save C: now, and reboot with the same C:
file. Also try an existing 8 MB save, manual language-first loading, and
checksum-corrupted/other-version inputs to check the two failure messages.
Firmware-half/C: isolation and reset gating are checked in simulation; the
physical HPS transfer, visible messages and persistence should be confirmed
in this board pass.

## Limits and work deliberately not run

- No Quartus whole-core build, fit/timing/resource claim, or board deployment
  was made. Those are assigned to someone else. The generated ROM must be
  available at its repository-relative path when building.
- No full firmware CPU boot bench or QEMU run was performed. Whole-core
  testing uses a tiny synthetic ARM program; the real-file test proves image
  reconstruction. Boot with the all-FF per-phone bytes is the stated assumption
  and is being checked separately on the board.
- Only the named 4.60 C1/S5 pair is validated. The signature comparison is
  not authentication or a full-image MD5 calculation. Checksum-preserving
  corruption, changed records with recomputed checksums, or a different
  language pack with the same MCU signatures need not be detected here.
- WIDE ioctl does not provide the exact odd-byte file length. One trailing
  high byte at a record boundary is treated as transport padding, regardless
  of its value. A malformed trailing single byte is consequently ambiguous;
  truncation inside a header/data/token section is rejected.
- Skipped Bluetooth/raw records have no reference checksum to validate;
  only their structure/length is checked. Type-21 prefix bytes are opaque.
- The raw development route retains its existing relaxed file-size behavior.
  Full CS0/CS1 images are the intended input; F4 is allowed to replace the
  whole CS1 chip, so use it before Phoenix when combining the two routes.
- No edits to `sys/`, `rtl/cpu/`, or `rtl/board/mmc_card.sv`. No push.

## Board validation and unexpected single-file reload — follow-up

The user reported that the default Python image, including FF at the 56
per-phone bytes at CS0 `0x12C–0x163`, booted to the idle screen and ran Sonic.
This resolves the earlier board-validation assumption above. The in-core
version check still uses the loaded integrity-table signatures, independently
of the PC tool's newer SHA-256 input checks.

The merged Phoenix loader (`a83342a`), built as debug core b24, also worked on
the board from an MGL with F1 MCU, F2 language, S1 a fresh blank C: copy and
S0 the card. Reported timings from CPU start: format 44–84 s, Time dialog
96 s, setup after Date 108–113 s, 852 KB C: write-back at 121 s, idle screen
by 170 s. A second boot using that save reached idle without formatting.
These are supplied board observations, not measurements from this follow-up.

An earlier otherwise identical run failed once after the second Enter at
106.3 s. Screenshots were unavailable until 120 s; afterwards the overlay
showed CPU reset, PC zero, no interrupt enables, save present and colour
bars. A lone MCU transfer is consistent with both the approximately 14 s
gap and the existing fresh-pair rule, but the transfer index and its trigger
were not captured. The rerun did not reproduce it. This change makes that
specific hypothesis observable; it does not claim to have found Main's
runtime trigger.

### Loader diagnostics

Commit `087088d` appends **word 37 at rows 156–158** and **word 38 at rows
160–162**, at x 16–47. The original 12 words and 25 counters retain every
position. Both new words are snapshotted together at the frame boundary,
including while the CPU is reset. The registers and drawing are inside
`ifndef NGAGE_NO_DEBUG`; a release build omits them.

| Word | Bits | Meaning |
|---|---|---|
| 37 | 31 / 30 | `ph_ready` / `ph_busy` |
| 37 | 29:28 | Pair `have`: bit 0 MCU, bit 1 language |
| 37 | 27:22 | Most recent download-start ioctl index (low six bits) |
| 37 | 21:19 | Last nonzero loader note |
| 37 | 18:14 | Parser state (0 idle, 1 fill, 15/16 version read, 17/18 patch) |
| 37 | 13:0 | Reserved, zero |
| 38 | 31:28 / 27:24 / 23:20 / 19:16 | F1 / F2 / F3 / F4 download-start counts |
| 38 | 15:0 | Full current-file error count |

Starts count rising edges of `ioctl_download`, not records or retries at the
DDR port. Each count saturates at 15 (printed `15+`); index and counts cover
the flat development downloads too. History survives CPU/OSD resets and
clears on `sys_reset` (the external RESET input or PLL unlock, including
initialisation after FPGA reconfiguration). The error count saturates at
65535 and clears at the next Phoenix file start, as before. The last note
persists: 0 none, 1 damaged, 2 unrecognised, 3 loaded, 4 reload-both.
`tools/mister_dbg.py` now prints these fields after the existing counters.
Old screenshots have no valid loader words; use a build containing this
change when interpreting them.

### Conservative handling of a resend

Commit `ba21a59` implements the requested fallback: after a successfully received file
that restarted the pair, info entry **12** says **Firmware reloaded: load
both files**. The event is emitted after EOF and DDR writes drain, when Main
has finished sending the file; the debug overlay retains note 4 afterwards.
A damaged resend instead reports the existing damage message. First loads
and the complementary file do not produce a reload warning. Existing info
IDs and OSD status bits are unchanged.

An exact raw-payload comparison against current DDR is not a sound MCU
identity test: the incoming original includes bytes that the NOS stand-in
and integrity digest patches have replaced. Ignoring those locations would
fail to check the whole payload. Further, on a late mismatch, filling the
image and continuing would lose the already-consumed prefix; the stream
cannot rewind. Retaining the old prefix can also retain records/gaps from
the other file or a previous image. A transparent solution needs additional
original-data storage or a complete identity scheme plus a transactional
reload/replay design, rather than a late switch to the existing fill state.
No such broader storage/protocol change is made here.

Consequently an identical single resend **still holds the CPU in reset**
until its companion is received. It now explains the wait. Selecting both
original files again is always the documented recovery; if the new overlay
identifies the one already received, sending just its missing companion
also completes the pair. Firmware fills still leave C: intact, its mount
stays present, and no firmware write dirties the C: save. This does not
promise preservation of guest state or any unsaved changes across a CPU
reset.

### Main source audit

Read the official `MiSTer-devel/Main_MiSTer` source pinned at
`065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7` (master at inspection), including
`user_io.cpp`, `menu.cpp`, MGL parsing, recent files and input handling.
Snapshots are ignored local research artifacts under
`build/main-phoenix-audit/`; no Main or framework code was changed. The
board's exact Main binary/revision was not supplied, so this is a source
inspection, not a reproduction on that binary.

- Startup ROM loading and remembered `FC`/`FSC` filenames run during core
  initialisation. Remembering requires the `C` modifier; NGage uses plain
  `F1`/`F2`. `Selected_F` remembers the browser selection and recent-file
  history, but does not periodically resend it.
  [Startup/parse_config](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/user_io.cpp#L981),
  [boot ROMs](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/user_io.cpp#L1694).
- A normal F-option selection or recent-file selection reaches
  `MENU_GENERIC_FILE_SELECTED` and `user_io_file_tx`. MGL uses the same
  route with an explicit path. An unfinished/delayed MGL item can therefore
  load a file with the core already running. The sequencer increments
  `current`, marks `done` at the end, and has no completed-list replay path.
  [MGL sequencer](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/menu.cpp#L1214),
  [F selection](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/menu.cpp#L2443),
  [transfer](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/menu.cpp#L2685).
- Enter, Space and keypad Enter set the menu's `select` event. The closed
  menu/info states do not use `select` to reopen an F entry. An incomplete
  MGL can open/select an entry without showing the OSD, but that requires
  `!done`; no Enter-only restart of a completed MGL was found.
  [Key events](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/menu.cpp#L1445),
  [closed menu](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/menu.cpp#L1632).
- Generic reset options pulse status bits; reset buttons send `UIO_BUT_SW`.
  Neither resends NGage F1. Special keyboard/core reload paths reconfigure
  an RBF; they are not a lone-file resend on plain Enter. A core info event
  rereads the configuration string to find `I`; it does not invoke
  `parse_config` or its remembered-file loader. The generic file-transfer
  loop sends one open file to EOF, without an automatic whole-file retry.
  [OSD reset](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/menu.cpp#L2607),
  [buttons](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/user_io.cpp#L3196),
  [info handling](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/user_io.cpp#L2761),
  [transfer loop](https://github.com/MiSTer-devel/Main_MiSTer/blob/065d0d2d3232ba7b81ff0257b5f5b19ad952e8f7/user_io.cpp#L3027).

No matching normal path explains the supplied completed-launcher,
Enter-only observation. On recurrence, retain screenshots before/after,
the exact MGL and Main revision, and Main's stdout: `user_io_file_tx` prints
the selected filename, byte count and index. With `log_file_entry` enabled,
Main also records selection paths under `/tmp`, including the MGL route
in the audited revision. Those logs distinguish an actual F1 repeat from
an F3/F4 transfer, core reload or unrelated reset. Do not infer the sender
solely from how long screenshots are unavailable.

For the next debug-board pass, capture a baseline after the MGL completes
and keep the overlay enabled through the Time/Date inputs. Compare start
counts against that baseline rather than assuming no automatic ROMs were
also loaded. A deliberate F1 reselect after saving C: should produce the
new message, `ready=0 busy=0 have=01 last=F1 note=4`, and one additional F1
start while `save=1` remains set. Selecting F2 should then produce the
loaded message and restart the phone with the same C:. This deliberate
sequence is covered locally; it has not yet been exercised on the board.

### Follow-up verification

All requested checks passed locally with Verilator 5.052, running one
simulation at a time:

| Check | Result |
|---|---|
| `make -C sim phoenix` | Pass; existing parser cases plus either-file resend, warning only after EOF, companion recovery, damage-message priority and C: preservation |
| `make -C sim phoenix-real PHOENIX_DIR=/Users/jacob/dev/fpga/mister/NGage_MiSTer/research/firmware/images/rh29-4.60-dp/inner/products/RH-29` | Pass; initial pair and MCU-resend/language-recovery pair both match both reference images byte for byte |
| `make -C sim top` | Pass; Phoenix cases 38,088,524 clocks, existing shell regression 150,622,764 clocks |
| `make -C sim save` | Pass; 24,124,618 clocks, both save sizes, firmware isolation and write-back checks |
| `make -C sim ddrflash` | Pass; 393,030 clocks, existing loader/readback/cache/blank-scan checks |
| `make lint` | Pass; includes `verilator --lint-only -Wall --top-module emu -f lint/rtl.f` and all listed module tops |
| `verilator --lint-only -Wall -DNGAGE_NO_DEBUG=1 --top-module emu -f lint/rtl.f` | Pass |

The real test takes 61,978,674 clocks / 22,394,085 DDR writes for the initial
pair, and 123,958,365 clocks / 44,788,170 writes including the resend and
recovery. Output MD5s remain CS0 `63aa211d06bd8df899e1239988b10316` and CS1
`db6a465764970f08d5ed7a16aa3ec500`. No firmware inputs or reference images
were modified or committed.

The top test reads the appended words from actual rendered pixels. Running
`uv run tools/mister_dbg.py sim/build/out/top_phoenix_reload.ppm
sim/build/out/top_phoenix_loader.ppm` also confirmed the decoder output:

```text
cpu_reset=1 ... save=1 ... loader: ready=0 busy=0 have=01 last=F1 starts[F1/F2/F3/F4]=2/1/0/0 note=4(reload-both) errors=0 state=0
cpu_reset=1 ... loader: ready=0 busy=0 have=00 last=F4 starts[F1/F2/F3/F4]=5/4/2/15+ note=1(damaged) errors=1 state=0
```

The first frame reproduces the suspected lone-MCU state; the second checks
all four counters, saturation, error visibility and retention through a
CPU/OSD reset. The top test then verifies companion loading releases reset,
and that firmware loads preserve C: and cause no save-file writes. Original
overlay rows/counters and every OSD option bit retain their positions.

No Quartus build, fit/resource claim, board deployment or full firmware CPU
boot bench was performed in this follow-up. The new notification and overlay
still need physical-board validation; b24's supplied successful boot timings
do not validate these later changes. Main's intermittent trigger remains
unreproduced. No edits to `sys/`, `rtl/cpu/`, or `rtl/board/mmc_card.sv`, and
no push. The audit and this report are committed separately from the two
implementation changes.
