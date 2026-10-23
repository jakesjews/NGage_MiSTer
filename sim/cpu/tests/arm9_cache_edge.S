@ SPDX-License-Identifier: GPL-3.0-or-later
@ Two-edge cache boundary: successive masked writes/read-first collisions,
@ all word offsets, both ways, fill followed immediately by a dependent lookup.
	.include "test.inc"
	.include "mmu.inc"
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
	TLBFLUSH
	mrc p15,0,r0,c1,c0,0
	orr r0,r0,#(CR_C|CR_W)
	orr r0,r0,#CR_I
	mcr p15,0,r0,c1,c0,0
	ldr r9,=0x00421e00
	ldr r10,=0x00431e00
	ldr r11,=0x00441e00
	mov r0,#0
	str r0,[r9]
	str r0,[r10]
	str r0,[r11]
	mcr p15,0,r0,c7,c10,0
	mcr p15,0,r0,c7,c6,0
	@ First load fills, second same-set load must see the new tag/valid.
	ldr r1,[r9]
	ldr r2,[r10]
	ldr r3,[r9]
	CHECK r1,0
	CHECK r2,0
	CHECK r3,0
	@ Back-to-back byte writes must merge, not forward an entire stale word.
	mov r0,#0x81
	mov r1,#0x92
	mov r2,#0xa3
	mov r3,#0xb4
	strb r0,[r9]
	strb r1,[r9,#1]
	strb r2,[r9,#2]
	strb r3,[r9,#3]
	ldr r4,[r9]
	ldrsb r5,[r9,#2]
	ldrh r6,[r9,#2]
	CHECK r4,0xb4a39281
	CHECK r5,0xffffffa3
	CHECK r6,0xb4a3
	@ The opposite way, followed by same-word loads at distances 0, 1, 2.
	str r4,[r10]
	ldr r5,[r10]
	strh r0,[r10]
	nop
	ldr r6,[r10]
	strb r1,[r10,#3]
	nop
	nop
	ldr r7,[r10]
	CHECK r5,0xb4a39281
	CHECK r6,0xb4a30081
	CHECK r7,0x92a30081
	@ Every line word and different sets in a continuous request stream.
	str r0,[r9,#4]
	str r1,[r9,#8]
	str r2,[r9,#12]
	str r3,[r9,#16]
	ldr r4,[r9,#4]
	ldr r5,[r9,#8]
	ldr r6,[r9,#12]
	ldr r7,[r9,#16]
	CHECK r4,0x81
	CHECK r5,0x92
	CHECK r6,0xa3
	CHECK r7,0xb4
	@ Dirty victim + immediate refetch: fill/dirty/valid chains must agree.
	str r3,[r11]
	ldr r4,[r11]
	ldr r5,[r10]
	ldr r6,[r9]
	CHECK r4,0xb4
	CHECK r5,0x92a30081
	CHECK r6,0xb4a39281
	CHECKPOINT
	mov r0,#0
	mcr p15,0,r0,c7,c10,0
	mcr p15,0,r0,c7,c6,0
	ldr r4,[r9]
	ldr r5,[r10]
	ldr r6,[r11]
	CHECK r4,0xb4a39281
	CHECK r5,0x92a30081
	CHECK r6,0xb4
	CHECKPOINT
	ldmfd sp!,{r4-r11,pc}
	.ltorg
