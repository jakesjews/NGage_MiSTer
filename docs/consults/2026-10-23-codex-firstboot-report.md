# First-boot format and boot indicators — 2026-10-23

Worktree: `NGage_MiSTer-cx-firstboot`, branch `codex/firstboot`, starting at
`8f267c241b22d82cad363fe6d32c69fbe97a0d3f`. Change 1 commit: `a3f053e`.
Change 2 is the subsequent boot-indicator commit.
Local commits only; no push.
Neither `sys/` nor `rtl/cpu/` is modified. No firmware boot bench is run.

## Change 1: blank C: fast path

- `nor_flash` receives `c_blank` on CS1 only. Sector erases in its upper
  4 MB return immediately without array writes, an erase window, toggle
  status, or suspend/resume state: the region is already erased. CS0,
  lower CS1, and chip erase retain their existing behavior.
- A word program started in blank C: has no emulated program delay. Its
  bus write waits for the memory transaction to finish; the first following
  read sees the programmed data. The operation stays fast even when its
  write clears blankness. Subsequent commands use the original timers,
  toggle bits, program failure, and erase suspend/resume logic.
- The old `c_blank` checked just the first 32-bit word, and could re-arm on
  erase. `ddram_flash` now scans enabled bytes throughout loaded C: and
  latches false on any non-FFFF chip write there. Erases and reset never
  re-arm it. Loading a new CS1 image from offset zero re-arms the scan;
  both the ioctl loader and save loader write sequentially with CPU held.
  Writing FFFF to an erased word leaves it blank.
- QEMU uses the same sticky blankness for sector erases and the HLE CBLANK
  register, including loaded saves and ROM patch notifications. Its word
  programs were already synchronous; that existing behavior is preserved.
  The model's existing 20 ms erase delay and RTL's 0.7 s delay remain in
  use after blankness clears. This change does not make their pre-existing
  timing models cycle-identical.

## Change 2: boot messages and activity dot

- Info IDs 1–6 are unchanged. ID 7 is `Booting the phone - about a minute...`
  (a comma separates entries in `I,`, so the sentence uses a hyphen). ID 8
  is `Phone kernel is up`. Start is CPU reset release after images/RTC are
  ready; the second message is the first `lcd_frame_ev` while `upp_lcd_on`.
  The fallback test generator cannot trip it. Reset re-arms both messages.
- Pending event bits serialize the existing test/save notifications and
  the new boot notifications, with a low cycle between `info_req` pulses.
- The new option is appended after the existing menu controls:
  `O[17:16],Activity dot,Boot only,Always,Off`. Zero is Boot only; value 1
  is Always, values 2/3 are Off. All earlier strings and bit positions,
  including aspect ratio at 122:121, are unchanged. The lint unused-bit
  waiver is narrowed to match the two newly consumed bits.
- A 6×6 green square at panel x=164–169, y=4–9 shows a CPU bus beat in the
  last 13,000,000 clocks (125 ms at 104 MHz). Boot only hides it on the
  first firmware frame; Always retains it after that. CPU reset clears
  the timer and suppresses the dot during memory self-test. Quiet traffic
  lets the underlying picture show through. The debug rows, mux and event
  counters are unchanged; the square never overlaps x=16–47, y=0–126.
- README adds one line documenting the option. The first-boot duration in
  its setup instructions remains the previous measured figure until a
  physical boot validates the new estimate.

## Verification

Run locally with Homebrew Verilator 5.052, one simulation at a time:

| Check | Result |
| --- | --- |
| `make -C sim flash` | PASS, both 16 MB and 8 MB chips; new blank main/boot-sector erase, FFFF program, first data program away from C:'s first word, next timed program, timed erase/suspend/resume, and unchanged command suite |
| `make -C sim ddrflash` | PASS; added isolated checks for image load, lower-CS1/CS0 exclusion, non-first-word writes, sticky clearing across erase/reset, and reloading a blank image |
| `make -C sim top` after change 1 | PASS, 119,463,677 clocks; video/rotation/crop, image loading, CPU smoke program, save mounting, memory-test messages, DDR3 and SDRAM protocol checks |
| `make lint` after change 1 | PASS, all configured module tops |
| `make -C sim top` after change 2 | PASS, 159,279,244 clocks; existing integration checks plus real LCD-interface start, one-shot/re-armed messages, fallback-frame exclusion, Boot only/Always/Off pixels, debug-row isolation, and the full 13,000,000-clock activity decay in a cached CPU loop |
| `make lint` after change 2 | PASS, all configured module tops |
| Configuration/debug compatibility | PASS; all pre-existing OSD option strings and info IDs preserved; counter and row-rendering source byte-for-byte unchanged |
| Changed QEMU C sources | PASS, `-fsyntax-only` against the existing QEMU build headers, using this worktree's header in a temporary include directory; no other worktree modified |

