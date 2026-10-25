@ SPDX-License-Identifier: GPL-3.0-or-later
@ The short-hit trust, swept over a D-cache fill. A first access misses
@ (the trigger); after a gap of 0-13 instructions a load reads a target
@ line whose short hit V2 must not accept at some clock of that fill, and
@ a younger writer of the loaded register that also reads it follows at
@ distance 1 or 2 (with a plain reader in between). Such a writer waits
@ for an accepted hit; if it took an unaccepted word and retired, the
@ load's later return would overwrite it. Each gap puts the target's W
@ clock at a different point of the fill: the FSM leaving IDLE, the
@ victim's write-back, the beats, the installation and the clock the fill
@ ends.
@
@ tk, the target: 0 the departing victim (the trigger's LRU way, the
@ other way clean; vic 1 makes the victim itself dirty), 1 the filling
@ line itself, word 2 (vic 1: both ways of its set dirty), 2 a resident
@ line of another set (vic 1: both ways of the trigger's set dirty).
@ tr: 0 a load miss, 1 a store miss that allocates (tk 0 only). sy 1: the
@ gap counts from the trigger's first word (a reader of it comes first),
@ so that the gaps reach the installation at every latency.
@ ck, the writer: 0 add r2,r2,#1 (late), 1 subs r2,r2,#VAL (late, flags:
@ Z and C set), 2 mov r2,r2,lsl #1 (early), 3 ldr r2,[r2] (an early
@ base). Every target word holds VAL, an ARM immediate and the address of
@ PTRV. The writer's result is read after a call, from the register file.
@ Each case runs twice (cold and warm I-cache) at the bench latency and
@ at fixed latencies of 8 and 24. The test fails with the first case:
@ number << 8 | error bits (1 the writer's result, 2 the reader, 4 the
@ flags).
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000
	.equ	VAL, 0x00480000		@ every target word
	.equ	PTRV, 0x2468ACE1	@ the word at VAL
	@ Sets 0x1B4, 0x2C8, 0x3D0 and 0x0E4 in D16 (their low 8 bits in D8)
	.equ	VLINE, 0x00421B40	@ tk 0: the victim
	.equ	X1LINE, 0x00441B40	@ tk 0: the set's other way
	.equ	X2LINE, 0x00461B40	@ tk 0: the trigger
	.equ	LLINE, 0x00422C80	@ tk 1: the trigger and the target
	.equ	Y1LINE, 0x00442C80
	.equ	Y2LINE, 0x00462C80
	.equ	OLINE, 0x00423D00	@ tk 2: the target
	.equ	ZLINE, 0x00420E40	@ tk 2: the trigger
	.equ	Z1LINE, 0x00440E40
	.equ	Z2LINE, 0x00460E40
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	@ an address below 16 MB without a literal (no D-cache access)
	.macro	MOVA reg, addr
	mov	\reg, #((\addr) & 0x00FF0000)
	orr	\reg, \reg, #((\addr) & 0x0000FF00)
	orr	\reg, \reg, #((\addr) & 0x000000FF)
	.endm

	.macro	CASE tk, tr, sy, ck, d, g, vic
	mov	r8, #2
