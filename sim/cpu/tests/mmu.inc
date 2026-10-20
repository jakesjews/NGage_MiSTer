@ SPDX-License-Identifier: GPL-3.0-or-later
@ MMU helpers for the tests: a level-1 table at TTB with the 16 MB of RAM
@ identity-mapped as sections (AP 11, domain 0, uncached), an abort
@ handler that records what happened, and the macros the tests use.
@
@ ab_state (the data area): +0 aborts taken, +4 LR, +8 FSR, +12 FAR,
@ +16 SPSR, +20 where a prefetch abort resumes, +24 kind (1 data, 2 prefetch)

	@ section descriptor
	.macro	SECT reg, pa, ap, dom, cb
	ldr	\reg, =((\pa & 0xFFF00000) | (\ap << 10) | (\dom << 5) | 0x10 | (\cb << 2) | 2)
	.endm

	@ L1 entry for va := reg (r12 used)
	.macro	SETL1 va, reg
	ldr	r12, =TTB + ((\va >> 20) << 2)
	str	\reg, [r12]
	.endm

	@ the access just before this macro must have taken a data abort with
	@ this FSR and FAR (r10, r12 used); clears the record
	.macro	DABT fsr, far
	ldr	r10, =ab_state
	ldr	r12, [r10, #0]
	CHECK	r12, 1
	ldr	r12, [r10, #24]
	CHECK	r12, 1
	ldr	r12, [r10, #8]
	and	r12, r12, #0xFF
	CHECK	r12, \fsr
	ldr	r10, =ab_state
	ldr	r12, [r10, #12]
	ldr	r10, =\far
	CHECKR	r12, r10
	bl	ab_clear
	.endm

	@ the access just before must not have aborted
	.macro	NOABT
	ldr	r10, =ab_state
	ldr	r12, [r10, #0]
	CHECK	r12, 0
	.endm

	@ flush both TLBs (r12)
	.macro	TLBFLUSH
	mov	r12, #0
	mcr	p15, 0, r12, c8, c7, 0
	.endm

	.text
	.arm
@ mmu_on: identity sections for the RAM, DACR = domain 0 client, MMU on
mmu_on:
	stmfd	sp!, {r0-r3, lr}
	ldr	r0, =TTB
	mov	r1, #0
	mov	r2, #4096
1:	str	r1, [r0], #4
	subs	r2, r2, #1
	bne	1b
	ldr	r0, =TTB
	ldr	r1, =(0x00000C12)	@ PA 0, AP 11, domain 0, C=B=0, section
	mov	r2, #16
2:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	2b
	ldr	r0, =TTB
	mcr	p15, 0, r0, c2, c0, 0
	mov	r0, #1
	mcr	p15, 0, r0, c3, c0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c8, c7, 0
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #CR_M
	mcr	p15, 0, r0, c1, c0, 0
	bl	ab_clear
	VECTOR	VEC_DABT, ab_dabt
	VECTOR	VEC_PABT, ab_pabt
	ldmfd	sp!, {r0-r3, pc}

ab_clear:
	stmfd	sp!, {r0, r1}
	ldr	r0, =ab_state
	mov	r1, #0
	str	r1, [r0, #0]
	str	r1, [r0, #24]
	ldmfd	sp!, {r0, r1}
	mov	pc, lr

@ data abort: record, skip the instruction (ARM state only)
ab_dabt:
	stmfd	sp!, {r0, r1}
	ldr	r0, =ab_state
	ldr	r1, [r0, #0]
	add	r1, r1, #1
	str	r1, [r0, #0]
	str	lr, [r0, #4]
	mrc	p15, 0, r1, c5, c0, 0
	str	r1, [r0, #8]
	mrc	p15, 0, r1, c6, c0, 0
	str	r1, [r0, #12]
	MRSN	r1, spsr
	str	r1, [r0, #16]
	mov	r1, #1
	str	r1, [r0, #24]
	ldmfd	sp!, {r0, r1}
	subs	pc, lr, #4

@ prefetch abort: record, resume at ab_state+20
ab_pabt:
	stmfd	sp!, {r0, r1}
	ldr	r0, =ab_state
	ldr	r1, [r0, #0]
	add	r1, r1, #1
	str	r1, [r0, #0]
	str	lr, [r0, #4]
	mov	r1, #2
	str	r1, [r0, #24]
	ldr	lr, [r0, #20]
	ldmfd	sp!, {r0, r1}
	movs	pc, lr

	.ltorg
	.data
	.align	2
ab_state:	.space	32
	.text
