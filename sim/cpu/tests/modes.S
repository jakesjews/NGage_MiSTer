@ SPDX-License-Identifier: GPL-3.0-or-later
@ PSRs and modes: MRS/MSR with every field mask, immediate and register
@ forms, SPSR per mode, banked r8-r12 (FIQ) and r13/r14 (every mode),
@ USR mode cannot change the control bits, ARMv4 PSRs have no Q bit,
@ SWP and SWPB.
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_SWI, swi_back

	@ flags field only
	msr	cpsr_f, #0xF0000000
	MRSN	r0, cpsr
	CHECK	r0, (0xF0000000 | M_SVC | PSR_I | PSR_F)
	ldr	r1, =0x50000000
	msr	cpsr_f, r1
	MRSN	r0, cpsr
	CHECK	r0, (0x50000000 | M_SVC | PSR_I | PSR_F)
	@ Q (bit 27) and the reserved bits do not exist on ARMv4 (bit 8 is
	@ left alone: QEMU would keep it, as the ARMv6 A bit)
	ldr	r1, =0x0F00FE00
	msr	cpsr_fsx, r1
	MRSN	r0, cpsr
	CHECK	r0, (M_SVC | PSR_I | PSR_F)
	CHECKPOINT

	@ every mode's r13, r14 and SPSR are its own; FIQ has its own r8-r12
	mov	r8, #8
	mov	r12, #12
	msr	cpsr_c, #(M_FIQ | PSR_I | PSR_F)
	mov	r8, #0x80
	mov	r12, #0xC0
	mov	r13, #0x13
	mov	r14, #0x14
	ldr	r1, =(0x10000000 | M_FIQ)
	msr	spsr_cxsf, r1
	msr	cpsr_c, #(M_IRQ | PSR_I | PSR_F)
	mov	r13, #0x23
	mov	r14, #0x24
	ldr	r1, =(0x20000000 | M_IRQ)
	msr	spsr_cxsf, r1
	CHECK	r8, 8			@ IRQ sees the user r8 (CHECK uses r12)
	msr	cpsr_c, #(M_ABT | PSR_I | PSR_F)
	mov	r13, #0x33
	mov	r14, #0x34
	ldr	r1, =(0x40000000 | M_ABT)
	msr	spsr_cxsf, r1
	msr	cpsr_c, #(M_UND | PSR_I | PSR_F)
	mov	r13, #0x43
	mov	r14, #0x44
	ldr	r1, =(0x80000000 | M_UND)
	msr	spsr_cxsf, r1
	msr	cpsr_c, #(M_FIQ | PSR_I | PSR_F)
	mov	r0, r8
	mov	r1, r12
	mov	r2, r13
	mov	r3, r14
	MRSN	r4, spsr
	msr	cpsr_c, #(M_IRQ | PSR_I | PSR_F)
	mov	r5, r13
	mov	r6, r14
	MRSN	r7, spsr
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	CHECK	r0, 0x80
	CHECK	r1, 0xC0
	CHECK	r2, 0x13
	CHECK	r3, 0x14
	CHECK	r4, (0x10000000 | M_FIQ)
	CHECK	r5, 0x23
	CHECK	r6, 0x24
	CHECK	r7, (0x20000000 | M_IRQ)
	CHECK	r8, 8
	msr	cpsr_c, #(M_ABT | PSR_I | PSR_F)
	mov	r0, r13
	MRSN	r1, spsr
	msr	cpsr_c, #(M_UND | PSR_I | PSR_F)
	mov	r2, r14
	MRSN	r3, spsr
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	CHECK	r0, 0x33
	CHECK	r1, (0x40000000 | M_ABT)
	CHECK	r2, 0x44
	CHECK	r3, (0x80000000 | M_UND)
	CHECKPOINT
	@ put the other modes' stacks back
	msr	cpsr_c, #(M_FIQ | PSR_I | PSR_F)
	ldr	sp, =STACK_FIQ
	msr	cpsr_c, #(M_IRQ | PSR_I | PSR_F)
	ldr	sp, =STACK_IRQ
	msr	cpsr_c, #(M_ABT | PSR_I | PSR_F)
	ldr	sp, =STACK_ABT
	msr	cpsr_c, #(M_UND | PSR_I | PSR_F)
	ldr	sp, =STACK_UND
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)

	@ SPSR field writes
	ldr	r1, =0xFFFFFFFF
	msr	spsr_f, r1
	MRSN	r0, spsr
	CHECK	r0, (0xF0000000 | M_USR)
	ldr	r1, =(M_SYS | PSR_T)
	msr	spsr_c, r1
	MRSN	r0, spsr
	CHECK	r0, (0xF0000000 | M_SYS | PSR_T)
	mov	r1, #M_USR
	msr	spsr_cxsf, r1
	CHECKPOINT

	@ USR mode: the flags can change, the control byte cannot
	msr	cpsr_c, #M_USR
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)	@ ignored
	MRSN	r0, cpsr
	and	r0, r0, #0xFF
	CHECK	r0, M_USR
	msr	cpsr_f, #0x30000000
	MRSN	r0, cpsr
	CHECK	r0, (0x30000000 | M_USR)
	swi	0			@ back to SVC through the handler below
	CHECKPOINT

	@ SWP and SWPB
	ldr	r4, =SCRATCH
	ldr	r1, =0x11223344
	str	r1, [r4]
	ldr	r2, =0xAABBCCDD
	swp	r3, r2, [r4]
	CHECK	r3, 0x11223344
	ldr	r0, [r4]
	CHECK	r0, 0xAABBCCDD
	mov	r2, #0x5A
	add	r5, r4, #2
	swpb	r3, r2, [r5]
	CHECK	r3, 0xBB
	ldr	r0, [r4]
	CHECK	r0, 0xAA5ACCDD
	swp	r3, r3, [r4]		@ same register for both
	CHECK	r3, 0xAA5ACCDD
	ldr	r0, [r4]
	CHECK	r0, 0xBB
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}

	.ltorg

	.section .text.handler, "ax"
	.global	swi_back
swi_back:				@ SWI 0: return in SVC mode
	mrs	r12, spsr
	bic	r12, r12, #0x1F
	orr	r12, r12, #(M_SVC | PSR_I | PSR_F)
	msr	spsr_cxsf, r12
	movs	pc, lr
