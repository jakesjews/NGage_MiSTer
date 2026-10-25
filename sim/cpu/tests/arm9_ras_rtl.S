@ SPDX-License-Identifier: GPL-3.0-or-later
@ The return stack's top (V2's RAS_TOP_FF) and D2's redirect payload
@ (REDIRECT_PAYLOAD), every way the stack changes:
@   * nested calls 1-12 deep (the 8-entry stack wraps), then their returns,
@     by BL/MOV PC,LR, BL/BX LR, BL/LDMFD SP!,{PC}, and Thumb BL/POP {PC}
@   * a mispredicted conditional branch between a call and its return, and
@     a call in the shadow of a mispredicted branch (the stack repaired)
@   * an SWI between a call and its return (W's flush repairs the stack)
@   * unpredicted direct branches behind a load-use stall, so D2's redirect
@     waits for S
@ Each call adds its depth to r10; the totals are checked. Run with the
@ I-cache off, then on (cold and warm); the trace is compared with QEMU.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_SWI, swi_handler
	bl	runs
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	bl	runs
	bl	runs
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

swi_handler:
	add	r10, r10, #0x1000
	movs	pc, lr

runs:
	stmfd	sp!, {lr}
	.irp form, 0, 1, 2
	.irp depth, 1, 4, 8, 9, 12
	mov	r10, #0
	mov	r0, #\depth
	bl	nest\form
	CHECK	r10, ((\depth) * ((\depth) + 1) / 2)
	.endr
	.endr
	@ Thumb nesting
	.irp depth, 1, 8, 12
	mov	r10, #0
	mov	r0, #\depth
	ldr	r1, =tstub + 1
	mov	lr, pc
	bx	r1
	CHECK	r10, ((\depth) * ((\depth) + 1) / 2)
	.endr
	@ a mispredicted branch between call and return, alternating taken
	mov	r10, #0
	mov	r4, #8
1:	bl	mixed
	subs	r4, r4, #1
	bne	1b
	CHECK	r10, 8 * 3 + 4 * 2
	@ an SWI between a call and its return
	mov	r10, #0
	bl	swicall
	bl	swicall
	CHECK	r10, 2 * 0x1001
	@ unpredicted direct branches behind a load-use stall
	mov	r10, #0
	bl	stalled
	CHECK	r10, 15
	ldmfd	sp!, {pc}
	.ltorg

@ r0 = depth; each level adds its depth, calls deeper, returns
nest0:	add	r10, r10, r0
	subs	r0, r0, #1
	moveq	pc, lr
	stmfd	sp!, {r0, lr}
	bl	nest0
	ldmfd	sp!, {r0, lr}
	mov	pc, lr
nest1:	add	r10, r10, r0
	subs	r0, r0, #1
	bxeq	lr
	stmfd	sp!, {r0, lr}
	bl	nest1
	ldmfd	sp!, {r0, lr}
	bx	lr
nest2:	add	r10, r10, r0
	subs	r0, r0, #1
	moveq	pc, lr
	stmfd	sp!, {r0, lr}
	bl	nest2
	ldmfd	sp!, {r0, pc}

@ the low bit of r4 picks a direction the predictor saw the other way
mixed:	stmfd	sp!, {lr}
	add	r10, r10, #3
	tst	r4, #1
	bne	2f
	bl	leaf			@ a call after the branch, taken path only
	add	r10, r10, #2
	b	3f
2:	nop
3:	ldmfd	sp!, {pc}
leaf:	mov	pc, lr

swicall:
	stmfd	sp!, {lr}
	add	r10, r10, #1
	swi	0
	ldmfd	sp!, {pc}

stalled:
	stmfd	sp!, {r4, lr}
	ldr	r4, =T_WORDS
	ldr	r0, [r4]
	add	r1, r0, #1		@ load-use: S waits
	b	4f
	nop
4:	ldr	r0, [r4, #4]
	mov	r1, r0, lsl #1		@ an early consumer: S waits longer
	bl	5f
	add	r10, r10, #8
	ldmfd	sp!, {r4, pc}
5:	ldr	r0, [r4, #8]
	add	r10, r10, r0
	mov	pc, lr
	.ltorg

	.thumb
	.thumb_func
tstub:	push	{lr}			@ an ARM caller: return by BX
	bl	tnest
	pop	{r1}
	bx	r1
	.thumb_func
tnest:	add	r10, r0
	sub	r0, #1
	beq	6f
	push	{r0, lr}
	bl	tnest
	pop	{r0}
	pop	{pc}
6:	bx	lr
	.arm

	.data
	.align	2
T_WORDS: .word	0, 0, 7
