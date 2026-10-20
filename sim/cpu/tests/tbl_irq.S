@ SPDX-License-Identifier: GPL-3.0-or-later
@ Thumb BL pairs interrupted at every point (RTL only: bench interrupt
@ timer). The IRQ handler returns as the Symbian kernel's does: a CP15
@ write (the domain access register) and then LDM ^ with the PC. Every
@ call must arrive and return, whichever instruction the IRQ lands on
@ (the first half, between the halves, the second half alone).
@@ qemu: no
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_IRQ, irq_sym
	ldr	r11, =state
	ldr	r10, =BENCH
	mov	r9, #1			@ the IRQ's delay in cycles
	mov	r8, #0			@ calls made in all
1:	mov	r0, #0
	str	r0, [r11, #0]		@ IRQs taken this round
	str	r9, [r10, #BENCH_IRQ_IN]
	msr	cpsr_c, #(M_SVC | PSR_F)	@ IRQ on
	ldr	r0, =t_calls + 1
	bx	r0
	.ltorg

	.thumb
	.align	2
t_calls:
	mov	r4, #0
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	bl	t_inc
	ldr	r0, =a_back
	bx	r0
	.align	2
t_inc:
	add	r4, #1
	bx	lr
	.ltorg

	.arm
	.align	2
a_back:
	ldr	r0, [r11, #0]		@ wait for this round's IRQ if it is late
	cmp	r0, #0
	beq	a_back
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	CHECK	r4, 12
	add	r8, r8, r4
	add	r9, r9, #1
	cmp	r9, #120
	bne	1b
	mov	r0, #0
	str	r0, [r10, #BENCH_INT]
	CHECK	r8, 12 * 119
	CHECKPOINT
	ldmfd	sp!, {r4-r11, pc}

@ IRQ, returning as the Symbian kernel does (ekern 0x50321a84): a CP15
@ write, then LDM ^ loading the PC
irq_sym:
	sub	lr, lr, #4
	stmfd	sp!, {r0-r3, r12, lr}
	ldr	r0, =state
	ldr	r1, [r0, #0]
	add	r1, r1, #1
	str	r1, [r0, #0]
	ldr	r2, =BENCH
	mov	r1, #0
	str	r1, [r2, #BENCH_INT]
	mrc	p15, 0, r0, c3, c0, 0
	mcr	p15, 0, r0, c3, c0, 0
	ldmfd	sp!, {r0-r3, r12, pc}^

	.ltorg
	.data
	.align	2
state:	.space	16
