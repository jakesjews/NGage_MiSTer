@ SPDX-License-Identifier: GPL-3.0-or-later
@ Guaranteed SDRAM-class I-fills: retire the critical instruction before the
@ terminal beat when a following sequential word arrives in this fill.
@ All ARM offsets are measured. Exact arithmetic checks following word
@ order; the CPU-bench observation checks actual retirement, not cache ACK.
@ icache_restart.S separately injects errors into each beat of unsafe fills.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ CODE, 0x00482000
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
	ldr r4, =CODE
	adr r0, original
	mov r1, r4
	mov r2, #8
2:	ldr r3, [r0], #4
	str r3, [r1], #4
	subs r2, r2, #1
	bne 2b
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	ldr r10, =BENCH
	mov r0, #20
	str r0, [r10, #BENCH_LATENCY]
	mov r5, #0
cold_next:
	str r4, [r10, #0x44]       @ watch this line's early retirement
	mov r0, #0
	mcr p15, 0, r0, c7, c5, 0
	mov r7, #0
	add r6, r4, r5
	adr lr, cold_return
	bx r6
cold_return:
	adr r0, results
	ldr r1, [r0, r5]
	CHECKR r7, r1
	ldr r8, [r10, #0x48]
	mov r9, r5, lsr #2
	mov r0, #1
	mov r0, r0, lsl r9
	and r8, r8, r0
@ Historical cache-side-only probe: keep its binary/counts as the baseline.
@ ifetch_rtl now requires early retirement at ALL offsets, including +12.
	cmp r5, #12
	beq last_word_wait
	CHECKR r8, r0             @ critical instruction retired during its fill
last_word_wait:

@ A warm call exercises the installed (unrotated) line too.
	mov r7, #0
	adr lr, warm_return
	bx r6
warm_return:
	adr r0, results
	ldr r1, [r0, r5]
	CHECKR r7, r1
	CHECKPOINT
	add r5, r5, #4
	cmp r5, #16
	bne cold_next
	mov r0, #0
	str r0, [r10, #BENCH_LATENCY]
	ldmfd sp!, {r4-r11, pc}
	.balign 16
original:
	add r7, r7, #3
	mov r7, r7, lsl #2
	add r7, r7, #5
	mov r7, r7, lsl #1
	bx lr
	nop
	nop
	nop
results:
	.word 34, 10, 10, 0
	.ltorg
