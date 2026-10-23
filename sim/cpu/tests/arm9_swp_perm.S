@ SPDX-License-Identifier: GPL-3.0-or-later
@ SWP read succeeds but its write is forbidden, on uncached and hot cached data.
@ Byte case uses an aligned address: both cores currently lose low FAR bits
@ on a byte permission fault (a separate, pre-existing MMU issue).
@ The read value and store must both remain uncommitted on the write abort.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!,{r4-r11,lr}
	bl mmu_on
	SECT r1,SCRATCH,2,0,0
	SETL1 SCRATCH,r1
	TLBFLUSH
	VECTOR VEC_DABT,swp_abort
	bl swp_cases
	SECT r1,SCRATCH,2,0,3
	SETL1 SCRATCH,r1
	TLBFLUSH
	mrc p15,0,r0,c1,c0,0
	orr r0,r0,#(CR_C|CR_W)
	mcr p15,0,r0,c1,c0,0
	bl swp_cases
	ldmfd sp!,{r4-r11,pc}
swp_cases:
	stmfd sp!,{lr}
	ldr r9,=SCRATCH
	ldr r2,=0x11223344
	str r2,[r9]
	ldr r2,[r9]
	mov r4,r9
	mov r0,#0x55
	ldr r1,=0xaabbccdd
	mov r6,#0
	adr r5,after_word
	MODE M_USR
	swp r0,r1,[r4]
after_word:
	CHECK r0,0x55
	and r6,r6,#0xff
	CHECK r6,13
	CHECKR r7,r4
	and r8,r8,#0xff
	CHECK r8,0xd0
	ldr r2,[r9]
	CHECK r2,0x11223344
	CHECKPOINT
	mov r4,r9
	mov r0,#0x66
	mov r6,#0
	adr r5,after_byte
	MODE M_USR
	swpb r0,r1,[r4]
after_byte:
	CHECK r0,0x66
	and r6,r6,#0xff
	CHECK r6,13
	CHECKR r7,r4
	and r8,r8,#0xff
	CHECK r8,0xd0
	ldr r2,[r9]
	CHECK r2,0x11223344
	CHECKPOINT
	ldmfd sp!,{pc}
swp_abort:
	mrc p15,0,r6,c5,c0,0
	mrc p15,0,r7,c6,c0,0
	MRSN r8,spsr
	mov r10,#0xd3
	msr spsr_cxsf,r10
	movs pc,r5
	.ltorg