The fresh worktree lacked ignored `build_id.v`; copied the generated
`lint/gen/build_id.v` there before running `top`. No servers or containers
were started. Logs are retained locally in `sim/build/firstboot-validation/`.
QEMU firmware execution, access-for-access boot comparison,
Quartus fitting/timing, and physical hardware validation are not performed.

## Board procedure and expected timing

1. Build this branch's RBF with the normal project flow. Preserve the
   existing working RBF and `rh29-460-cs1-save.bin`.
2. Use a disposable copy of `rh29-460-cs1-blank.bin` (8 MB; C: offsets
   `0x400000`–`0x7FFFFF` all FF). Adapt the **NGageTrc-blank** launcher
   pattern: select the new RBF, load the existing patched CS0 via F1/index 1,
   mount the disposable blank CS1 on **S1**, and keep the usual MMC on S0.
   The checked-in progress log describes the trace build and pristine-CS1
   trial on 2026-10-22, but does not contain the literal launcher file.
   README documents the F1/S1/S0 layout. Do not mount the pristine source
   image itself if it must remain blank: S1 writes saves back to that file.
3. Time from CPU start (after image/save loading) and also record wall time
   from selecting the launcher. The blank erase phase should take seconds
   rather than adding roughly 50 seconds (71 sectors × 0.7 seconds).
   The intended Time/Date arrival is near the same build's warm-boot time,
   roughly 60–75 seconds of CPU boot on the current cache builds, rather
   than minutes at the Nokia logo. This is an expectation, not a measured result. The older
   recorded build was about 170 seconds blank versus 105 seconds saved;
   the two-way-cache measurement was 66 seconds of bus activity / about 96
   seconds after launcher load. Compare against a warm boot of this exact
   RBF, not a different CPU build.
4. Accept Time and Date with Enter, wait for save writeback (or use **Save
   C: now**), then relaunch the same mounted file. Confirm user data survives
   and the second boot does not format C:. Restore a fresh disposable copy
   before repeating the first-boot timing trial.
5. Check the boot-start message after image loading, and one kernel-up
   message on the first firmware LCD frame. In **Boot only**, the dot must
   stop being overlaid then; in **Always**, it must follow later bus traffic;
   in **Off**, it must never alter pixels. Enable Debug overlay and confirm
   its rows remain readable by `tools/mister_dbg.py`. Reset and repeat to
   verify the two messages re-arm.

## Risks and limits

- `medint.pdd` has status-sensitive loops. The chip bench proves the new
  status contract, not firmware compatibility: immediate completion must
  be checked by the boot-bench owner and on the board. In particular,
  confirm that the initial format accepts an immediately erased sector.
- The fast window ends on the first non-erased C: write as requested.
  Erases interleaved after that write remain timed; the policy alone cannot
  guarantee that the entire format finishes in seconds.
- Loading a partial CS1 image starting at zero is not a supported proof of
  blankness: use the full 8 MB image. Resetting an interrupted format keeps
  the conservative nonblank state; retry with a fresh image when needed.
- No timing-closure or board-speed claim is made from these simulations.
- The first firmware LCD frame is only a boot milestone, not proof that
  Symbian reached its idle screen or that user applications are ready.
  Boot only can disappear earlier than idle, as requested.
- The dot is in panel coordinates, so it rotates with the picture and
  vertical crop can hide this corner. No debug row is moved to make room.

## Hang found on the board and fixed

This follow-up starts at merged `e6813955`. It supersedes the immediate-done
status contract and the unverified firmware-compatibility statements above.
The board capture supplied for this fix stayed at `0x5037feb8/0x5037fec0`
from 28 seconds through 240 seconds: 20.00 M instructions/s, CPI 5.2,
23.1% flash wait, and 3,999,316 bus beats/s. No new board run is claimed here.

### Driver analysis and the minimum handshake

`research/firmware/analysis/medint.pdd.arm.txt` contains two copies of the
Samsung command routines. In the erase-start loop at `0x5037feac` (second
copy `0x50380d50`), `ldrh` reads the sector, `tst #0x80; bne` waits **until
busy**, and `tst #8` checks DQ3 from that **same sample**. Immediate FFFF
therefore spins forever. Completion at `0x5037ff68` / `0x50380df8` reads
twice: either FFFF means done; otherwise DQ7 means suspended, DQ5 means
failure with a final reread, and neither means still busy.

