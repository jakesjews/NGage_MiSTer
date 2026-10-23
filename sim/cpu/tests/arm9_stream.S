@ SPDX-License-Identifier: GPL-3.0-or-later
@ Ordered scalar request pipeline: adjacent accesses, RAM collisions, gaps,
@ post-index base forwarding, and an abort with a younger store at each distance.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!,{r4-r11,lr}
	VECTOR VEC_DABT, stream_abort
	bl stream_cases
	bl mmu_on
	ldr r0,=TTB
	ldr r1,=0x00000c1e
	mov r2,#16
1:	str r1,[r0],#4
	add r1,r1,#0x00100000
	subs r2,r2,#1
	bne 1b
	TLBFLUSH
	mrc p15,0,r0,c1,c0,0
	orr r0,r0,#(CR_C|CR_W)
	orr r0,r0,#CR_I
	mcr p15,0,r0,c1,c0,0
	VECTOR VEC_DABT, stream_abort
	bl stream_cases
	bl stream_cases
	ldmfd sp!,{r4-r11,pc}

stream_cases:
	stmfd sp!,{lr}
	ldr r9,=SCRATCH
	mov r0,#0x11
	mov r1,#0x22
	mov r2,#0x33
	mov r3,#0x44
	@ Consecutive read/write collisions on one word and across sets/lines.
	str r0,[r9]
	ldr r4,[r9]
	str r1,[r9]
	ldr r5,[r9]
	str r2,[r9,#16]
	ldr r6,[r9,#16]
	str r3,[r9,#64]
	ldr r7,[r9,#64]
	CHECK r4,0x11
	CHECK r5,0x22
	CHECK r6,0x33
	CHECK r7,0x44
	mov r8,r9
	str r0,[r8],#4
	str r1,[r8],#4
	str r2,[r8],#4
	str r3,[r8],#4
	mov r8,r9
	ldr r4,[r8],#4
	ldr r5,[r8],#4
	ldr r6,[r8],#4
	ldr r7,[r8],#4
	CHECK r4,0x11
	CHECK r5,0x22
	CHECK r6,0x33
	CHECK r7,0x44
	add r0,r9,#16
	CHECKR r8,r0
	@ Byte masks and the RAM bypass preserve the untouched lanes.
	mov r0,#0x88
	strb r0,[r9,#1]
	ldrsb r4,[r9,#1]
	mov r0,#0x99
	strh r0,[r9,#2]
	ldrh r5,[r9,#2]
	ldr r6,[r9]
	CHECK r4,0xffffff88
	CHECK r5,0x99
	CHECK r6,0x00998811
	@ Gaps move invalid metadata as well as valid memory records.
	ldr r0,[r9,#64]
	add r1,r1,#1
	ldr r2,[r9,#16]
	add r3,r0,r2
	str r3,[r9,#128]
	ldr r4,[r9,#128]
	CHECK r4,0x77
	CHECKPOINT
	@ A younger store must not escape an older abort, even when adjacent.
	mov r0,#0x55
	str r0,[r9,#128]
	ldr r4,=NOWHERE
	adr r5,after0
	cmp r9,r9
fault0:
	ldr r0,[r4],#4
	str r1,[r9,#128]
	adds r2,r2,#1
	after0:
	CHECK r0,0x55
	CHECK r4,NOWHERE
	ldr r0,[r9,#128]
	CHECK r0,0x55
	CHECK r6,0x600000d3
	adr r8,fault0+8
	CHECKR r7,r8
	adr r5,after1
fault1:
	str r0,[r4],#4
	mov r1,#0x66
	str r1,[r9,#128]
	after1:
	CHECK r4,NOWHERE
	ldr r0,[r9,#128]
	CHECK r0,0x55
	adr r8,fault1+8
	CHECKR r7,r8
	CHECKPOINT
	ldmfd sp!,{pc}
stream_abort:
	MRSN r6,spsr
	mov r7,lr
	movs pc,r5
	.ltorg
