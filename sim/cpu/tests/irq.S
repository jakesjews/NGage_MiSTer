@ SPDX-License-Identifier: GPL-3.0-or-later
@ IRQ and FIQ (bench interrupt lines, RTL only): entry state (mode, LR,
@ SPSR, I and F), masking, the FIQ register bank, an FIQ nested in an IRQ
@ handler, interrupts in Thumb state, and a long computation interrupted
@ hundreds of times (the handler re-arms the bench timer) whose result
@ must come out exact.
@@ qemu: no
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_IRQ, irq_handler
	VECTOR	VEC_FIQ, fiq_handler
	ldr	r11, =state
	ldr	r10, =BENCH

	@ 1. IRQ while spinning in SVC mode
	mov	r0, #0
	str	r0, [r11, #0]		@ IRQ count
	mov	r0, #100
	str	r0, [r10, #BENCH_IRQ_IN]
	msr	cpsr_c, #(M_SVC | PSR_F)	@ IRQ on
	mov	r1, #0
1:	add	r1, r1, #1
	ldr	r0, [r11, #0]
	cmp	r0, #0
	beq	1b
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, [r11, #4]		@ SPSR seen by the handler (flags vary)
	bic	r0, r0, #0xF0000000
	CHECK	r0, (M_SVC | PSR_F)
	ldr	r0, [r11, #8]		@ CPSR in the handler
	and	r0, r0, #0xFF
	CHECK	r0, (M_IRQ | PSR_I | PSR_F)
	ldr	r0, [r11, #12]		@ LR_irq - 4 is in the loop
	sub	r0, r0, #4
	adr	r2, 1b
	sub	r0, r0, r2
	cmp	r0, #16
	movlo	r0, #1
	movhs	r0, #0
	CHECK	r0, 1
	CHECKPOINT

	@ 2. a masked IRQ waits; it is taken once I is cleared
	mov	r0, #0
	str	r0, [r11, #0]
	mov	r0, #1
	str	r0, [r10, #BENCH_INT]	@ IRQ line high now
	mov	r1, #50
2:	subs	r1, r1, #1
	bne	2b
	ldr	r0, [r11, #0]
	CHECK	r0, 0
	msr	cpsr_c, #(M_SVC | PSR_F)
	nop
	nop
	nop
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, [r11, #0]
	CHECK	r0, 1
	CHECKPOINT

	@ 3. FIQ: own r8-r12, F and I set on entry
	mov	r8, #0x88
	mov	r9, #0x99
	mov	r0, #0
	str	r0, [r11, #16]		@ FIQ count
	mov	r0, #80
	str	r0, [r10, #BENCH_FIQ_IN]
	msr	cpsr_c, #(M_SVC | PSR_I)	@ FIQ on
3:	ldr	r0, [r11, #16]
	cmp	r0, #0
	beq	3b
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	CHECK	r8, 0x88
	CHECK	r9, 0x99
	ldr	r0, [r11, #20]		@ CPSR in the FIQ handler
	and	r0, r0, #0xFF
	CHECK	r0, (M_FIQ | PSR_I | PSR_F)
	CHECKPOINT

	@ 4. FIQ nested in an IRQ handler
	mov	r0, #0
	str	r0, [r11, #0]
	str	r0, [r11, #16]
	mov	r0, #1
	str	r0, [r11, #24]		@ ask the IRQ handler to wait for an FIQ
	mov	r0, #60
	str	r0, [r10, #BENCH_IRQ_IN]
	msr	cpsr_c, #(M_SVC)	@ both on
4:	ldr	r0, [r11, #0]
	cmp	r0, #0
	beq	4b
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, [r11, #16]
	CHECK	r0, 1
	ldr	r0, [r11, #28]		@ the FIQ handler's SPSR: IRQ mode
	and	r0, r0, #0x1F
	CHECK	r0, M_IRQ
	mov	r0, #0
	str	r0, [r11, #24]
	CHECKPOINT

	@ 5. IRQ in Thumb state: SPSR has T, return goes back to Thumb
	mov	r0, #0
	str	r0, [r11, #0]
	ldr	r0, =t_spin + 1
	bx	r0
	.thumb
	.align	2
t_spin:
	ldr	r1, =state
	mov	r2, #0
	@ (IRQ is unmasked on the ARM side, then the timer is armed in Thumb)
	ldr	r0, =a_unmask
	bx	r0
	.align	2
t_arm:					@ arm the timer from Thumb state
	ldr	r0, =BENCH
	mov	r3, #60
	str	r3, [r0, #BENCH_IRQ_IN]
t_loop:
	add	r2, #1
	ldr	r0, [r1, #0]
	cmp	r0, #0
	beq	t_loop
	ldr	r0, =a_thumb_done
	bx	r0
	.ltorg
	.arm
	.align	2
a_unmask:
	msr	cpsr_c, #(M_SVC | PSR_F)
	ldr	r0, =t_arm + 1
	bx	r0
a_thumb_done:
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, [r11, #4]		@ SPSR: T set
	and	r0, r0, #PSR_T
	CHECK	r0, PSR_T
	ldr	r0, [r11, #12]		@ LR_irq - 4 is inside t_loop
	sub	r0, r0, #4
	ldr	r2, =t_loop
	sub	r0, r0, r2
	cmp	r0, #8
	movlo	r0, #1
	movhs	r0, #0
	CHECK	r0, 1
	CHECKPOINT

	@ 6. a computation interrupted many times must be exact: the IRQ
	@ handler re-arms the timer while r11[32] counts down
	mov	r0, #200
	str	r0, [r11, #32]
	mov	r0, #0
	str	r0, [r11, #0]
	mov	r0, #37
	str	r0, [r10, #BENCH_IRQ_IN]
	msr	cpsr_c, #(M_SVC | PSR_F)
	ldr	r4, =SCRATCH
	mov	r5, #0			@ checksum
	mov	r6, #0			@ i
	ldr	r7, =0x9E3779B9
6:	mul	r8, r6, r7
	add	r5, r5, r8, ror #7
	str	r5, [r4, r6, lsl #2]
	ldmia	r4, {r0-r3}
	eor	r5, r5, r0
	add	r6, r6, #1
	cmp	r6, #1024
	bne	6b
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, [r11, #0]
	cmp	r0, #100		@ it was interrupted often
	movhs	r0, #1
	movlo	r0, #0
	CHECK	r0, 1
	STORE_RESULT r5, 0
	CHECK	r5, 0xFEBDA720
	mov	r0, #0
	str	r0, [r10, #BENCH_INT]
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}

@ IRQ: count, record SPSR/CPSR/LR, drop the line; re-arm while r11[32] > 0;
@ if r11[24] is set, enable FIQ and wait for one first
irq_handler:
	stmfd	sp!, {r0-r3}
	ldr	r0, =state
	ldr	r1, [r0, #0]
	add	r1, r1, #1
	str	r1, [r0, #0]
	MRSN	r1, spsr
	str	r1, [r0, #4]
	MRSN	r1, cpsr
	str	r1, [r0, #8]
	str	lr, [r0, #12]
	ldr	r2, =BENCH
	mov	r1, #0
	str	r1, [r2, #BENCH_INT]
	ldr	r1, [r0, #24]
	cmp	r1, #0
	beq	1f
	mov	r1, #30
	str	r1, [r2, #BENCH_FIQ_IN]
	msr	cpsr_c, #(M_IRQ | PSR_I)	@ FIQ on
2:	ldr	r1, [r0, #16]
	cmp	r1, #0
	beq	2b
	msr	cpsr_c, #(M_IRQ | PSR_I | PSR_F)
1:	ldr	r1, [r0, #32]
	subs	r1, r1, #1
	blo	3f
	str	r1, [r0, #32]
	ldr	r3, =BENCH_IRQ_IN
	and	r1, r1, #63
	add	r1, r1, #20
	str	r1, [r2, r3]
3:	ldmfd	sp!, {r0-r3}
	subs	pc, lr, #4

@ FIQ: banked r8-r12 only
fiq_handler:
	ldr	r8, =state
	ldr	r9, [r8, #16]
	add	r9, r9, #1
	str	r9, [r8, #16]
	MRSN	r9, cpsr
	str	r9, [r8, #20]
	MRSN	r9, spsr
	str	r9, [r8, #28]
	ldr	r10, =BENCH
	mov	r9, #0
	str	r9, [r10, #BENCH_INT]
	mov	r8, #0
	mov	r9, #0
	mov	r10, #0
	subs	pc, lr, #4

	.ltorg
	.data
	.align	2
state:	.space	64
