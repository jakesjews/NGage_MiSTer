# N-Gage QD for MiSTer

The Nokia N-Gage QD as a MiSTer core: the phone's own firmware boots on an
ARM925T reconstruction with its LCD, keypad, flash, SDRAM and game-card
slot, so N-Gage game cards run as they did on the device. The cellular side
is not emulated; the phone comes up as an offline handset with no SIM.

## What you need

- A MiSTer with the SDRAM module (32 MB or larger).
- Your own RH-29 (N-Gage QD) firmware, software version 4.60: the Phoenix
  files `RH2946.0C1` (MCU) and `RH2946.0S5` (language pack).
- A game-card image (`.mmc`) to play games. The phone can boot without one.

## Setup

No firmware conversion or Python installation is needed. The core reads the
Phoenix files and applies its NOS stand-in and boot patches itself.

1. Copy a build containing the Phoenix loader to `/media/fat/_Console/`
   (for example `NGage_YYYYMMDD.rbf`).
2. In `/media/fat/games/NGage/`, put these three files:

   | File on MiSTer | Contents |
   |---|---|
   | `boot1.rom` | Your `RH2946.0C1`, renamed |
   | `boot2.rom` | Your `RH2946.0S5`, renamed |
   | `boot1.vhd` | A copy of [ngage-c-drive.bin](releases/ngage-c-drive.bin), renamed |

   The `.vhd` is a raw 4 MB C: save, with no VHD container header. Keep this
   copy between boots: it holds phone settings and game saves. Copy the blank
   file only when creating a new profile.
3. Start the core. MiSTer loads both ROMs and mounts the save automatically.
   The core reports **Firmware 4.60 loaded**, then **Booting the phone**.
   A fresh C: is formatted on its first boot; accept the Time and Date dialogs
   with Enter. The activity dot shows recent CPU bus traffic.
4. Pick your card with **Mount MMC card** in the OSD. To mount one by default,
   copy its image as `boot0.vhd` in the same games folder.
5. Press Menu (F5), select the card's game, then OK (Enter).

For manual loading, choose **Load firmware (RH2946.0C1)**, **Load language
pack (RH2946.0S5)** and **Mount C: save**. They can be selected in any order;
loading firmware preserves C:, and mounting a save preserves firmware.
Reselecting either file of a completed firmware pair starts a new pair, so
select both again. **Firmware reloaded: load both files** explains this wait;
it also appears if a file is resent unexpectedly. After a damaged-file
message, also reload both files. The mounted C: save is preserved.

An [MGL launcher](https://mister-devel.github.io/MkDocs_MiSTer/advanced/mgl/)
can select files explicitly. With these files in `games/NGage/`, for example:

```xml
<mistergamedescription>
    <rbf>_Console/NGage</rbf>
    <file delay="1" type="f" index="1" path="RH2946.0C1"/>
    <file delay="1" type="f" index="2" path="RH2946.0S5"/>
    <file delay="1" type="s" index="1" path="my-c-drive.bin"/>
    <file delay="1" type="s" index="0" path="sonicn.mmc"/>
</mistergamedescription>
```

F1/F2 now mean Phoenix MCU/language, S1 is C: and S0 is the card. Update old
flat-image launchers: development **Load flash CS0 image** is F3 and **Load
flash CS1 image** is F4. The flat route needs both complete chips; S1 now
loads only C:. A plain F4 load supplies volatile C: and detaches its save;
mount S1 afterwards to persist it. Phoenix can also use C: supplied by F4;
load F4 before the Phoenix pair so the pair supplies the firmware half.

The PC tools remain available for development: `tools/mkimage.py phoenix
RH2946.0C1 RH2946.0S5 -o out` produces flat `cs0.bin`/`cs1.bin`; `flat` mode
accepts flat dumps. To prepare cards from an Aaru dump or a game folder,
use `tools/mkcard.py` (Python 3; folder mode also needs mtools, and archives
need unar). Its output `.mmc` includes the card metadata used by the core. The tool checks that the two files are the 4.60 ones.

## Controls

| N-Gage | Keyboard | Gamepad |
|---|---|---|
| Rocker | Arrows | D-pad |
| 5 / 7 (game keys) | Z / X, or the number keys | A / B |
| OK | Enter, Space | X |
| Left / right soft key | F1 / F2 | L / R |
| Menu | F5, Home | Start |
| Call / End | F3 / F4 | Select / — |
| 0-9, *, # | Number keys, keypad * and # | — |
| Clear, Edit | Backspace, left Shift | — |
| Power | F8 | — |

## Good to know

- **Keep C: mounted to persist settings and game saves.** New save files
  are exactly 4 MB (4,194,304 bytes). Existing 8 MB CS1 saves also work:
  only their upper 4 MB is loaded or written; the lower half is ignored.
- Saves go out to the file a few seconds after the phone writes them;
  **Save C: now** in the OSD writes them at once.
- Keep one C: save copy per profile.
- The firmware is Spanish (movistar) in this version; the game cards do
  not care.
- **Activity dot**: *Boot only* (default, until the first firmware LCD frame), *Always*, or *Off*; green shows recent CPU bus activity.
- **Aspect ratio** in the OSD: *Original* is the panel's own shape (176:208,
  turned with Rotate); `[ARC1]` and `[ARC2]` are your own ratios from
  `custom_aspect_ratio_1` and `custom_aspect_ratio_2` in `MiSTer.ini`, for
  example `custom_aspect_ratio_1=11:13`. *Vertical Crop* fits the upright
  picture to 1080p at 6x; *Scale* is the usual integer-scaling choice.

