@ SPDX-License-Identifier: GPL-3.0-or-later
@ Critical-word-first: every word, byte lane, signed/unsigned load format,
@ immediate ALU/shifter/store consumers, and overwriting the destination
@ while the remaining fill is in flight. The bench checks the write/lock
@ edge; these checks verify the value and the final assembled cache line.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
	.equ DATA, 0x00420000

	.macro LOAD op, off, expected
	mcr	p15, 0, r4, c7, c6, 1
	\op	r0, [r4, #\off]
	add	r1, r0, #1
	mov	r2, r0, lsl #1
	str	r0, [r5]
	CHECK	r0, \expected
	CHECK	r1, ((\expected + 1) & 0xFFFFFFFF)
	CHECK	r2, ((\expected << 1) & 0xFFFFFFFF)
	ldr	r3, [r5]
	CHECK	r3, \expected
	.endm

	.macro WORD idx, val
	LOAD	ldr, (4*\idx), \val
	.irp byte, 0, 1, 2, 3
	LOAD	ldrb, (4*\idx+\byte), ((\val >> (8*\byte)) & 0xFF)
	LOAD	ldrsb, (4*\idx+\byte), ((((\val >> (8*\byte)) & 0xFF) ^ 0x80) - 0x80)
	.endr
	.irp half, 0, 2
	LOAD	ldrh, (4*\idx+\half), ((\val >> (8*\half)) & 0xFFFF)
	LOAD	ldrsh, (4*\idx+\half), ((((\val >> (8*\half)) & 0xFFFF) ^ 0x8000) - 0x8000)
	.endr
	@ A second write after the dependent operation must survive fill end.
	mcr	p15, 0, r4, c7, c6, 1
	ldr	r0, [r4, #(4*\idx)]
	add	r0, r0, #1
	.rept 32
	mov	r1, r1
	.endr
	CHECK	r0, ((\val + 1) & 0xFFFFFFFF)
	@ The other words must be assembled at their real indices after wrap.
	ldr	r0, [r4, #0]
	CHECK	r0, 0x98FEDC80
	ldr	r0, [r4, #4]
	CHECK	r0, 0x13579BDF
	ldr	r0, [r4, #8]
	CHECK	r0, 0xFEDC3210
	ldr	r0, [r4, #12]
	CHECK	r0, 0x807F01FF
	CHECKPOINT
	b	.Lpool\@
	.ltorg
.Lpool\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	ldr	r4, =DATA
	ldr	r5, =SIG_DATA
	ldr	r0, =0x98FEDC80
	str	r0, [r4, #0]
	ldr	r0, =0x13579BDF
	str	r0, [r4, #4]
	ldr	r0, =0xFEDC3210
	str	r0, [r4, #8]
	ldr	r0, =0x807F01FF
	str	r0, [r4, #12]
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	mov	r6, #2
1:
	WORD	0, 0x98FEDC80
	WORD	1, 0x13579BDF
	WORD	2, 0xFEDC3210
	WORD	3, 0x807F01FF
	subs	r6, r6, #1
	bne	1b
	@ Each partial store uses a fresh zero-filled line. The requested word
	@ arrives first, is merged, and must survive the three following beats.
	ldr	r7, =DATA + 0x100
	.irp word, 0, 1, 2, 3
	.irp byte, 0, 1, 2, 3
	mov	r0, #0xA5
	strb	r0, [r7, #(4*\word+\byte)]
	ldmia	r7, {r0-r3}
	CHECK	r\word, (0xA5 << (8*\byte))
	.irp other, 0, 1, 2, 3
	.if \other != \word
	CHECK	r\other, 0
	.endif
	.endr
	add	r7, r7, #16
	.endr
	.irp half, 0, 2
	ldr	r0, =0xA5C3
	strh	r0, [r7, #(4*\word+\half)]
	ldmia	r7, {r0-r3}
	CHECK	r\word, (0xA5C3 << (8*\half))
	.irp other, 0, 1, 2, 3
	.if \other != \word
	CHECK	r\other, 0
	.endif
	.endr
	add	r7, r7, #16
	.endr
	.endr
	CHECKPOINT
	NOABT
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg
