@ SPDX-License-Identifier: GPL-3.0-or-later
@ Adjacent PSR/CP15 producers and consumers, including a cold data access.
@ Real mode changes must still discard decoded old-bank instructions.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11,lr}
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
	mov r10,#8
again:
	ldr r9,=SCRATCH
	ldr r8,[r9]
	msr cpsr_f,#0x60000000
	moveq r0,#0x11
	movne r0,#0xee
	mrs r1,cpsr
	msr cpsr_f,#0x90000000
	movmi r2,#0x22
	movpl r2,#0xee
	mrs r3,cpsr
	CHECK r0,0x11
	CHECK r2,0x22
	and r1,r1,#0xf0000000
	and r3,r3,#0xf0000000
	CHECK r1,0x60000000
	CHECK r3,0x90000000

	msr cpsr_c,#(M_SVC|PSR_F)
	mrs r4,cpsr
	msr cpsr_c,#(M_SVC|PSR_I)
	mrs r5,cpsr
	msr cpsr_c,#(M_SVC|PSR_I|PSR_F)
	mrs r6,cpsr
	and r4,r4,#0xff
	and r5,r5,#0xff
	and r6,r6,#0xff
	CHECK r4,(M_SVC|PSR_F)
	CHECK r5,(M_SVC|PSR_I)
	CHECK r6,(M_SVC|PSR_I|PSR_F)
	cmp r0,r0
	msrne cpsr_c,#(M_FIQ|PSR_I|PSR_F)
	mrs r7,cpsr
	and r7,r7,#0xff
	CHECK r7,(M_SVC|PSR_I|PSR_F)

	@ Read dependency, WAW, then independent work behind a coprocessor read.
	mrc p15,0,r0,c0,c0,0
	add r1,r0,#1
	CHECK r1,0x54029253
	mrc p15,0,r2,c0,c0,0
	mov r2,#0x33
	mrc p15,0,r3,c1,c0,0
	add r4,r2,#1
	ldr r7,=(CR_C|CR_W|CR_I)
	and r5,r3,r7
	CHECK r2,0x33
	CHECK r4,0x34
	CHECK r5,(CR_C|CR_W|CR_I)
	subs r10,r10,#1
	bne again
	CHECKPOINT
	ldmfd sp!,{r4-r11,pc}
	.ltorg
