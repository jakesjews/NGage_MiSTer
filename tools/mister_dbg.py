#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Decode the core's debug overlay from a MiSTer screenshot.

With the OSD option "Debug overlay" on, NGage.sv draws the CPU's committed
PC (32 bits, bit 31 leftmost) in panel rows 0-2 at x 16..47 and eight status
bits in rows 4-6 at x 16..23: cpu_reset, irq, fiq, bus activity, CS0 loaded,
CS1 loaded, CS1 save present, memory-test master (0 in cores from 2026-11-10 on). White = 1. Rows 8, 12, 16,
20, 24, 28, 32 and 36 (3 lines each, x 16..47) hold 32-bit words: interrupt
sources of bank 0, the IRQ-plane and FIQ-plane enables of bank 0, the three
words the kernel writes to on-chip RAM 0x0C0047F0/F4/F8 on Kern::Fault
(category text, then the reason), the hardware trace's first trigger PC
(rtl/mister/dbg_trace.sv), {dumps[7:0], triggers[7:0], kernel-text
bytes[15:0]} (rtl/mister/dbg_sti.sv), then the wall clock {valid, 10'b0,
hour[4:0], 2'b0, min[5:0], 2'b0, sec[5:0]} (rows 40-42), its date
year << 16 | month << 8 | day (rows 44-46), the audio peaks of the last
frame {left[15:0], right[15:0]} (rows 48-50), {kernel-text writes
dropped[7:0], 7'b0, dumping, 16'b0} (rows 52-54), then the 33 per-second
counters of rtl/mister/dbg_counters.sv (rows 56-186; NGage.sv names them).
Appended word 45 (rows 188-190) holds loader ready[31], busy[30], have[29:28]
(bit 0 MCU, bit 1 language), last ioctl index[27:22], last note[21:19], parser
state[18:14]. Word 46 (rows 192-194) holds F1..F4 start counts[31:16] as four
saturating 4-bit counters and the full current-file error count[15:0]. These
words keep updating during CPU reset; sys_reset (RESET/PLL unlock) clears history.

A second column at x 56..87 (the same rows from 8 on; cores from 2026-11-10)
starts with a marker ("NGE2", "NGE3" or "NGE4") and holds the exception counters of NGage.sv
(dbg_ev2): per second, the SWI, IRQ, FIQ, data-abort, prefetch-abort and
undefined exceptions taken; the clocks in User mode; the privileged clocks
after each of those six (charged to the exception that last took the CPU out
of User mode); the instructions retired in User mode; the aborts/undefined,
SWIs and interrupts taken in a privileged mode; the kernel calls of 4,096
clocks or more and of 65,536 or more; with the marker "NGE3" also the
clocks in Supervisor, Undefined and IRQ mode and the RH-29 v4.60 kernel's
process switches with their I-cache, I-TLB and D-TLB invalidations and
D-cache clean loops; with "NGE4" also the display: the clocks of picture
uploads (a RAMWR from the top line to its last pixel) in all, in Undefined
mode and in User mode, the video frames that were torn (a pixel written on
the line being scanned out) and fresh (an upload ended since the frame
before), the uploads ended, and the fresh frames sorted by the video frames
since the fresh one before (1, 2, 3, 4, 5 or 6, 7 and more).
Then the PC of one SWI in 64, of the last data abort,
prefetch abort and undefined instruction (address + 8, + 4 in Thumb) and
the low CPSR byte before each. A capture without a marker is decoded
without this part.

