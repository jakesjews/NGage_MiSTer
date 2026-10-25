@ SPDX-License-Identifier: GPL-3.0-or-later
@ An older load of r2 followed by younger writers of r2, where the older
@ load is uncached (a long blocking access, never a short hit) or an
@ uncached LDM's last word, and the chain continues through a cached
@ line (the shape of file data read from the flash and then used):
@
@ older (ok): 0 ldr r2,[unc], 1 ldmia unc,{r1,r2}, 2 ldr r2,lit (cached)
@ chain (ck): 0 ldr r2,[r2]; ldr r2,[r2,#4], 1 ldr r2,[r2], 2 add r2,#4,
@	3 ldr r2,lit2 (an independent younger writer), 4 mov r3,r2 then
@	ldr r2,lit2 (a reader, then the independent writer)
@ line (ts): the first cached line of the chain (P0's; the literal's for
@	ok 2) 0 present, 1 departing (a store miss to its set just before
@	the chain; for ok 2 before the literal), 2 absent
@ isa: ARM, Thumb. gap: 0-2 instructions before the chain.
@ Each case runs twice (cold and warm I-cache) at the bench latency and
@ at a fixed latency of 24. The test fails with the first case:
@ number << 8 | 1 (r2 wrong) | 2 (the reader's r3 wrong).
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000
	.equ	P0, 0x00410E90		@ the chain: [P0] = P1, [P1 + 4] = V3
	.equ	P1, 0x00410ED0
	.equ	V3, 0x00000A24
	.equ	Q, 0x00410F14		@ lit2's value
	.equ	WP, 0x00412000		@ [WP] junk, [WP + 4] = P0 (read uncached)
	.equ	XBASE1, 0x00420000
	.equ	XBASE2, 0x00440000
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	.macro	CASE ok, ck, ts, isa, gap
	mov	r8, #2
.Lagain\@:
	adr	r9, .Llit\@
	mov	r1, #\ok
	mov	r2, #\ts
	bl	prepare			@ r4 = the evictor, r5 = UNC alias of WP
	ldr	r2, =0x0BADBAD0
	mov	r3, #0
	.if \isa
	adr	r0, .Lthumb\@ + 1
	bx	r0
	.thumb
.Lthumb\@:
	.else
	.arm
	.endif
	.if (\ts == 1) && (\ok == 2)
	str	r3, [r4]
	.endif
	.if \ok == 0
	ldr	r2, [r5, #4]
	.elseif \ok == 1
	.if \isa
	ldmia	r5!, {r1, r2}
	.else
	ldmia	r5, {r1, r2}
	.endif
	.else
	ldr	r2, .Llit\@
	.endif
	.if (\ts == 1) && (\ok != 2)
	str	r3, [r4]
	.endif
	.rept	\gap
	mov	r8, r8
	.endr
	.if \ck == 0
	ldr	r2, [r2, #0]
	ldr	r2, [r2, #4]
	.elseif \ck == 1
	ldr	r2, [r2, #0]
	.elseif \ck == 2
	.if \isa
	add	r2, #4
	.else
	add	r2, r2, #4
	.endif
	.elseif \ck == 3
	ldr	r2, .Lqq\@
	.else
	mov	r3, r2
	ldr	r2, .Lqq\@
	.endif
	.if \isa
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
	bl	.Lcall\@
	b	.Lafter\@
.Lcall\@:
	.rept	8
	mov	r8, r8
	.endr
	mov	pc, lr
	.endif
.Lafter\@:
	mov	r0, #0
	.if \ck == 0
	ldr	r1, =V3
	.elseif \ck == 1
	ldr	r1, =P1
	.elseif \ck == 2
	ldr	r1, =(P0 + 4)
	.else
	ldr	r1, =Q
	.endif
	cmp	r2, r1
	orrne	r0, r0, #1
	.if \ck == 4
	ldr	r1, =P0
	cmp	r3, r1
	orrne	r0, r0, #2
	.endif
	mov	r2, #0
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.ltorg
	.balign	256
.Llit\@:
	.word	P0, 0, 0, 0
.Lqq\@:
	.word	Q, 0, 0, 0
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
	.irp ok, 0, 1, 2
	.irp ck, 0, 1, 2, 3, 4
	.irp ts, 0, 1, 2
	.irp isa, 0, 1
	.irp gap, 0, 1, 2
	CASE	\ok, \ck, \ts, \isa, \gap
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

@ r9 = the literal's address, r1 = ok, r2 = ts. Writes the chain words
@ through the uncached alias, cleans and invalidates the D-cache, then
@ puts the chain's first cached line (P0's, or the literal's for ok 2)
@ present (ts 0), present as the LRU way beside a dirty line (ts 1) or
@ absent (ts 2), and lit2's line present. Returns r4 = an uncached line
@ of that set, r5 = UNC alias of WP. No literal load after the
@ invalidation.
prepare:
	stmfd	sp!, {lr}
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r6, =(UNC + P0 - 0x00400000)
	ldr	r0, =P1
	str	r0, [r6]
	ldr	r6, =(UNC + P1 - 0x00400000)
	ldr	r0, =V3
	str	r0, [r6, #4]
	ldr	r5, =(UNC + WP - 0x00400000)
	ldr	r0, =0x5A5A5A5A
	str	r0, [r5]
	ldr	r0, =P0
	str	r0, [r5, #4]
	ldr	r7, =P0
	cmp	r1, #2
	moveq	r7, r9			@ the first cached line
	ldr	r0, =0x1FF0
	and	r0, r7, r0
	ldr	r4, =XBASE2
	add	r4, r4, r0
	ldr	r6, =XBASE1
	add	r6, r6, r0
	ldr	lr, =P1
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r0, [lr]		@ P1's line present
	ldr	r0, [r9, #16]		@ lit2's line present
	cmp	r2, #2
	ldrne	r0, [r7]		@ the first cached line
	cmp	r2, #1
	streq	r0, [r6]		@ its other way, MRU and dirty
	ldreq	r0, [r6]
	mov	r3, #0
	ldmfd	sp!, {pc}
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
