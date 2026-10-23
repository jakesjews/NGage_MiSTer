@ SPDX-License-Identifier: GPL-3.0-or-later
@ Late load operands: cold/hot lines, both ALU inputs, barrel source and
@ amount, stores, two operands, formats, WAW/conditions, base writeback,
@ LDM temporaries, PC, Thumb, carry preservation and abort recovery.
@ Default @@ conventions: compare both signature and trace with QEMU.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main

@ r4 points at {3, 5, scratch, scratch}. Invalidate before each dependency
@ on the first pass, retain the line on the second. r7 is the cold flag.
	.macro COLD
	cmp r7, #0
	mcrne p15, 0, r4, c7, c14, 1
	.endm

@ Run each operation at consumer distances 1, 2, and 3.
	.macro GAP n
	.rept \n
	nop
	.endr
	.endm
	.macro PROBE n
	COLD
	ldr r0, [r4]
	GAP \n
	add r2, r0, #1
	CHECK r2, 4
	COLD
	ldr r0, [r4]
	GAP \n
	add r2, r3, r0
	CHECK r2, 10
	COLD
	ldr r0, [r4]
	GAP \n
	add r2, r0, r0
	CHECK r2, 6
	COLD
	ldr r0, [r4]
	GAP \n
	mov r2, r0, lsl #3
	CHECK r2, 24
	COLD
	ldr r0, [r4]
	GAP \n
	mov r2, r3, lsl r0
	CHECK r2, 56
	COLD
	ldr r0, [r4]
	GAP \n
	str r0, [r4, #8]
	ldr r2, [r4, #8]
	CHECK r2, 3
	COLD
	ldr r0, [r4]
	ldr r1, [r4, #4]
	GAP \n
	add r2, r0, r1
	CHECK r2, 8
	COLD
	ldr r0, [r4]
	ldr r1, [r4, #4]
	GAP \n
	mov r2, r1, lsl r0
	CHECK r2, 40
	.endm

test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	SECT r1, 0x00000000, 3, 0, 3
	SETL1 0x00000000, r1
	SECT r1, SCRATCH, 3, 0, 3
	SETL1 SCRATCH, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #(CR_C | CR_W)
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	ldr r4, =SCRATCH
	mov r0, #3
	mov r1, #5
	stmia r4, {r0, r1}
	mov r3, #7
	mov r7, #1
1:
	PROBE 0
	PROBE 1
	PROBE 2
	subs r7, r7, #1
	bpl 1b
	CHECKPOINT

	@ Younger ALU writers, true and false conditions, and retained WAW lock.
	ldr r0, [r4]
	mov r0, #11
	add r2, r0, #1
	CHECK r2, 12
	cmp r3, #7
	ldr r0, [r4]
	movne r0, #99
	add r2, r0, #1
	CHECK r2, 4
	mov r0, #13
	cmp r3, #7
	ldrne r0, [r4]
	add r2, r0, #1
	CHECK r2, 14
	ldr r0, [r4]
	add r0, r0, #1
	CHECK r0, 4

	@ Base writeback and the loaded register are separate destinations.
	mov r5, r4
	ldr r0, [r5], #4
	add r2, r0, #1
	CHECK r2, 4
	sub r2, r5, r4
	CHECK r2, 4
	ldmia r4, {r0, r1}
	add r2, r0, r1
	CHECK r2, 8
	stmia r4, {r0, r1}

	@ Carry from an intervening flag setter must survive the late wait.
	ldr r0, [r4]
	cmp r3, #7
	adcs r2, r0, #0
	CHECK r2, 4
	ldr r0, [r4]
	cmp r3, #7
	movs r2, r0, rrx
	CHECK r2, 0x80000001
	ldr r0, [r4]
	mul r2, r0, r3
	CHECK r2, 21
	@ Long multiply high uop must retain its raw accumulator inputs while
	@ busy, even though the low uop is in the ALU forwarding network.
	ldr r8, =0x2500
	ldr r10, =0x46453603
	smull r11, r0, r8, r10
	CHECK r0, 0xA28
	mov r5, #13
	mov r9, #17
	umlal r9, r5, r8, r10
	CHECK r5, 0xA35
	CHECKPOINT

	@ A later uncached access stalls the pipe while the previous cached
	@ result is transiently in memory. The pending consumer must retain it.
	ldr r5, =(SCRATCH + 0x100000)
	mov r1, #13
	str r1, [r5]
	ldr r0, [r4]
	ldr r1, [r5]
	add r2, r0, #1
	CHECK r1, 13
	CHECK r2, 4

	@ Both hit and miss formatting, without another load into the same reg.
	ldr r0, =0x8001FF80
	str r0, [r4, #12]
	mov r7, #1
2:
	COLD
	ldrsb r0, [r4, #12]
	add r2, r0, #1
	CHECK r2, 0xFFFFFF81
	COLD
	ldrb r0, [r4, #12]
	add r2, r0, #1
	CHECK r2, 129
	COLD
	ldrsh r0, [r4, #14]
	add r2, r0, #1
	CHECK r2, 0xFFFF8002
	COLD
	ldrh r0, [r4, #14]
	add r2, r0, #1
	CHECK r2, 0x8002
	subs r7, r7, #1
	bpl 2b
	CHECKPOINT

	@ Flush an outstanding dependent instruction on a translation abort.
	mov r0, #17
	ldr r5, =0x10000000
	ldr r0, [r5]
	add r2, r0, #1
	CHECK r2, 18
	DABT 5, 0x10000000
	CHECKPOINT

	@ Load-to-PC retains the existing sleep/redirect protocol.
	adr r0, 3f
	str r0, [r4, #8]
	ldr pc, [r4, #8]
	FAIL
3:
	adr lr, 4f
	adr r0, thumb_part + 1
	bx r0
4:
	CHECK r2, 8
	CHECK r5, 24
	CHECK r6, 56
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
	.ltorg
	.thumb
	.thumb_func
thumb_part:
	ldr r0, [r4]
	ldr r1, [r4, #4]
	add r2, r0, r1
	ldr r0, [r4]
	lsl r5, r0, #3
	ldr r0, [r4]
	mov r6, #7
	lsl r6, r0
	ldr r0, [r4]
	str r0, [r4, #8]
	bx lr
