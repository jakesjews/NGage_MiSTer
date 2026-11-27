# N-Gage QD for MiSTer

The Nokia N-Gage QD as a MiSTer core. The phone's own firmware boots on a
reconstruction of its hardware, so N-Gage game cards run as they did on the
phone. Its cellular software runs as well, with a test SIM in the slot and
no radio behind it.

## What you need

- A MiSTer with an SDRAM module (32 MB or larger).
- The N-Gage QD firmware, version 4.10 (model RH-29), as it comes in Nokia's
  service packages for the phone: `N-GageQD RH-29.zip`. It is Nokia's and is
  not included. Searching the Internet Archive for "Nokia DCT4 firmwares"
  finds the collection that has it in its file list.
  - `N-GageQD RH-29.zip` (811,528,203 bytes): SHA-256
    `8cbfc6e54b9e59b4c8cb72712297629359db443af78505d9f7188eda8f38732b`
- Game cards as `.mmc` images (see [Game cards](#game-cards)).

## Setup

The `.rbf` in [releases/](releases/) and the published unpacker page are
still those of `NGage_20261120`, from before this setup: follow
[its README](https://github.com/jakesjews/NGage_MiSTer/blob/9210fa2/README.md)
for them. The steps here are for a core built from the current source, with
the unpacker page as it is in [web/](web/)
([docs/BUILDING.md](docs/BUILDING.md)).

1. Copy the `.rbf` to `/media/fat/_Console/`.
2. Create the folder `/media/fat/games/NGage/` and copy
   [boot0.vhd](releases/boot0.vhd) and [boot2.vhd](releases/boot2.vhd) into
   it. Together they are the phone's memory: its C: drive with your settings
   and game saves, and what the phone keeps about itself.
3. Drop the zip on the [firmware unpacker](https://ngage-mister.vercel.app/)
   and save `boot0.rom` and `boot1.rom` into the folder.
   - `boot0.rom` (16,777,216 bytes): SHA-256
     `8ae1f84ae5893a6e5d04649e684ae600b093efb432cd052458294d1db5c2ef2e`
   - `boot1.rom` (8,388,608 bytes): SHA-256
     `1058c15e99e363e42362282c4264db8e68776def8fdcc6e4e72ad9b0fcf4a8d1`
4. Copy your `.mmc` images into the folder.
5. Start **NGage** from the Console menu. The first start formats C:, which
   keeps the Nokia logo on screen for about two minutes, and then asks for
   the time and date: press Enter for each.
6. Open the OSD, choose **Mount MMC card** and pick a game.
7. If the game does not start by itself, press Menu (F5), move to its icon and
   press OK (Enter).

If you have the firmware as `RH2941.0C1` and one of its language packs
(`RH2941.021`, or another for 4.10), drop those two on the unpacker instead
of the zip. The checksums in step 3 are those of the files made with
`RH2941.021`; another language pack gives its own.

To have a card in the slot at every start, name a copy of its image
`boot1.vhd`. The game is then in the phone's menu from the start.

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
  Choose **Save C: and PMM now** in the OSD before switching off right after
  a save.
- The phone takes its date and time from the MiSTer at every start. What
  you enter at the first start lasts until the next one.
- `boot0.vhd` and `boot2.vhd` are one phone: keep them together. Replacing
  both with the files from releases/ starts a new phone. Replacing only one
  does not work: a new `boot2.vhd` erases the C: beside it at the next start,
  and a new `boot0.vhd` beside a used `boot2.vhd` is never formatted.
- Coming from `NGage_20261120` or an earlier release: replace every file in
  the folder but your cards. The firmware files of those releases are
  refused, and the new `boot2.vhd` erases an old `boot0.vhd`.
  [docs/BUILDING.md](docs/BUILDING.md#on-the-mister) has the way to keep
  an old C:.
- Five minutes after the last key press the phone shows its screen saver,
  over a game too: a bar with the date and time on a black screen. Any key
  brings the picture back.
- Sonic N comes back muted, with a crossed-out speaker at the top right, when
  the screen saver or the phone's menu takes over outside play. Press 0 (Y)
  a few times to step its volume back up.
- Leave a game before changing cards: exit to the phone's menu, then mount
  the next card.
- Bluetooth switches on and searches for devices, and never finds one: the
  core's Bluetooth module has no radio, so games cannot be played over it.
- **Aspect ratio** set to *Original* keeps the screen's own 176:208 shape,
  and **Rotate** turns the picture for a rotated display.
- The **Firmware** page of the OSD loads the same four files by hand.

## Troubleshooting

- Black screen: the phone starts only when `boot0.rom` and `boot1.rom` are in
  `games/NGage/` under exactly those names.
- **Firmware files not valid: see the README**: `boot0.rom` and `boot1.rom`
  are not the two files the unpacker makes (step 3 has their sizes). The
  firmware files of earlier releases get this message: make them again.
- The Nokia logo stays for more than five minutes on the first start:
  `boot2.vhd` is missing, or it is not the file from releases/. Start again
  from both files of step 2.
- The Nokia logo stays for a long time on a later start: the phone is
  repairing C: after power was cut during a save. Leave it running.
- **C: save file must be 4 or 8 MB**, **PMM save must be 64 KiB**: start
  again from the files of step 2.
- **C: read-only: no saves**, **PMM read-only**: the file is write-protected.

## More

- [docs/BUILDING.md](docs/BUILDING.md): building the core and running its tests.
- [docs/UPP_WD2.md](docs/UPP_WD2.md) describes the hardware as reconstructed,
  [docs/CPU.md](docs/CPU.md) the processor,
  [docs/BLUETOOTH.md](docs/BLUETOOTH.md) the Bluetooth module,
  [docs/FIRMWARE-PROFILES.md](docs/FIRMWARE-PROFILES.md) how the unmodified
  firmware was brought up and
  [docs/NOS_STANDIN.md](docs/NOS_STANDIN.md) the stand-in for the phone's
  cellular software that earlier releases ran.
  [docs/PROGRESS-LOG.md](docs/PROGRESS-LOG.md) is the development record.
- [docs/RETROTINK4K.md](docs/RETROTINK4K.md) is a RetroTINK 4K profile shaped
  like the QD's screen.

This project's own files are GPL-2.0-or-later ([LICENSE](LICENSE)), except
the CPU in [rtl/cpu](rtl/cpu), which is GPL-3.0-or-later
([rtl/cpu/LICENSE](rtl/cpu/LICENSE)): its caches, MMU, register file and
writeback are derived from the ZAP processor by Revanth Kamaraj
([rtl/cpu/NOTICE](rtl/cpu/NOTICE)). The core as a whole is therefore
distributed under the GPL version 3.
