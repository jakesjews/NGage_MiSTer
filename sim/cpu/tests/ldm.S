@ SPDX-License-Identifier: GPL-3.0-or-later
@ LDM/STM: all four addressing modes with and without writeback, a single
@ register, the base first in an STM list, PC in an LDM list, the user
@ bank (^ without PC) from FIQ mode, exception return (^ with PC), and
@ data aborts part-way through (an external abort at the end of RAM):
@ the base register keeps its value (ARM9TDMI base-restored model), FSR
@ and FAR describe the first faulting word.
	.include "test.inc"
	.equ	RAM_END, 0x01000000	@ first address after the 16 MB of RAM
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_DABT, dabt_handler
	ldr	r0, =SCRATCH
	mov	r1, #1
	mov	r2, #2
	mov	r3, #3
	mov	r4, #4

	@ IA / IB / DA / DB, writeback
	mov	r5, r0
	stmia	r5!, {r1-r4}
	sub	r6, r5, r0
	CHECK	r6, 16
	ldr	r6, [r0, #12]
	CHECK	r6, 4
	add	r5, r0, #16
	stmib	r5!, {r1-r2}		@ +20, +24
	sub	r6, r5, r0
	CHECK	r6, 24
	ldr	r6, [r0, #24]
	CHECK	r6, 2
	add	r5, r0, #40
	stmda	r5!, {r1-r3}		@ +32, +36, +40
	sub	r6, r5, r0
	CHECK	r6, 28
	ldr	r6, [r0, #32]
	CHECK	r6, 1
	add	r5, r0, #56
	stmdb	r5!, {r3-r4}		@ +48, +52
	sub	r6, r5, r0
	CHECK	r6, 48
	ldr	r6, [r0, #52]
	CHECK	r6, 4
	CHECKPOINT
	mov	r5, r0
	ldmia	r5, {r7-r10}
	CHECK	r10, 4
	add	r5, r0, #16
	ldmib	r5!, {r7-r8}
	CHECK	r8, 2
	sub	r6, r5, r0
	CHECK	r6, 24
	add	r5, r0, #40
	ldmda	r5, {r7-r9}
	CHECK	r7, 1
	CHECK	r9, 3
	add	r5, r0, #56
	ldmdb	r5!, {r9-r10}
	CHECK	r9, 3
	sub	r6, r5, r0
	CHECK	r6, 48
	ldmia	r0, {r11}		@ one register
	CHECK	r11, 1
	CHECKPOINT

	@ base first in the list of an STM with writeback: the old base is stored
	add	r5, r0, #64
	mov	r6, r5
	stmia	r5!, {r5, r6}
	ldr	r7, [r0, #64]
	CHECKR	r7, r6
	sub	r7, r5, r0
	CHECK	r7, 72
	@ PC in the list: a branch
	adr	r7, 1f
	str	r7, [r0, #80]
	add	r5, r0, #76
	ldmia	r5, {r6, pc}
	FAIL
1:	CHECK	r6, 0			@ (+76 was never written: zero)
	CHECKPOINT

	@ user bank from FIQ mode: STM^/LDM^ without PC
	msr	cpsr_c, #(M_SYS | PSR_I | PSR_F)
	ldr	r8, =0x08080808
	ldr	r13, =0x0D0D0D0D
	ldr	r14, =0x0E0E0E0E
	msr	cpsr_c, #(M_FIQ | PSR_I | PSR_F)
	mov	r8, #0x88		@ FIQ bank
	mov	r13, #0xDD
	add	r5, r0, #96
	stmia	r5, {r8, r13, r14}^	@ user r8, r13, r14
	ldr	r6, [r5, #0]
	CHECK	r6, 0x08080808
	ldr	r6, [r5, #4]
	CHECK	r6, 0x0D0D0D0D
	CHECK	r8, 0x88		@ own bank untouched
	ldr	r6, =0x12345678
	str	r6, [r5, #0]
	ldmia	r5, {r8}^		@ into user r8
	nop
	CHECK	r8, 0x88
	msr	cpsr_c, #(M_SYS | PSR_I | PSR_F)
	CHECK	r8, 0x12345678
	ldr	r13, =STACK_USR
	mov	r14, #0
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	CHECKPOINT

	@ exception return: LDM^ with PC restores the CPSR from the SPSR
	msr	cpsr_c, #(M_ABT | PSR_I | PSR_F)
	mov	r6, #(M_SVC | PSR_I | PSR_F)
	orr	r6, r6, #0x40000000	@ Z
	msr	spsr_cxsf, r6
	adr	r6, 2f
	add	r5, r0, #112
	str	r6, [r5]
	ldmia	r5, {pc}^
	FAIL
2:	MRSN	r6, cpsr
	CHECK	r6, (M_SVC | PSR_I | PSR_F | 0x40000000)
	CHECKPOINT

	@ LDM aborting at its third word: base unchanged, first two loaded
	ldr	r9, =RAM_END - 8
	ldr	r1, =0x11111111
	ldr	r2, =0x22222222
	stmia	r9, {r1, r2}
	mov	r1, #0
	mov	r2, #0
	mov	r3, #0
	mov	r4, #0
	ldr	r11, =result
	mov	r10, r9
3:	ldmia	r10!, {r1-r4}
	ldr	r6, [r11, #0]		@ aborted
	CHECK	r6, 1
	CHECKR	r10, r9			@ base restored
	CHECK	r1, 0x11111111
	CHECK	r2, 0x22222222
	ldr	r6, [r11, #4]		@ LR_abt = instruction + 8
	adr	r7, 3b + 8
	CHECKR	r6, r7
	ldr	r6, [r11, #8]		@ FSR status: external abort
	and	r6, r6, #0xF
	CHECK	r6, 8
	ldr	r6, [r11, #12]		@ FAR = the first word that failed
	CHECK	r6, RAM_END
	CHECKPOINT

	@ the same with the base in the list (loaded before the abort): it
	@ still ends up with its old value
	mov	r6, #0
	str	r6, [r11, #0]
	sub	r1, r9, #4		@ base r1, list r1-r4, r1 loaded first
	mov	r8, r1
	str	r9, [r1]		@ the word that would go into r1
4:	ldmia	r1!, {r1-r4}
	ldr	r6, [r11, #0]
	CHECK	r6, 1
	CHECKR	r1, r8
	CHECKPOINT

	@ STM aborting at its third word: base unchanged, first two stored
	mov	r6, #0
	str	r6, [r11, #0]
	ldr	r1, =0xAAAAAAAA
	ldr	r2, =0xBBBBBBBB
	mov	r10, r9
5:	stmia	r10!, {r1-r4}
	ldr	r6, [r11, #0]
	CHECK	r6, 1
	CHECKR	r10, r9
	ldr	r6, [r9]
	CHECK	r6, 0xAAAAAAAA
	ldr	r6, [r9, #4]
	CHECK	r6, 0xBBBBBBBB
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}

@ data abort handler: result[0] = 1, [1] = LR, [2] = FSR, [3] = FAR; skip
@ the aborted instruction
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
	ldmfd	sp!, {r0-r1}
	subs	pc, lr, #4

	.ltorg
	.data
	.align	2
result:	.space	16
