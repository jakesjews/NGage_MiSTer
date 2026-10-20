#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Translate jsmolka/gba-tests sources (FASMARM syntax) to GNU as.

    python3 -I fasm2gas.py --set arm|thumb SRC_DIR [--faithful] [--tag T]
        [--skip N ...] > out.S

Reads the test bodies of one set (the files the upstream driver arm.asm or
thumb.asm includes, in its order) from SRC_DIR and writes one GNU as file
with a driver for this bench (sim/cpu/tests/test.inc): test_main switches
to System mode as the GBA BIOS would leave it, runs every test, and returns
to SVC mode. A failed test records its number at SIG_DATA (count at +0,
numbers from +0x80) and the run carries on with the next test; the test
passes when nothing was recorded.

--skip N removes test N (from its tN label to the start of the next test).
GBA addresses are moved into the bench's RAM (see RELOC).

--faithful writes only the test bodies, with the upstream m_exit and the
upstream layout, so that the result can be compared word for word with the
prebuilt arm.gba / thumb.gba; that is how the translation was checked.
"""
import argparse
import os
import re
import sys

ARM_FILES = ["conditions", "branches", "flags", "shifts", "data_processing",
             "psr_transfer", "multiply", "single_transfer", "halfword_transfer",
             "data_swap", "block_transfer"]
THUMB_FILES = ["logical", "shifts", "arithmetic", "branches", "memory"]

CONSTS = {
    "FLAG_N": "(1 << 31)", "FLAG_Z": "(1 << 30)", "FLAG_C": "(1 << 29)",
    "FLAG_V": "(1 << 28)",
    "MODE_USR": "0x10", "MODE_FIQ": "0x11", "MODE_IRQ": "0x12",
    "MODE_SVC": "0x13", "MODE_ABT": "0x17", "MODE_SYS": "0x1F",
    "MEM_IWRAM": "GBA_IWRAM",
}

# GBA memory the tests use, moved into the bench RAM: (file, old line,
# new line). IWRAM (0x03000000) is GBA_IWRAM in the driver; the Thumb
# memory tests build EWRAM's 0x02000000 as 2 << 24.
RELOC = [("memory", "lsl     mem, 24", "lsl     mem, 21")]   # 0x00400000

REGS = {f"r{i}" for i in range(16)} | {"sp", "lr", "pc", "ip", "fp", "sl"}
SHIFTS = {"lsl", "lsr", "asr", "ror", "rrx"}
BRANCH = re.compile(r"^(b|bl)(eq|ne|cs|cc|hs|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al)?$")
SHIFT_OP = re.compile(r"^(lsl|lsr|asr|ror)s?$")
DP3 = re.compile(r"^(and|eor|sub|rsb|add|adc|sbc|rsc|orr|bic)s?"
                 r"(eq|ne|cs|cc|hs|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al)?$")


def split_ops(s):
    """Split an operand list at top-level commas."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


class Translator:
    def __init__(self, thumb, faithful):
        self.thumb = thumb
        self.faithful = faithful
        self.aliases = set()
        self.glabel = ""

    def is_reg(self, t):
        t = t.strip().lower()
        return t in REGS or t in self.aliases or t.startswith(("cpsr", "spsr"))

    def expr(self, e):
        e = e.strip()
        e = re.sub(r"\bshl\b", "<<", e)
        e = re.sub(r"\bshr\b", ">>", e)
        e = re.sub(r"\band\b", "&", e)
        e = re.sub(r"\bxor\b", "^", e)
        e = re.sub(r"\bor\b", "|", e)
        e = re.sub(r"\bnot\b", "~", e)
        for k, v in CONSTS.items():
            e = re.sub(rf"\b{k}\b", v, e)
        return e

    def label(self, e):
        e = e.strip()
        e = re.sub(r"(?<![\w.])\.(\w+)", lambda m: f"{self.glabel}_L_{m.group(1)}", e)
        return e

    def imm(self, e):
        return "#" + self.expr(e)

    def operand(self, op):
        """A data-processing style operand: register, shift or immediate."""
        o = op.strip()
        if self.is_reg(o) or o.startswith("{"):
            return o
        if o.startswith("-") and self.is_reg(o[1:]):
            return o
        w = o.split(None, 1)
        if w and w[0].lower() in SHIFTS:
            if len(w) == 1:
                return o
            return w[0] + " " + (w[1] if self.is_reg(w[1]) else self.imm(w[1]))
        return self.imm(o)

    def address(self, op):
        o = op.strip()
        bang = o.endswith("!")
        if bang:
            o = o[:-1].strip()
        if not o.startswith("["):
            return self.label(o)                # PC-relative label
        inner = split_ops(o[1:-1])
        res = [inner[0]] + [self.operand(x) for x in inner[1:]]
        return "[" + ", ".join(res) + "]" + ("!" if bang else "")

    def insn(self, mn, ops):
        m = mn.lower()
        if BRANCH.match(m) and len(ops) == 1:
            return f"{mn}\t{self.label(ops[0])}"
        if m == "adr":
            return f"adr\t{ops[0]}, {self.label(ops[1])}"
        if m in ("bx", "push", "pop", "mrs") or m.startswith(("ldm", "stm")):
            if self.thumb and m in ("ldm", "stm"):
                mn = m + "ia"
            return f"{mn}\t{', '.join(ops)}"
        if re.match(r"^(ldr|str|swp)", m):
            if m.startswith("swp"):
                return f"{mn}\t{ops[0]}, {ops[1]}, {self.address(ops[2])}"
            rest = [self.address(ops[1])] + [self.operand(x) for x in ops[2:]]
            return f"{mn}\t{ops[0]}, {', '.join(rest)}"
        if SHIFT_OP.match(m) and len(ops) == 2 and (not self.thumb or not self.is_reg(ops[1])):
            # two-operand shift: Rd is also the source
            ops = [ops[0], ops[0], ops[1]]
        if re.match(r"^rrxs?", m) and len(ops) == 1:
            ops = [ops[0], ops[0]]
        if not self.thumb and DP3.match(m):
            n = len([o for o in ops if o.split()[0].lower() not in SHIFTS])
            if n == 2:
                # "add r0, r1, lsl 2" / "add r0, 1": Rd is also Rn
                ops = [ops[0]] + ops
        return f"{mn}\t{', '.join(self.operand(o) if i else o for i, o in enumerate(ops))}"

    def m_exit(self, n):
        if self.faithful:
            if self.thumb:
                return [f"mov\tr7, #{n}", "bl\ttmain_end"]
            return [f"mov\tr12, #({n} & 0xFF)", f"orr\tr12, r12, #({n} & 0xFF00)", "b\teval"]
        if self.thumb:
            return [f"mov\tr7, #{n}", "bl\tgba_fail_t"]
        return [f"mov\tr12, #({n} & 0xFF)", f"orr\tr12, r12, #({n} & 0xFF00)", "bl\tgba_fail"]

    def line(self, raw):
        code, _, comment = raw.partition(";")
        out = []
        code = code.rstrip()
        indent = "\t"
        m = re.match(r"^(\.?\w+):(.*)$", code.strip())
        if m:
            name = m.group(1)
            if name.startswith("."):
                name = f"{self.glabel}_L_{name[1:]}"
            else:
                self.glabel = name
            out.append(f"{name}:")
            code = m.group(2)
        s = code.strip()
        if s:
            w = s.split(None, 1)
            mn, rest = w[0], (w[1] if len(w) > 1 else "")
            ml = mn.lower()
            m2 = re.match(r"^(\w+)\s+equ\s+(\w+)$", s)
            if m2:
                self.aliases.add(m2.group(1))
                out.append(f"{indent}{m2.group(1)}\t.req\t{m2.group(2)}")
            elif ml == "restore":
                self.aliases.discard(rest.strip())
                out.append(f"{indent}.unreq\t{rest.strip()}")
            elif ml == "code16":
                self.thumb = True
                out.append(f"{indent}.thumb\n{indent}.syntax\tdivided")
            elif ml == "code32":
                self.thumb = False
                out.append(f"{indent}.arm\n{indent}.syntax\tunified")
            elif ml == "align":
                out.append(f"{indent}.balign\t{rest.strip()}")
            elif ml == "nop" and not self.thumb:
                # FASMARM assembles nop as 0xE320F000 (the ARMv6K hint; on
                # ARMv4T an MSR CPSR with no fields), GNU as as MOV r0, r0
                out.append(f"{indent}.word\t0xE320F000\t@ nop (FASMARM encoding)")
            elif ml == "dw":
                out.append(f"{indent}.word\t{self.expr(rest)}")
            elif ml == "dh":
                out.append(f"{indent}.hword\t{self.expr(rest)}")
            elif ml == "m_exit":
                out += [indent + x for x in self.m_exit(int(rest.strip()))]
            elif ml in ("m_half", "m_word"):
                reg, val = split_ops(rest)
                parts = [0xFF, 0xFF00] + ([0xFF0000, 0xFF000000] if ml == "m_word" else [])
                out.append(f"{indent}mov\t{reg}, #(({self.expr(val)}) & 0x{parts[0]:X})")
                for p in parts[1:]:
                    out.append(f"{indent}orr\t{reg}, {reg}, #(({self.expr(val)}) & 0x{p:X})")
            elif ml in ("include", "macro", "format") or ml.startswith("m_"):
                raise SystemExit(f"fasm2gas: unsupported line: {raw.strip()}")
            else:
                out.append(indent + self.insn(mn, split_ops(rest)))
        if comment.strip():
            if out:
                out[-1] += "\t@ " + comment.strip()
            else:
                out.append("\t@ " + comment.strip())
        return out


def strip_skipped(lines, skip):
    """Drop tests in skip: from 'tN:' to the next 'tM:' (or a *_passed label)."""
    out, dropping = [], False
    for ln in lines:
        m = re.match(r"^t(\d+)\w*:", ln.strip())
        if m and not re.match(r"^t\d+[a-z]+:", ln.strip()):
            dropping = int(m.group(1)) in skip
            if dropping:
                out.append(ln.strip() + "\t; skipped")    # earlier tests branch here
                continue
        elif re.match(r"^\w+_passed:", ln.strip()):
            dropping = False
        if not dropping:
            out.append(ln)
    return out


DRIVER_HEAD = """\
@ Generated by sim/cpu/tools/fasm2gas.py from jsmolka/gba-tests ({set}/*.asm,
@ MIT licence, see sim/cpu/ext/gba-tests/LICENSE); do not edit.
@ Skipped tests: {skipped}
	.include "test.inc"
	.equ	GBA_IWRAM, 0x00500000
	.equ	GBA_FAILS, SIG_DATA
	.syntax	unified
	.text
	.arm
	.global	test_main
test_main:
	ldr	r0, gba_svc_p
	str	sp, [r0]
	str	lr, [r0, #4]
	mov	r1, #0
	ldr	r0, gba_fails_p0
	str	r1, [r0]
	msr	cpsr_c, #M_SYS			@ as the GBA BIOS leaves it
	mov	r12, #0
	b	gba_start
gba_svc_p:	.word	gba_svc_sp
gba_fails_p0:	.word	GBA_FAILS
gba_start:
"""

DRIVER_ARM_TAIL = """\
	.arm
	.syntax	unified
	.balign	4
gba_end:
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, =gba_svc_sp
	ldr	sp, [r0]
	ldr	lr, [r0, #4]
	ldr	r0, =GBA_FAILS
	ldr	r0, [r0]
	CHECK	r0, 0
	mov	pc, lr
"""

DRIVER_COMMON = """\
@ gba_fail: record test r12 (ARM, from bl) or r7 (gba_fail_t, Thumb bl);
@ changes no register and no flag, uses no stack
	.thumb
	.syntax	divided
	.balign	4
gba_fail_t:
	bx	pc
	nop
	.arm
	.syntax	unified
	str	r12, gba_sv12
	mov	r12, r7
	str	lr, gba_svlr
	bl	gba_rec
	ldr	lr, gba_svlr
	ldr	r12, gba_sv12
	bx	lr
gba_fail:
	str	lr, gba_svlr
	bl	gba_rec
	ldr	lr, gba_svlr
	bx	lr
gba_rec:
	str	r0, gba_sv0
	str	r1, gba_sv1
	ldr	r0, gba_fails_p
	ldr	r1, [r0]
	add	r1, r1, #1
	str	r1, [r0]
	sub	r1, r1, #1
	and	r1, r1, #31
	add	r0, r0, #0x80
	str	r12, [r0, r1, lsl #2]
	ldr	r1, gba_sv1
	ldr	r0, gba_sv0
	mov	pc, lr
gba_fails_p:	.word	GBA_FAILS
gba_sv0:	.word	0
gba_sv1:	.word	0
gba_sv12:	.word	0
gba_svlr:	.word	0
gba_svc_sp:	.word	0
gba_svc_lr:	.word	0
	.ltorg
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", choices=["arm", "thumb"], required=True)
    ap.add_argument("--faithful", action="store_true")
    ap.add_argument("--skip", type=int, nargs="*", default=[])
    ap.add_argument("--tag", action="append", default=[],
                    help="add an '@@ TAG' line (bench test tags, see sim/cpu/Makefile)")
    ap.add_argument("src")
    opt = ap.parse_args()
    files = ARM_FILES if opt.set == "arm" else THUMB_FILES
    thumb = opt.set == "thumb"
    tr = Translator(thumb, opt.faithful)
    out = []
    if opt.faithful:
        out.append("\t.syntax\tunified\n\t.equ\tGBA_IWRAM, 0x03000000\n\t.text")
        out.append("\t.thumb\n\t.syntax\tdivided\ntmain:\n\tmov\tr7, #0" if thumb else "\t.arm")
    else:
        out.append(DRIVER_HEAD.format(set=opt.set,
                                      skipped=" ".join(map(str, sorted(opt.skip))) or "none"))
        out += [f"@@ {t}" for t in opt.tag]
        if thumb:
            out.append("\tadr\tr0, tmain + 1\n\tbx\tr0\n\t.thumb\n\t.syntax\tdivided\n"
                       "\t.balign\t2\ntmain:\n\tmov\tr7, #0")
    for f in files:
        with open(os.path.join(opt.src, opt.set, f + ".asm")) as fh:
            lines = fh.read().splitlines()
        for name, old, new in RELOC:
            if name == f and not opt.faithful:
                lines = [ln.replace(old, new) for ln in lines]
        lines = strip_skipped(lines, set(opt.skip))
        out.append(f"@ ---- {opt.set}/{f}.asm")
        tr.glabel = f
        for ln in lines:
            out += tr.line(ln)
    if opt.faithful:
        if thumb:
            out.append("tmain_end:\n\tadr\tr0, eval\n\tbx\tr0\n\t.arm\n\t.balign\t4\neval:")
        else:
            out.append("eval:")
    else:
        if thumb:
            out.append("tmain_end:\n\tadr\tr0, gba_end\n\tbx\tr0")
        else:
            out.append("\tb\tgba_end")
        out.append(DRIVER_ARM_TAIL)
        out.append(DRIVER_COMMON)
    print("\n".join(out))


if __name__ == "__main__":
    sys.exit(main())
