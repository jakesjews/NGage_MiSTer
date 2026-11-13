# N-Gage QD for MiSTer

The Nokia N-Gage QD as a MiSTer core. The phone's own firmware boots on a
reconstruction of its hardware, so N-Gage game cards run as they did on the
phone. The cellular side is not emulated: the phone comes up as a handset
with no SIM.

## What you need

- A MiSTer with an SDRAM module (32 MB or larger).
- The N-Gage QD firmware, version 4.10 (model RH-29), as it comes in Nokia's
  service packages for the phone: `N-GageQD RH-29.zip`. It is Nokia's and is
  not included. Searching the Internet Archive for "Nokia DCT4 firmwares"
  finds the collection that has it in its file list.
- Game cards as `.mmc` images (see [Game cards](#game-cards)).

## Setup

1. Copy the `.rbf` from [releases/](releases/) to `/media/fat/_Console/`.
2. Create the folder `/media/fat/games/NGage/` and copy
   [boot0.vhd](releases/boot0.vhd) into it. This is the phone's C: drive: its
   settings and your game saves.
3. Drop the zip on the [firmware unpacker](https://ngage-mister.vercel.app/)
   and save `boot0.rom` and `boot1.rom` into the folder.
4. Copy your `.mmc` images into the folder.
5. Start **NGage** from the Console menu. The first start formats C: and asks
   for the time and date: press Enter for each.
6. Open the OSD, choose **Mount MMC card** and pick a game.
7. If the game does not start by itself, press Menu (F5), move to its icon and
   press OK (Enter).

If you have the firmware as `RH2941.0C1` and one of its language packs
(`RH2941.021`, or another for 4.10), rename them `boot0.rom` and `boot1.rom`
instead of step 3.

To have a card in the slot at every start, name a copy of its image
`boot1.vhd`. The phone then starts at its idle screen with the game in the menu.

## Controls

- Rocker: arrow keys, or the D-pad
- 5 and 7 (the game keys): Z and X, or A and B on a gamepad
- OK: Enter or Space, or X
- Left and right soft key: F1 and F2, or L and R
- Menu: F5 or Home, or Start
- Call and End: F3 and F4 (Select is Call)
- 0 to 9: the number keys (0 is Y on a gamepad)
- \* and #: keypad \* and keypad /
- Clear: Backspace
- Edit: left Shift
- Power: F8

The other phone keys can be given to gamepad buttons in MiSTer's button
mapping.

## Game cards

`tools/mkcard.py` (Python 3) makes the `.mmc` images the core mounts:

- From an [Aaru](https://www.aaru.app) dump of a card:
  `tools/mkcard.py SonicN.aaruf sonicn` writes `sonicn.mmc`.
- From a game's folder or an archive of it:
  `tools/mkcard.py --folder game.zip game`. This needs
  [mtools](https://www.gnu.org/software/mtools/), and
  [unar](https://theunarchiver.com/command-line-tools) for archives.

Only the `.mmc` file goes on the MiSTer.

## Good to know

- **Saves reach `boot0.vhd` a few seconds after the phone writes them.**
  Choose **Save C: now** in the OSD before switching off right after a save.
- Keep your `boot0.vhd`: replacing it with the blank file starts a new phone.
- Coming from a release that ran firmware 4.60 (up to 2026-11-12): replace
  all three files. A `boot0.vhd` made under 4.60 does not work with 4.10.
- Five minutes after the last key press the phone shows its screen saver,
  over a game too: a bar with the date and time on a black screen. Any key
  brings the picture back.
- Sonic N comes back muted, with a crossed-out speaker at the top right, when
  the screen saver or the phone's menu takes over outside play. Press 0 (Y)
  a few times to step its volume back up.
- Leave a game before changing cards: exit to the phone's menu, then mount
  the next card.
- **Aspect ratio** set to *Original* keeps the screen's own 176:208 shape,
  and **Rotate** turns the picture for a rotated display.
- **Load firmware**, **Load language pack** and **Mount C: save** in the OSD
  load the same three files by hand, in any order.
  **Load flash** is for development.

## Troubleshooting

- Black screen: the phone starts only when `boot0.rom`, `boot1.rom` and
  `boot0.vhd` are all in `games/NGage/` under exactly those names.
- **Firmware not recognised: needs RH-29 4.10**: these are other firmware
  files (4.60's, from an earlier release of the core), or the two are swapped.
  `boot0.rom` is `RH2941.0C1`.
- **Firmware file damaged**: copy the two firmware files to the MiSTer again.
- **C: save file must be 4 or 8 MB**: start again from a copy of the blank file.
- **C: read-only: no saves**: `boot0.vhd` is write-protected.
- The Nokia logo stays for a long time: the phone is formatting C: (first
  start) or repairing it (after power was cut during a save). Leave it running.

## More

- [docs/BUILDING.md](docs/BUILDING.md): building the core and running its tests.
- [docs/UPP_WD2.md](docs/UPP_WD2.md) describes the hardware as reconstructed,
  [docs/CPU.md](docs/CPU.md) the processor and
  [docs/NOS_STANDIN.md](docs/NOS_STANDIN.md) the stand-in for the phone's
  cellular firmware. [docs/PROGRESS-LOG.md](docs/PROGRESS-LOG.md) is the
  development record.
- [docs/RETROTINK4K.md](docs/RETROTINK4K.md) is a RetroTINK 4K profile shaped
  like the QD's screen.

This project's own files are GPL-2.0-or-later ([LICENSE](LICENSE)). The CPU's
caches, MMU and writeback come from the ZAP core ([rtl/cpu/zap](rtl/cpu/zap),
GPL-3.0-or-later), so the core as a whole is distributed under the GPL
version 3.
