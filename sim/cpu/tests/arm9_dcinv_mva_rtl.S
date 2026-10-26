@ SPDX-License-Identifier: GPL-3.0-or-later
@ Cache maintenance by MVA on lines the memory changed behind the cache: the
@ LFFS driver's shape (2026-10-25). The C: flash has a cached alias
@ (0x59600000, read by line fills on the board) and an uncached one
@ (0x59200000, programmed through); after a program the driver must make the
@ cached alias forget the sector, by MVA. Here every set of a 1 KB window
@ holds a target line and, in the other way, a foreign line; the memory
@ behind the target is changed through the uncached alias and the cached
@ copy is then invalidated (c7,c6,1), cleaned+invalidated (c7,c14,1), or the
@ whole D-cache invalidated (c7,c6,0); every word of the line read back
@ cached must be the new value. Variants: the target filled before or after
@ the foreign line (so it sits in either way), the invalidate's MVA at word
@ 0 or word 3 of the line, and the window at two offsets. Results
@ (SIG_DATA): +0 wrong words in all, then per case (16 bytes): wrong words,
@ first wrong address, value found, value expected.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000		@ uncached alias of PA 0x00400000
	.equ	TGT, 0x00480000		@ the window (1 KB: 64 lines)
	.equ	OC1, 0x00490000		@ the same sets, another tag
	.equ	KEY, 0xA5A5A5A5
	.equ	LINES, 64
	.equ	R_TOTAL, SIG_DATA
	.equ	R_CASE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	@ op: 0 = invalidate by MVA, 1 = clean+invalidate by MVA, 2 = invalidate all
	@ first: 1 = target filled before the foreign line, 0 = after
	@ mva3: 1 = the maintenance MVA names word 3 of the line
	@ off: window offset (0 or 0x8000: different sets of the same tags)
	.macro	CASE op, first, mva3, off, idx
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0		@ clean
	mcr	p15, 0, r0, c7, c6, 0		@ invalidate
	ldr	r4, =(TGT + \off)
	ldr	r5, =(OC1 + \off)
	ldr	r6, =(UNC + TGT - 0x00400000 + \off)
	ldr	r7, =KEY
	@ memory behind the window: word = address ^ KEY (through the alias)
	mov	r8, #0
1:	add	r9, r4, r8
	eor	r9, r9, r7
	str	r9, [r6, r8]
	add	r8, r8, #4
	cmp	r8, #(LINES * 16)
	bne	1b
	@ fill the window's lines and the foreign lines, in the chosen order
	mov	r8, #0
2:	.if \first
	ldr	r9, [r4, r8]
	ldr	r9, [r5, r8]
	.else
	ldr	r9, [r5, r8]
	ldr	r9, [r4, r8]
	.endif
	add	r8, r8, #16
	cmp	r8, #(LINES * 16)
	bne	2b
	@ the "program": new words behind the cache, word = (address ^ KEY) + 1
	mov	r8, #0
3:	add	r9, r4, r8
	eor	r9, r9, r7
	add	r9, r9, #1
	str	r9, [r6, r8]
	add	r8, r8, #4
	cmp	r8, #(LINES * 16)
	bne	3b
	@ the maintenance, per line
	.if \op == 2
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0
	.else
	mov	r8, #0
4:	add	r0, r4, r8
	.if \mva3
	add	r0, r0, #12
	.endif
	.if \op == 0
	mcr	p15, 0, r0, c7, c6, 1
	.else
	mcr	p15, 0, r0, c7, c14, 1
	.endif
	add	r8, r8, #16
	cmp	r8, #(LINES * 16)
	bne	4b
	.endif
	@ read back cached: every word of every line
	mov	r10, #0				@ wrong words
	mov	r11, #0				@ first wrong address
	mov	r8, #0
5:	ldr	r9, [r4, r8]
	add	r0, r4, r8
	eor	r0, r0, r7
	add	r0, r0, #1
	cmp	r9, r0
	beq	6f
	add	r10, r10, #1
	cmp	r10, #1
	bne	6f
	add	r11, r4, r8
	mov	r2, r9
	mov	r3, r0
6:	add	r8, r8, #4
	cmp	r8, #(LINES * 16)
	bne	5b
	ldr	r12, =R_CASE
	add	r12, r12, #(16 * \idx)
	str	r10, [r12]
	str	r11, [r12, #4]
	cmp	r10, #0
	strne	r2, [r12, #8]
	strne	r3, [r12, #12]
	ldr	r12, =R_TOTAL
	ldr	r0, [r12]
	add	r0, r0, r10
	str	r0, [r12]
	b	7f
	.ltorg
7:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3		@ RAM cached
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
	@ the foreign lines' memory
	ldr	r1, =(UNC + OC1 - 0x00400000)
	ldr	r2, =OC1
	ldr	r3, =KEY
	mov	r4, #0
1:	add	r5, r2, r4
	eor	r5, r5, r3
	str	r5, [r1, r4]
	add	r4, r4, #4
	ldr	r6, =(0x8000 + LINES * 16)
	cmp	r4, r6
	bne	1b
	ldr	r0, =SIG_DATA
	mov	r1, #0
	mov	r2, #0x200
2:	str	r1, [r0], #4
	subs	r2, r2, #4
	bne	2b

	.set	idx, 0
	.irp	off, 0, 0x8000
	.irp	op, 0, 1, 2
	.irp	first, 1, 0
	.irp	mva3, 0, 1
	CASE	\op, \first, \mva3, \off, idx
	.set	idx, idx + 1
	.endr
	.endr
	.endr
	.endr
	ldr	r0, =R_TOTAL
	ldr	r0, [r0]
	CHECK	r0, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg
