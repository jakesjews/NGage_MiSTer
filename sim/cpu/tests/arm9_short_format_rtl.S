@ SPDX-License-Identifier: GPL-3.0-or-later
@ The D-cache's short-port response, formatted per way (V2's WAY_FORMAT),
@ with the set collision of a RAM write registered (REG_COLLISION), and
@ W's load word through S's own rotator (W_ROTATE). Every load form (LDR
@ at byte offsets 0-3, so rotated; LDRB, LDRSB at 0-3; LDRH, LDRSH at 0
@ and 2) hits a line held in way 0, then in way 1 (the other way holds
@ another line of the set). Each result is read by a late ALU operand and
@ by a shifted operand (ROR, LSL with its carry, ASR), at distance 1 (S
@ takes W's word through its rotator) and 3. Then a store to the same
@ word just before the load (a word, the loaded byte, another byte, a
@ halfword; distances 1 and 2), a store to the set's other way, and a
@ store followed by 1-3 loads of another set before the load. Every
@ expected value is an assembly-time constant built with MOV/ORR, and the
@ addresses too: no reference goes through the D-cache. Each case starts
@ with the D-cache cleaned and invalidated; the second pass has the code
@ warm.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000		@ uncached alias of SCRATCH's MB
	.equ	TLINE, SCRATCH + 0x1A40	@ set 0x1A4 in D16, 0xA4 in D8
	.equ	OLINE, SCRATCH + 0x5A40	@ the same set
	.equ	W0, 0x24C34281
	.equ	W1, 0x18E75695
	.equ	W2, 0x3CFB6AA9
	.equ	W3, 0x70DF4E8D
	.equ	SV, 0xF15A3C96		@ the stored word
	.equ	M32, 0xFFFFFFFF
	.text
	.arm
	.global	test_main

	@ a 32-bit constant without a literal (no D-cache access)
	.macro	MOV32 reg, val
	mov	\reg, #((\val) & 0xFF)
	orr	\reg, \reg, #((\val) & 0xFF00)
	orr	\reg, \reg, #((\val) & 0xFF0000)
	orr	\reg, \reg, #((\val) & 0xFF000000)
	.endm

	@ fail unless \reg == \val
	.macro	EXPECT reg, val
	MOV32	r12, \val
	CHECKR	\reg, r12
	.endm

	@ the loaded value of form fm from word w (assembly-time)
	.macro	LVAL sym, fm, w
	.if \fm == 0
	.set	\sym, (\w) & M32
	.elseif \fm < 4
	.set	\sym, ((((\w) & M32) >> (8 * \fm)) | ((\w) << (32 - 8 * \fm))) & M32
	.elseif \fm < 8
	.set	\sym, (((\w) & M32) >> (8 * (\fm - 4))) & 0xFF
	.elseif \fm < 12
	.set	_b, (((\w) & M32) >> (8 * (\fm - 8))) & 0xFF
	.set	\sym, (_b - ((_b & 0x80) << 1)) & M32
	.elseif \fm < 14
	.set	\sym, (((\w) & M32) >> (16 * (\fm - 12))) & 0xFFFF
	.else
	.set	_h, (((\w) & M32) >> (16 * (\fm - 14))) & 0xFFFF
	.set	\sym, (_h - ((_h & 0x8000) << 1)) & M32
	.endif
	.endm

	@ the consumer's value (cr 0-3) of v (assembly-time)
	.macro	CVAL sym, cr, v
	.if \cr == 0
	.set	\sym, \v
	.elseif \cr == 1
	.set	\sym, (((\v) >> 8) | ((\v) << 24)) & M32
	.elseif \cr == 2
	.set	\sym, ((\v) << 1) & M32
	.else
	.set	\sym, (((\v) >> 3) | ((((\v) >> 31) & 1) * 0xE0000000)) & M32
	.endif
	.endm

	@ the consumer of \src (cr 0-3) into \dst; r6 counts the carry
	.macro	CONS cr, src, dst
	.if \cr == 0
	add	\dst, \src, #0
	.elseif \cr == 1
	mov	\dst, \src, ror #8
	.elseif \cr == 2
	movs	\dst, \src, lsl #1
	adc	r6, r6, #0
	.else
	mov	\dst, \src, asr #3
	.endif
	.endm

	@ a load form (fm 0-15) into \dst from [\base, offset]
	.macro	LDF fm, dst, base
	.if \fm < 4
	ldr	\dst, [\base, #\fm]
	.elseif \fm < 8
	ldrb	\dst, [\base, #(\fm - 4)]
	.elseif \fm < 12
	ldrsb	\dst, [\base, #(\fm - 8)]
	.elseif \fm < 14
	ldrh	\dst, [\base, #((\fm - 12) * 2)]
	.else
	ldrsh	\dst, [\base, #((\fm - 14) * 2)]
	.endif
	.endm

	@ a hit in way \way, read at distance \dist
	.macro	HIT fm, way, cr, dist
	mov	r1, #\way
	bl	prep
	mov	r6, #0
	mov	r0, #0
	cmp	r0, #1			@ C clear
	LDF	\fm, r2, r9
	.rept	\dist - 1
	mov	r0, r0
	.endr
	CONS	\cr, r2, r3
	LVAL	_v, \fm, W0
	CVAL	_c, \cr, _v
	EXPECT	r2, _v
	EXPECT	r3, _c
	.if \cr == 2
	EXPECT	r6, ((_v >> 31) & 1)
	.endif
	.endm

	@ a store (sk 0 word, 1 the loaded byte, 2 another byte, 3 a
	@ halfword) to the word, then the load at distance \dist
	.macro	STL fm, way, sk, dist, cr
	MOV32	r10, SV
	mov	r1, #\way
	bl	prep
	.if \sk == 0
	str	r10, [r9]
	.set	_m, SV
	.elseif \sk == 1
	strb	r10, [r9, #(\fm & 3)]
	.set	_m, (W0 & ~(0xFF << (8 * (\fm & 3)))) | ((SV & 0xFF) << (8 * (\fm & 3)))
	.elseif \sk == 2
	strb	r10, [r9, #((\fm + 1) & 3)]
	.set	_m, (W0 & ~(0xFF << (8 * ((\fm + 1) & 3)))) | ((SV & 0xFF) << (8 * ((\fm + 1) & 3)))
	.else
	strh	r10, [r9, #2]
	.set	_m, (W0 & 0xFFFF) | ((SV & 0xFFFF) << 16)
	.endif
	.rept	\dist - 1
	mov	r0, r0
	.endr
	LDF	\fm, r2, r9
	CONS	\cr, r2, r3
	LVAL	_v, \fm, _m
	CVAL	_c, \cr, _v
	EXPECT	r2, _v
	EXPECT	r3, _c
	.endm

	@ a store to the set's other way, then the load
	.macro	OTHER fm, way, dist
	MOV32	r10, SV
	mov	r1, #\way
	bl	prep
	str	r10, [r11]
	.rept	\dist - 1
	mov	r0, r0
	.endr
	LDF	\fm, r2, r9
	mov	r3, r2, ror #8
	LVAL	_v, \fm, W0
	CVAL	_c, 1, _v
	EXPECT	r2, _v
	EXPECT	r3, _c
	.endm

	@ a store to the word, then \n loads of another set (XLINE), then
	@ the load: the RAM write's set collision lands on a changed read set
	.macro	SXL fm, way, n
	MOV32	r10, SV
	mov	r1, #\way
	bl	prep
	str	r10, [r9]
	.rept	\n
	ldr	r0, [r7]
	.endr
	LDF	\fm, r2, r9
	mov	r3, r2, ror #8
	LVAL	_v, \fm, SV
	CVAL	_c, 1, _v
	EXPECT	r2, _v
	EXPECT	r3, _c
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, SCRATCH, 3, 0, 3
	SETL1	SCRATCH, r1
	SECT	r1, SCRATCH, 3, 0, 0
	SETL1	UNC, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r0, =PASSES
	mov	r1, #2
	str	r1, [r0]
pass:
	bl	hits
	bl	stores
	ldr	r0, =PASSES
	ldr	r1, [r0]
	subs	r1, r1, #1
	str	r1, [r0]
	bne	pass
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

hits:
	stmfd	sp!, {lr}
	.irp fm, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
	.irp way, 0, 1
	.irp cr, 0, 1, 2, 3
	.irp dist, 1, 3
	HIT	\fm, \way, \cr, \dist
	.endr
	.endr
	b	1f
	.ltorg
1:
	.endr
	.endr
	ldmfd	sp!, {pc}

stores:
	stmfd	sp!, {lr}
	.irp fm, 0, 1, 3, 4, 7, 10, 12, 15
	.irp way, 0, 1
	.irp sk, 0, 1, 2, 3
	.irp dist, 1, 2
	STL	\fm, \way, \sk, \dist, (\sk & 1)
	.endr
	.endr
	OTHER	\fm, \way, 1
	OTHER	\fm, \way, 2
	SXL	\fm, \way, 1
	SXL	\fm, \way, 2
	SXL	\fm, \way, 3
	b	1f
	.ltorg
1:
	.endr
	.endr
	ldmfd	sp!, {pc}

@ r1 = the way TLINE goes to. The D-cache is cleaned and invalidated,
@ the pattern written through the uncached alias, then TLINE and
@ OLINE loaded in the order that puts TLINE in way r1, and the fills left
@ to end; XLINE (the next set) is loaded too. Returns r9 = TLINE, r11 =
@ OLINE, r7 = XLINE. Registers only (no literal).
prep:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0	@ the last case's dirty line, before the pattern
	mcr	p15, 0, r0, c7, c6, 0
	MOV32	r9, TLINE
	MOV32	r8, (UNC + TLINE - SCRATCH)
	MOV32	r11, OLINE
	add	r7, r9, #16		@ XLINE, the next set
	MOV32	r0, W0
	str	r0, [r8]
	MOV32	r0, W1
	str	r0, [r8, #4]
	MOV32	r0, W2
	str	r0, [r8, #8]
	MOV32	r0, W3
	str	r0, [r8, #12]
	cmp	r1, #0
	ldreq	r0, [r9]
	ldr	r0, [r11]
	ldrne	r0, [r9]
	ldr	r0, [r7]
	add	r0, r0, #0
	mov	r0, #100		@ both fills end: the loads are short hits
1:	subs	r0, r0, #1
	bne	1b
	mov	pc, lr

	.data
	.align	2
PASSES:	.word	0
