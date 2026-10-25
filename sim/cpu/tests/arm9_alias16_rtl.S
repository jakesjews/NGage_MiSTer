@ SPDX-License-Identifier: GPL-3.0-or-later
@ Cached synonyms: one physical line written through one virtual address
@ and read through another, the IPC shape of the moving memory model (the
@ kernel writes a client's buffer through its home address, the client
@ reads it at its run address). The 16 KB two-way D-cache indexes with
@ VA[12:4], one bit above the 4 KB page, so two VAs of one page that
@ differ in bit 12 use different sets (colours); at 8 KB every synonym of
@ a line shares its set. The cache is VIVT: nothing keeps two cached
@ copies coherent, so only some outcomes are architectural. Those are
@ checked here; every other outcome is recorded, and V2's record must
@ equal ZAP's at the same cache size (the same program, the same cache).
@
@ Mappings of PA 0x00500000 (WB = write-back, WT = write-through):
@   A 0x01000000 section WB            D 0x01100000 section WB
@   T 0x01200000 section WT            C 0x02100000 small pages WB
@   B 0x02000000 small pages WB, page n -> PA page n^1 (VA[12] flipped)
@ Pairs (writer -> reader): A->D, A->C (same colour), A->B, B->A, C->B
@ (other colour at 16 KB), T->B (write-through, other colour).
@ Per case, after a clean+invalidate of the whole cache and OLD in memory:
@   pre:    the reader's line loaded first (a stale clean copy) and/or the
@           writer's line loaded first (the store hits)
@   write:  str, strh, strb, stm of the line, a 256-byte stm stream ending
@           on the line whose allocations evict dirty lines (write-backs in
@           flight), or str then two loads that evict the written line
@   maint:  none (the kernel's IPC copy), clean+invalidate or clean of the
@           writer's line by MVA
@   timing: the reader's load right after, after 3 or 16 instructions, or
@           right after a load miss to another line (hit-under-miss)
@ then the reader's four words (V), memory through the uncached identity
@ map (M), and memory after a whole-cache clean (F) are classified per
@ word: 1 = the written value, 0 = the old one, 3 = anything else.
@ Architectural checks: F is the written line; after the writer's line
@ was cleaned M is, and so is V when the reader had no copy; WT: M and V
@ (no reader copy) are written values; the evicted written line is in
@ memory, and V is when the reader had no copy.
@ Results (SIG_DATA): +0 failed checks, +4 first (case << 8 | check),
@ +8 cases, +12 a sum of every word read, +0x10 one word per case:
@ V codes [7:0], M [15:8], F [23:16] (two bits per word), checks [31:24].
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	PA, 0x00500000
	.equ	VA_A, 0x01000000
	.equ	VA_D, 0x01100000
	.equ	VA_T, 0x01200000
	.equ	VA_B, 0x02000000
	.equ	VA_C, 0x02100000
	.equ	CB_TAB, L2_AREA			@ coarse tables, 1 KB each
	.equ	CC_TAB, L2_AREA + 0x400
	.equ	XOFF1, 0x80000			@ two other tags of a line's set
	.equ	XOFF2, 0xC0000
	.equ	HOFF, 0x40800			@ a line of another set
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_CASES, SIG_DATA + 8
	.equ	RES_SUM, SIG_DATA + 12
	.equ	RES_TABLE, SIG_DATA + 0x10
	@ driver state (st)
	.equ	ST_PAIR, 0
	.equ	ST_PRE, 4
	.equ	ST_FORM, 8
	.equ	ST_MAINT, 12
	.equ	ST_TIM, 16
	.equ	ST_CASE, 20
	.equ	ST_OFF, 24
	.equ	ST_W, 28
	.equ	ST_R, 32
	.equ	ST_OLD, 36			@ 4 words
	.equ	ST_NEW, 52			@ 4 words: the expected line
	.equ	ST_V, 68			@ 4 words read
	.text
	.arm
	.global	test_main

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, PA, 3, 0, 3
	SETL1	VA_A, r1
	SETL1	VA_D, r1
	SECT	r1, PA, 3, 0, 2			@ C=1 B=0: write-through
	SETL1	VA_T, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	@ coarse tables: B flips VA[12], C maps page n to page n
	ldr	r0, =CB_TAB
	ldr	r1, =CC_TAB
	ldr	r2, =(PA | 0xFFE)		@ small page, AP 11 x4, C=B=1
	mov	r3, #0
1:	eor	r4, r3, #1
	add	r4, r2, r4, lsl #12
	str	r4, [r0, r3, lsl #2]
	add	r4, r2, r3, lsl #12
	str	r4, [r1, r3, lsl #2]
	add	r3, r3, #1
	cmp	r3, #256
	bne	1b
	ldr	r1, =(CB_TAB | 0x10 | 1)
	SETL1	VA_B, r1
	ldr	r1, =(CC_TAB | 0x10 | 1)
	SETL1	VA_C, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r0, =RES_FAILS
	mov	r1, #0
	str	r1, [r0]
	str	r1, [r0, #4]
	str	r1, [r0, #8]
	str	r1, [r0, #12]
	ldr	r11, =st
	str	r1, [r11, #ST_CASE]
	@ pair, pre, form, maint, timing
	mov	r0, #0
	str	r0, [r11, #ST_PAIR]
2:	mov	r0, #0
	str	r0, [r11, #ST_PRE]
3:	mov	r0, #0
	str	r0, [r11, #ST_FORM]
4:	mov	r0, #0
	str	r0, [r11, #ST_MAINT]
5:	mov	r0, #0
	str	r0, [r11, #ST_TIM]
6:	bl	one_case
	ldr	r11, =st
	ldr	r0, [r11, #ST_TIM]
	add	r0, r0, #1
	str	r0, [r11, #ST_TIM]
	cmp	r0, #4
	bne	6b
	ldr	r0, [r11, #ST_MAINT]
	add	r0, r0, #1
	str	r0, [r11, #ST_MAINT]
	cmp	r0, #3
	bne	5b
	ldr	r0, [r11, #ST_FORM]
	add	r0, r0, #1
	str	r0, [r11, #ST_FORM]
	cmp	r0, #6
	bne	4b
	ldr	r0, [r11, #ST_PRE]
	add	r0, r0, #1
	str	r0, [r11, #ST_PRE]
	cmp	r0, #4
	bne	3b
	ldr	r0, [r11, #ST_PAIR]
	add	r0, r0, #1
	str	r0, [r11, #ST_PAIR]
	cmp	r0, #6
	bne	2b
	ldr	r0, =RES_FIRST
	ldr	r0, [r0]
	CHECK	r0, 0
	ldr	r0, =RES_FAILS
	ldr	r0, [r0]
	CHECK	r0, 0
	ldr	r0, =RES_CASES
	ldr	r0, [r0]
	CHECK	r0, 6 * 4 * 6 * 3 * 4
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ classify 4 words at r0 against OLD (st+ST_OLD) and NEW (st+ST_NEW):
@ returns r0 = 2 bits a word (1 new, 0 old, 3 other), adds them to the sum.
@ Uses r1-r3; r11 = st.
classify:
	stmfd	sp!, {r4-r7, lr}
	mov	r4, #0
	mov	r5, #0
1:	ldr	r1, [r0, r5, lsl #2]
	ldr	r2, =RES_SUM
	ldr	r3, [r2]
	add	r3, r3, r1
	str	r3, [r2]
	add	r2, r11, #ST_NEW
	ldr	r2, [r2, r5, lsl #2]
	add	r3, r11, #ST_OLD
	ldr	r3, [r3, r5, lsl #2]
	mov	r6, #3
	cmp	r1, r3
	moveq	r6, #0
	cmp	r1, r2
	moveq	r6, #1
	mov	r7, r5, lsl #1
	orr	r4, r4, r6, lsl r7
	add	r5, r5, #1
	cmp	r5, #4
	bne	1b
	mov	r0, r4
	ldmfd	sp!, {r4-r7, pc}
	.ltorg

@ one case from st's pair, pre, form, maint and timing
one_case:
	stmfd	sp!, {r4-r11, lr}
	ldr	r11, =st
	@ the line: PA page 0 or 1, offsets 0x100-0xFF0 (room for the stream)
	ldr	r0, [r11, #ST_CASE]
	and	r1, r0, #1
	mov	r1, r1, lsl #12
	add	r2, r0, r0, lsl #1		@ case * 0x130 & 0xEF0
	add	r2, r2, r0, lsl #4
	mov	r2, r2, lsl #4
	and	r2, r2, #0xEF0
	add	r2, r2, #0x100
	orr	r1, r1, r2
	str	r1, [r11, #ST_OFF]
	@ the writer's and the reader's VAs
	ldr	r2, [r11, #ST_PAIR]
	ldr	r3, =pairs
	add	r3, r3, r2, lsl #4
	ldmia	r3, {r4-r7}			@ writer base, flip, reader base, flip
	eor	r8, r1, r5, lsl #12
	add	r8, r8, r4
	str	r8, [r11, #ST_W]
	eor	r8, r1, r7, lsl #12
	add	r8, r8, r6
	str	r8, [r11, #ST_R]
	@ the whole cache clean and empty, OLD in memory
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r0, [r11, #ST_CASE]
	ldr	r2, =0xA0000055
	orr	r2, r2, r0, lsl #12
	ldr	r3, =PA
	add	r3, r3, r1			@ the uncached identity map
	add	r4, r11, #ST_OLD
	mov	r5, #4
1:	str	r2, [r3], #4
	str	r2, [r4], #4
	add	r2, r2, #0x100
	subs	r5, r5, #1
	bne	1b
	@ the written values and the expected line
	ldr	r6, =0xB000000F
	orr	r6, r6, r0, lsl #8
	add	r8, r6, #0x10
	add	r9, r6, #0x20
	add	r10, r6, #0x30
	ldr	r4, [r11, #ST_OLD]
	ldr	r5, [r11, #ST_OLD + 4]
	ldr	r7, [r11, #ST_OLD + 8]
	ldr	r12, [r11, #ST_OLD + 12]
	ldr	r0, [r11, #ST_FORM]
	cmp	r0, #3
	cmpne	r0, #4
	moveq	r4, r6				@ stm, stream: the four words
	moveq	r5, r8
	moveq	r7, r9
	moveq	r12, r10
	cmp	r0, #0
	cmpne	r0, #5
	moveq	r4, r6				@ str
	cmp	r0, #1				@ strh at +2
	moveq	r4, r4, lsl #16
	moveq	r4, r4, lsr #16
	orreq	r4, r4, r6, lsl #16
	cmp	r0, #2				@ strb at +1
	biceq	r4, r4, #0xFF00
	andeq	r3, r6, #0xFF
	orreq	r4, r4, r3, lsl #8
	add	r3, r11, #ST_NEW
	stmia	r3, {r4, r5, r7, r12}
	ldr	r4, [r11, #ST_W]
	ldr	r5, [r11, #ST_R]
	add	r11, r4, #XOFF1			@ r11, r12: the writer's set, other tags
	add	r12, r4, #XOFF2
	ldr	r7, =HOFF
	add	r7, r4, r7			@ another set (hit-under-miss)
	@ stream: both ways of its 16 sets dirty first, so that its
	@ allocations write lines back while the reader's load issues
	cmp	r0, #4
	bne	2f
	sub	r1, r11, #0xF0
	sub	r3, r12, #0xF0
	mov	r2, #16
3:	str	r2, [r1], #16
	str	r2, [r3], #16
	subs	r2, r2, #1
	bne	3b
2:	@ pre: bit 0 the reader's copy, bit 1 the writer's line
	ldr	r1, =st
	ldr	r2, [r1, #ST_PRE]
	tst	r2, #1
	ldrne	r3, [r5]
	tst	r2, #2
	ldrne	r3, [r4]
	@ the snippet for form, maint, timing
	ldr	r2, [r1, #ST_MAINT]
	ldr	r3, [r1, #ST_TIM]
	add	r2, r3, r2, lsl #2		@ maint * 4 + timing
	add	r0, r0, r0, lsl #1		@ form * 12
	add	r2, r2, r0, lsl #2
	ldr	r3, =snips
	ldr	r3, [r3, r2, lsl #2]
	mov	lr, pc
	mov	pc, r3
	ldr	r11, =st
	add	r12, r11, #ST_V
	stmia	r12, {r0-r3}
	@ V, M, F
	mov	r0, r12
	bl	classify
	mov	r9, r0
	ldr	r0, [r11, #ST_OFF]
	ldr	r1, =PA
	add	r0, r0, r1
	ldmia	r0, {r1-r4}
	stmia	r12, {r1-r4}
	mov	r0, r12
	bl	classify
	orr	r9, r9, r0, lsl #8
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r0, [r11, #ST_OFF]
	ldr	r1, =PA
	add	r0, r0, r1
	ldmia	r0, {r1-r4}
	stmia	r12, {r1-r4}
	mov	r0, r12
	bl	classify
	orr	r9, r9, r0, lsl #16
	@ the architectural checks (bits 24+)
	ldr	r0, =0xFF
	mov	r8, #0
	and	r1, r0, r9, lsr #16		@ F: the written line
	cmp	r1, #0x55
	orrne	r8, r8, #1
	ldr	r2, [r11, #ST_PRE]
	ldr	r3, [r11, #ST_MAINT]
	ldr	r4, [r11, #ST_FORM]
	ldr	r5, [r11, #ST_PAIR]
	and	r6, r0, r9, lsr #8		@ M
	and	r7, r0, r9			@ V
	@ cleaned (maint), write-through (pair 4) or evicted (form 5)
	mov	r1, #0
	cmp	r3, #0
	movne	r1, #1
	cmp	r5, #4
	moveq	r1, #1
	cmp	r4, #5
	moveq	r1, #1
	cmp	r1, #0
	beq	4f
	cmp	r6, #0x55
	orrne	r8, r8, #2			@ memory holds it
	tst	r2, #1
	bne	4f
	cmp	r7, #0x55
	orrne	r8, r8, #4			@ the reader without a copy sees it
4:	orr	r9, r9, r8, lsl #24
	ldr	r0, [r11, #ST_CASE]
	ldr	r1, =RES_TABLE
	str	r9, [r1, r0, lsl #2]
	cmp	r8, #0
	beq	5f
	ldr	r1, =RES_FAILS
	ldr	r2, [r1]
	add	r2, r2, #1
	str	r2, [r1]
	ldr	r1, =RES_FIRST
	ldr	r2, [r1]
	cmp	r2, #0
	orreq	r2, r8, r0, lsl #8
	streq	r2, [r1]
5:	add	r0, r0, #1
	str	r0, [r11, #ST_CASE]
	ldr	r1, =RES_CASES
	str	r0, [r1]
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ The timed part. In: r4 the writer's line, r5 the reader's, r6 r8 r9 r10
@ the values, r7 a line of another set, r11 r12 two other tags of the
@ writer's set. Out: r0-r3 the reader's four words.
	.macro	SNIP form, maint, tim
snip_\form\()_\maint\()_\tim:
	.if \form == 0
	str	r6, [r4]
	.elseif \form == 1
	strh	r6, [r4, #2]
	.elseif \form == 2
	strb	r6, [r4, #1]
	.elseif \form == 3
	stmia	r4, {r6, r8, r9, r10}
	.elseif \form == 4
	sub	r0, r4, #0xF0
	.rept	16
	stmia	r0!, {r6, r8, r9, r10}
	.endr
	.else
	str	r6, [r4]
	ldr	r11, [r11]			@ both ways of the set replaced:
	ldr	r12, [r12]			@ the written line goes back
	.endif
	.if \maint == 1
	mcr	p15, 0, r4, c7, c14, 1
	.elseif \maint == 2
	mcr	p15, 0, r4, c7, c10, 1
	.endif
	.if \tim == 1
	.rept	3
	nop
	.endr
	.elseif \tim == 2
	.rept	16
	nop
	.endr
	.elseif \tim == 3
	ldr	r3, [r7]			@ a miss pending
	.endif
	ldr	r0, [r5]
	ldr	r1, [r5, #4]
	ldr	r2, [r5, #8]
	ldr	r3, [r5, #12]
	mov	pc, lr
	.endm

	.irp	form, 0, 1, 2, 3, 4, 5
	.irp	maint, 0, 1, 2
	.irp	tim, 0, 1, 2, 3
	SNIP	\form, \maint, \tim
	.endr
	.endr
	.endr

	.data
	.align	4
@ writer base, its VA[12] flip, reader base, its flip
pairs:
	.word	VA_A, 0, VA_D, 0
	.word	VA_A, 0, VA_C, 0
	.word	VA_A, 0, VA_B, 1
	.word	VA_B, 1, VA_A, 0
	.word	VA_T, 0, VA_B, 1
	.word	VA_C, 0, VA_B, 1
	.macro	SNIPW form, maint, tim
	.word	snip_\form\()_\maint\()_\tim
	.endm
snips:
	.irp	form, 0, 1, 2, 3, 4, 5
	.irp	maint, 0, 1, 2
	.irp	tim, 0, 1, 2, 3
	SNIPW	\form, \maint, \tim
	.endr
	.endr
	.endr
st:	.space	96
