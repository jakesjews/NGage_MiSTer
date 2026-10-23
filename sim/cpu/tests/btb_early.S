@ SPDX-License-Identifier: GPL-3.0-or-later
@ Early BTB redirects: dense branch chains (including a branch as target),
@ adjacent Thumb halfwords, changing indirect targets, and stale predictions
@ after replacing a branch with an ordinary instruction. Every wrong-path
@ instruction changes r6, checked at the end. Run at all bus latencies.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	@ Only the code section needs caching; data writes stay uncached.
	SECT r1, 0, 3, 0, 3
	SETL1 0, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	mov r6, #0
	mov r4, #64
	mov r5, #0
	b arm_chain
	.balign 16
arm_chain:
	add r5, r5, #1
	b arm_a
	add r6, r6, #1
	add r6, r6, #1
arm_a:
	b arm_b
	add r6, r6, #1
arm_b:
	subs r4, r4, #1
	bne arm_chain
	CHECK r5, 64
	CHECK r6, 0
	CHECKPOINT

	@ Reuse one indirect branch with alternating targets after training.
	mov r4, #64
	mov r5, #0
indirect_loop:
	tst r4, #1
	ldreq r8, =indirect_a
	ldrne r8, =indirect_b
	mov pc, r8
	add r6, r6, #1
indirect_a:
	add r5, r5, #1
	b indirect_done
indirect_b:
	add r5, r5, #2
indirect_done:
	subs r4, r4, #1
	bne indirect_loop
	CHECK r5, 96
	CHECK r6, 0
	CHECKPOINT

	@ The Thumb target is at +2 within a word. BX changes T in the ALU;
	@ the BTB may only predict an address, never make that state change.
	mov r4, #64
	mov r5, #0
	ldr r0, =thumb_chain + 1
	adr lr, thumb_done
	bx r0
thumb_done:
	CHECK r5, 64
	CHECK r6, 0
	CHECKPOINT

	@ Train, then replace a taken branch with ADD. An early stale hit must
	@ be corrected by predecode, including the fall-through instruction.
	mov r4, #16
	mov r5, #0
train_mutable:
	bl mutable
	subs r4, r4, #1
	bne train_mutable
	ldr r0, =mutable
	ldr r1, =0xe2866001		@ add r6, r6, #1
	str r1, [r0]
	mcr p15, 0, r0, c7, c5, 0	@ invalidate instruction cache
	bl mutable
	CHECK r5, 1
	CHECK r6, 1
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
	.ltorg

	.balign 32
mutable:
	b mutable_target
	add r5, r5, #1
mutable_target:
	mov pc, lr
	add r6, r6, #64

	.thumb
	.balign 16
	nop
	.thumb_func
thumb_chain:
	add r5, #1
	b thumb_a
	add r6, #1
thumb_a:
	b thumb_b
	add r6, #1
thumb_b:
	sub r4, #1
	bne thumb_chain
	bx lr
	add r6, #1
