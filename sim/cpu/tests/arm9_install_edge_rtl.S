@ SPDX-License-Identifier: GPL-3.0-or-later
@ Loads and their readers around the installation of a filling D-cache
@ line. A first access misses on word c of the line (a load, or a store
@ that allocates and is merged into the fill); the fill returns word c
@ first and wraps (c = 0 linear, else wrapped). After a gap of 0-6
@ instructions a second load reads word k and is read at once by an
@ ALU operand (late, in A) and a shifted operand (early, in S), then a
@ third load reads word k+1 and is summed with the second. With both
@ ways of the set dirty, the victim's write-back is deferred behind the
@ installation, when the new line can hit in the background. Each case
@ runs twice (cold and warm I-cache) at the bench latency and at fixed
@ latencies of 8 and 24. Values are computed here; the test fails with
@ the first case: number << 8 | error bits (1 first load, 2 its reader,
@ 4 second load, 8 shifted reader, 16 ALU reader, 32 third load, 64 sum).
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000
	.equ	LINE, 0x00430B40	@ set 0xB4
	.equ	X1, 0x00470B40
	.equ	X2, 0x00450B40
	.equ	W_0, 0x13572460
	.equ	W_1, 0x24681371
	.equ	W_2, 0x35792482
	.equ	W_3, 0x468A3593
	.equ	SV, 0x9ABCDEF0		@ the store's word
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	@ M_n: word n of the line after the first access (fa 1 stores word c)
	.macro	EXPECT reg, n, fa, c
	.if (\fa == 1) && (\n == \c)
	ldr	\reg, =SV
	.elseif \n == 0
	ldr	\reg, =W_0
	.elseif \n == 1
	ldr	\reg, =W_1
	.elseif \n == 2
	ldr	\reg, =W_2
	.else
	ldr	\reg, =W_3
	.endif
	.endm

	.macro	CASE fa, c, k, g, vk
	mov	r8, #2
.Lagain\@:
	mov	r1, #\vk
	bl	prepare			@ r9 = LINE
	ldr	r0, =SV
	.if \fa == 0
	ldr	r1, [r9, #(\c * 4)]
	mov	r12, r1
	.else
	str	r0, [r9, #(\c * 4)]
	.endif
	.rept	\g
	mov	r3, r3
	.endr
	ldr	r2, [r9, #(\k * 4)]
	add	r5, r2, #0
	mov	r6, r2, lsl #1
	ldr	r7, [r9, #(((\k + 1) & 3) * 4)]
	add	r3, r7, r2
	@ check
	mov	r0, #0
	.if \fa == 0
	EXPECT	r4, \c, \fa, \c
	cmp	r1, r4
	orrne	r0, r0, #1
	cmp	r12, r4
	orrne	r0, r0, #2
	.endif
	EXPECT	r4, \k, \fa, \c
	cmp	r2, r4
	orrne	r0, r0, #4
	cmp	r5, r4
	orrne	r0, r0, #16
	cmp	r6, r4, lsl #1
	orrne	r0, r0, #8
	EXPECT	r1, ((\k + 1) & 3), \fa, \c
	cmp	r7, r1
	orrne	r0, r0, #32
	add	r1, r1, r4
	cmp	r3, r1
	orrne	r0, r0, #64
	mov	r2, #0
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.ltorg
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
	@ 2 bench latency, 1 latency 8, 0 latency 24
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
	.irp fa, 0, 1
	.irp vk, 0, 1
	.irp c, 0, 1, 2, 3
	.irp k, 0, 1, 2, 3
	.irp g, 0, 1, 2, 3, 4, 5, 6
	CASE	\fa, \c, \k, \g, \vk
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

@ r1 = victim kind: 0 the set empty, 1 both ways dirty (X1 the LRU).
@ Returns r9 = LINE (absent from the D-cache).
prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r6, =(UNC + LINE - 0x00400000)
	ldr	r0, =W_0
	str	r0, [r6]
	ldr	r0, =W_1
	str	r0, [r6, #4]
	ldr	r0, =W_2
	str	r0, [r6, #8]
	ldr	r0, =W_3
	str	r0, [r6, #12]
	ldr	r9, =LINE
	ldr	r4, =X1
	ldr	r5, =X2
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0
	cmp	r1, #1
	streq	r0, [r4]
	ldreq	r0, [r4]
	streq	r0, [r5]
	ldreq	r0, [r5]
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
	orreq	r1, r0, r10, lsl #8
	streq	r1, [r6, #4]
	mov	pc, lr
	.ltorg

	.data
	.align	2
CONFIG:	.word	0
