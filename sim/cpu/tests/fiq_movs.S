@ SPDX-License-Identifier: GPL-3.0-or-later
@ FIQ at every point around a mode switch by MOVS PC, LR to the next
@ instruction (RTL only: bench interrupt timer), as the Symbian kernel
@ leaves an exception handler (ekern 0x50321614: MSR SPSR, MOV LR, PC,
@ MOVS PC, LR, BX LR in the new mode). The FIQ handler keeps state in its
@ banked r8-r12; the interrupted code's r8-r12 must not change, and the
@ handler's must persist from one FIQ to the next.
@@ qemu: no
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_FIQ, fiq_h
	mrc	p15, 0, r0, c1, c0, 0	@ I-cache on (MMU off): fetches cached
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r11, =state
	ldr	r10, =BENCH
	@ the FIQ bank: r8 = FIQs taken, r9 = &state, r10 = BENCH
	msr	cpsr_c, #(M_FIQ | PSR_I | PSR_F)
	mov	r8, #0
	ldr	r9, =state
	ldr	r10, =BENCH
	ldr	r12, =0xF1F1F1F1
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r8, =0x88888888
	ldr	r9, =0x99999999
	ldr	r12, =0xCCCCCCCC
	mov	r4, #1			@ the FIQ's delay
	mov	r5, #0			@ rounds
1:	str	r4, [r10, #BENCH_FIQ_IN]
	@ into UND mode (as a handler), FIQ masked, then back to SVC with
	@ FIQ on through MOVS PC, LR to the next instruction
	bl	switch_back
	@ wait for this round's FIQ if it is late
2:	ldr	r6, [r11, #0]
	cmp	r6, r5
	bls	2b
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, =0x88888888
	CHECKR	r8, r0
	ldr	r0, =0x99999999
	CHECKR	r9, r0
	ldr	r0, =0xCCCCCCCC
	CHECKR	r12, r0
	add	r5, r5, #1
	add	r4, r4, #1
	cmp	r4, #80
	bne	1b
	ldr	r0, [r11, #0]		@ FIQs counted by the handler in memory
	CHECK	r0, 79
	msr	cpsr_c, #(M_FIQ | PSR_I | PSR_F)
	mov	r0, r8			@ and in its banked r8
	ldr	r1, =0xF1F1F1F1
	cmp	r12, r1
	movne	r0, #0
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	CHECK	r0, 79
	mov	r0, #0
	str	r0, [r10, #BENCH_INT]
	CHECKPOINT
	ldmfd	sp!, {r4-r11, pc}

@ enter UND mode with the SVC return address in LR_svc, then leave it the
@ kernel's way: SPSR = SVC with FIQ enabled, MOV LR, PC, MOVS PC, LR
switch_back:
	mrs	r0, cpsr
	bic	r0, r0, #(0x1F | PSR_F)
	orr	r0, r0, #M_SVC		@ SVC, I set, F clear
	msr	cpsr_c, #(M_UND | PSR_I | PSR_F)
	msr	spsr_fc, r0
	mov	lr, pc
	movs	pc, lr
	bx	lr			@ SVC's LR: back to the caller

@ FIQ: count in the banked r8 and in memory, drop the line (read back,
@ then past the CPU's two-flop synchroniser, so it is not taken again)
fiq_h:
	add	r8, r8, #1
	str	r8, [r9, #0]
	mov	r11, #0
	str	r11, [r10, #BENCH_INT]
	ldr	r11, [r10, #BENCH_INT]
	nop
	nop
	nop
	nop
	subs	pc, lr, #4

	.ltorg
	.data
	.align	2
state:	.space	16
