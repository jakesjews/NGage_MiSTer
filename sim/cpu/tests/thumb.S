@ SPDX-License-Identifier: GPL-3.0-or-later
@ Thumb: every instruction format, interworking with BX, BL, SWI and the
@ undefined instruction from Thumb state, PC-relative loads and ADD Rd, PC
@ from both halfword positions, POP {pc} (no state change on ARMv4T). The
@ Thumb code stores results to SIG_DATA (part of the signature compared
@ with QEMU); the ARM code checks the ones that matter most.
@
@ SIG_DATA layout (r7 = SIG_DATA in the Thumb code):
@   00-0C shifts   10-1C add/sub   20 imm8   24-3C ALU   40-48 PC-relative
@   4C-54 carry ops  50 BL's LR  58/5C SWI LR/SPSR  60/64 UND LR/SPSR
@   68 POP marker  6C MUL  70-7C load/store area
@   80-9C (r7 + 0x80): load/store results, SP ops, conditions
@   A0-B0 LDM/STM
	.include "test.inc"

	.macro	TCOND c, bit		@ r6 |= bit if condition c holds for r0 vs r1
	cmp	r0, r1
	b\c	1f
	b	2f
1:	mov	r5, #\bit
	orr	r6, r5
2:
	.endm

	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_SWI, swi_handler
	VECTOR	VEC_UND, und_handler

	ldr	r7, =SIG_DATA
	ldr	r0, =t_start + 1
	bx	r0			@ to Thumb
	.ltorg

