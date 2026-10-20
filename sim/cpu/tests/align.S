@ SPDX-License-Identifier: GPL-3.0-or-later
@ Alignment faults with control bit A set (MMU off): misaligned word
@ accesses (LDR, STR, LDM, STM, SWP, Thumb LDR) and halfword accesses
@ (LDRH, LDRSH, STRH) take a data abort with FSR status 0b0001 and FAR =
@ the address; nothing is loaded or stored and the base is not written
@ back; bytes never fault.
	.include "test.inc"

	@ ATRY n: the instruction before this macro must abort; check FSR/FAR
	.macro	ATRY far
	ldr	r12, [r11, #0]
	CHECK	r12, 1
	ldr	r12, [r11, #8]
	CHECK	r12, 1			@ FSR: alignment, domain 0
	ldr	r12, [r11, #12]
	ldr	r10, =\far
	CHECKR	r12, r10
	mov	r12, #0
	str	r12, [r11, #0]
	.endm

	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_DABT, dabt_handler
	ldr	r11, =result
	ldr	r0, =SCRATCH
	ldr	r1, =0x11223344
	str	r1, [r0]
	str	r1, [r0, #4]
	mrc	p15, 0, r2, c1, c0, 0
	orr	r2, r2, #CR_A
	mcr	p15, 0, r2, c1, c0, 0

	mov	r3, #0x77
1:	ldr	r3, [r0, #1]
	ATRY	SCRATCH + 1
	CHECK	r3, 0x77		@ not loaded
	ldr	r12, [r11, #4]		@ LR_abt = instruction + 8
	adr	r10, 1b + 8
	CHECKR	r12, r10
	mvn	r3, #0
	str	r3, [r0, #2]
	ATRY	SCRATCH + 2
	ldr	r4, [r0]
	CHECK	r4, 0x11223344		@ not stored
	ldrh	r3, [r0, #1]
	ATRY	SCRATCH + 1
	ldrsh	r3, [r0, #3]
	ATRY	SCRATCH + 3
	strh	r3, [r0, #5]
	ATRY	SCRATCH + 5
	CHECKPOINT

	@ bytes and aligned halfwords are fine
	ldrb	r3, [r0, #1]
	CHECK	r3, 0x33
	strb	r3, [r0, #7]
	ldrh	r3, [r0, #2]
	CHECK	r3, 0x1122
	ldr	r3, [r11, #0]
	CHECK	r3, 0
	CHECKPOINT

	@ writeback is not done when the access faults
	add	r5, r0, #1
	ldr	r3, [r5], #4
	ATRY	SCRATCH + 1
	sub	r6, r5, r0
	CHECK	r6, 1
	ldr	r3, [r5, #4]!
	ATRY	SCRATCH + 5
	sub	r6, r5, r0
	CHECK	r6, 1
	CHECKPOINT

	@ LDM/STM and SWP are word accesses; SWPB is not
	add	r5, r0, #2
	mov	r6, #0x55
	ldmia	r5!, {r6, r7}
	ATRY	SCRATCH + 2
	CHECK	r6, 0x55
	sub	r6, r5, r0
	CHECK	r6, 2
	stmdb	r5, {r6, r7}
	ATRY	SCRATCH - 6
	ldr	r4, [r0]
	CHECK	r4, 0x11223344
	add	r5, r0, #1
	swp	r3, r1, [r5]
	ATRY	SCRATCH + 1
	mov	r3, #0x99
	swpb	r4, r3, [r5]
	CHECK	r4, 0x33
	CHECKPOINT

	@ Thumb LDR at a misaligned address
	ldr	r3, =t_code + 1
	add	r5, r0, #6
	bx	r3
	.thumb
	.align	2
t_code:
	ldr	r2, [r5, #0]
	ldr	r3, =a_back
	bx	r3
	.ltorg
	.arm
	.align	2
a_back:
	ATRY	SCRATCH + 6

	@ A off again: no fault (the access itself is checked in align_rot.S)
	bic	r2, r2, #CR_A
	mrc	p15, 0, r2, c1, c0, 0
	bic	r2, r2, #CR_A
	mcr	p15, 0, r2, c1, c0, 0
	CHECKPOINT
	ldmfd	sp!, {r4-r11, pc}

@ data abort: result[0] = 1, [1] = LR, [2] = FSR, [3] = FAR; skip it
dabt_handler:
	stmfd	sp!, {r0-r1}
	ldr	r0, =result
	mov	r1, #1
	str	r1, [r0, #0]
	str	lr, [r0, #4]
	mrc	p15, 0, r1, c5, c0, 0
	str	r1, [r0, #8]
	mrc	p15, 0, r1, c6, c0, 0
	str	r1, [r0, #12]
	MRSN	r1, spsr
	tst	r1, #PSR_T
	ldmfd	sp!, {r0-r1}
	subeqs	pc, lr, #4		@ ARM: next instruction
	subs	pc, lr, #6		@ Thumb: next instruction

	.ltorg
	.data
	.align	2
result:	.space	16
