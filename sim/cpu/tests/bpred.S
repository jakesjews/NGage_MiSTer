@ SPDX-License-Identifier: GPL-3.0-or-later
@ Branch prediction must never change what runs. A MOV PC, LR whose
@ branch-predictor entry holds the taken state of another address (same
@ index, other tag) gets no predicted target, so the fetch goes on past it
@ and the ALU must send it to LR. Upstream ZAP kept the predicted PC of an
@ older instruction for such a MOV and took the MOV as correctly predicted
@ when that equalled LR, which is what a conditional BL predicted not taken
@ leaves (BL + 4): the instructions after the MOV ran (found by the boot
@ bench in the kernel). The predictor has 512 entries indexed by address
@ bits 9:1, so addresses 1 KB apart share an entry.
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	mov	r4, #0
	mov	r0, #0
	@ train the entry of the MOV PC, LR in callee: a taken B 1 KB lower
	mov	r5, #8
1:	bl	trainer
	subs	r5, r5, #1
	bne	1b
	@ train the conditional BL as not taken, then take it once
	mov	r5, #4
2:	movs	r1, #0			@ Z set: BLNE not taken
	blne	callee
	subs	r5, r5, #1
	bne	2b
	CHECK	r0, 0
	movs	r1, #1			@ Z clear: BLNE taken, predicted not taken
	blne	callee
	CHECK	r0, 1			@ callee ran once and returned here
	CHECK	r4, 0			@ nothing ran past its MOV PC, LR
	CHECKPOINT
	@ the same through a BL whose prediction the loop above trained taken
	movs	r1, #1
	blne	callee
	CHECK	r0, 2
	CHECK	r4, 0
	CHECKPOINT
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

	.balign	1024
trainer:
	b	3f			@ taken, trains the entry of callee_ret
3:	mov	pc, lr
	.space	1024 - 12
callee:
	add	r0, r0, #1
callee_ret:				@ trainer + 1 KB
	mov	pc, lr
	mov	r4, #1			@ must not run
	mov	pc, lr
