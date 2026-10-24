@ SPDX-License-Identifier: GPL-3.0-or-later
@ A redirect taken while the I-fill of its own line is outstanding, with
@ the new path's line cold so that a second fill follows. The bench runs
@ this test with every I-fill provisional (--icache-quarantine), so the
@ words of the first fill sit in the fetch queue as pending entries that
@ the fill's completion releases; the redirect must discard them, and
@ the second fill's entries must not be released by the first fill.
@
@ After invalidating the I-cache, a case enters line A at word e (0-3,
@ so the critical word is e and the fill wraps), executes 0 or 1 plain
@ instruction, then the redirect (rk): 0 b, 1 beq (taken), 2 bx r3,
@ 3 mov pc,r3, 4 ldr pc,[r4], 5 svc. Every other word of A and of the
@ next line is poison (mov r2, #0xBA). The target (bk) is 0 two lines
@ ahead of A or 1 far away (cold either way); it sets r6 bit by bit.
@ Each case runs twice (BTB untrained, then trained), at the bench
@ latency and at fixed latencies of 8 and 24. The test fails with the
@ first case: number << 8 | error bits (1 poison retired, 2 target
@ words wrong, 4 the plain instruction lost or repeated).
@@ qemu: no
@@ bench: --icache-quarantine
	.include "test.inc"
	.include "mmu.inc"
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	.macro	POISON n
	.rept	\n
	mov	r2, #0xBA
	.endr
	.endm

	.macro	CASE rk, e, p, bk
	.if (\e + \p) > 3
	.exitm
	.endif
	mov	r8, #2
.Lagain\@:
	adr	r3, .Lb\@
	.if \bk == 1
	ldr	r3, =.Lfar\@
	.endif
	adr	r4, .Lptr\@
	str	r3, [r4]
	mov	r0, #VEC_SWI
	str	r3, [r0]
	mov	r1, #0
	mov	r2, #0
	mov	r6, #0
	cmp	r0, r0			@ Z for beq
	mcr	p15, 0, r1, c7, c10, 4	@ drain (the pointer and vector stores)
	mcr	p15, 0, r1, c7, c5, 0	@ invalidate the I-cache
	b	.Lent\@
	.balign	16
.La\@:
	POISON	\e
.Lent\@:
	.if \p
	add	r1, r1, #0x10
	.endif
	.if \rk == 0 && \bk == 0
	b	.Lb\@
	.elseif \rk == 0
	b	.Lfar\@
	.elseif \rk == 1 && \bk == 0
	beq	.Lb\@
	.elseif \rk == 1
	beq	.Lfar\@
	.elseif \rk == 2
	bx	r3
	.elseif \rk == 3
	mov	pc, r3
	.elseif \rk == 4
	ldr	pc, [r4]
	.else
	svc	#0
	.endif
	POISON	(3 - \e - \p)
	POISON	4			@ the next line, sequential wrong path
.Lb\@:
	.if \bk == 0
	orr	r6, r6, #1
	orr	r6, r6, #2
	orr	r6, r6, #4
	b	.Lback\@
	.else
	POISON	4			@ not the target in this variant
	.endif
.Lback\@:
	msr	cpsr_c, #0xD3
	mov	r0, #0
	cmp	r2, #0
	orrne	r0, r0, #1
	cmp	r6, #7
	orrne	r0, r0, #2
	.if \p
	cmp	r1, #0x10
	.else
	cmp	r1, #0
	.endif
	orrne	r0, r0, #4
	mov	r2, #0
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.ltorg
	.balign	4
.Lptr\@:
	.word	0
	.subsection 1
	.balign	16
.Lfar\@:
	.if \bk == 1
	orr	r6, r6, #1
	orr	r6, r6, #2
	orr	r6, r6, #4
	b	.Lback\@
	.endif
	.balign	16
	POISON	4
	.subsection 0
.Lend\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	@ cacheable identity sections (the D-cache stays off), I-cache on
	bl	mmu_on
	ldr	r0, =TTB
	ldr	r1, =0x00000C1E
	mov	r2, #16
1:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	1b
	SECT	r0, BENCH, 3, 0, 0
	SETL1	BENCH, r0
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r11, =RES_TABLE
	ldr	r0, =RES_FAILS
	mov	r1, #0
	str	r1, [r0]
	str	r1, [r0, #4]
	mov	r10, #0
	mov	r1, #2
	ldr	r0, =CONFIG
	str	r1, [r0]
config:
	ldr	r0, =CONFIG
	ldr	r1, [r0]
	cmp	r1, #1
	movhi	r1, #0
	moveq	r1, #8
	movlo	r1, #24
	ldr	r0, =BENCH
	str	r1, [r0, #BENCH_LATENCY]
	b	cases
	.ltorg
cases:
	.irp rk, 0, 1, 2, 3, 4, 5
	.irp bk, 0, 1
	.irp e, 0, 1, 2, 3
	.irp p, 0, 1
	CASE	\rk, \e, \p, \bk
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
	ldmfd	sp!, {r4-r11, pc}
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
	orreq	r1, r0, r10, lsl #8
	streq	r1, [r6, #4]
	mov	pc, lr
	.ltorg

	.data
	.align	2
CONFIG:	.word	0