usage: tools/mister_dbg.py SHOT.png [SHOT.png ...]
The screenshot must be the whole 176x208 picture at an integer scale
(direct_video=0 for the core); the scale is taken from the image width.
"""
import sys

from PIL import Image

NAMES = ["cpu_reset", "irq", "fiq", "bus", "cs0", "cs1", "save", "memtest"]


def bit(im, scale, x, y):
    r, g, b = im.getpixel((x * scale + scale // 2, y * scale + scale // 2))[:3]
    return 1 if r + g + b > 384 else 0


def decode(path):
    im = Image.open(path).convert("RGB")
    scale = im.width // 176
    if scale < 1 or im.width != 176 * scale or im.height != 208 * scale:
        return "%s: not a 176x208 integer-scaled capture (%dx%d)" % (path, im.width, im.height)
    pc = 0
    for i in range(32):
        pc = (pc << 1) | bit(im, scale, 16 + i, 1)
    bits = [bit(im, scale, 16 + i, 5) for i in range(8)]
    flags = " ".join("%s=%d" % (n, v) for n, v in zip(NAMES, bits))
    words = []
    for row in range(9, 9 + 4 * 47, 4):     # 12 fixed words, 33 counters, 2 loader words
        w = 0
        for i in range(32):
            w = (w << 1) | bit(im, scale, 16 + i, row)
        words.append(w)
    cat = (words[3].to_bytes(4, "little") + words[4].to_bytes(4, "little")).rstrip(b"\0")
    cat = cat.decode("latin-1") if cat and all(32 <= c < 127 for c in cat) else ""
    w8, w9, w10, w11 = words[8], words[9], words[10], words[11]
    return "%s: pc=%08x %s src0=%08x en_irq0=%08x en_fiq0=%08x fault=%08x %08x %08x %r trace: pc=%08x dumps=%d triggers=%d text: %d bytes, %d dropped rtc: valid=%d %02d:%02d:%02d %04d-%02d-%02d audio: %d %d" % (
        path, pc, flags, words[0], words[1], words[2], words[3], words[4], words[5], cat,
        words[6], words[7] >> 24, (words[7] >> 16) & 0xFF, words[7] & 0xFFFF, w11 >> 24,
        w8 >> 31, (w8 >> 16) & 0x1F, (w8 >> 8) & 0x3F, w8 & 0x3F, w9 >> 16, (w9 >> 8) & 0xFF, w9 & 0xFF,
        w10 >> 16, w10 & 0xFFFF) + counters(words[12:45]) + loader(words[45:47]) + exceptions(im, scale)


COL2_MARKS = {0x4E474532: 19, 0x4E474533: 27, 0x4E474534: 39}      # "NGE2", "NGE3", "NGE4": the number of counters
MODES = {0x10: "usr", 0x11: "fiq", 0x12: "irq", 0x13: "svc", 0x17: "abt", 0x1B: "und", 0x1F: "sys"}


def column2(im, scale):
    """The second column's counters and its five sampled words, or None when
    the capture has no marker."""
    def word(row):
        w = 0
        for i in range(32):
            w = (w << 1) | bit(im, scale, 56 + i, row)
        return w
    n = COL2_MARKS.get(word(9))
    if n is None:
        return None
    words = [word(row) for row in range(13, 13 + 4 * (n + 5), 4)]
    return words[:n], words[n:]


def exceptions(im, scale):
    col = column2(im, scale)
    if col is None:
        return ""
    w, sampled = col
    swi, irq, fiq, dabt, pabt, und, user = w[:7]
    p_swi, p_irq, p_fiq, p_dabt, p_pabt, p_und = w[7:13]
    u_instr, k_abt, k_swi, k_int, long1, long2 = w[13:19]
    swi_pc, dabt_pc, pabt_pc, und_pc, cpsr = sampled
    clk = 104_000_000
    pct = lambda n: 100.0 * n / clk
    other = clk - user - p_swi - p_irq - p_fiq - p_dabt - p_pabt - p_und
    mode = lambda b: "%s%s" % (MODES.get(b & 0x1F, "%02x" % (b & 0x1F)), "/T" if b & 0x20 else "")
    more = ""
    if len(w) >= 27:
        more = (" | mode clocks: svc %.2f%% und %.2f%% irq %.2f%% | kernel process switches %d/s: I-cache invalidations %d,"
                " I-TLB %d, D-TLB %d, D-cache clean loops %d" % (pct(w[19]), pct(w[20]), pct(w[21]), w[22], w[23], w[24], w[25], w[26]))
    if len(w) >= 39:
        up, up_und, up_user, torn, fresh, ended = w[27:33]
        more += (" | display: %d uploads ended, %.2f ms each (undefined mode %.0f%%, user %.0f%%), %d fresh and %d torn video frames,"
                 " fresh frames by video frames since the last 1:%d 2:%d 3:%d 4:%d 5-6:%d 7+:%d" % (
                     ended, 1000.0 * up / clk / max(ended, 1), 100.0 * up_und / max(up, 1), 100.0 * up_user / max(up, 1),
                     fresh, torn, w[33], w[34], w[35], w[36], w[37], w[38]))
    return (" | exceptions per s: swi %d irq %d fiq %d dabt %d pabt %d und %d"
            " | clocks: user %.2f%% after-swi %.2f%% after-irq %.2f%% after-fiq %.2f%% after-dabt %.2f%% after-pabt %.2f%% after-und %.2f%% other %.2f%%"
            " | user %.2f M instr | in privileged modes: %d abort/und %d swi %d irq/fiq | kernel calls >=4096 clk: %d, >=65536 clk: %d"
            " | swi sample pc=%08x (%s) last dabt pc=%08x (%s) pabt pc=%08x (%s) und pc=%08x (%s)" % (
                swi, irq, fiq, dabt, pabt, und,
                pct(user), pct(p_swi), pct(p_irq), pct(p_fiq), pct(p_dabt), pct(p_pabt), pct(p_und), pct(other),
                u_instr / 1e6, k_abt, k_swi, k_int, long1, long2,
                swi_pc, mode(cpsr), dabt_pc, mode(cpsr >> 8), pabt_pc, mode(cpsr >> 16), und_pc, mode(cpsr >> 24)) + more)


def loader(w):
    state, history = w
    counts = [(history >> shift) & 15 for shift in (28, 24, 20, 16)]
    starts = "/".join("15+" if n == 15 else str(n) for n in counts)
    notes = {0: "none", 1: "damaged", 2: "unrecognised", 3: "loaded", 4: "reload-both"}
    note = (state >> 19) & 7
    return (
        " | loader: ready=%d busy=%d have=%s last=F%d starts[F1/F2/F3/F4]=%s note=%d(%s) errors=%d state=%d" % (
            state >> 31, (state >> 30) & 1, format((state >> 28) & 3, "02b"),
            (state >> 22) & 63, starts, note, notes.get(note, "unknown"), history & 65535, (state >> 14) & 31))


def counters(w):
    # per second: frames, pixels, instructions retired, wait-for-interrupt
    # clocks, bus wait clocks on the SDRAM / the flash / elsewhere, bus beats;
    # then the CPU's stall taps (clocks): the data side's bus wait, the
    # combined FIFO-full OR fetch-wait, no instruction out of the fetch FIFO, the issue, shifter and
    # decode stalls; the ALU's and writeback's flush counts; uops and replays.
    # NGAGE_CORE_ARM9 keeps this wire format. Its nearest equivalents are:
    # data = backend HOLD/reload/retry/return, code = fetch wait/full,
    # nofifo = no S-entry instruction, issue = D2 hazard or S/A unavailable,
    # shifter = register-shift/multiply wait, decode = W CP15 occupancy,
    # alu flush = registered A redirect, wb flush = W exception/serial/PC
    # recovery. Scalar misses retain operands and do not count as replays.
    # uops/instructions count W retirement; D-cache events are shared with ZAP.
    # Next are the MMC card counters (512-byte blocks completed, data-phase
    # clocks, wire-wait-for-Linux clocks), and the D-cache's events (load-miss
    # fills, store-miss fills, line write-backs, uncached completions)
    frames, pix, retired, wfi, wsd, wfl, wot, beats = w[:8]
    dstall, cstall, nofifo, s_issue, s_shift, s_dec, clr_alu, clr_wb, uops, replays = w[8:18]
    mmc_blks, mmc_data, mmc_wait = w[18:21]
    dc_ld, dc_st, dc_wb, dc_unc = w[21:25]   # D-cache: load-miss fills, store-miss fills, write-backs, uncached completions
    # New counter indices 25..32 = overlay words 37..44, rows 156..186:
    # FIFO full; raw fetch wait; demand fill completions (including faults);
    # fetch wait AND !FIFO full; demand fill wait behind DATA; demand fill
    # wait for the external arbiter/self-test; I-TLB beats; D-TLB beats.
    # The wait clocks overlap the old code counter and bus target counters.
    fifo_full, fetch_wait, ic_fill, ic_wait, ic_merge, ic_arb, itlb, dtlb = w[25:33]
    clk = 104_000_000
    pct = lambda n: 100.0 * n / clk
    return " | per s: %d frames, %d px, %.2f M instr, idle %.1f%%, bus wait sdram %.1f%% flash %.1f%% other %.1f%%, %d beats | stalls: data %.1f%% code-combined %.1f%% nofifo %.1f%% issue %.1f%% shifter %.1f%% decode %.1f%%, flush alu %d wb %d, %.2f M uops, %d replays, mmc %d blk/s data %.1f%% wait %.1f%% | dcache %d ld-fill %d st-fill %d wb %d unc | icache %d demand-fill fifo-full %.1f%% fetch-wait %.1f%% true-wait %.1f%% fill-merger-wait %.1f%% fill-grant-wait %.1f%% | tlb %d I-beats %d D-beats" % (
        frames, pix, retired / 1e6, pct(wfi), pct(wsd), pct(wfl), pct(wot), beats,
        pct(dstall), pct(cstall), pct(nofifo), pct(s_issue), pct(s_shift), pct(s_dec), clr_alu, clr_wb, uops / 1e6, replays,
        mmc_blks, pct(mmc_data), pct(mmc_wait), dc_ld, dc_st, dc_wb, dc_unc,
        ic_fill, pct(fifo_full), pct(fetch_wait), pct(ic_wait), pct(ic_merge), pct(ic_arb), itlb, dtlb)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(decode(p))
