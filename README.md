# N-Gage QD for MiSTer

The Nokia N-Gage QD as a MiSTer core: the phone's own firmware boots on an
ARM925T reconstruction with its LCD, keypad, flash, SDRAM and game-card
slot, so N-Gage game cards run as they did on the device. The cellular side
is not emulated; the phone comes up as an offline handset with no SIM.

## What you need

- A MiSTer with the SDRAM module (32 MB or larger).
- Your own RH-29 (N-Gage QD) firmware, software version 4.60: the Phoenix
  flash files `RH2946.0C1` and `RH2946.0S5`.
- Game-card dumps: an [Aaru](https://www.aaru.app/) dump of a card, or the
  card's root folder.
- On your computer: Python 3, and for game folders
  [unar](https://theunarchiver.com/command-line) and
  [mtools](https://www.gnu.org/software/mtools/).

## Setup

1. Build the flash images from the firmware:
   `tools/mkimage.py phoenix RH2946.0C1 RH2946.0S5 -o out` writes `cs0.bin`
   (16 MB) and `cs1.bin` (8 MB).
2. Build a card image per game: `tools/mkcard.py aaru DUMP.aaruf -o game`
   for a dump, or `tools/mkcard.py folder GAMEDIR -o game` for a folder;
   each gives `game.mmc`.
3. Copy the newest `NGage_YYYYMMDD.rbf` from [releases/](releases/) to
   `/media/fat/_Console/` on the MiSTer (or a folder of its own such as
   `_Console/_NGage/`, which the menu shows as "NGage") and the images to
   `/media/fat/games/NGage/` ([MiSTer file
   transfer](https://mister-devel.github.io/MkDocs_MiSTer/)).
4. Start the core. In the OSD: **Load flash CS0** → `cs0.bin`, **Mount
   flash CS1 (save)** → a copy of `cs1.bin` (the core writes your saves
   into it), **Mount MMC card** → `game.mmc`.
5. The first start formats the phone's C: drive: the Nokia logo stays for
   two to three minutes, then the phone asks for the time and date
   (OK = Enter). Later starts go straight to the idle screen.
6. Menu key (F5), then down to the card's game, OK.

An `.mgl` launcher can do step 4: file indexes 1 (CS0), 2 (CS1 as a plain
load) or mount slot 1 (CS1 save) and slot 0 (card).

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

- **Mount `cs1.bin` as a save (not as a plain load) if you want settings
  and game saves to persist**; a plain load of CS1 is lost at the next
  start. The save file must be exactly 8 MB.
- Saves go out to the file a few seconds after the phone writes them;
  **Save C: now** in the OSD writes them at once.
- One `cs1.bin` copy per profile: the phone's C: drive lives inside it.
- The firmware is Spanish (movistar) in this version; the game cards do
  not care.
- **Aspect ratio** in the OSD: *Original* is the panel's own shape (176:208,
  turned with Rotate); `[ARC1]` and `[ARC2]` are your own ratios from
  `custom_aspect_ratio_1` and `custom_aspect_ratio_2` in `MiSTer.ini`, for
  example `custom_aspect_ratio_1=11:13`. *Vertical Crop* fits the upright
  picture to 1080p at 6x; *Scale* is the usual integer-scaling choice.

## Status

Verified on a MiSTer with the release build in [releases/](releases/):
boot to the idle screen, the first-start format of C:, saves written back
to the mounted image, Sonic N from its card (menu entry, title screen,
demo) and its keys (5 skips the intro, the rocker moves through the
character select), and the game's sound reaches the audio output (checked
by measurement, not yet by ear).

## Troubleshooting

- Nokia logo and nothing else for minutes: the first start is formatting
  C:; a second start with a plain-loaded CS1 formats it again. After the
  core was stopped in the middle of writing saves, the next start spends
  minutes recovering the phone's file system (its sector erases take the
  chip's 0.7 s each); it does come up.
- "CS1 save file must be 8 MB": the mounted file is a different size.
- The phone asks for the time at every start: the firmware does that in
  this environment (the model too); OK accepts the clock it shows, or
  enter the real one.
- Nothing on screen at all: the core needs both flash images before the
  CPU starts; check that CS0 loaded.

## More

[docs/UPP_WD2.md](docs/UPP_WD2.md) describes the hardware as reconstructed,
[docs/CPU.md](docs/CPU.md) the processor, [docs/NOS_STANDIN.md](docs/NOS_STANDIN.md)
- [RetroTINK 4K direct video](docs/RETROTINK4K.md): a profile recipe that shows the picture the way the QD's screen did.
the stand-in for the phone's cellular firmware, and
[docs/PROGRESS-LOG.md](docs/PROGRESS-LOG.md) the development record.
This project's own files are GPL-2.0-or-later ([LICENSE](LICENSE)); the
CPU is built from the ZAP core ([rtl/cpu/zap](rtl/cpu/zap), GPL-3.0-or-later),
so the core as a whole is distributed under the GPL version 3.
