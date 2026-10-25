@ SPDX-License-Identifier: GPL-3.0-or-later
@ A load hitting a departing line, followed by younger writers of its
@ destination that also READ it (the board's second V2 death, 25.25 s:
@ Symbian's handle lookup caller at 0x503CBDC4, Thumb):
@
@	ldr	r0, [r0, #36]		@ miss: its fill evicts the literal line
@	ldr	r2, [pc, #12]		@ the literal: hits the departing line
@	ldr	r2, [r2, #0]		@ reads and writes r2
@	ldr	r2, [r2, #4]		@ reads and writes r2
@	...				@ r2 read much later (orr r1, r1, r2, lsl #16)
@
@ isa: 0 ARM, 1 Thumb. trig: the access just before, 0 a load miss (the
@ board's), 1 a store miss, to another line of the literal's set.
@ chain (ck): 0 ldr r2,[r2]; ldr r2,[r2,#4], 1 ldr r2,[r2], 2 add r2,#4,
@ 3 r2 lsl #1. gap: 0-2 instructions between the literal load and the
@ chain. victim: the set's other way 0 clean, 1 dirty. Each case runs
@ twice (cold and warm I-cache), at the bench latency and at 24. The
@ final r2 is read after a call, from the register file. The test fails
@ with the first case: number << 8 | 1.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000
	.equ	P0, 0x00410E90		@ the literal's value
	.equ	P1, 0x00410ED0		@ the word at P0
	.equ	V3, 0x00000A24		@ the word at P1 + 4
	.equ	XBASE1, 0x00420000
	.equ	XBASE2, 0x00440000
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	.macro	CASE isa, trig, ck, gap, vic
	mov	r8, #2
.Lagain\@:
	adr	r9, .Llit\@
	mov	r1, #\vic
	bl	prepare			@ r4 = the evicting line, r3 = 0
	ldr	r2, =0x0BADBAD0
	mov	r1, #0
	.if \isa
	adr	r0, .Lthumb\@ + 1
	bx	r0
	.thumb
.Lthumb\@:
	.if \trig
	str	r3, [r4]
	.else
	ldr	r0, [r4]
	.endif
	ldr	r2, .Llit\@
	.rept	\gap
	mov	r8, r8
	.endr
	.if \ck == 0
	ldr	r2, [r2, #0]
	ldr	r2, [r2, #4]
	.elseif \ck == 1
	ldr	r2, [r2, #0]
	.elseif \ck == 2
	add	r2, #4
	.else
	lsl	r2, r2, #1
	.endif
	bl	.Lcall\@
	adr	r0, .Larm\@
	bx	r0
	.balign	4
.Lcall\@:
	.rept	8
	mov	r8, r8
	.endr
	bx	lr
	.balign	4
	.arm
.Larm\@:
	.else
	.if \trig
	str	r3, [r4]
	.else
	ldr	r0, [r4]
	.endif
	ldr	r2, .Llit\@
	.rept	\gap
	mov	r8, r8
	.endr
	.if \ck == 0
	ldr	r2, [r2, #0]
	ldr	r2, [r2, #4]
	.elseif \ck == 1
	ldr	r2, [r2, #0]
	.elseif \ck == 2
	add	r2, r2, #4
	.else
	mov	r2, r2, lsl #1
	.endif
	bl	.Lcall\@
	b	.Lafter\@
.Lcall\@:
	.rept	8
	mov	r8, r8
	.endr
	mov	pc, lr
	.endif
.Lafter\@:
	orr	r0, r1, r2, lsl #0	@ r2 from the register file
	.if \ck == 0
	ldr	r2, =V3
	.elseif \ck == 1
	ldr	r2, =P1
	.elseif \ck == 2
	ldr	r2, =(P0 + 4)
	.else
	ldr	r2, =(P0 << 1)
	.endif
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.ltorg
	.balign	256
.Llit\@:
	.word	P0, 0, 0, 0
.Lend\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r11, =RES_TABLE
	ldr	r0, =RES_FAILS
	mov	r1, #0
	str	r1, [r0]
	str	r1, [r0, #4]
	mov	r10, #0
	mov	r1, #1
	ldr	r0, =CONFIG
	str	r1, [r0]
config:
	ldr	r0, =CONFIG
	ldr	r1, [r0]
	cmp	r1, #1
	moveq	r1, #0
	movne	r1, #24
	ldr	r0, =BENCH
	str	r1, [r0, #BENCH_LATENCY]
	b	cases
	.ltorg
cases:
	.irp isa, 0, 1
	.irp trig, 0, 1
	.irp ck, 0, 1, 2, 3
	.irp gap, 0, 1, 2
	.irp vic, 0, 1
	CASE	\isa, \trig, \ck, \gap, \vic
	.endr
	.endr
	.endr
	.endr
	.endr
	ldr	r0, =CONFIG
	ldr	r1, [r0]
	subs	r1, r1, #1
	str	r1, [r0]
	bpl	config
	ldr	r0, =BENCH
	mov	r1, #0
	str	r1, [r0, #BENCH_LATENCY]
	ldr	r0, =RES_FIRST
	ldr	r0, [r0]
	CHECK	r0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ r9 = the literal's address, r1 = 1 for a dirty other way. Puts the
@ literal's line in the D-cache as the LRU way of its set. Returns r4 =
@ an uncached line of that set, r3 = 0. No literal load after the
@ invalidation.
prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r6, =(UNC + P0 - 0x00400000)
	ldr	r0, =P1
	str	r0, [r6]
	ldr	r6, =(UNC + P1 - 0x00400000)
	ldr	r0, =V3
	str	r0, [r6, #4]
	ldr	r5, =P0
	ldr	r7, =P1
	ldr	r0, =0x1FF0
	and	r0, r9, r0
	ldr	r4, =XBASE2
	add	r4, r4, r0
	ldr	r6, =XBASE1
	add	r6, r6, r0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r0, [r5]
	ldr	r0, [r7]
	ldr	r0, [r9]		@ the literal's line
	cmp	r1, #1
	streq	r0, [r6]		@ the other way, MRU (dirty)
	ldr	r0, [r6]
	mov	r3, #0
	mov	pc, lr
	.ltorg

@ r0 = observed, r2 = expected; r8 = pass, r10 = case, r11 = table
verify:
	mov	r3, #0
	cmp	r0, r2
	movne	r3, #1
	add	r6, r11, r10, lsl #4
	cmp	r8, #2
	streq	r3, [r6]
	strne	r3, [r6, #4]
	str	r0, [r6, #8]
	str	r2, [r6, #12]
	cmp	r3, #0
	moveq	pc, lr
	ldr	r6, =RES_FAILS
	ldr	r1, [r6]
	add	r1, r1, #1
	str	r1, [r6]
	ldr	r1, [r6, #4]
	cmp	r1, #0
	orreq	r1, r3, r10, lsl #8
	streq	r1, [r6, #4]
	mov	pc, lr
	.ltorg

	.data
	.align	2
CONFIG:	.word	0
