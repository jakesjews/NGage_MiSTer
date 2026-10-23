@ SPDX-License-Identifier: GPL-3.0-or-later
@ Measure hot load/use distances for every late-pickup operand class.
@ Default @@ conventions: compare signature and trace with QEMU.
@ lp_*_begin/end labels delimit 64 iterations for Vtb_cpu --watch.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main

	.macro CASE name, gap, operation:vararg
	.global lp_\name\()_begin, lp_\name\()_end
	.balign 16
lp_\name\()_begin:
	mov r6, #64
1:
	ldr r0, [r4]
	.rept \gap
	nop
	.endr
	\operation
	subs r6, r6, #1
	bne 1b
lp_\name\()_end:
	nop
	.endm

test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	SECT r1, 0, 3, 0, 3
	SETL1 0, r1
	SECT r1, SCRATCH, 3, 0, 3
	SETL1 SCRATCH, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #(CR_C | CR_W)
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	ldr r4, =SCRATCH
	mov r0, #3
	str r0, [r4]
	mov r3, #7
	CASE rn0, 0, add r2, r0, #1
	CHECK r2, 4
	CASE rn1, 1, add r2, r0, #1
	CHECK r2, 4
	CASE rn2, 2, add r2, r0, #1
	CHECK r2, 4
	CASE rn3, 3, add r2, r0, #1
	CHECK r2, 4
	CASE rn4, 4, add r2, r0, #1
	CHECK r2, 4
	CASE rm0, 0, add r2, r3, r0
	CHECK r2, 10
	CASE rm1, 1, add r2, r3, r0
	CHECK r2, 10
	CASE rm2, 2, add r2, r3, r0
	CHECK r2, 10
	CASE rm3, 3, add r2, r3, r0
	CHECK r2, 10
	CASE rm4, 4, add r2, r3, r0
	CHECK r2, 10
	CASE both0, 0, add r2, r0, r0
	CHECK r2, 6
	CASE both1, 1, add r2, r0, r0
	CHECK r2, 6
	CASE both2, 2, add r2, r0, r0
	CHECK r2, 6
	CASE both3, 3, add r2, r0, r0
	CHECK r2, 6
	CASE both4, 4, add r2, r0, r0
	CHECK r2, 6
	CASE shift0, 0, mov r2, r0, lsl #3
	CHECK r2, 24
	CASE shift1, 1, mov r2, r0, lsl #3
	CHECK r2, 24
	CASE shift2, 2, mov r2, r0, lsl #3
	CHECK r2, 24
	CASE shift3, 3, mov r2, r0, lsl #3
	CHECK r2, 24
	CASE shift4, 4, mov r2, r0, lsl #3
	CHECK r2, 24
	CASE amount0, 0, mov r2, r3, lsl r0
	CHECK r2, 56
	CASE amount1, 1, mov r2, r3, lsl r0
	CHECK r2, 56
	CASE amount2, 2, mov r2, r3, lsl r0
	CHECK r2, 56
	CASE amount3, 3, mov r2, r3, lsl r0
	CHECK r2, 56
	CASE amount4, 4, mov r2, r3, lsl r0
	CHECK r2, 56
	CASE store0, 0, str r0, [r4, #8]
	ldr r2, [r4, #8]
	CHECK r2, 3
	CASE store1, 1, str r0, [r4, #8]
	ldr r2, [r4, #8]
	CHECK r2, 3
	CASE store2, 2, str r0, [r4, #8]
	ldr r2, [r4, #8]
	CHECK r2, 3
	CASE store3, 3, str r0, [r4, #8]
	ldr r2, [r4, #8]
	CHECK r2, 3
	CASE store4, 4, str r0, [r4, #8]
	ldr r2, [r4, #8]
	CHECK r2, 3
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
	.ltorg
