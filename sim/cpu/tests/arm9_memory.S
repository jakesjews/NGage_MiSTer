@ SPDX-License-Identifier: GPL-3.0-or-later
@ Held scalar-memory context, ordered younger DP, pending load/base tags,
@ queue backpressure, and precise abort cancellation. Shared with ZAP/QEMU.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!,{r4-r11,lr}
	VECTOR VEC_DABT, memory_abort
	bl memory_cases
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
	VECTOR VEC_DABT, memory_abort
	bl memory_cases
	bl memory_cases
	ldmfd sp!,{r4-r11,pc}

memory_cases:
	stmfd sp!,{lr}
	ldr r9,=SCRATCH
	mov r0,#0x31
	str r0,[r9]
	mov r1,#0x42
	str r1,[r9,#4]
	mov r1,#3
	str r1,[r9,#8]

	@ A younger write shadows an unready load; the stalled E operand must
	@ survive the two-entry result queue filling and then draining.
	ldr r0,[r9]
	mov r0,#0x53
	add r1,r0,#1
	adds r2,r1,#1
	adc r3,r2,#1
	CHECK r0,0x53
	CHECK r1,0x54
	CHECK r2,0x55
	CHECK r3,0x56

	@ Both writers from a post-indexed load: base and load destination.
	mov r4,r9
	ldr r0,[r4],#4
	add r1,r4,#4
	add r2,r0,#1
	add r3,r9,#8
	CHECKR r1,r3
	CHECK r2,0x32
	ldr r0,[r9,#8]
	mov r1,#7
	mov r2,r1,lsl r0
	CHECK r2,56

	@ False consumers must not wait for or observe an unready destination.
	cmp r9,r9
	ldr r0,[r9]
	addne r1,r0,#1
	mov r1,#0x64
	CHECK r1,0x64

	@ Failed memory must never issue its invalid address or change its base.
	ldr r4,=NOWHERE
	mov r0,#0x75
	cmp r9,r9
	ldrne r0,[r4],#4
	add r1,r0,#1
	CHECK r1,0x76
	CHECK r4,NOWHERE

	@ Independent younger flags/register results exist before an uncached
	@ bus abort. The handler sees the pre-fault state and skips those results.
	mov r0,#0x86
	mov r1,#0x97
	mov r2,#0xa8
	ldr r4,=NOWHERE
	adr r5,after_abort
	cmp r9,r9
faulting_load:
	ldr r0,[r4],#4
	mov r1,#1
	adds r2,r1,#1
	add r3,r2,#1
	str r3,[r9]
after_abort:
	CHECK r0,0x86
	CHECK r1,0x97
	CHECK r2,0xa8
	CHECK r4,NOWHERE
	CHECK r6,0x600000d3
	adr r8,faulting_load+8
	CHECKR r7,r8
	ldr r0,[r9]
	CHECK r0,0x31
	CHECKPOINT
	ldmfd sp!,{pc}

memory_abort:
	MRSN r6,spsr
	mov r7,lr
	movs pc,r5
	.ltorg
