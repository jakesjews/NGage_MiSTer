#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate a random ARM-state CPU test (for comparison with QEMU).

    python3 -I gen_random.py --seed N [--count 600] > randN.S

The program is a seeded random mix of data processing (every opcode,
condition, S bit, immediate / immediate-shift / register-shift operands),
multiplies, loads and stores of every size and addressing mode, LDM/STM,
SWP, MSR to the flags, MRS and short forward branches, with a CHECKPOINT
(all registers and the CPSR) every few instructions and the scratch memory
summed at the end. It checks nothing itself: the RTL and QEMU must produce
the same signature and the same instruction trace. UNPREDICTABLE forms
and unaligned accesses (QEMU aborts on those) are not generated.
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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--count", type=int, default=600)
    opt = ap.parse_args()
    rng = random.Random(opt.seed)

    out = [f"@ Generated by sim/cpu/tools/gen_random.py --seed {opt.seed} "
           f"--count {opt.count}; do not edit.\n",
           "\t.include \"test.inc\"\n\t.syntax unified\n\t.text\n\t.arm\n\t.global\ttest_main\n",
           "test_main:\n\tstmfd\tsp!, {r4-r11, lr}\n",
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
