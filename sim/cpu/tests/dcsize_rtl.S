@ SPDX-License-Identifier: GPL-3.0-or-later
@ Enlarged two-way D-cache: the reported 8 KB index operations must cover
@ every physical set colour. Exact dirty/writeback/invalidation checks at
@ VA[12]=0/1, both TI ways and C=0; unrelated sets and VA ops stay targeted.
@ Also move a page to an alias with the opposite VA[12], with the kernel's
@ full index sweep between owners. The supported experiment is 16 KB/two
@ ways; this same binary also checks the unchanged 8 KB/two-way default.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ A0, 0x00420E00
	.equ B0, 0x00430E00
	.equ A1, 0x00421E00
	.equ B1, 0x00431E00
	.equ OTHER, 0x00422D00
	.equ UNC, 0x20000000
	.equ ALIAS, 0x30000000
	.equ UA0, UNC + 0x20E00
	.equ UB0, UNC + 0x30E00
	.equ UA1, UNC + 0x21E00
	.equ UB1, UNC + 0x31E00
	.equ UOTHER, UNC + 0x22D00
	.text
	.arm
	.global test_main

	.macro MEMCHECK addr, value
	ldr	r2, =\addr
	ldr	r1, [r2]
	CHECK	r1, \value
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	@ Small page at ALIAS maps A1's PA page: VA bit 12 changes 1 -> 0.
	ldr	r0, =L2_AREA
	ldr	r1, =0x00421FFE
	str	r1, [r0]
	ldr	r1, =(L2_AREA | 1)
	SETL1	ALIAS, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	@ The write buffer stays off (W = 0): a store miss then allocates its
	@ line, the policy these checks are written for. With W = 1 a store miss
	@ is posted instead (walloc_posted_rtl.S, buffer_modes.S).
	orr	r0, r0, #CR_C
	mcr	p15, 0, r0, c1, c0, 0
	mrc	p15, 0, r0, c0, c0, 1
	CHECK	r0, 0x05109149
	ldr	r4, =A0
	ldr	r5, =B0
	ldr	r6, =A1
	ldr	r7, =B1
	ldr	r8, =OTHER

	@ 1. C=1 selects one architectural way, across both physical colours.
	bl	prepare
	mov	r0, #4
	mcr	p15, 0, r0, c15, c1, 0
	mov	r0, #0xE00
	mcr	p15, 0, r0, c7, c10, 2
	MEMCHECK UA0, 0xA2
	MEMCHECK UA1, 0xC2
	MEMCHECK UB1, 0xD1	@ other way still dirty, not cleaned
	MEMCHECK UOTHER, 0xE1	@ unrelated index untouched
	ldr	r0, =0x80000E00
	mcr	p15, 0, r0, c7, c10, 2
	MEMCHECK UB0, 0xB2
	MEMCHECK UB1, 0xD2
	CHECKPOINT

	@ 2. Discard reaches the upper colour, without cleaning it or way 1.
	bl	prepare
	mov	r0, #0xE00
	mcr	p15, 0, r0, c7, c6, 2
	ldr	r1, [r6]
	CHECK	r1, 0xC1
	ldr	r1, [r7]
	CHECK	r1, 0xD2
	MEMCHECK UB1, 0xD1
	CHECKPOINT

	@ 3. C=0 clean+invalidate covers both ways and all physical colours.
	bl	prepare
	mov	r0, #1
	mcr	p15, 0, r0, c15, c1, 0
	mov	r0, #0xE00
	mcr	p15, 0, r0, c7, c14, 2
	MEMCHECK UA0, 0xA2
	MEMCHECK UB0, 0xB2
	MEMCHECK UA1, 0xC2
	MEMCHECK UB1, 0xD2
	ldr	r2, =UA1
	mov	r0, #0xC3
	str	r0, [r2]
	ldr	r1, [r6]
	CHECK	r1, 0xC3	@ the upper-colour tag was invalidated
	MEMCHECK UOTHER, 0xE1
	CHECKPOINT

	@ 4. VA operations still use all actual index bits and touch one line.
	bl	prepare
	mcr	p15, 0, r6, c7, c10, 1
	MEMCHECK UA1, 0xC2
	MEMCHECK UB1, 0xD1
	MEMCHECK UOTHER, 0xE1
	ldr	r2, =UA1
	mov	r0, #0xC4
	str	r0, [r2]
	mcr	p15, 0, r6, c7, c6, 1
	ldr	r1, [r6]
	CHECK	r1, 0xC4
	CHECKPOINT

	@ 5. Firmware-sized index sweep, then transfer ownership to a differently
	@ coloured cached alias. No simultaneous dirty-alias coherence is assumed.
	bl	prepare
	bl	kernel_sweep
	MEMCHECK UA1, 0xC2
	ldr	r9, =(ALIAS + 0xE00)
	ldr	r1, [r9]
	CHECK	r1, 0xC2
	mov	r0, #0xC5
	str	r0, [r9]
	bl	kernel_sweep
	ldr	r1, [r6]
	CHECK	r1, 0xC5
	MEMCHECK UA1, 0xC5
	CHECKPOINT
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}

prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r2, =UA0
	mov	r0, #0xA1
	str	r0, [r2]
	ldr	r2, =UB0
	mov	r0, #0xB1
	str	r0, [r2]
	ldr	r2, =UA1
	mov	r0, #0xC1
	str	r0, [r2]
	ldr	r2, =UB1
	mov	r0, #0xD1
	str	r0, [r2]
	ldr	r2, =UOTHER
	mov	r0, #0xE1
	str	r0, [r2]
	@ At 16 KB, A0/A1 fill way 0 of their sets, B0/B1 way 1.
	@ At 8 KB A0/B0 have already been evicted before A1/B1 occupy the set.
	mov	r0, #0xA2
	str	r0, [r4]
	mov	r0, #0xB2
	str	r0, [r5]
	mov	r0, #0xC2
	str	r0, [r6]
	mov	r0, #0xD2
	str	r0, [r7]
	mov	r0, #0xE2
	str	r0, [r8]
	mov	pc, lr

kernel_sweep:
	@ Same c0-derived loop as ekern 0x503224BC; C=1 way bit is bit 31.
	mov	r0, #4
	mcr	p15, 0, r0, c15, c1, 0
	mrc	p15, 0, r0, c0, c0, 1
	mov	r1, r0, lsr #15
	and	r1, r1, #7
	mov	r2, r0, lsr #18
	and	r2, r2, #7
	mov	r3, r0, lsr #12
	and	r3, r3, #3
	mov	r0, #8
	mov	r0, r0, lsl r3
	sub	r2, r2, r1
	add	r2, r2, #9
	mov	r3, #1
	mov	r3, r3, lsl r2
	mov	r2, #1
	mov	r2, r2, ror r1
	mov	r1, #0
1:
	mcr	p15, 0, r1, c7, c14, 2
	add	r1, r1, r0
	tst	r1, r3
	beq	1b
	bic	r1, r1, r3
	adds	r1, r1, r2
	bcc	1b
	mov	pc, lr
	.ltorg
