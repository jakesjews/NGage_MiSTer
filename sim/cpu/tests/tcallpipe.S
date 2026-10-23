@ SPDX-License-Identifier: GPL-3.0-or-later
@ Dense Thumb BL/return loops with and without the I-cache, without IRQs.
@ Default @@ conventions: compare signature and trace with QEMU.
@ Named regions measure 64 iterations of twelve calls with --watch.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	ldr r0, =tcall_uncached_begin + 1
	bx r0
uncached_return:
	CHECK r5, 768
	CHECKPOINT
	bl mmu_on
	SECT r1, 0, 3, 0, 3
	SETL1 0, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	ldr r0, =tcall_cached_begin + 1
	bx r0
cached_return:
	CHECK r5, 768
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
	.ltorg

	.macro CALL_LOOP name
	.thumb
	.balign 16
	.global tcall_\name\()_begin, tcall_\name\()_end
	.thumb_func
tcall_\name\()_begin:
	mov r4, #64
	mov r5, #0
1:
	.rept 12
	bl \name\()_callee
	.endr
	sub r4, #1
	bne 1b
tcall_\name\()_end:
	nop
	ldr r0, =\name\()_return
	bx r0
\name\()_callee:
	add r5, #1
	bx lr
	.ltorg
	.endm
	CALL_LOOP uncached
	CALL_LOOP cached
