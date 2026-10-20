@ SPDX-License-Identifier: GPL-3.0-or-later
@ Multiplies: MUL, MLA, UMULL, UMLAL, SMULL, SMLAL, with and without S.
@ After a flag-setting multiply only N and Z are defined on ARMv4 (C and V
@ are UNPREDICTABLE), so only those are checked.
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}

	ldr	r0, =0x12345678
	ldr	r1, =0x9ABCDEF0
	mul	r2, r0, r1
	CHECK	r2, 0x242D2080
	mov	r3, #7
	mla	r4, r0, r3, r1		@ 7 * r0 + r1
	CHECK	r4, 0x1A2B3C38
	mvn	r5, #0			@ -1
	mul	r6, r5, r5
	CHECK	r6, 1
	mov	r7, #0
	muls	r6, r0, r7		@ 0: Z=1
	MRSN	r8, cpsr
	and	r8, r8, #0xC0000000
	CHECK	r8, 0x40000000
	muls	r6, r5, r0		@ negative: N=1
	MRSN	r8, cpsr
	and	r8, r8, #0xC0000000
	CHECK	r8, 0x80000000
	CHECK	r6, 0xEDCBA988
	CHECKPOINT

	@ multiplier operands that end early on an ARM9TDMI (small Rs)
	mov	r3, #0x7F
	mul	r2, r0, r3
	CHECK	r2, 0x07F6E588
	ldr	r3, =0xFFFFFF80		@ -128
	mul	r2, r0, r3
	CHECK	r2, 0xE5D4C400
	ldr	r3, =0x00FFFFFF
	mul	r2, r0, r3
	CHECK	r2, 0x65CBA988
	CHECKPOINT

	@ long multiplies
	umull	r2, r3, r0, r1		@ 0x0B00EA4E_242D2080
	CHECK	r2, 0x242D2080
	CHECK	r3, 0x0B00EA4E
	smull	r2, r3, r0, r1		@ r1 is negative
	CHECK	r2, 0x242D2080
	CHECK	r3, 0xF8CC93D6
	mov	r2, #1
	mov	r3, #2
	umlal	r2, r3, r0, r1
	CHECK	r2, 0x242D2081
	CHECK	r3, 0x0B00EA50
	mvn	r2, #0
	mov	r3, #0
	smlal	r2, r3, r5, r5		@ (-1 * -1) + 0xFFFFFFFF = 0x1_00000000
	CHECK	r2, 0
	CHECK	r3, 1
	umulls	r2, r3, r5, r5		@ 0xFFFFFFFE_00000001: N=1
	MRSN	r8, cpsr
	and	r8, r8, #0xC0000000
	CHECK	r8, 0x80000000
	CHECK	r2, 1
	CHECK	r3, 0xFFFFFFFE
	mov	r2, #0
	mov	r3, #0
	smlals	r2, r3, r7, r0		@ 0: Z=1
	MRSN	r8, cpsr
	and	r8, r8, #0xC0000000
	CHECK	r8, 0x40000000
	mov	r2, #0
	mov	r3, #0
	umlals	r2, r3, r5, r7		@ 0 (Z only if both halves are 0)
	MRSN	r8, cpsr
	and	r8, r8, #0xC0000000
	CHECK	r8, 0x40000000
	CHECKPOINT

	@ multiply results used at once (forwarding)
	mov	r0, #3
	mov	r1, #5
	mul	r2, r0, r1
	add	r3, r2, r2
	mul	r4, r2, r3		@ 15 * 30
	CHECK	r4, 450
	umull	r5, r6, r4, r4
	adds	r7, r5, r6
	CHECK	r7, 202500
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}
	.ltorg