arm_back:				@ the Thumb code returns here with BX
	ldr	r7, =SIG_DATA
	CHECKPOINT
	ldr	r0, [r7, #0x00]		@ LSL #1 of 0x81
	CHECK	r0, 0x102
	ldr	r0, [r7, #0x04]		@ LSR #32 of 0x80000000
	CHECK	r0, 0
	ldr	r0, [r7, #0x08]		@ ASR #32
	CHECK	r0, 0xFFFFFFFF
	ldr	r0, [r7, #0x40]		@ literal, LDR at a word-aligned address
	CHECK	r0, 0x11223344
	ldr	r0, [r7, #0x44]		@ literal, LDR at an address with bit 1 set
	CHECK	r0, 0x55667788
	ldr	r0, [r7, #0x48]		@ ADD Rd, PC, #4: PC rounded down to a word
	ldr	r1, =t_addpc_at + 6
	CHECKR	r0, r1
	ldr	r0, [r7, #0x50]		@ BL: LR = next instruction | 1
	ldr	r1, =t_bl_ret + 1
	CHECKR	r0, r1
	ldr	r0, [r7, #0x58]		@ SWI from Thumb: LR = next instruction
	ldr	r1, =t_swi_ret
	CHECKR	r0, r1
	ldr	r0, [r7, #0x5C]		@ SPSR in the SWI handler has T
	and	r0, r0, #PSR_T
	CHECK	r0, PSR_T
	ldr	r0, [r7, #0x60]		@ undefined from Thumb: LR = next instruction
	ldr	r1, =t_und_ret
	CHECKR	r0, r1
	ldr	r0, [r7, #0x68]		@ POP {pc} stayed in Thumb
	CHECK	r0, 0x7777
	ldr	r0, [r7, #0x6C]
	CHECK	r0, 0x366176F8
	ldr	r0, [r7, #0x98]		@ conditions after 0 - 1
	CHECK	r0, 0x1A
	ldr	r0, [r7, #0x9C]		@ conditions after 1 - 1
	CHECK	r0, 0x25
	ldr	r0, [r7, #0xB4]		@ STR Rd, [SP, #4] read through ADD Rd, SP, #4
	CHECK	r0, 0x5A5A0001
	ldr	r0, [r7, #0xB8]		@ LDR Rd, [SP, #12] of a store through another register
	CHECK	r0, 0x5A5A0002
	ldmfd	sp!, {r4-r11, pc}

swi_handler:				@ store LR and SPSR, return
	ldr	r12, =SIG_DATA
	str	lr, [r12, #0x58]
	MRSN	r11, spsr
	str	r11, [r12, #0x5C]
	movs	pc, lr
und_handler:
	ldr	r12, =SIG_DATA
	str	lr, [r12, #0x60]
	MRSN	r11, spsr
	str	r11, [r12, #0x64]
	movs	pc, lr
	.ltorg

	.thumb
	.align	2
t_start:
	@ format 1: shifts by immediate
	mov	r0, #0x81
	lsl	r1, r0, #1
	str	r1, [r7, #0x00]
	mov	r0, #1
	lsl	r0, r0, #31
	lsr	r1, r0, #32
	str	r1, [r7, #0x04]
	asr	r1, r0, #32
	str	r1, [r7, #0x08]
	asr	r1, r0, #4
	str	r1, [r7, #0x0C]
	@ format 2: add/sub register and 3-bit immediate
	mov	r0, #200
	mov	r1, #55
	add	r2, r0, r1
	sub	r3, r0, r1
	add	r4, r2, #7
	sub	r5, r3, #7
	str	r2, [r7, #0x10]
	str	r3, [r7, #0x14]
	str	r4, [r7, #0x18]
	str	r5, [r7, #0x1C]
	@ format 3: 8-bit immediates
	mov	r0, #255
	cmp	r0, #255
	add	r0, #1
	sub	r0, #2
	str	r0, [r7, #0x20]
	@ format 4: ALU operations
	ldr	r0, =0xF0F0F0F0
	ldr	r1, =0x12345678
	mov	r2, r0
	and	r2, r1
	str	r2, [r7, #0x24]
	mov	r2, r0
	eor	r2, r1
	str	r2, [r7, #0x28]
	mov	r2, r0
	orr	r2, r1
	str	r2, [r7, #0x2C]
	mov	r2, r0
	bic	r2, r1
	str	r2, [r7, #0x30]
	mvn	r2, r1
	str	r2, [r7, #0x34]
	neg	r2, r1
	str	r2, [r7, #0x38]
	mov	r4, #4
	mov	r2, r1
	ror	r2, r4
	str	r2, [r7, #0x3C]
	mov	r2, r1
	lsl	r2, r4			@ shifts by register, flags in the trace
	lsr	r2, r4
	asr	r2, r4
	mov	r4, #40
	lsl	r2, r4			@ by 40: 0, C = 0
	mov	r4, #32
	lsr	r1, r4			@ by 32: 0, C = bit 31

	@ PC-relative loads: the first LDR is at a word-aligned address
	.align	2
	ldr	r0, t_lit1
	str	r0, [r7, #0x40]
	nop
	ldr	r0, t_lit2		@ (word-aligned address + 6)
	str	r0, [r7, #0x44]
	.align	2
	nop
t_addpc_at:				@ bit 1 set
	add	r0, pc, #4		@ ((t_addpc_at + 4) & ~3) + 4
	str	r0, [r7, #0x48]
	b	1f
	.align	2
t_lit1:	.word	0x11223344
t_lit2:	.word	0x55667788
1:	@ carry in and flags
	mov	r0, #0
	mvn	r0, r0			@ -1
	mov	r1, #1
	add	r2, r0, r1		@ 0: C=1 Z=1
	adc	r2, r1			@ 1 + 1 + 1
	str	r2, [r7, #0x4C]
	sub	r3, r1, r0		@ 1 - (-1) = 2, borrow: C=0
	sbc	r3, r1			@ 2 - 1 - 1
	str	r3, [r7, #0x54]
	tst	r0, r1
	cmn	r0, r1
	cmp	r1, r0
	@ BL and LR
	bl	t_sub
t_bl_ret:
	@ SWI and undefined from Thumb
	swi	0x12
t_swi_ret:
	.short	0xDE00			@ B with condition 1110: undefined
t_und_ret:
	@ hi registers: ADD, CMP, MOV (no flags but CMP)
	mov	r8, r7
	mov	r0, #0x10
	add	r8, r0
	mov	r1, r8
	sub	r1, r7
	cmp	r8, r7
	mov	r9, sp
	mov	r2, sp
	cmp	r2, r9
	mov	r10, r1
	add	r10, r10
	@ load/store with register offset; halfwords, signed
	mov	r0, #0x70
	ldr	r1, =0x8899AABB
	str	r1, [r7, r0]		@ +0x70
	mov	r2, #0x72
	ldrh	r3, [r7, r2]		@ 0x8899
	ldrb	r4, [r7, r2]		@ 0x99
	ldsh	r5, [r7, r2]		@ 0xFFFF8899
	mov	r2, #0x73
	ldsb	r6, [r7, r2]		@ 0xFFFFFF88
	mov	r2, #0x80
	add	r2, r7
	str	r3, [r2, #0x00]
	str	r4, [r2, #0x04]
	str	r5, [r2, #0x08]
	str	r6, [r2, #0x0C]
	mov	r2, #0x74
	strh	r1, [r7, r2]		@ 0xAABB at +0x74
	mov	r2, #0x77
	strb	r1, [r7, r2]		@ 0xBB at +0x77
	@ immediate offsets (base r2 = r7 + 0x70)
	mov	r2, #0x70
	add	r2, r7
	ldr	r3, [r2, #0]
	ldrb	r4, [r2, #1]
	ldrh	r5, [r2, #2]
	strb	r4, [r2, #8]
	strh	r5, [r2, #10]
	str	r3, [r2, #12]
	@ SP-relative, ADD Rd, SP, ADD SP, PUSH/POP
	sub	sp, #16
	str	r3, [sp, #0]
	str	r4, [sp, #12]
	ldr	r0, [sp, #12]
	add	r1, sp, #8
	mov	r2, sp
	sub	r1, r2			@ 8
	add	sp, #16
	mov	r2, #0x80
	add	r2, r7
	str	r0, [r2, #0x10]
	str	r1, [r2, #0x14]
	@ SP-relative addresses are SP + offset: store through SP, load through
	@ another register, and the other way round (upstream ZAP used SP - offset,
	@ which a store and load both through SP do not show)
	sub	sp, #16
	ldr	r0, =0x5A5A0001
	str	r0, [sp, #4]
	add	r1, sp, #4
	ldr	r3, [r1]		@ 0x5A5A0001
	ldr	r0, =0x5A5A0002
	str	r0, [r1, #8]		@ SP + 12
	ldr	r0, [sp, #12]		@ 0x5A5A0002
	add	sp, #16
	str	r3, [r2, #0x34]		@ +0xB4
	str	r0, [r2, #0x38]		@ +0xB8
	push	{r0-r3, lr}
	pop	{r4-r7}
	pop	{r0}
	ldr	r7, =SIG_DATA
	@ POP {pc} with bit 0 clear: no change of state on ARMv4T
	adr	r0, t_pop_target
	push	{r0}
	pop	{pc}
	.align	2
t_pop_target:
	ldr	r0, =0x7777
	str	r0, [r7, #0x68]
	@ multiply
	ldr	r0, =0x12345678
	ldr	r1, =0x9ABCDEF1
	mul	r1, r0
	str	r1, [r7, #0x6C]
	@ LDMIA/STMIA with writeback
	mov	r0, #0xA0
	add	r0, r7
	mov	r1, #1
	mov	r2, #2
	mov	r3, #3
	stmia	r0!, {r1-r3}
	sub	r0, #12
	ldmia	r0!, {r4-r6}
	sub	r0, r7			@ 0xAC
	mov	r2, #0x80
	add	r2, r7
	str	r0, [r2, #0x30]		@ +0xB0
	@ conditional branches
	mov	r6, #0
	mov	r0, #0
	mov	r1, #1			@ 0 - 1: N=1 Z=0 C=0 V=0
	TCOND	eq, 0x01
	TCOND	ne, 0x02
	TCOND	cs, 0x04
	TCOND	cc, 0x08
	TCOND	mi, 0x10
	TCOND	pl, 0x20
	TCOND	hi, 0x40
	TCOND	ge, 0x80
	str	r6, [r2, #0x18]		@ +0x98
	mov	r6, #0
	mov	r0, #1			@ 1 - 1: Z=1 C=1
	TCOND	eq, 0x01
	TCOND	ne, 0x02
	TCOND	cs, 0x04
	TCOND	cc, 0x08
	TCOND	mi, 0x10
	TCOND	pl, 0x20
	TCOND	hi, 0x40
	TCOND	lt, 0x80
	str	r6, [r2, #0x1C]		@ +0x9C
	@ back to ARM
	ldr	r0, =arm_back
	bx	r0

t_sub:
	mov	r0, lr
	str	r0, [r7, #0x50]
	bx	lr			@ LR bit 0 set: stays in Thumb

	.ltorg