The program commands at `0x50380360/0x50380434` and
`0x503811b0/0x50381284` use a timer FIQ to poll. The `tst #8` at
`0x503803c8/0x50381218` tests interrupt-controller status, **not flash DQ3**.
The source halfword comes from RAM; `ldrsb` at `0x503803f4/0x50381244`
reads the flash destination. XOR with the expected data shifted left 24
makes the sign flag compare DQ7. On mismatch, `tst #0x20` at
`0x50380454/0x503812a4` tests the flash DQ5 bit: zero retries at the next
FIQ; one rereads the byte and then compares a halfword before failing.
Masking bit 5 of the expected data keeps it out of that status test.
The separate Intel-command routines use a different protocol and are not
entered by these Samsung A0/30 commands.

The minimum rule is **one busy status read per fast operation, then array
data**. No fixed microsecond delay is necessary. A time-only window could
expire before the driver polls and recreate the hang. The busy sample has
inverted DQ7, DQ5=0, and erase DQ3=1. DQ6 advances on each fast status read;
selected erase sectors also advance DQ2. Both implementations initialize
this separate fast toggle phase to zero, preserving the existing timed
path's toggle state.

- RTL keeps the operation busy and disables array-line bypass until that
  read. Other banks continue to read array data without consuming it.
  Blank erases perform no memory writes or suspend/resume transition.
  Programs hold the command ACK until the memory write lands, then retain
  their busy sample even if that write has just cleared `c_blank`.
- QEMU installs a matching one-read overlay over the operation's bank
  (sixteen banks). Byte reads select the proper byte lane; a 32-bit read
  consumes the busy halfword and returns array data for the next halfword,
  matching two accesses to the x16 chip. No fast erase timer is scheduled.
- The first non-FF C: program still closes the shortcut. Later RTL
  programs and erases use the original timers, failures, and suspend/resume;
  QEMU retains its original synchronous programs and 20 ms timed erases.
  Existing model-versus-RTL timing differences are not changed by this fix.

### Follow-up verification

The QEMU source was cloned and built in this worktree with `model/build.sh`
(pinned QEMU v11.1.2). Configure first selected Apple's Python 3.9, which
lacked `tomli`; rerunning with `PYTHON=/opt/homebrew/bin/python3` succeeded.
The modified flash source was copied into that local QEMU tree and rebuilt
with Ninja. Firmware images and disassembly were copied into ignored local
`research/firmware/` paths from the adjacent checkout; nothing there was
modified. CS1 is 8 MB with its entire upper 4 MB verified FF.

The flash bench now replays the actual driver branches above, including
main and boot sectors, delayed first polls, reads in other banks, FFFF
programs, both data DQ7 polarities and bit-5 values, the first non-FF write,
and the same polling after cutoff. It checks that the timed erase window,
program delay, DQ6 toggling and erase suspend/resume remain in effect.

| Check | Result |
| --- | --- |
| `make -C sim flash` | PASS, both chips, including the new driver replays and unchanged command suite |
| `make -C sim top` | PASS, 159,279,244 clocks, CPU smoke program, memory/save paths, video, boot messages and activity options |
| `make lint` | PASS, all configured module tops |
| Local QEMU qtest flash accesses | PASS, exact fast status samples, byte lanes, split 32-bit reads, other-bank exclusion, same-bank status, first-write cutoff and normal timed erase suspend/resume |
| Fresh model, requested 150-second run | PASS, reaches Time; kernel log continues through startup services, no kernel panic |
| Time/Date acceptance and saved-C: reboot | PASS, both dialogs accepted, save written, reboot reaches idle at 19 guest seconds with zero erase commands |

RTL logs are in `sim/build/firstboot-hang-validation/`. The direct model
check and its wire log are retained locally as `model/.out/check-fast-flash.py`
and `model/.out/flash-qtest.log`. No RTL firmware boot bench, Quartus fit,
or hardware run was performed.

### Guest timing and persistence

The timed comparison binary was built from the pre-fix flash source with
only its blank-sector early return removed in the **ignored QEMU source
copy**. This restores the previous 20 ms erase timer without changing the
tracked source or another worktree. Both runs use the same images, patches,
`shift=4,sleep=off`, fixed RTC input, format-key script, and one screenshot
per guest second. The requested fixed run was:

