# First-boot format and boot indicators — 2026-10-23

Worktree: `NGage_MiSTer-cx-firstboot`, branch `codex/firstboot`, starting at
`8f267c241b22d82cad363fe6d32c69fbe97a0d3f`. Local commits only; no push.
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

## Verification

Run locally with Homebrew Verilator 5.052, one simulation at a time:

| Check | Result |
| --- | --- |
| `make -C sim flash` | PASS, both 16 MB and 8 MB chips; new blank main/boot-sector erase, FFFF program, first data program away from C:'s first word, next timed program, timed erase/suspend/resume, and unchanged command suite |
| `make -C sim ddrflash` | PASS; added isolated checks for image load, lower-CS1/CS0 exclusion, non-first-word writes, sticky clearing across erase/reset, and reloading a blank image |
| `make -C sim top` after change 1 | PASS, 119,463,677 clocks; video/rotation/crop, image loading, CPU smoke program, save mounting, memory-test messages, DDR3 and SDRAM protocol checks |
| `make lint` after change 1 | PASS, all configured module tops |
| Changed QEMU C sources | PASS, `-fsyntax-only` against the existing QEMU build headers, using this worktree's header in a temporary include directory; no other worktree modified |

The fresh worktree lacked ignored `build_id.v`; copied the generated
`lint/gen/build_id.v` there before running `top`. No servers or containers
were started. QEMU firmware execution, access-for-access boot comparison,
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
   roughly a minute on the current cache builds, rather than minutes at the
   Nokia logo. This is an expectation, not a measured result. The older
   recorded build was about 170 seconds blank versus 105 seconds saved;
   compare against a warm boot of this exact RBF, not a different CPU build.
4. Accept Time and Date with Enter, wait for save writeback (or use **Save
   C: now**), then relaunch the same mounted file. Confirm user data survives
   and the second boot does not format C:. Restore a fresh disposable copy
   before repeating the first-boot timing trial.

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
