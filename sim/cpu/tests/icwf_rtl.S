@ SPDX-License-Identifier: GPL-3.0-or-later
@ Demand fills at every word offset, including +12 -> +0 wrapping. Each
@ instruction has a different effect. Rewrite backing RAM behind I-cache
@ after the cold call: all four warm entries must still execute the OLD
@ installed words. Invalidate, then all four must execute the new words.
@ D-cache stays off; changing code behind a live I-cache is RTL-only.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ CODE, 0x00481000
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
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	ldr r4, =CODE
	mov r5, #0
cold_next:
	adr r0, original
	bl copy_line
	mov r0, #0
	mcr p15, 0, r0, c7, c5, 0
	mov r7, #0
	add r6, r4, r5
	adr lr, cold_return
	bx r6
cold_return:
	adr r0, sums
	ldr r1, [r0, r5]
	CHECKR r7, r1

@ The line installed from the wrapped fill must retain all four original
@ words. Also verify the following line was not corrupted by wraparound.
	adr r0, replacement
	bl copy_line
	mov r8, #0
warm_next:
	mov r7, #0
	add r6, r4, r8
	adr lr, warm_return
	bx r6
warm_return:
	adr r0, sums
	ldr r1, [r0, r8]
	CHECKR r7, r1
	add r8, r8, #4
	cmp r8, #16
	bne warm_next

@ Invalidate exposes backing RAM. Start at the same original miss offset,
@ then visit every word of the newly installed line without invalidating.
	mov r0, #0
	mcr p15, 0, r0, c7, c5, 0
	mov r7, #0
	add r6, r4, r5
	adr lr, fresh_return
	bx r6
fresh_return:
	adr r0, sums
	ldr r1, [r0, r5]
	mov r1, r1, lsl #4
	CHECKR r7, r1
	mov r8, #0
fresh_warm_next:
	mov r7, #0
	add r6, r4, r8
	adr lr, fresh_warm_return
	bx r6
fresh_warm_return:
	adr r0, sums
	ldr r1, [r0, r8]
	mov r1, r1, lsl #4
	CHECKR r7, r1
	add r8, r8, #4
	cmp r8, #16
	bne fresh_warm_next
	CHECKPOINT
	add r5, r5, #4
	cmp r5, #16
	bne cold_next
	ldmfd sp!, {r4-r11, pc}

copy_line:
	mov r1, r4
	mov r2, #8
2:	ldr r3, [r0], #4
	str r3, [r1], #4
	subs r2, r2, #1
	bne 2b
	bx lr
	.balign 16
original:
	add r7, r7, #1
	add r7, r7, #2
	add r7, r7, #4
	add r7, r7, #8
	bx lr
	nop
	nop
	nop
replacement:
	add r7, r7, #16
	add r7, r7, #32
	add r7, r7, #64
	add r7, r7, #128
	bx lr
	nop
	nop
	nop
sums:
	.word 15, 14, 12, 8
	.ltorg
