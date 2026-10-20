@ SPDX-License-Identifier: GPL-3.0-or-later
@ Caches on (MMU on, RAM write-back): a 64 KB memory test (eight times the
@ D-cache, so lines are evicted and written back), bytes and halfwords in
@ cached lines, LDM/STM across lines, clean and clean+flush operations
@ followed by reads through an uncached alias, a write-through alias,
@ and self-modifying code (D clean + I flush). Everything checked here
@ holds with or without caches, so QEMU (which has none) must agree.
	.include "test.inc"
	.include "mmu.inc"
	.equ	BUF,      SCRATCH + 0x10000	@ 64 KB test area
	.equ	UNC,      0x20000000		@ uncached alias of PA 0x00400000
	.equ	WTA,      0x21000000		@ write-through alias of the same
	.equ	CODE_PA,  0x00480000		@ generated code
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	@ RAM sections write-back (C=B=1), the aliases, caches on
	ldr	r0, =TTB
	ldr	r1, =0x00000C1E
	mov	r2, #16
1:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	1b
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	SECT	r1, 0x00400000, 3, 0, 2		@ C=1 B=0
	SETL1	WTA, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	CHECKPOINT

	@ 1. 64 KB pattern, checksum, clean, compare through the uncached alias
	ldr	r4, =BUF
	ldr	r5, =0x9E3779B9
	mov	r6, #0
	mov	r7, #0			@ checksum
2:	mul	r8, r6, r5
	eor	r8, r8, r6, ror #13
	str	r8, [r4, r6, lsl #2]
	add	r7, r7, r8
	add	r6, r6, #1
	cmp	r6, #0x4000
	bne	2b
	mov	r6, #0
	mov	r9, #0
3:	ldr	r8, [r4, r6, lsl #2]
	add	r9, r9, r8
	add	r6, r6, #1
	cmp	r6, #0x4000
	bne	3b
	CHECKR	r9, r7
	STORE_RESULT r7, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0	@ clean D
	mcr	p15, 0, r0, c7, c10, 4	@ drain
	ldr	r4, =UNC + 0x10000
	mov	r6, #0
	mov	r9, #0
4:	ldr	r8, [r4, r6, lsl #2]
	add	r9, r9, r8
	add	r6, r6, #1
	cmp	r6, #0x4000
	bne	4b
	CHECKR	r9, r7
	CHECKPOINT

	@ 2. bytes and halfwords inside cached lines
	ldr	r4, =BUF
	ldr	r0, [r4]		@ line in the cache
	mov	r1, #0xA1
	strb	r1, [r4, #1]
	mov	r1, #0xB2
	strb	r1, [r4, #14]
	ldr	r1, =0xC3D4
	strh	r1, [r4, #6]
	ldrb	r2, [r4, #1]
	CHECK	r2, 0xA1
	ldrh	r2, [r4, #6]
	CHECK	r2, 0xC3D4
	ldr	r2, [r4, #12]
	and	r2, r2, #0x00FF0000
	CHECK	r2, 0x00B20000
	ldrsb	r2, [r4, #14]
	CHECK	r2, 0xFFFFFFB2
	CHECKPOINT

	@ 3. LDM/STM across line boundaries
	add	r4, r4, #0x108		@ 8 bytes before a line boundary
	mov	r0, #1
	mov	r1, #2
	mov	r2, #3
	mov	r3, #4
	mov	r5, #5
	mov	r6, #6
	stmia	r4, {r0-r3, r5, r6}
	mov	r0, #0
	mov	r1, #0
	mov	r2, #0
	mov	r3, #0
	mov	r5, #0
	mov	r6, #0
	ldmia	r4, {r0-r3, r5, r6}
	add	r0, r0, r1
	add	r0, r0, r2
	add	r0, r0, r3
	add	r0, r0, r5
	add	r0, r0, r6
	CHECK	r0, 21
	ldr	r0, [r4, #20]
	CHECK	r0, 6
	CHECKPOINT

	@ 4. clean+flush entry by VA, then read memory through the alias
	ldr	r4, =BUF + 0x200
	ldr	r0, =0x77665544
	str	r0, [r4]
	mcr	p15, 0, r4, c7, c14, 1
	ldr	r5, =UNC + 0x10200
	ldr	r1, [r5]
	CHECK	r1, 0x77665544
	@ and by index (all 512 lines, both "ways"), the Symbian loop
	ldr	r0, =0x11223344
	str	r0, [r4, #4]
	mov	r3, #0
5:	mcr	p15, 0, r3, c7, c14, 2
	add	r3, r3, #0x10
	tst	r3, #0x1000
	beq	5b
	ldr	r3, =0x80000000
6:	mcr	p15, 0, r3, c7, c14, 2
	add	r3, r3, #0x10
	tst	r3, #0x1000
	beq	6b
	ldr	r1, [r5, #4]
	CHECK	r1, 0x11223344
	ldr	r1, [r4, #4]		@ refetched through the cache
	CHECK	r1, 0x11223344
	CHECKPOINT

	@ 5. write-through alias: memory is updated at once
	ldr	r4, =WTA + 0x300
	ldr	r5, =UNC + 0x300
	ldr	r0, [r4]		@ line allocated through the WT alias
	ldr	r0, =0xFEEDF00D
	str	r0, [r4]
	ldr	r1, [r5]
	CHECK	r1, 0xFEEDF00D
	ldr	r1, [r4]
	CHECK	r1, 0xFEEDF00D
	mov	r0, #0x5A
	strb	r0, [r4, #3]
	ldr	r1, [r5]
	CHECK	r1, 0x5AEDF00D
	CHECKPOINT

	@ 6. self-modifying code: write "mov r0, #n; mov pc, lr", clean D,
	@ flush I, call; twice with different n
	ldr	r4, =CODE_PA
	ldr	r0, =0xE3A00011		@ mov r0, #0x11
	ldr	r1, =0xE1A0F00E		@ mov pc, lr
	stmia	r4, {r0, r1}
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c10, 4
	mcr	p15, 0, r0, c7, c5, 0
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x11
	ldr	r0, =0xE3A00022		@ mov r0, #0x22
	str	r0, [r4]
	mcr	p15, 0, r4, c7, c10, 1	@ clean D entry
	mcr	p15, 0, r0, c7, c10, 4
	mcr	p15, 0, r4, c7, c5, 1	@ flush I entry
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x22
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}
	.ltorg
