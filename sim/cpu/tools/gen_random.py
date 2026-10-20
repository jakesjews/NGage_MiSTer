#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate a random ARM-state or Thumb CPU test (for comparison with QEMU).

    python3 -I gen_random.py --seed N [--count 600] [--thumb] > randN.S

The program is a seeded random mix of data processing (every opcode,
condition, S bit, immediate / immediate-shift / register-shift operands),
multiplies, loads and stores of every size and addressing mode, LDM/STM,
SWP, MSR to the flags, MRS and short forward branches, with a CHECKPOINT
(all registers and the CPSR) every few instructions and the scratch memory
summed at the end. It checks nothing itself: the RTL and QEMU must produce
the same signature and the same instruction trace. UNPREDICTABLE forms
and unaligned accesses (QEMU aborts on those) are not generated.

With --thumb the program runs in Thumb state: every format-1 to 5 data
operation (shifts, add/subtract, 8-bit immediates, the 16 ALU operations,
the high-register forms), loads and stores of every size with immediate and
register offsets, PUSH/POP, LDMIA/STMIA, ADD Rd, PC and short conditional
branches; r7 holds the scratch base. Checkpoints go through an ARM veneer
(BL, then BX PC).

With --cache the program runs with the MMU on (the RAM identity-mapped,
write-back) and both caches enabled, so loads and stores of every kind hit
and miss; QEMU has no caches and must still agree.
"""
import argparse
import random

CONDS = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge",
         "lt", "gt", "le", "", "", "", ""]          # AL more often
DP = ["and", "eor", "sub", "rsb", "add", "adc", "sbc", "rsc", "tst", "teq",
      "cmp", "cmn", "orr", "mov", "bic", "mvn"]
SHIFTS = ["lsl", "lsr", "asr", "ror"]
REGS = [f"r{i}" for i in range(12)]                 # r12 = base, r13/r14 kept
SCRATCH_WORDS = 256                                  # 1 KB at SCRATCH


def rot_imm(rng):
    v = rng.getrandbits(8)
    r = rng.randrange(16) * 2
    return ((v >> r) | (v << (32 - r))) & 0xFFFFFFFF if r else v


def operand2(rng):
    k = rng.randrange(4)
    if k == 0:
        return f"#0x{rot_imm(rng):x}"
    rm = rng.choice(REGS)
    if k == 1:
        return rm
    if k == 2:
        sh = rng.choice(SHIFTS + ["rrx"])
        if sh == "rrx":
            return f"{rm}, rrx"
        n = rng.randrange(1, 33) if sh in ("lsr", "asr") else rng.randrange(0, 32)
        if sh == "ror" and n == 0:
            n = 1
        return f"{rm}, {sh} #{n}"
    return f"{rm}, {rng.choice(SHIFTS)} {rng.choice(REGS)}"


def base(rng, align, span):
    """r12 := a random address in the scratch area, aligned to align, with
    span bytes of room after it."""
    off = rng.randrange(0, SCRATCH_WORDS * 4 - span - 64) & ~(align - 1)
    return f"\tldr\tr12, =SCRATCH + {off + 32}\n"


def instr(rng):
    k = rng.randrange(100)
    c = rng.choice(CONDS)
    if k < 45:
        op = rng.choice(DP)
        s = "s" if rng.random() < 0.5 else ""
        if op in ("tst", "teq", "cmp", "cmn"):
            return f"\t{op}{c}\t{rng.choice(REGS)}, {operand2(rng)}\n"
        if op in ("mov", "mvn"):
            return f"\t{op}{s}{c}\t{rng.choice(REGS)}, {operand2(rng)}\n"
        return f"\t{op}{s}{c}\t{rng.choice(REGS)}, {rng.choice(REGS)}, {operand2(rng)}\n"
    if k < 55:
        s = "s" if rng.random() < 0.3 else ""
        rd, rm, rs, rn = rng.sample(REGS, 4)
        m = rng.randrange(6)
        if m == 0:
            return f"\tmul{s}{c}\t{rd}, {rm}, {rs}\n"
        if m == 1:
            return f"\tmla{s}{c}\t{rd}, {rm}, {rs}, {rn}\n"
        op = ["umull", "umlal", "smull", "smlal"][m - 2]
        return f"\t{op}{s}{c}\t{rd}, {rn}, {rm}, {rs}\n"
    if k < 80:
        size = rng.choice(["", "b", "h", "sb", "sh"])
        load = rng.random() < 0.6 or size in ("sb", "sh")
        align = {"": 4, "b": 1, "h": 2, "sb": 1, "sh": 2}[size]
        rd = rng.choice(REGS)
        if size in ("h", "sb", "sh"):
            off = rng.randrange(0, 64) & ~(align - 1)
        else:
            off = rng.randrange(0, 256) & ~(align - 1)
        sign = "-" if rng.random() < 0.3 else ""
        mode = rng.randrange(3)
        out = base(rng, align, 512)
        if sign:
            out = base(rng, align, 512).replace("SCRATCH + ", f"SCRATCH + {off} + ")
        addr = [f"[r12, #{sign}{off}]", f"[r12, #{sign}{off}]!", f"[r12], #{sign}{off}"][mode]
        op = ("ldr" if load else "str") + size
        return out + f"\t{op}{c}\t{rd}, {addr}\n"
    if k < 88:
        regs = sorted(rng.sample(range(12), rng.randrange(1, 9)))
        lst = ", ".join(f"r{r}" for r in regs)
        am = rng.choice(["ia", "ib", "da", "db"])
        wb = "!" if rng.random() < 0.5 else ""
        op = "ldm" if rng.random() < 0.5 else "stm"
        out = base(rng, 4, 64)
        if am in ("da", "db"):
            out = out.replace("SCRATCH + ", "SCRATCH + 64 + ")
        return out + f"\t{op}{am}{c}\tr12{wb}, {{{lst}}}\n"
    if k < 91:
        rd, rm = rng.sample(REGS, 2)
        b = "b" if rng.random() < 0.5 else ""
        return base(rng, 4, 4) + f"\tswp{b}{c}\t{rd}, {rm}, [r12]\n"
    if k < 94:
        return f"\tmsr\tcpsr_f, #0x{rng.randrange(16) << 28:x}\n"
    if k < 97:
        rd = rng.choice(REGS)
        return f"\tmrs{c}\t{rd}, cpsr\n\tbic{c}\t{rd}, {rd}, #0x100\n"
    n = rng.randrange(1, 4)
    body = "".join(instr_simple(rng) for _ in range(n))
    return f"\tb{c}\t1f\n{body}1:\n"


def instr_simple(rng):
    op = rng.choice(["add", "sub", "eor", "orr"])
    return f"\t{op}\t{rng.choice(REGS)}, {rng.choice(REGS)}, {operand2(rng)}\n"


TLO = [f"r{i}" for i in range(7)]                   # r7 = scratch base
THI = ["r8", "r9", "r10", "r11"]
T_ALU = ["and", "eor", "lsl", "lsr", "asr", "adc", "sbc", "ror", "tst", "neg",
         "cmp", "cmn", "orr", "mul", "bic", "mvn"]
T_CONDS = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge",
           "lt", "gt", "le"]


CACHE_ON = ("\tbl\tmmu_on\n"
            "\tldr\tr0, =TTB\n\tldr\tr1, =0x00000C1E\n\tmov\tr2, #16\n"
            "9:\tstr\tr1, [r0], #4\n\tadd\tr1, r1, #0x00100000\n\tsubs\tr2, r2, #1\n\tbne\t9b\n"
            "\tmov\tr0, #0\n\tmcr\tp15, 0, r0, c8, c7, 0\n"
            "\tmrc\tp15, 0, r0, c1, c0, 0\n\torr\tr0, r0, #(CR_C | CR_W)\n\torr\tr0, r0, #CR_I\n"
            "\tmcr\tp15, 0, r0, c1, c0, 0\n")


def preamble(opt, syntax):
    inc = "\t.include \"test.inc\"\n" + ("\t.include \"mmu.inc\"\n" if opt.cache else "")
    return [inc + syntax + "\t.text\n\t.arm\n\t.global\ttest_main\n",
            "test_main:\n\tstmfd\tsp!, {r4-r11, lr}\n" + (CACHE_ON if opt.cache else "")]


def t_instr(rng):
    """One Thumb instruction (or a short group), divided syntax."""
    k = rng.randrange(100)
    lo = lambda: rng.choice(TLO)
    if k < 10:
        op = rng.choice(["lsl", "lsr", "asr"])
        n = rng.randrange(0, 32) if op == "lsl" else rng.randrange(1, 33)
        return f"\t{op}\t{lo()}, {lo()}, #{n}\n"
    if k < 20:
        op = rng.choice(["add", "sub"])
        last = lo() if rng.random() < 0.5 else f"#{rng.randrange(8)}"
        return f"\t{op}\t{lo()}, {lo()}, {last}\n"
    if k < 30:
        op = rng.choice(["mov", "cmp", "add", "sub"])
        return f"\t{op}\t{lo()}, #{rng.randrange(256)}\n"
    if k < 55:
        op = rng.choice(T_ALU)
        rd, rs = lo(), lo()
        if op == "mul":
            rd, rs = rng.sample(TLO, 2)                # Rd == Rm is UNPREDICTABLE
        return f"\t{op}\t{rd}, {rs}\n"
    if k < 63:
        op = rng.choice(["add", "mov", "cmp"])
        a, b = rng.choice(THI), rng.choice(TLO + THI)
        if rng.random() < 0.5:
            a, b = b, a
        return f"\t{op}\t{a}, {b}\n"
    if k < 66:
        return f"\tadd\t{lo()}, pc, #{4 * rng.randrange(64)}\n"
    if k < 80:
        size = rng.choice(["", "b", "h", "sb", "sh"])
        load = rng.random() < 0.6 or size in ("sb", "sh")
        op = ("ldr" if load else "str") + size
        align = {"": 4, "b": 1, "h": 2, "sb": 1, "sh": 2}[size]
        if size in ("sb", "sh") or rng.random() < 0.5:
            off = rng.randrange(0, 256) & ~(align - 1)
            return f"\tmov\tr6, #{off}\n\t{op}\t{rng.choice(TLO[:6])}, [r7, r6]\n"
        off = rng.randrange(0, 32) * align
        return f"\t{op}\t{lo()}, [r7, #{off}]\n"
    if k < 86:
        n = rng.randrange(1, 5)
        a = sorted(rng.sample(range(7), n))
        b = sorted(rng.sample(range(7), n))
        return (f"\tpush\t{{{', '.join(f'r{r}' for r in a)}}}\n"
                f"\tpop\t{{{', '.join(f'r{r}' for r in b)}}}\n")
    if k < 92:
        n = rng.randrange(1, 6)
        regs = sorted(rng.sample(range(7), n))
        op = rng.choice(["ldmia", "stmia"])
        return (f"\t{op}\tr7!, {{{', '.join(f'r{r}' for r in regs)}}}\n"
                f"\tsub\tr7, #{4 * n}\n")
    n = rng.randrange(1, 4)
    body = "".join(f"\t{rng.choice(['add', 'sub', 'eor', 'orr'])}\t{lo()}, {lo()}\n"
                   if rng.random() < 0.5 else f"\tadd\t{lo()}, #{rng.randrange(256)}\n"
                   for _ in range(n))
    return f"\tb{rng.choice(T_CONDS)}\t1f\n{body}1:\n"


def thumb_main(opt, rng):
    out = [f"@ Generated by sim/cpu/tools/gen_random.py --thumb --seed {opt.seed} "
           f"--count {opt.count}{' --cache' if opt.cache else ''}; do not edit.\n"] + \
          preamble(opt, "") + [
           "\tldr\tr0, =init_data\n\tldr\tr1, =SCRATCH\n",
           f"\tmov\tr2, #{SCRATCH_WORDS}\n",
           "0:\tldr\tr3, [r0], #4\n\tstr\tr3, [r1], #4\n\tsubs\tr2, r2, #1\n\tbne\t0b\n"]
    for r in TLO + THI:
        out.append(f"\tldr\t{r}, =0x{rng.getrandbits(32):08x}\n")
    out.append("\tldr\tr7, =SCRATCH + 32\n")
    out.append(f"\tmsr\tcpsr_f, #0x{rng.randrange(16) << 28:x}\n\tCHECKPOINT\n")
    out.append("\tadr\tr12, t_start + 1\n\tbx\tr12\n\t.ltorg\n")
    out.append("@ checkpoint veneer: Thumb BL here, ARM CHECKPOINT, back with BX LR\n"
               "\t.thumb\n\t.align\t2\nt_ckpt:\n\tbx\tpc\n\tnop\n\t.arm\n"
               "\tCHECKPOINT\n\tbx\tlr\n")
    out.append("\t.thumb\n\t.align\t2\nt_start:\n")
    for i in range(opt.count):
        out.append(t_instr(rng))
        if i % 16 == 15:
            out.append("\tbl\tt_ckpt\n")
        if i % 64 == 63:
            out.append("\tb\t3f\n\t.align\t2\n\t.ltorg\n3:\n")
    out.append("\tbl\tt_ckpt\n\tldr\tr6, =a_end\n\tbx\tr6\n\t.align\t2\n\t.ltorg\n")
    out.append("\t.arm\n\t.align\t2\na_end:\n\tldr\tr12, =SIG_DATA\n\tstmia\tr12, {r0-r11}\n")
    out.append(f"\tldr\tr0, =SCRATCH\n\tmov\tr1, #0\n\tmov\tr2, #{SCRATCH_WORDS}\n"
               "2:\tldr\tr3, [r0], #4\n\tadd\tr1, r1, r3, ror #3\n\tsubs\tr2, r2, #1\n\tbne\t2b\n"
               "\tldr\tr12, =SIG_DATA\n\tstr\tr1, [r12, #48]\n")
    out.append("\tldmfd\tsp!, {r4-r11, pc}\n\t.ltorg\n\t.data\n\t.align\t2\ninit_data:\n")
    for i in range(SCRATCH_WORDS):
        out.append(f"\t.word\t0x{rng.getrandbits(32):08x}\n")
    print("".join(out), end="")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--count", type=int, default=600)
    ap.add_argument("--thumb", action="store_true")
    ap.add_argument("--cache", action="store_true",
                    help="run with the MMU (identity map) and both caches on, write-back")
    opt = ap.parse_args()
    rng = random.Random(opt.seed)
    if opt.thumb:
        thumb_main(opt, rng)
        return

    out = [f"@ Generated by sim/cpu/tools/gen_random.py --seed {opt.seed} "
           f"--count {opt.count}{' --cache' if opt.cache else ''}; do not edit.\n"] + \
          preamble(opt, "\t.syntax unified\n") + [
           # scratch memory from a seeded table
           "\tldr\tr0, =init_data\n\tldr\tr1, =SCRATCH\n",
           f"\tmov\tr2, #{SCRATCH_WORDS}\n",
           "0:\tldr\tr3, [r0], #4\n\tstr\tr3, [r1], #4\n\tsubs\tr2, r2, #1\n\tbne\t0b\n"]
    for r in REGS:
        out.append(f"\tldr\t{r}, =0x{rng.getrandbits(32):08x}\n")
    out.append(f"\tmsr\tcpsr_f, #0x{rng.randrange(16) << 28:x}\n\tCHECKPOINT\n")
    for i in range(opt.count):
        out.append(instr(rng))
        if i % 20 == 19:
            out.append("\tCHECKPOINT\n\tb\t3f\n\t.ltorg\n3:\n")
    # final state and a sum of the scratch area
    out.append("\tCHECKPOINT\n\tldr\tr12, =SIG_DATA\n\tstmia\tr12, {r0-r11}\n")
    out.append(f"\tldr\tr0, =SCRATCH\n\tmov\tr1, #0\n\tmov\tr2, #{SCRATCH_WORDS}\n"
               "2:\tldr\tr3, [r0], #4\n\tadd\tr1, r1, r3, ror #3\n\tsubs\tr2, r2, #1\n\tbne\t2b\n"
               "\tldr\tr12, =SIG_DATA\n\tstr\tr1, [r12, #48]\n")
    out.append("\tldmfd\tsp!, {r4-r11, pc}\n\t.ltorg\n\t.data\n\t.align\t2\ninit_data:\n")
    for i in range(SCRATCH_WORDS):
        out.append(f"\t.word\t0x{rng.getrandbits(32):08x}\n")
    print("".join(out), end="")


if __name__ == "__main__":
    main()