.Lagain\@:
	mov	r1, #\vic
	bl	prep\tk			@ r4 = the trigger, r9 = the target
	mov	r3, #0
	.if \tr
	str	r3, [r4]
	.else
	ldr	r0, [r4]
	.endif
	.if \sy
	mov	r3, r0			@ waits for the trigger's first word
	.endif
	.rept	\g
	mov	r3, r3
	.endr
	ldr	r2, [r9]
	.if \d == 2
	add	r5, r2, #3
	.endif
	.if \ck == 0
	add	r2, r2, #1
	.elseif \ck == 1
	subs	r2, r2, #VAL
	.elseif \ck == 2
	mov	r2, r2, lsl #1
	.else
	ldr	r2, [r2]
	.endif
	.if \d == 1
	add	r5, r2, #3
	.endif
	mrs	r7, cpsr
	bl	call8
	mov	r0, #0
	.if \ck == 0
	ldr	r1, =(VAL + 1)
	.elseif \ck == 1
	mov	r1, #0
	.elseif \ck == 2
	ldr	r1, =(VAL << 1)
	.else
	ldr	r1, =PTRV
	.endif
	cmp	r2, r1
	orrne	r0, r0, #1
	.if \d == 2
	ldr	r1, =(VAL + 3)
	.else
	add	r1, r1, #3
	.endif
	cmp	r5, r1
	orrne	r0, r0, #2
	.if \ck == 1
	and	r7, r7, #0xF0000000
	cmp	r7, #0x60000000
	orrne	r0, r0, #4
	.endif
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.ltorg
.Lend\@:
	.endm

	.macro	GAPS tk, tr, sy, ck, d, vic
	.irp g, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
	CASE	\tk, \tr, \sy, \ck, \d, \g, \vic
	.endr
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
	@ the targets' words and PTRV, through the uncached alias
	ldr	r0, =VAL
	ldr	r1, =(UNC + VLINE - 0x00400000)
	str	r0, [r1]
	str	r0, [r1, #4]
	str	r0, [r1, #8]
	str	r0, [r1, #12]
	ldr	r1, =(UNC + LLINE - 0x00400000)
	str	r0, [r1]
	str	r0, [r1, #4]
	str	r0, [r1, #8]
	str	r0, [r1, #12]
	ldr	r1, =(UNC + OLINE - 0x00400000)
	str	r0, [r1]
	str	r0, [r1, #4]
	str	r0, [r1, #8]
	str	r0, [r1, #12]
	ldr	r1, =(UNC + VAL - 0x00400000)
	ldr	r0, =PTRV
	str	r0, [r1]
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
	.irp ck, 0, 1, 2, 3
	.irp d, 1, 2
	.irp vic, 0, 1
	GAPS	0, 0, 0, \ck, \d, \vic
	GAPS	0, 0, 1, \ck, \d, \vic
	GAPS	0, 1, 0, \ck, \d, \vic
	GAPS	1, 0, 0, \ck, \d, \vic
	GAPS	1, 0, 1, \ck, \d, \vic
	GAPS	2, 0, 0, \ck, \d, \vic
	GAPS	2, 0, 1, \ck, \d, \vic
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

@ The prep routines clean and invalidate the D-cache, then shape it with
@ register addresses only (no literal pool access after the invalidate).
@ VAL's line (set 0) is made resident for ck 3. r1 = vic.

@ tk 0: VLINE then X1LINE, so VLINE is the LRU way; the trigger X2LINE
@ evicts it. vic 1: VLINE dirty (with its own value).
prep0:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	MOVA	r9, VLINE
	MOVA	r6, X1LINE
	MOVA	r4, X2LINE
	mov	r5, #VAL
	ldr	r0, [r5]
	ldr	r0, [r9]
	cmp	r1, #1
	streq	r5, [r9]
	ldr	r0, [r6]
	mov	pc, lr

@ tk 1: LLINE absent; the trigger is its word 0, the target its word 2.
@ vic 1: both ways of the set dirty.
prep1:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	MOVA	r4, LLINE
	MOVA	r6, Y1LINE
	MOVA	r7, Y2LINE
	add	r9, r4, #8
	mov	r5, #VAL
	ldr	r0, [r5]
	cmp	r1, #1
	streq	r0, [r6]
	ldreq	r0, [r6]
	streq	r0, [r7]
	ldreq	r0, [r7]
	mov	pc, lr

@ tk 2: OLINE resident; the trigger ZLINE misses in another set.
@ vic 1: both ways of the trigger's set dirty.
prep2:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	MOVA	r9, OLINE
	MOVA	r4, ZLINE
	MOVA	r6, Z1LINE
	MOVA	r7, Z2LINE
	mov	r5, #VAL
	ldr	r0, [r5]
	ldr	r0, [r9]
	cmp	r1, #1
	streq	r0, [r6]
	ldreq	r0, [r6]
	streq	r0, [r7]
	ldreq	r0, [r7]
	mov	pc, lr

call8:
	.rept	8
	mov	r8, r8
	.endr
	mov	pc, lr

@ r0 = error bits; r8 = pass, r10 = case, r11 = table (a byte per pass)
verify:
	add	r6, r11, r10, lsl #1
	cmp	r8, #2
	streqb	r0, [r6]
	strneb	r0, [r6, #1]
	cmp	r0, #0
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
