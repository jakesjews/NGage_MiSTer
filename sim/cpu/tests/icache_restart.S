@ SPDX-License-Identifier: GPL-3.0-or-later
@ Early I-cache restart: every ARM/Thumb offset, sequential words, redirects,
@ invalidation, and precise errors on each of the four fill beats. Every
@ error line is retried at every offset, so installing a failed line fails.
@ Injected bus errors and fixed bus latency have no QEMU equivalent.
@@ qemu: no
@@ bench: --read-error 0x00480000 --read-error 0x00480014 --read-error 0x00480028 --read-error 0x0048003c
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	ldr r0, =TTB
	ldr r1, =0x00000C1E
	mov r2, #16
1:	str r1, [r0], #4
	add r1, r1, #0x00100000
	subs r2, r2, #1
	bne 1b
	SECT r0, 0xF0000000, 3, 0, 0
	SETL1 0xF0000000, r0
	TLBFLUSH
	VECTOR VEC_PABT, restart_abort
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0

@ All ARM offsets, with an empty I-cache each time. The following line's
@ BX redirects while its sequential fall-through can still be filling.
	ldr r4, =arm_words
	mov r5, #4
arm_next:
	mov r0, #0
	mcr p15, 0, r0, c7, c5, 0
	mov r7, #0
	adr lr, arm_return
	bx r4
arm_return:
	CHECKR r7, r5
	add r4, r4, #4
	subs r5, r5, #1
	bne arm_next
	CHECKPOINT

@ Both Thumb halves of every word must be returned correctly, including
@ the held/repeated word address for adjacent 16-bit instructions.
	ldr r4, =thumb_words + 1
	mov r5, #8
thumb_next:
	mov r0, #0
	mcr p15, 0, r0, c7, c5, 0
	mov r7, #0
	adr lr, thumb_return
	bx r4
thumb_return:
	CHECKR r7, r5
	add r4, r4, #2
	subs r5, r5, #1
	bne thumb_next
	CHECKPOINT

@ Force long gaps between beats. Even a word returned tens of clocks
@ before the final fault must not increment r7 before the abort.
	ldr r0, =BENCH
	mov r1, #20
	str r1, [r0, #BENCH_LATENCY]
	ldr r0, =0x00480000
	ldr r1, =0xE2877001	@ add r7, r7, #1
	mov r2, #16
2:	str r1, [r0], #4
	subs r2, r2, #1
	bne 2b
	ldr r4, =0x00480000
	ldr r5, =0x00480040
	adr r6, arm_fault_return
	mov r7, #0
	mov r8, #0
arm_fault_next:
	bx r4
arm_fault_return:
	add r4, r4, #4
	cmp r4, r5
	bne arm_fault_next
	CHECK r8, 16
	CHECK r7, 0
	CHECKPOINT

@ Repeat in Thumb state at all eight offsets of each failing line.
	ldr r4, =0x00480001
	add r5, r5, #1
	adr r6, thumb_fault_return
thumb_fault_next:
	bx r4
thumb_fault_return:
	add r4, r4, #2
	cmp r4, r5
	bne thumb_fault_next
	CHECK r8, 48
	CHECK r7, 0
	CHECKPOINT
	ldr r0, =BENCH
	mov r1, #0
	str r1, [r0, #BENCH_LATENCY]
	ldmfd sp!, {r4-r11, pc}

restart_abort:
	sub r0, lr, #4
	bic r1, r4, #1
	CHECKR r0, r1		@ precise PC: the first requested instruction
	CHECK r7, 0		@ no provisional instruction executed
	add r8, r8, #1
	mrs r0, spsr
	bic r0, r0, #PSR_T
	msr spsr_cxsf, r0
	movs pc, r6

	.ltorg
	.balign 16
arm_words:
	.rept 4
	add r7, r7, #1
	.endr
	bx lr
	.rept 3
	nop
	.endr
	.balign 16
	.thumb
thumb_words:
	.rept 8
	add r7, #1
	.endr
	bx lr
	.rept 7
	nop
	.endr
	.arm
