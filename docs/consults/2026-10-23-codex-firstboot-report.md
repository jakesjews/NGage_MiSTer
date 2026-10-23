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