## Status

The existing flat-image path was verified on a MiSTer with the release
build in [releases/](releases/):
boot to the idle screen, the first-start format of C:, saves written back
to the mounted image, Sonic N from its card (menu entry, title screen,
demo) and its keys (5 skips the intro, the rocker moves through the
character select), and the game's sound reaches the audio output (checked
by measurement, not yet by ear).

The direct Phoenix path reproduces the reference flash images byte for byte.
Board testing with debug build b24 confirmed a fresh C: format, Time/Date
setup, save write-back and arrival at the idle screen; the next boot skipped
formatting. One earlier run stalled after a suspected unexpected firmware
resend. Loader diagnostics and a reload message now cover that case in
simulation; their board check is pending. See the
[implementation report](docs/consults/2026-10-23-codex-phoenix-report.md).

## Troubleshooting

- Nokia logo and nothing else for minutes: a start with a plain-loaded
  CS1 formats C: again each time (mount it as the save instead). After the
  core was stopped in the middle of writing saves, the next start spends
  minutes recovering the phone's file system (its sector erases take the
  chip's 0.7 s each); it does come up. The activity dot in the corner
  shows the phone is busy.
- **Firmware file damaged**: a checksum, record, or file-length check failed.
  Reload both original Phoenix files.
- **Firmware reloaded: load both files**: a repeated MCU or language download
  started a new pair. Select both original files again; keep the same C: save.
  In a debug build, `tools/mister_dbg.py` prints the latest download index,
  F1/F2/F3/F4 start counts, pair state, last message and error count.
- **Firmware not recognised: needs RH-29 4.60**: the firmware integrity-table
  signatures do not match the supported release; the core leaves it unpatched
  and holds the phone in reset. Use the MCU and language pack named above.
- **C: save file must be 4 or 8 MB**: use the supplied blank file or an existing
  save of exactly that size.
- The phone asks for the time at every start: the firmware does that in
  this environment (the model too); OK accepts the clock it shows, or
  enter the real one.
- The phone does not start: both Phoenix files and a C: save must finish
  loading. Check the OSD messages and the three automatic-load filenames.

## More

[docs/UPP_WD2.md](docs/UPP_WD2.md) describes the hardware as reconstructed,
[docs/CPU.md](docs/CPU.md) the processor, [docs/NOS_STANDIN.md](docs/NOS_STANDIN.md)
the stand-in for the phone's cellular firmware, and
[docs/PROGRESS-LOG.md](docs/PROGRESS-LOG.md) the development record.
[docs/RETROTINK4K.md](docs/RETROTINK4K.md) is a RetroTINK 4K profile recipe for
direct video, shaped like the QD's own screen.
This project's own files are GPL-2.0-or-later ([LICENSE](LICENSE)); the
CPU's caches, MMU and writeback come from the ZAP core
([rtl/cpu/zap](rtl/cpu/zap), GPL-3.0-or-later), so the core as a whole is
distributed under the GPL version 3.
