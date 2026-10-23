@ SPDX-License-Identifier: GPL-3.0-or-later
@ Final-beat base writeback must be suppressed on both load and store aborts.
@ Default @@ conventions: compare signature and trace with QEMU.
	.include "test.inc"
	.equ RAM_END, 0x01000000
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	VECTOR VEC_DABT, dabt_handler
	ldr r9, =RAM_END - 4
	mov r1, #23
	str r1, [r9]
	ldr r11, =result
	mov r10, r9
	mov r1, #0
	mov r2, #17
	ldmia r10!, {r1, r2}
	CHECKR r10, r9
	CHECK r1, 23
	CHECK r2, 17
	ldr r6, [r11]
	CHECK r6, 1
	ldr r6, [r11, #4]
	CHECK r6, RAM_END
	CHECKPOINT
	mov r1, #31
	mov r2, #43
	stmia r10!, {r1, r2}
	CHECKR r10, r9
	ldr r6, [r9]
	CHECK r6, 31
	ldr r6, [r11]
	CHECK r6, 2
	CHECKPOINT
	@ One-register transfer: its first beat is also its final beat.
	ldr r9, =RAM_END
	mov r10, r9
	ldmia r10!, {r1}
	CHECKR r10, r9
	CHECK r1, 31
	stmia r10!, {r1}
	CHECKR r10, r9
	ldr r6, [r11]
	CHECK r6, 4
	CHECKPOINT
	@ A false condition must neither access the bad address nor update base.
	cmp r1, r1
	ldmneia r10!, {r1, r2}
	stmneia r10!, {r1, r2}
	CHECKR r10, r9
	ldr r6, [r11]
	CHECK r6, 4
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}

dabt_handler:
	stmfd sp!, {r0-r1}
	ldr r0, =result
	ldr r1, [r0]
	add r1, r1, #1
	str r1, [r0]
	mrc p15, 0, r1, c6, c0, 0
	str r1, [r0, #4]
	ldmfd sp!, {r0-r1}
	subs pc, lr, #4
	.ltorg
	.data
	.align 2
result:
	.word 0, 0
