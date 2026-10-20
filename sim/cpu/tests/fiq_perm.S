@ SPDX-License-Identifier: GPL-3.0-or-later
@ A privileged FIQ handler storing to a section that user mode may not
@ touch (AP 01), with the FIQ arriving around the kernel's return to user
@ mode (MSR SPSR, MOV LR, PC, MOVS PC, LR) and in user code (RTL only:
@ bench interrupt timer). The handler's accesses must be checked in FIQ
@ mode, never as user: no aborts. The handler's sequence is the firmware
@ flash driver's (medint.pdd 0x50380404: a load that may miss, three
@ halfword command writes and the data, and MOVEQS PC, LR right after,
@ back to user mode).
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	DEV, 0x10000000			@ VA of the AP 01 section
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_FIQ, fiq_h
	VECTOR	VEC_SWI, swi_h
	bl	mmu_on
	SECT	r1, 0x00400000, 1, 1, 0		@ AP 01, domain 1, uncached
	SETL1	DEV, r1
	SECT	r1, BENCH, 3, 0, 0			@ the bench registers
	SETL1	BENCH, r1
	mov	r0, #0x5			@ domains 0 and 1: client
	mcr	p15, 0, r0, c3, c0, 0
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r11, =state
	ldr	r10, =BENCH
	mov	r4, #1				@ the FIQ's delay
1:	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0		@ the control block misses again
	str	r4, [r10, #BENCH_FIQ_IN]
	@ the kernel's return to user mode, FIQ and IRQ enabled there
	mov	r0, #M_USR
	msr	spsr_fc, r0
	adr	lr, u_code
	movs	pc, lr
u_code:						@ user mode
	ldr	r0, [r11, #0]
	cmp	r0, r4
	blo	u_code				@ until this round's FIQ
	swi	0				@ back to SVC
	add	r4, r4, #1
	cmp	r4, #90
	bne	1b
	mov	r0, #0
	str	r0, [r10, #BENCH_INT]
	ldr	r0, =ab_state
	ldr	r0, [r0, #0]
	CHECK	r0, 0				@ no aborts
	ldr	r0, [r11, #0]
	CHECK	r0, 89
	ldr	r0, =DEV + 0x100
	ldrh	r0, [r0]
	CHECK	r0, 0x1234			@ the handler's data store
	CHECKPOINT
	ldmfd	sp!, {r4-r11, pc}

@ SWI from user code: continue after it in SVC mode, interrupts masked
swi_h:
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	mov	pc, lr

fiq_h:
	sub	lr, lr, #4
	ldr	r10, =BENCH			@ drop the line first
	mov	r11, #0
	str	r11, [r10, #BENCH_INT]
	ldr	r11, [r10, #BENCH_INT]
	ldr	r8, =state
	ldr	r9, [r8, #0]
	add	r9, r9, #1
	str	r9, [r8, #0]
	ldr	ip, =cblk
	ldm	ip, {r8, sl}			@ limit, data address
	mov	r9, #0
	cmp	r9, r8
	ldrls	r8, [ip, #8]			@ the command address (may miss)
	add	r9, sl, r9
	ldr	fp, =0x00001234
	lsrs	sl, fp, #16			@ Z = 1
	mov	sl, #0xaa
	strh	sl, [r8]
	sub	r8, r8, #0x600
	mov	sl, #0x55
	strh	sl, [r8, #0xaa]
	add	r8, r8, #0x600
	mov	sl, #0xa0
	strh	sl, [r8]
	strh	fp, [r9]
	moveqs	pc, lr				@ back to user mode right after
	b	.

	.ltorg
	.data
	.align	4
cblk:	.word	0x7FFFFFFF, DEV + 0x100, DEV + 0xAAA, 0
state:	.space	16
