# Changing games without rebooting the phone

Hardware-tested on 2026-10-27 using the stripped 104 MHz RF seed-13
build. The MiSTer was upstairs, with no JTAG connection. Direct Video was
temporarily disabled for captures. No RTL or MiSTer framework changes were
needed.

## Observed behavior

The initial Tony Hawk launcher booted the phone once; its idle screen was
visible by 50 seconds. The two subsequent changes used the existing OSD
**Mount MMC card** entry, without loading another MGL/RBF or selecting reset:

- **Tony Hawk card to Sonic N:** the replacement was recognized, Sonic's
  SEGA logo was visible about 11 seconds after confirming the mount, and
  Sonic appeared in the phone's application menu. Neo Green Hill gameplay,
  movement and jumping were verified. The game was exited through its own
  menu before the next swap.
- **Sonic N to Asphalt:** the phone displayed a card-inserted notification
  and replaced Sonic's application icon with Asphalt. Launching that entry
  reached the game's menu by the 30-second capture. A Cop
  Chase race was then reached without another phone boot.

Linux's open file descriptors independently confirmed that Main switched
from the Tony Hawk image to `sonicn.mmc`, then `asphalt-urban-gt.mmc`, while
retaining the same `rh29-460-cs1-save.bin`. The action log contains just one
initial `load` before both swaps. These are functional checks, not new FPS
measurements or timing sign-off.

Evidence: `build/timing-closure/hardware/mmc-hot-swap/`, including
timestamped actions, screenshots, mounted-file checks and `result.json`.
The RBF SHA-256 is
`4896f23ba76ce20a81746565af345d4a189dd263f0bd2c7001b588d375e15d7d`.

## Test procedure and remaining limit

For successive games on one loaded build, exit the current game, select
**Mount MMC card** in the MiSTer OSD and choose the next `.mmc` image.
Return to the phone menu and open the new game's icon if it does not start
automatically. Do not change **Mount C: save** or load a game-specific MGL
for this operation: loading the MGL reloads the FPGA and firmware.

The first direct swap produced the phone's warning about removing a card
without first selecting **Remove mem. card**. Nokia's local QD user guide
(`research/symbian/downloads/user-guides/Nokia_N_Gage_QD_UG_en.pdf`, page 14)
places that command in the power-key menu. F8 presses of 80, 180 and 600 ms
did not open that menu in this run, so the clean-eject sequence is **not
verified**. The inspected sidecars advertise Sonic as permanently
write-protected, but Tony Hawk and Asphalt support writes and are not
permanently write-protected. Do not assume every game image is read-only,
claim safe removal of a writable card, or automate swaps during gameplay
or writes based on this test.

The unused `mmc_card.present` output initially looked like a blocker, but
the live tests show that this firmware recognizes these replacements
without it. The precise detection path was not traced. An image mount
resets the emulated card state; it is absent from the CPU reset expression.

Use warm card changes to avoid repeated phone startup during functional
game tests. A different FPGA build still requires a boot. Retain explicit
cold-boot coverage and a consistent startup/scene procedure for performance
comparisons; these warm runs do not establish performance equivalence to
the previous cold runs.

After the test, the original MiSTer.ini and NGage.CFG were restored and
checksum-verified. The original stripped seed-13 Tony Hawk launcher was
reloaded to restore Direct Video, and the phone idle screen was visible
at the 50-second capture. That final reload was for restoring the capture
configuration, not between the two game swaps. The temporary input
helpers and Zaparoo service were stopped. Asphalt's test run was not
explicitly saved before restoration.
