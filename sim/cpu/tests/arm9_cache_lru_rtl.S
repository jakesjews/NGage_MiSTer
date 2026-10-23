@ SPDX-License-Identifier: GPL-3.0-or-later
@ Adjacent hit/fill LRU updates and dirty-byte writeback at the short boundary.
@ Uncached aliases observe the physical backing store; QEMU has no cache model.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ LA, 0x00421e00
	.equ LB, 0x00431e00
	.equ LC, 0x00441e00
	.equ UNC, 0x20000000
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!,{r4-r11,lr}
	bl mmu_on
	ldr r0,=TTB
	ldr r1,=0x00000c1e
	mov r2,#16
1:	str r1,[r0],#4
	add r1,r1,#0x00100000
	subs r2,r2,#1
	bne 1b
	SECT r1,0x00400000,3,0,0
	SETL1 UNC,r1
	TLBFLUSH
	mrc p15,0,r0,c1,c0,0
	orr r0,r0,#(CR_C|CR_W)
	orr r0,r0,#CR_I
	mcr p15,0,r0,c1,c0,0
	ldr r4,=LA
	ldr r5,=LB
	ldr r6,=LC
	ldr r7,=UNC+0x21e00
	ldr r8,=UNC+0x31e00
	ldr r11,=UNC+0x41e00
	mov r0,#0
	str r0,[r7]
	str r0,[r8]
	str r0,[r11]
	mcr p15,0,r0,c7,c10,0
	mcr p15,0,r0,c7,c6,0
	ldr r0,[r4]
	ldr r1,[r5]
	mov r0,#0x81
	mov r1,#0x92
	@ Two adjacent dirty updates, then hit A immediately before miss C.
	strb r0,[r4]
	strb r1,[r5,#1]
	ldr r2,[r4]
	ldr r3,[r6]
	ldr r9,[r7]
	ldr r10,[r8]
	CHECK r2,0x81
	CHECK r9,0
	CHECK r10,0x9200
	@ Dirty C followed by hit B immediately before miss A: C must be evicted.
	ldr r2,[r5]
	strb r0,[r6,#2]
	ldr r2,[r5]
	ldr r3,[r4]
	ldr r9,[r11]
	CHECK r2,0x9200
	CHECK r3,0x81
	CHECK r9,0x810000
	CHECKPOINT
	ldmfd sp!,{r4-r11,pc}
	.ltorg
