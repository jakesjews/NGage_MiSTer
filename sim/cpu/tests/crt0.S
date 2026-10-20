@ SPDX-License-Identifier: GPL-3.0-or-later
@
@ Start-up for the CPU tests: vectors at 0 that jump through a writable
@ table (VEC_TABLE), the halt loop at 0x40 where the bench and QEMU stop,
@ reset code that gives every mode a stack and known registers, and the
@ pass/fail exit. See test.inc.
	.include "test.inc"

	.section .vectors, "ax"
	.arm
	.global	_start
_start:
	ldr	pc, vec_reset		@ 0x00
	ldr	pc, vec_und		@ 0x04
	ldr	pc, vec_swi		@ 0x08
	ldr	pc, vec_pabt		@ 0x0C
	ldr	pc, vec_dabt		@ 0x10
	ldr	pc, vec_rsvd		@ 0x14
	ldr	pc, vec_irq		@ 0x18
	ldr	pc, vec_fiq		@ 0x1C
vec_reset:	.word	reset_handler	@ 0x20 = VEC_TABLE
vec_und:	.word	unexpected_und
vec_swi:	.word	unexpected_swi
vec_pabt:	.word	unexpected_pabt
vec_dabt:	.word	unexpected_dabt
vec_rsvd:	.word	unexpected_rsvd
vec_irq:	.word	unexpected_irq
vec_fiq:	.word	unexpected_fiq
	.global	_halt
_halt:					@ 0x40
	b	_halt

	.text
	.arm
reset_handler:
	@ Known PSRs: every mode's SPSR holds USR mode, the A bit QEMU sets
	@ at reset is cleared (ARMv4 has no A bit).
	mov	r0, #M_USR
	msr	cpsr_cxsf, #(M_IRQ | PSR_I | PSR_F)
	ldr	sp, =STACK_IRQ
	mov	lr, #0
	msr	spsr_cxsf, r0
	msr	cpsr_cxsf, #(M_FIQ | PSR_I | PSR_F)
	ldr	sp, =STACK_FIQ
	mov	lr, #0
	mov	r8, #0
	mov	r9, #0
	mov	r10, #0
	mov	r11, #0
	mov	r12, #0
	msr	spsr_cxsf, r0
	msr	cpsr_cxsf, #(M_ABT | PSR_I | PSR_F)
	ldr	sp, =STACK_ABT
	mov	lr, #0
	msr	spsr_cxsf, r0
	msr	cpsr_cxsf, #(M_UND | PSR_I | PSR_F)
	ldr	sp, =STACK_UND
	mov	lr, #0
	msr	spsr_cxsf, r0
	msr	cpsr_cxsf, #(M_SYS | PSR_I | PSR_F)
	ldr	sp, =STACK_USR
	mov	lr, #0
	msr	cpsr_cxsf, #(M_SVC | PSR_I | PSR_F)
	ldr	sp, =STACK_SVC
	mov	lr, #0
	msr	spsr_cxsf, r0

	ldr	r0, =SIG_BASE
	mov	r1, #0
	str	r1, [r0]
	add	r2, r0, #0x100
	str	r2, [r0, #4]

	mov	r0, #0
	mov	r1, #0
	mov	r2, #0
	mov	r3, #0
	mov	r4, #0
	mov	r5, #0
	mov	r6, #0
	mov	r7, #0
	mov	r8, #0
	mov	r9, #0
	mov	r10, #0
	mov	r11, #0
	mov	r12, #0
	cmp	r0, #1			@ flags: N=0 Z=0 C=0 V=0
	bl	test_main
	b	test_pass

@ check_failed: r0 = value found, r1 = value expected, r2 = CHECK number,
@ lr = just after the failing CHECK
	.global	check_failed
check_failed:
	ldr	r3, =SIG_FAIL
	sub	lr, lr, #4
	stmia	r3, {r0, r1}
	str	lr, [r3, #8]
	ldr	r0, =0xBAD00000
	orr	r0, r0, r2
	b	test_exit

	.global	test_pass
test_pass:
	mov	r0, #1
	b	test_exit

@ test_exit: r0 = result. Store it, then (when privileged) clean the
@ D-cache and turn the MMU and caches off, so that memory holds everything
@ and the halt loop runs at its physical address.
	.global	test_exit
test_exit:
	ldr	r1, =SIG_BASE
	str	r0, [r1]
	mrs	r2, cpsr
	and	r2, r2, #0x1F
	cmp	r2, #M_USR
	beq	_halt
	mrc	p15, 0, r2, c1, c0, 0
	mov	r3, #0
	mcr	p15, 0, r3, c7, c10, 0		@ clean D-cache
	mcr	p15, 0, r3, c7, c10, 4		@ drain write buffer
	bic	r2, r2, #(CR_M | CR_C)
	bic	r2, r2, #(CR_I)
	mcr	p15, 0, r2, c1, c0, 0
	nop
	nop
	nop
	b	_halt

@ Unexpected exceptions end the test with 0xBAD0E0nn, nn = vector offset
unexpected_und:
	ldr	r2, =0xE004
	b	unexpected
unexpected_swi:
	ldr	r2, =0xE008
	b	unexpected
unexpected_pabt:
	ldr	r2, =0xE00C
	b	unexpected
unexpected_dabt:
	ldr	r2, =0xE010
	b	unexpected
unexpected_rsvd:
	ldr	r2, =0xE014
	b	unexpected
unexpected_irq:
	ldr	r2, =0xE018
	b	unexpected
unexpected_fiq:
	ldr	r2, =0xE01C
unexpected:
	mov	r0, lr
	mrs	r1, spsr
	bic	r1, r1, #0x100
	add	lr, lr, #4		@ check_failed reports lr - 4
	b	check_failed

	.ltorg
