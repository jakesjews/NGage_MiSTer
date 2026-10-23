# RetroTINK 4K profile for direct video

The core can send its picture to a RetroTINK 4K as direct video: the MiSTer
puts the core's own timing on HDMI instead of its scaler's, and the RetroTINK
does the scaling. This page is the recipe for a profile that shows the picture
the way the N-Gage QD's own screen did. A RetroTINK profile can only be saved
from the device, so the steps set it up on the RetroTINK and save it there.

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
2. Output: 4K (2160p) at 60 Hz, full range RGB. Turn Frame Lock on so the
   output follows the core's 60.07 Hz instead of resampling it.
3. Cropping: Auto Crop off. Crop to the picture: 176 pixels wide, 208 lines
   tall, centred (208 wide, 176 tall with the core's Rotate). The picture
   sits in the middle of the 413x262 frame, so a centred crop finds it;
   nudge the horizontal and vertical position until the black border is
   gone on all four sides and no picture is cut.
4. Scaling: Integer. Aspect ratio: 1:1 pixel aspect (square pixels). That
   gives 10x: 1760x2080 for the upright picture, a portrait image with
   black at the sides, which is the QD's own shape; or 12x: 2496x2112 for
   the rotated picture.
5. Processing: Sharpness neutral (no ringing; the pixels are already
   10 times their size). Masks: the LCD or dot-grid mask at a low strength,
   around 20 %, for the panel's pixel grid; off for a clean picture.
   Scanlines off.
6. Save: Profile, Save Profile, into an SVS slot, and name the file on the
   SD card `S<number>_NGage.rt4` under `/profile/SVS/`. If the MiSTer's
   RetroTINK profile-switching script is installed, add the core name
   `NGage` with that number to its core list so the profile loads with the
   core.

## Why these numbers

- 10x is the largest integer scale of 208 lines that fits 2160; 12x the
  largest of 176. Integer scaling keeps every pixel the same size, which is
  what the QD's panel showed.
- 1:1 pixel aspect because the panel's pixels were square: 176x208 pixels
  on 35x41 mm.
- Frame Lock because the core's frame is 60.07 Hz, not 60.00; without it
  a frame is dropped or repeated about every 14 seconds.