```sh
NGAGE_SAVE1=none NGAGE_KEYS=model/keys/format-c.txt \
  NGAGE_SHOT=1 NGAGE_RTC=2004-06-01T12:00:00 model/run.sh -t 150
```

Its logs and screenshots are in `model/.out/`; the timed baseline is in
`model/.out/timed-baseline/`. Screenshot index 0034 is guest second 35,
since the first shot (index 0000) is taken at second 1.

| Observation | Timed model, 20 ms erases | Fixed blank fast path |
| --- | --- | --- |
| First erase command | 8.429255 s | 8.429255 s |
| Last erase command | 16.451778 s | 16.451778 s |
| Last timed erase completion | 16.471778 s | No erase timer |
| First non-FF C: program | Not separately logged | 16.501870 s; closes fast eligibility |
| Time dialog first visible | 35 s (absent at 34 s) | 35 s (absent at 34 s) |
| Date dialog, after OK at 40 s | 41 s (absent at 40 s) | 41 s (absent at 40 s) |
| Erase commands in this scripted run | 142 timed | 142 fast, zero timed |

The supplied format-key script produces **two passes of 71 sectors**:
8.429255–12.662297 s and 12.928784–16.451778 s. The first pass precedes
`auxstart 105` at 12.817990 s in `kern.log`, which requests another format.
All 142 erases remain inside the blank window; the first program is later.
Thus the erase-command phase takes about **8.02 guest seconds** with the
fix. This test does not show a dialog-time speedup over the already-short
20 ms model timer: firmware polling/scheduling hides that delay. It proves
that removing the timers no longer hangs. The board's 0.7 s sector timings
are substantially longer; the board speedup must be measured separately.

Evidence: [timed Time at 35 s](2026-10-23-firstboot/timed-time-35s.png),
[fixed Time at 35 s](2026-10-23-firstboot/fixed-time-35s.png),
[timed Date at 41 s](2026-10-23-firstboot/timed-date-41s.png),
[fixed Date at 41 s](2026-10-23-firstboot/fixed-date-41s.png).

The Time/Date acceptance runs append `lsk` down/up at 40/40.2 s and
45/45.2 s to `format-c.txt` (local `model/.out/format-and-accept.txt`).
The timed run uses `NGAGE_OUT=model/.out/timed-accepted`; the fixed run
uses `NGAGE_OUT=model/.out/fixed-saved` and
`NGAGE_SAVE1=model/.out/firstboot-save.bin`. The latter ran for 60 wall
seconds, accepted both dialogs, reached idle, and saved an 8,388,608-byte
CS1 containing 869,653 non-FF bytes in C: at exit.

The saved-C: reboot uses:

```sh
NGAGE_OUT=model/.out/warm-saved NGAGE_SAVE1=model/.out/firstboot-save.bin \
  NGAGE_KEYS= NGAGE_SHOT=1 NGAGE_RTC=2004-06-01T12:00:00 model/run.sh -t 60
```

QEMU explicitly reports starting CS1 from that save. The firmware reaches
[idle at guest second 19](2026-10-23-firstboot/saved-idle-19s.png)
(splash still visible at second 18), without the Time or Date dialogs.
The complete 60-wall-second warm run logs **zero fast erases, zero timed
erases and zero fast programs**, and exits normally on the requested
SIGINT timeout, writing its updated save.

### Board handoff and remaining limits

Use the blank-image/NGageTrc-blank launcher procedure above with a new
build containing this fix, and a disposable fresh
`rh29-460-cs1-blank.bin`. The observed `0x5037feb8/0x5037fec0` spin should
now end on its first status poll; keep capturing until Time and Date,
accept both, save C:, and confirm a subsequent launch skips formatting.
Time from CPU start and compare with a saved boot of this same RBF. The
35-second model result is guest time, not a board wall-time prediction.
Removing the board's 0.7-second delay from each blank erase should remove
the long erase contribution; firmware scheduling and programs after the
first non-FF write remain. The earlier 60–75-second board expectation
still needs the separate hardware run.

This policy deliberately retains busy until a bank status read consumes
it; a reset clears it. Software that issues another command without ever
polling is outside the verified medint.pdd sequence. Full firmware
access-for-access comparison on the RTL and the current CPU/cache changes
remains with the other engineer. No files under `sys/` or `rtl/cpu/` were
changed, and nothing was pushed. All local model/test processes are stopped
when validation finishes; the built QEMU and logs remain for reproduction.
