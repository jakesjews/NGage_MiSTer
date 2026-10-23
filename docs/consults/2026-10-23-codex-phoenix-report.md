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
