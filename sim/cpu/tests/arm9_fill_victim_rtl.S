@ SPDX-License-Identifier: GPL-3.0-or-later
@ A cached block copy whose source lines replace valid lines of other tags
@ (the board's LFFS copy, 2026-10-25): a SignalTap capture of the V2 core
@ (8 KB two-way D-cache) showed the first word of each 16-byte source line
@ coming back as the same set's older line's word (0x596e06a0's word for
@ 0x596f06a0), one clock after the previous access, and the rest of the
@ line right after its fill. Here both ways of every source set are first
@ filled with lines of two other tags (OC1 then OC2: OC1 is the LRU
@ victim), then 4 KB is copied eight words at a time, descending
@ (ldmdb/stmdb, the ROM's Mem::Copy for src < dst) or ascending, into a
@ destination offset like the ROM's (+0x408: the destination's sets are
@ the source's + 0x40), and the copy is checked word for word through the
@ uncached alias. A wrong word is classified: 1 = the victim's (OC1's)
@ word, 2 = OC2's, 4/5 = the dirty foreign line's (F1/F2, occ 3), 3 = other. Results (SIG_DATA): +0 total wrong words,
@ +4..+0x10 wrong words by word-in-line, then per case (16 bytes): wrong
@ words, first wrong offset | kind << 28, value found, value expected.
@ Cases: bus latency 0 (the model's --lat), 8 and 24 fixed; ways occupied
@ 3 (both ways DIRTY with foreign tags F1/F2, so every fill of the copy,
@ source and destination, first writes a victim back), 2, 1 (OC1 only) or
@ 0 (cold); descending then ascending. 24 cases, 16 bytes of results each.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000		@ uncached alias of PA 0x00400000
	.equ	SRC, 0x00480000		@ 4 KB cached source
	.equ	OC1, 0x00490000		@ the same sets, another tag (the LRU victim)
	.equ	OC2, 0x004A0000		@ the same sets, a third tag
	.equ	F1, 0x004D0000		@ foreign DIRTY lines in every set (occ 3)
	.equ	F2, 0x004E0000		@ a second way of them
	.equ	DSTB, 0x004C0408	@ destination = DSTB + source offset
	.equ	KEY, 0xA5A5A5A5
	.equ	LEN, 0x1000
	.equ	R_TOTAL, SIG_DATA
	.equ	R_POS, SIG_DATA + 4
	.equ	R_CASE, SIG_DATA + 0x20
	.text
	.arm
	.global	test_main

	.macro	CASE occ, down, lat, idx
	mov	r0, #\lat
	ldr	r1, =BENCH
	str	r0, [r1, #BENCH_LATENCY]
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0		@ clean the data cache
	mcr	p15, 0, r0, c7, c6, 0		@ invalidate it
	.if \occ == 3
	ldr	r1, =F1
	ldr	r2, =F2
	ldr	r3, =KEY
	mov	r4, #(LEN / 16)
	add	r4, r4, #1
1:	eor	r5, r1, r3
	str	r5, [r1], #16		@ a dirty line of a foreign tag in each way
	eor	r5, r2, r3
	str	r5, [r2], #16
	subs	r4, r4, #1
	bne	1b
	.elseif \occ
	ldr	r1, =OC1
	ldr	r2, =OC2
	mov	r3, #(LEN / 16)
1:	ldr	r4, [r1], #16
	.if \occ == 2
	ldr	r5, [r2], #16
	.endif
	subs	r3, r3, #1
	bne	1b
	.endif
	.if \down
	ldr	r1, =(SRC + LEN)
	ldr	r0, =(DSTB + LEN)
	ldr	r2, =SRC
2:	ldmdb	r1!, {r4-r11}
	stmdb	r0!, {r4-r11}
	cmp	r1, r2
	bne	2b
	.else
	ldr	r1, =SRC
	ldr	r0, =DSTB
	ldr	r2, =(SRC + LEN)
2:	ldmia	r1!, {r4-r11}
	stmia	r0!, {r4-r11}
	cmp	r1, r2
	bne	2b
	.endif
	mov	r0, #\idx
	bl	verify
	b	3f
	.ltorg
3:
	.endm

@ verify: r0 = case index. Cleans and invalidates, then compares the
@ destination (uncached alias) with address ^ KEY of the source, records.
verify:
	stmfd	sp!, {r4-r11, lr}
	mov	r11, r0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r1, =(UNC + DSTB - 0x00400000)
	ldr	r2, =SRC
	ldr	r3, =KEY
	mov	r4, #0				@ wrong words this case
	mov	r5, #0				@ first wrong offset | kind << 28
	mov	r6, #0				@ first value found
	mov	r7, #0				@ first value expected
	mov	r8, #0				@ offset
1:	ldr	r9, [r1, r8]
	add	r10, r2, r8
	eor	r10, r10, r3			@ expected
	cmp	r9, r10
	beq	2f
	add	r4, r4, #1
	ldr	r12, =R_POS
	and	r0, r8, #0xC
	ldr	lr, [r12, r0]
	add	lr, lr, #1
	str	lr, [r12, r0]
	cmp	r4, #1
	bne	2f
	mov	r5, r8
	mov	r6, r9
	mov	r7, r10
	eor	r0, r10, #0x10000		@ OC1's word at this offset
	cmp	r9, r0
	orreq	r5, r5, #(1 << 28)
	beq	2f
	eor	r0, r10, #0x20000		@ OC2's
	cmp	r9, r0
	orreq	r5, r5, #(2 << 28)
	beq	2f
	eor	r0, r10, #0x50000		@ F1's
	cmp	r9, r0
	orreq	r5, r5, #(4 << 28)
	beq	2f
	eor	r0, r10, #0x60000		@ F2's
	cmp	r9, r0
	orreq	r5, r5, #(5 << 28)
	orrne	r5, r5, #(3 << 28)
2:	add	r8, r8, #4
	cmp	r8, #LEN
	bne	1b
	ldr	r12, =R_CASE
	add	r12, r12, r11, lsl #4
	stmia	r12, {r4-r7}
	ldr	r12, =R_TOTAL
	ldr	r0, [r12]
	add	r0, r0, r4
	str	r0, [r12]
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3		@ RAM cached (code, source, destination)
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0		@ UNC: its uncached alias
	SETL1	UNC, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	@ the three regions through the uncached alias: word = address ^ KEY
	ldr	r1, =(UNC + SRC - 0x00400000)
	ldr	r2, =SRC
	ldr	r3, =KEY
	mov	r4, #0
1:	add	r5, r2, r4
	eor	r5, r5, r3
	str	r5, [r1, r4]
	eor	r6, r5, #0x10000
	add	r7, r1, #0x10000
	str	r6, [r7, r4]
	eor	r6, r5, #0x20000
	add	r7, r1, #0x20000
	str	r6, [r7, r4]
	eor	r6, r5, #0x50000
	add	r7, r1, #0x50000
	str	r6, [r7, r4]
	eor	r6, r5, #0x60000
	add	r7, r1, #0x60000
	str	r6, [r7, r4]
	add	r4, r4, #4
	ldr	r8, =(LEN + 16)
	cmp	r4, r8
	bne	1b
	@ clear the results
	ldr	r0, =SIG_DATA
	mov	r1, #0
	mov	r2, #0x200
2:	str	r1, [r0], #4
	subs	r2, r2, #4
	bne	2b

	.set	idx, 0
	.irp	lat, 0, 8, 24
	.irp	occ, 3, 2, 1, 0
	.irp	down, 1, 0
	CASE	\occ, \down, \lat, idx
	.set	idx, idx + 1
	.endr
	.endr
	.endr
	ldr	r0, =R_TOTAL
	ldr	r0, [r0]
	CHECK	r0, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg
