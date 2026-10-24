@ SPDX-License-Identifier: GPL-3.0-or-later
@ Warm dependent block tails. The marker convention matches arm9_cycles.
@ Partial block faults remain covered by mmu_page/align/dhold_rtl.
@@ bench: --arm9-cycles --arm9-cycle-model arm9v2/arm9_tail-cycles.txt
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
	ldr r9,=SCRATCH
	mov r0,#1
	mov r1,#2
	mov r2,#3
	stmia r9,{r0-r2}
	.rept 5
	bl tail1
	bl tail3
	bl tail1_shift
	bl tail3_shift
	.endr
	CHECKPOINT
	ldmfd sp!,{r4-r11,pc}
	.ltorg

	.macro TAIL name,list,src,shift,expected
	.balign 16
\name:
	.rept 8
	mov r10,r10
	.endr
start_\name:
	mov r10,r10
	ldmia r9,\list
	.if \shift
	add r4,r5,\src,lsl #1
	.else
	add r4,\src,#1
	.endif
end_\name:
	mov r10,r10
	CHECK r4,\expected
	bx lr
	.endm
	@ r5 is reset to zero by crt0 and not changed here.
	TAIL tail1,"{r0}",r0,0,2
	TAIL tail3,"{r0-r2}",r2,0,4
	TAIL tail1_shift,"{r0}",r0,1,2
	TAIL tail3_shift,"{r0-r2}",r2,1,6
	.ltorg
	.balign 4
	.word 0x59433941,0x31574f44,4
	.word start_tail1,end_tail1,7,name_tail1,5
	.word start_tail3,end_tail3,9,name_tail3,5
	.word start_tail1_shift,end_tail1_shift,7,name_tail1_shift,5
	.word start_tail3_shift,end_tail3_shift,9,name_tail3_shift,5
name_tail1: .asciz "tail1"
name_tail3: .asciz "tail3"
name_tail1_shift: .asciz "tail1_shift"
name_tail3_shift: .asciz "tail3_shift"
