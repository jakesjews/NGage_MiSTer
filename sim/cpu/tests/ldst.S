@ SPDX-License-Identifier: GPL-3.0-or-later
@ Single loads and stores: word, byte, halfword, signed byte and halfword;
@ immediate, register and scaled-register offsets; pre/post-indexing,
@ writeback, subtraction; PC-relative loads; load-use; aligned only (the
@ unaligned cases are in align.S and rtl_misc.S).
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	ldr	r0, =SCRATCH
	ldr	r1, =0x89ABCDEF
	ldr	r2, =0x01234567

	@ word, immediate offsets
	str	r1, [r0]
	str	r2, [r0, #4]
	ldr	r3, [r0]
	CHECK	r3, 0x89ABCDEF
	ldr	r3, [r0, #4]
	CHECK	r3, 0x01234567
	add	r4, r0, #8
	ldr	r3, [r4, #-4]
	CHECK	r3, 0x01234567
	@ pre-indexed with writeback, post-indexed
	mov	r4, r0
	ldr	r3, [r4, #4]!
	CHECK	r3, 0x01234567
	sub	r5, r4, r0
	CHECK	r5, 4
	mov	r4, r0
	ldr	r3, [r4], #4
	CHECK	r3, 0x89ABCDEF
	sub	r5, r4, r0
	CHECK	r5, 4
	ldr	r3, [r4], #-4
	CHECK	r3, 0x01234567
	CHECKR	r4, r0
	CHECKPOINT

	@ register and scaled register offsets
	mov	r5, #1
	ldr	r3, [r0, r5, lsl #2]
	CHECK	r3, 0x01234567
	mov	r5, #8
	add	r4, r0, #12
	ldr	r3, [r4, -r5]
	CHECK	r3, 0x01234567
	mov	r5, #16
	ldr	r3, [r4, -r5, asr #1]!
	CHECK	r3, 0x01234567
	sub	r5, r4, r0
	CHECK	r5, 4
	mov	r5, #8
	str	r1, [r0, r5]!		@ SCRATCH+8
	sub	r5, r0, #8
	CHECK	r5, SCRATCH
	ldr	r0, =SCRATCH
	ldr	r3, [r0, #8]
	CHECK	r3, 0x89ABCDEF
	CHECKPOINT

	@ bytes
	strb	r1, [r0, #16]		@ EF
	mov	r6, r1, lsr #8
	strb	r6, [r0, #17]		@ CD
	mov	r6, r1, lsr #16
	strb	r6, [r0, #18]		@ AB
	mov	r6, r1, lsr #24
	strb	r6, [r0, #19]		@ 89
	ldr	r3, [r0, #16]
	CHECK	r3, 0x89ABCDEF
	ldrb	r3, [r0, #16]
	CHECK	r3, 0xEF
	ldrb	r3, [r0, #19]
	CHECK	r3, 0x89
	ldrsb	r3, [r0, #17]		@ CD = negative
	CHECK	r3, 0xFFFFFFCD
	ldrsb	r3, [r0, #4]		@ 67
	CHECK	r3, 0x67
	mov	r5, #2
	ldrb	r3, [r0, r5]
	CHECK	r3, 0xAB
	CHECKPOINT

	@ halfwords
	strh	r1, [r0, #20]		@ CDEF
	strh	r2, [r0, #22]		@ 4567
	ldr	r3, [r0, #20]
	CHECK	r3, 0x4567CDEF
	ldrh	r3, [r0, #20]
	CHECK	r3, 0xCDEF
	ldrh	r3, [r0, #22]
	CHECK	r3, 0x4567
	ldrsh	r3, [r0, #20]
	CHECK	r3, 0xFFFFCDEF
	ldrsh	r3, [r0, #22]
	CHECK	r3, 0x4567
	mov	r5, #22
	ldrh	r3, [r0, r5]
	CHECK	r3, 0x4567
	add	r4, r0, #20
	ldrsh	r3, [r4], #2
	CHECK	r3, 0xFFFFCDEF
	ldrh	r3, [r4, #0]!
	CHECK	r3, 0x4567
	sub	r5, r4, r0
	CHECK	r5, 22
	add	r4, r0, #24
	strh	r1, [r4, #-2]!
	ldr	r3, [r0, #20]
	CHECK	r3, 0xCDEFCDEF
	sub	r5, r4, r0
	CHECK	r5, 22
	CHECKPOINT

	@ PC-relative loads and literal pools
	ldr	r3, lit1
	CHECK	r3, 0xCAFEF00D
	ldrh	r3, lit1
	CHECK	r3, 0xF00D
	ldrb	r3, lit1 + 3
	CHECK	r3, 0xCA
	adr	r4, lit1
	ldr	r3, [r4]
	CHECK	r3, 0xCAFEF00D
	b	2f
lit1:	.word	0xCAFEF00D
2:	CHECKPOINT

	@ load-use: the loaded value is used by the next instructions
	ldr	r3, [r0]
	add	r4, r3, #1
	CHECK	r4, 0x89ABCDF0
	ldr	r3, [r0, #4]
	ldr	r7, [r0, r3, lsr #22]	@ 0x01234567 >> 22 = 4
	CHECK	r7, 0x01234567
	ldrb	r3, [r0, #4]
	ldrb	r7, [r0, r3, lsr #4]	@ 0x67 >> 4 = 6: byte 6 = 0x23
	CHECK	r7, 0x23
	CHECKPOINT

	@ stores of the base and of a just-loaded register
	add	r4, r0, #32
	str	r4, [r4]
	ldr	r3, [r0, #32]
	CHECKR	r3, r4
	ldr	r5, [r0]
	str	r5, [r0, #36]
	ldr	r3, [r0, #36]
	CHECK	r3, 0x89ABCDEF
	CHECKPOINT

	@ LDRT/STRT (MMU off: plain accesses)
	mov	r4, r0
	ldrt	r3, [r4], #4
	CHECK	r3, 0x89ABCDEF
	strt	r1, [r4], #4
	ldr	r3, [r0, #4]
	CHECK	r3, 0x89ABCDEF
	ldrbt	r3, [r0], #0
	CHECK	r3, 0xEF
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}
	.ltorg
