@ SPDX-License-Identifier: GPL-3.0-or-later
@ Successive scalar loads overwrite the same physical register. Every
@ consumer must use the youngest value, including a held/missing second
@ load while the first load still owns W or its registered return.
@ Firmware-like RSB and CMP cases, early shift, and late store data.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main

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
	ldr r4, =SCRATCH + 0x2680
	mov r0, #0
	str r0, [r4]
	mov r0, #7
	str r0, [r4, #4]
	mov r8, #8
1:
	@ Cold and warmed second loads, with identical first-load destinations.
	tst r8, #1
	mcreq p15, 0, r4, c7, c14, 1
	ldr r1, =0x80400000
	ldr r3, pointer
	ldr r3, [r3]
	rsb r3, r1, r3
	CHECK r3, 0x7fc00000
	ldr r3, pointer
	ldr r3, [r3]
	cmp r3, #0
	bne wrong
	ldr r3, pointer
	ldr r3, [r3, #4]
	mov r2, r3, lsl #3
	CHECK r2, 56
	ldr r3, pointer
	ldr r3, [r3, #4]
	str r3, [r4, #8]
	ldr r2, [r4, #8]
	CHECK r2, 7
	subs r8, r8, #1
	bne 1b
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
wrong:
	FAIL
	.align 4
pointer:
	.word SCRATCH + 0x2680
	.ltorg
