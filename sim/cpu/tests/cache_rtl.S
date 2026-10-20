@ SPDX-License-Identifier: GPL-3.0-or-later
@ What the caches do that a model without caches cannot show (RTL only):
@ write-back data stays in the D-cache until cleaned; the single-line
@ operations by VA and by index (TI operand) clean, discard or both, and
@ leave other lines alone; a write-through page updates memory at once;
@ the I-cache keeps old code until it is flushed.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	BUF,  0x00420000		@ PA, cached write-back (identity)
	.equ	UNC,  0x20000000		@ uncached alias of PA 0x00400000
	.equ	WTA,  0x21000000		@ write-through alias of the same
	.equ	UBUF, UNC + 0x20000		@ BUF through the uncached alias
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	ldr	r0, =TTB
	ldr	r1, =0x00000C1E		@ RAM write-back
	mov	r2, #16
1:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	1b
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	SECT	r1, 0x00400000, 3, 0, 2
	SETL1	WTA, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r4, =BUF
	ldr	r5, =UBUF

	@ 1. write-back: memory is old until the line is cleaned (by VA)
	ldr	r0, =0x11111111
	str	r0, [r5]		@ memory
	ldr	r1, [r4]		@ line in the cache
	ldr	r0, =0x22222222
	str	r0, [r4]		@ dirty
	ldr	r1, [r5]
	CHECK	r1, 0x11111111
	mcr	p15, 0, r4, c7, c10, 1	@ clean entry
	ldr	r1, [r5]
	CHECK	r1, 0x22222222
	ldr	r1, [r4]		@ still cached: memory changes are not seen
	ldr	r0, =0x33333333
	str	r0, [r5]
	ldr	r1, [r4]
	CHECK	r1, 0x22222222
	CHECKPOINT

	@ 2. flush entry by VA discards dirty data
	ldr	r0, =0x44444444
	str	r0, [r4]		@ dirty again (memory holds 0x33333333)
	mcr	p15, 0, r4, c7, c6, 1
	ldr	r1, [r4]		@ refetched from memory
	CHECK	r1, 0x33333333
	ldr	r1, [r5]
	CHECK	r1, 0x33333333
	CHECKPOINT

	@ 3. a VA operation for another address with the same index does nothing
	ldr	r0, =0x55555555
	str	r0, [r4]		@ dirty
	add	r6, r4, #0x2000		@ same index, other tag (8 KB cache)
	mcr	p15, 0, r6, c7, c6, 1
	ldr	r1, [r4]
	CHECK	r1, 0x55555555
	ldr	r1, [r5]
	CHECK	r1, 0x33333333
	CHECKPOINT

	@ 4. clean+flush entry by index (TI operand: set in bits 11:4; TI
	@ config C = 0, so both "ways" of the set)
	and	r7, r4, #0xFF0
	mcr	p15, 0, r7, c7, c14, 2
	ldr	r1, [r5]
	CHECK	r1, 0x55555555		@ written back
	ldr	r0, =0x66666666
	str	r0, [r5]
	ldr	r1, [r4]		@ and invalidated: refetched
	CHECK	r1, 0x66666666
	CHECKPOINT

	@ 5. flush by index discards, clean by index keeps the line
	ldr	r0, =0x77777777
	str	r0, [r4]
	mcr	p15, 0, r7, c7, c6, 2
	ldr	r1, [r4]
	CHECK	r1, 0x66666666
	ldr	r0, =0x88888888
	str	r0, [r4]
	mcr	p15, 0, r7, c7, c10, 2
	ldr	r1, [r5]
	CHECK	r1, 0x88888888
	ldr	r0, =0x99999999
	str	r0, [r5]
	ldr	r1, [r4]		@ still valid in the cache
	CHECK	r1, 0x88888888
	@ TI config C = 1: bit 31 selects the way (line); the other is untouched
	mov	r0, #0x04
	mcr	p15, 0, r0, c15, c1, 0
	ldr	r0, =0xAAAAAAAA
	str	r0, [r4]		@ dirty, line index bit 8 = VA bit 12 = 0
	orr	r8, r7, #0x80000000	@ the other way
	mcr	p15, 0, r8, c7, c6, 2
	ldr	r1, [r4]
	CHECK	r1, 0xAAAAAAAA		@ not discarded
	mcr	p15, 0, r7, c7, c6, 2	@ this way
	ldr	r1, [r4]
	CHECK	r1, 0x99999999
	mov	r0, #0x01
	mcr	p15, 0, r0, c15, c1, 0
	CHECKPOINT

	@ 6. whole-cache clean
	ldr	r0, =0xBBBBBBBB
	str	r0, [r4, #4]
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r1, [r5, #4]
	CHECK	r1, 0xBBBBBBBB
	CHECKPOINT

	@ 7. write-through: memory at once, line updated
	ldr	r4, =WTA + 0x300
	ldr	r5, =UNC + 0x300
	ldr	r1, [r4]		@ allocate
	ldr	r0, =0xCCCCCCCC
	str	r0, [r4]
	ldr	r1, [r5]
	CHECK	r1, 0xCCCCCCCC
	ldr	r0, =0xDDDDDDDD
	str	r0, [r5]		@ memory behind the cache
	ldr	r1, [r4]
	CHECK	r1, 0xCCCCCCCC		@ the line (still valid) wins
	CHECKPOINT

	@ 8. the I-cache keeps old code until flushed
	ldr	r4, =0x00480000
	ldr	r0, =0xE3A00011		@ mov r0, #0x11
	ldr	r1, =0xE1A0F00E		@ mov pc, lr
	stmia	r4, {r0, r1}
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c5, 0
	mov	lr, pc
	mov	pc, r4			@ fills the I-cache line
	CHECK	r0, 0x11
	ldr	r0, =0xE3A00022
	str	r0, [r4]
	mcr	p15, 0, r4, c7, c10, 1	@ memory updated, I-cache not flushed
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x11		@ old code
	mcr	p15, 0, r4, c7, c5, 1
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x22
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}
	.ltorg
