# RetroTINK 4K profile for direct video

The core can send its picture to a RetroTINK 4K as direct video: the MiSTer
puts the core's own timing on HDMI instead of its scaler's, and the RetroTINK
does the scaling. `tools/retrotink4k/NGage.rt4` is a ready profile that shows
the picture the way the N-Gage QD's own screen did: integer scaling with
square pixels, gen lock to the core's frame rate, the picture cropped by the
direct-video metadata. Copy it to the RetroTINK's SD card as
`profile/DV1/NGage.rt4` and it loads by itself when the core starts (the
profile has Auto Load DV1 on). The settings below are the same profile set
by hand, for a RetroTINK that already has a profile of your own to keep.

## What the RetroTINK receives

- A 240p-style frame: 262 lines at 60.07 Hz, 15.74 kHz, 413 pixels a line at
  a 6.5 MHz pixel clock.
- The N-Gage picture is 176x208 pixels, square pixels, centred in that frame
  with black around it. With the core's Rotate option it is turned a quarter
  turn and becomes 208x176 for a landscape TV.
- RGB, full range, 8 bits a component (the panel's 16-bit colour widened).

The QD's screen was 176x208 pixels on a 2.1-inch panel, about 35 by 41 mm,
held upright: a portrait picture with square pixels and a faint pixel grid.

## MiSTer side

1. In `MiSTer.ini`, in the `[NGage]` section, set `direct_video=1`. (The
   board here has a `[NGage]` section that overrides the global setting
   to 0; change that one.)
2. In the core's OSD leave Rotate off for an upright picture, or set it for
   a landscape TV. Aspect ratio, Vertical Crop, Crop Offset and Scale are
   scaler options and do nothing in direct video.
3. Connect the MiSTer's HDMI to the RetroTINK's HDMI input.

## RetroTINK side

Set these, then save the profile. Menu names are the RetroTINK 4K's as of
its 2025 firmware; if one has moved, the setting is the thing to find.

1. Input: HDMI. The RetroTINK detects the MiSTer direct-video signal as a
   240p source; leave the sync and timing detection on Auto.
2. HDMI Output: 4K60, RGB Range Full, Sync Lock "Gen" so the output
   follows the core's 60.07 Hz instead of resampling it.
3. Cropping: HDMI Receiver Setup, Auto-Crop on. MiSTer direct video carries
   the picture's position, size and pixel rate in its metadata, so the
   RetroTINK crops to the 176x208 picture (208x176 with the core's Rotate)
   and samples it one sample a pixel without trims.
4. Scaling/Crop Setup: Scaling Mode "Auto Fill Int HV" (integer on both
   axes), Aspect Correction "1:1 (Sq. Pixel)", Aspect Ratio 1:1. That
   gives 10x: 1760x2080 for the upright picture, a portrait image with
   black at the sides, which is the QD's own shape; or 12x: 2496x2112 for
   the rotated picture.
5. Processing: Sharpness neutral (no ringing; the pixels are already
   10 times their size). Masks: the LCD or dot-grid mask at a low strength,
   around 20 %, for the panel's pixel grid; off for a clean picture.
   Scanlines off.
6. Save: Profiles, Save Profile. For automatic loading put the file at
   `profile/DV1/NGage.rt4` with Auto Load DV1 on, as the provided file is;
   for an SVS switch name it `profile/SVS/S<number>_NGage.rt4` instead.

## Why these numbers

- 10x is the largest integer scale of 208 lines that fits 2160; 12x the
  largest of 176. Integer scaling keeps every pixel the same size, which is
  what the QD's panel showed.
- 1:1 pixel aspect because the panel's pixels were square: 176x208 pixels
  on 35x41 mm.
- Frame Lock because the core's frame is 60.07 Hz, not 60.00; without it
  a frame is dropped or repeated about every 14 seconds.

## How the file was made

From the "Dead Stock" MiSTer direct-video profile set (TheJesusFish's
Retrotink-DV1-Profile-Repository, the Atari Lynx profile: no scanlines, no
mask, Auto-Crop and Auto Load DV1 on), with cajunpanda's `rtink` tool:
Scaling Mode "Auto Fill Int HV" and Aspect Correction "1:1 (Sq. Pixel)" and
Aspect Ratio 1:1 for every input mode, Sync Lock Gen, Input Source HDMI;
nothing else changed. The tool recomputes the profile's checksum. Made on
the firmware 1.92 settings map; profiles from 1.92 to 1.99 share the layout.
