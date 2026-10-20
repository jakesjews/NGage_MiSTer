@ SPDX-License-Identifier: GPL-3.0-or-later
@ SWI and undefined-instruction exceptions: entry (mode, LR, SPSR, I and F,
@ vector) and return, from SVC and from USR mode; which coprocessor
@ instructions are UNDEFINED (anything but MCR/MRC to CP15 in a privileged
@ mode); a failed condition never traps.
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_SWI, swi_handler
	VECTOR	VEC_UND, und_handler

	@ SWI from SVC with flags set: LR = next instruction, SPSR = CPSR
	ldr	r4, =result
	mov	r0, #0
	msr	cpsr_f, #0xF0000000	@ NZCV
	MRSN	r5, cpsr
1:	swi	0x123456
	CHECK	r0, 0x5A
	ldr	r1, [r4, #0]		@ LR seen by the handler
	adr	r2, 1b + 4
	CHECKR	r1, r2
	ldr	r1, [r4, #4]		@ SPSR seen by the handler
	CHECKR	r1, r5
	ldr	r1, [r4, #8]		@ CPSR in the handler
	CHECK	r1, (M_SVC | PSR_I | PSR_F | 0xF0000000)
	ldr	r1, [r4, #12]		@ the SWI's comment field
	CHECK	r1, 0x123456
	CHECKPOINT

	@ undefined instruction from SVC
	msr	cpsr_f, #0x40000000	@ Z
2:	.word	0xE7F000F0		@ permanently undefined
	CHECK	r0, 0xA5
	ldr	r1, [r4, #0]
	adr	r2, 2b + 4
	CHECKR	r1, r2
	ldr	r1, [r4, #8]
	CHECK	r1, (M_UND | PSR_I | PSR_F | 0x40000000)
	ldr	r1, [r4, #16]
	CHECK	r1, 0xE7F000F0
	CHECKPOINT

	@ a failed condition never traps
	mov	r0, #0
	msr	cpsr_f, #0		@ Z clear
	.word	0x07F000F0		@ "eq" form of the undefined instruction
	swieq	0x11
	CHECK	r0, 0
	CHECKPOINT

	@ from USR mode, with IRQ and FIQ enabled in the CPSR (no sources
	@ here): the handler sees mode USR in SPSR, I set, F unchanged
	msr	cpsr_c, #M_USR
	mov	r0, #0
3:	swi	0x42			@ flags from the last CHECK: Z C
	CHECK	r0, 0x5A
	ldr	r1, [r4, #4]
	CHECK	r1, (0x60000000 | M_USR)
	ldr	r1, [r4, #8]
	CHECK	r1, (0x60000000 | M_SVC | PSR_I)
	mov	r0, #0
4:	.word	0xE7F123F1
	CHECK	r0, 0xA5
	ldr	r1, [r4, #4]
	CHECK	r1, (0x60000000 | M_USR)
	ldr	r1, [r4, #8]
	CHECK	r1, (0x60000000 | M_UND | PSR_I)
	CHECKPOINT

	@ CP15 from user mode is UNDEFINED, as is every other coprocessor
	mov	r0, #0
	mrc	p15, 0, r1, c0, c0, 0
	CHECK	r0, 0xA5
	mov	r0, #0
	mcr	p15, 0, r1, c7, c7, 0
	CHECK	r0, 0xA5
	swi	0			@ back to SVC (handler below)
	MODE	M_SVC

	mov	r0, #0
	mrc	p6, 0, r1, c0, c0, 0		@ no coprocessor 6
	CHECK	r0, 0xA5
	mov	r0, #0
	mcr	p7, 0, r1, c1, c2, 3
	CHECK	r0, 0xA5
	mov	r0, #0
	cdp	p15, 0, c1, c2, c3, 0	@ CDP/LDC/STC to CP15
	CHECK	r0, 0xA5
	mov	r0, #0
	ldr	r5, =SCRATCH
	ldc	p15, c1, [r5]
	CHECK	r0, 0xA5
	mov	r0, #0
	stc	p15, c1, [r5]
	CHECK	r0, 0xA5
	mov	r0, #0
	cdp	p2, 1, c1, c2, c3, 4
	CHECK	r0, 0xA5
	CHECKPOINT

	@ conditional coprocessor instructions that fail do nothing
	mov	r0, #0
	cmp	r0, #1			@ Z clear
	mrceq	p14, 0, r1, c0, c0, 0
	cdpeq	p15, 0, c1, c2, c3, 0
	mrceq	p15, 0, r0, c0, c0, 0	@ privileged, but not executed
	CHECK	r0, 0
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}

@ SWI handler: r0 = 0x5A; result[0] = LR, [1] = SPSR, [2] = CPSR, [3] =
@ comment field. SWI 0 returns to the caller in SVC mode instead.
swi_handler:
	stmfd	sp!, {r1-r3}
	ldr	r1, =result
	str	lr, [r1, #0]
	MRSN	r2, spsr
	str	r2, [r1, #4]
	MRSN	r2, cpsr
	str	r2, [r1, #8]
	ldr	r2, [lr, #-4]
	bic	r2, r2, #0xFF000000
	str	r2, [r1, #12]
	mov	r0, #0x5A
	cmp	r2, #0
	ldmfd	sp!, {r1-r3}
	movnes	pc, lr
	@ SWI 0: return in SVC mode with interrupts masked
	mrs	r12, spsr
	bic	r12, r12, #0x1F
	orr	r12, r12, #(M_SVC | PSR_I | PSR_F)
	msr	spsr_cxsf, r12
	movs	pc, lr

@ UND handler: r0 = 0xA5; result[0] = LR, [1] = SPSR, [2] = CPSR, [4] =
@ the instruction
und_handler:
	stmfd	sp!, {r1-r2}
	ldr	r1, =result
	str	lr, [r1, #0]
	MRSN	r2, spsr
	str	r2, [r1, #4]
	MRSN	r2, cpsr
	str	r2, [r1, #8]
	ldr	r2, [lr, #-4]
	str	r2, [r1, #16]
	mov	r0, #0xA5
	ldmfd	sp!, {r1-r2}
	movs	pc, lr

	.ltorg
	.data
	.align	2
result:	.space	32
