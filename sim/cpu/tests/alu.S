@ SPDX-License-Identifier: GPL-3.0-or-later
@ Data processing: every opcode, flag results, carry in, PC as an operand,
@ conditions. (CHECK changes the flags, so flags are read before checking.)
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {lr}

	@ ADD/ADC/SUB/SBC/RSB/RSC with flags
	ldr	r0, =0x7FFFFFFF
	mov	r1, #1
	adds	r2, r0, r1		@ overflow: N=1 V=1
	MRSN	r3, cpsr
	CHECK	r2, 0x80000000
	and	r3, r3, #0xF0000000
	CHECK	r3, 0x90000000
	CHECKPOINT

	mvn	r0, #0
	adds	r2, r0, #1		@ 0: Z=1 C=1
	MRSN	r3, cpsr
	adc	r4, r1, r1		@ 1 + 1 + C = 3
	and	r3, r3, #0xF0000000
	CHECK	r3, 0x60000000
	CHECK	r4, 3

	mov	r0, #5
	subs	r2, r0, #7		@ -2: N=1 C=0 (borrow)
	MRSN	r3, cpsr
	sbc	r4, r0, #1		@ 5 - 1 - !C = 3
	rsc	r7, r0, #10		@ 10 - 5 - !C = 4
	CHECK	r2, 0xFFFFFFFE
	and	r3, r3, #0xF0000000
	CHECK	r3, 0x80000000
	CHECK	r4, 3
	CHECK	r7, 4
	subs	r6, r0, r0		@ 0: Z=1 C=1
	sbc	r4, r0, #1		@ 5 - 1 - 0 = 4
	rsc	r7, r0, #10		@ 10 - 5 - 0 = 5
	CHECK	r4, 4
	CHECK	r7, 5
	rsb	r5, r0, #100
	CHECK	r5, 95
	rsbs	r5, r0, #0		@ -5: N=1 C=0
	MRSN	r3, cpsr
	and	r3, r3, #0xF0000000
	CHECK	r3, 0x80000000
	CHECKPOINT

	@ logic ops and the shifter carry
	ldr	r0, =0xF0F0F0F0
	ldr	r1, =0x0FF00FF0
	and	r2, r0, r1
	CHECK	r2, 0x00F000F0
	eor	r2, r0, r1
	CHECK	r2, 0xFF00FF00
	orr	r2, r0, r1
	CHECK	r2, 0xFFF0FFF0
	bic	r2, r0, r1
	CHECK	r2, 0xF000F000
	mvn	r2, r1
	CHECK	r2, 0xF00FF00F
	cmp	r0, r0			@ Z=1 C=1 N=0 V=0
	movs	r2, r0, lsl #1		@ C = old bit 31 = 1, N=1, V kept
	MRSN	r3, cpsr
	CHECK	r2, 0xE1E1E1E0
	and	r3, r3, #0xF0000000
	CHECK	r3, 0xA0000000
	ands	r2, r1, #0		@ Z=1, C kept (no rotation)
	MRSN	r3, cpsr
	and	r3, r3, #0xF0000000
	CHECK	r3, 0x60000000
	CHECKPOINT

	@ compares
	mov	r0, #3
	cmp	r0, #3
	moveq	r1, #1
	movne	r1, #2
	CHECK	r1, 1
	cmn	r0, #3
	movpl	r1, #4
	CHECK	r1, 4
	tst	r0, #4
	moveq	r1, #5
	CHECK	r1, 5
	teq	r0, #3
	moveq	r1, #6
	CHECK	r1, 6
	CHECKPOINT

	@ every condition after one compare: 0 vs -1 is unsigned lower and
	@ signed greater
	mov	r0, #0
	mvn	r1, #0
	mov	r2, #0
	cmp	r0, r1
	orrhi	r2, r2, #0x001
	orrls	r2, r2, #0x002
	orrge	r2, r2, #0x004
	orrlt	r2, r2, #0x008
	orrgt	r2, r2, #0x010
	orrle	r2, r2, #0x020
	orrcs	r2, r2, #0x040
	orrcc	r2, r2, #0x080
	orrmi	r2, r2, #0x100
	orrpl	r2, r2, #0x200
	orrvs	r2, r2, #0x400
	orrvc	r2, r2, #0x800
	CHECK	r2, 0x0A96
	@ and with V set: 0x80000000 - 1
	mov	r0, #0x80000000
	mov	r2, #0
	cmp	r0, #1			@ N=0 Z=0 C=1 V=1
	orrhi	r2, r2, #0x001
	orrls	r2, r2, #0x002
	orrge	r2, r2, #0x004
	orrlt	r2, r2, #0x008
	orrgt	r2, r2, #0x010
	orrle	r2, r2, #0x020
	orrcs	r2, r2, #0x040
	orrcc	r2, r2, #0x080
	orrmi	r2, r2, #0x100
	orrpl	r2, r2, #0x200
	orrvs	r2, r2, #0x400
	orrvc	r2, r2, #0x800
	CHECK	r2, 0x0669
	CHECKPOINT

	@ PC as an operand reads as the instruction's address + 8
	adr	r0, 1f
1:	mov	r1, pc
	sub	r1, r1, r0
	CHECK	r1, 8
	add	r2, pc, #4
	sub	r2, r2, pc		@ (a + 8 + 4) - (a + 4 + 8)
	CHECK	r2, 0

	@ rotated immediates; MOVS with a rotated immediate sets C from bit 31
	mov	r0, #0xFF000000
	CHECK	r0, 0xFF000000
	mov	r0, #0x3FC
	CHECK	r0, 0x3FC
	movs	r0, #0x80000000
	MRSN	r3, cpsr
	and	r3, r3, #0xF0000000
	CHECK	r3, 0xA0000000
	CHECKPOINT

	@ data processing that writes PC
	adr	r0, 2f
	mov	pc, r0
	FAIL
2:	mov	r1, #0
	add	pc, pc, r1		@ lands two instructions on
	b	3f
	b	4f
3:	FAIL
4:	adr	r0, 5f
	sub	pc, r0, #0
	FAIL
5:	CHECKPOINT

	ldmfd	sp!, {pc}
	.ltorg
