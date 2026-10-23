@ SPDX-License-Identifier: GPL-3.0-or-later
@ A queued Thumb undefined instruction must not replace an older LDM's
@ held decode metadata. The following taken branch must kill a queued SWI.
	.include "test.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!,{r4-r8,lr}
	VECTOR VEC_UND, queue_und
	mov r8,#0
	adr r0,queue_data
	adr r6,after_undefined
	adr r7,queue_arm
	adr r4,queue_thumb
	add r4,r4,#1
	bx r4

	.thumb
	.balign 4
queue_thumb:
	ldmia r0!,{r1-r3}
	.hword 0xde00
after_undefined:
	b after_wrong_path
	swi 42
	.hword 0xde00
after_wrong_path:
	bx r7

	.arm
	.balign 4
queue_arm:
	CHECK r1,0x11
	CHECK r2,0x22
	CHECK r3,0x33
	CHECK r8,1
	adr r4,queue_data+12
	CHECKR r0,r4
	CHECKPOINT
	ldmfd sp!,{r4-r8,pc}

queue_und:
	@ All transfers, and the LDM writeback, precede this exception.
	CHECK r1,0x11
	CHECK r2,0x22
	CHECK r3,0x33
	CHECKR lr,r6
	add r8,r8,#1
	movs pc,lr
	.ltorg
	.balign 4
queue_data:
	.word 0x11,0x22,0x33
