@ SPDX-License-Identifier: GPL-3.0-or-later
@ Barrel shifter: immediate and register shift amounts, the special
@ encodings (LSR/ASR #32, RRX), amounts of 0, 32 and above, carry out.
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {lr}
	ldr	r0, =0x80000001

	@ immediate amounts
	movs	r1, r0, lsl #1		@ 2, C=1
	MRSN	r2, cpsr
	CHECK	r1, 2
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x20000000
	movs	r1, r0, lsr #1		@ 0x40000000, C=1
	MRSN	r2, cpsr
	CHECK	r1, 0x40000000
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x20000000
	movs	r1, r0, lsr #32		@ encoded as LSR #0: 0, C = bit 31
	MRSN	r2, cpsr
	CHECK	r1, 0
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x60000000
	movs	r1, r0, asr #1		@ 0xC0000000, C=1
	MRSN	r2, cpsr
	CHECK	r1, 0xC0000000
	and	r2, r2, #0xF0000000
	CHECK	r2, 0xA0000000
	movs	r1, r0, asr #32		@ all sign, C = bit 31
	MRSN	r2, cpsr
	CHECK	r1, 0xFFFFFFFF
	and	r2, r2, #0xF0000000
	CHECK	r2, 0xA0000000
	movs	r1, r0, ror #4		@ 0x18000000, C = bit 27 = 0
	MRSN	r2, cpsr
	CHECK	r1, 0x18000000
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x00000000
	CHECKPOINT
	cmp	r0, r0			@ C=1
	movs	r1, r0, rrx		@ (C << 31) | (r0 >> 1), C = bit 0
	MRSN	r2, cpsr
	CHECK	r1, 0xC0000000
	and	r2, r2, #0xF0000000
	CHECK	r2, 0xA0000000
	mov	r3, #0
	adds	r3, r3, #0		@ C=0
	movs	r1, r0, rrx
	CHECK	r1, 0x40000000
	movs	r1, r0, lsl #0		@ C unchanged
	MRSN	r2, cpsr
	CHECK	r1, 0x80000001
	CHECKPOINT

	@ register amounts: only the bottom byte counts
	mov	r4, #0
	movs	r1, r0, lsl r4		@ amount 0: value and C unchanged
	MRSN	r2, cpsr
	CHECK	r1, 0x80000001
	mov	r4, #32
	movs	r1, r0, lsl r4		@ 0, C = bit 0
	MRSN	r2, cpsr
	CHECK	r1, 0
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x60000000
	mov	r4, #33
	movs	r1, r0, lsl r4		@ 0, C = 0
	MRSN	r2, cpsr
	CHECK	r1, 0
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x40000000
	mov	r4, #32
	movs	r1, r0, lsr r4		@ 0, C = bit 31
	MRSN	r2, cpsr
	CHECK	r1, 0
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x60000000
	mov	r4, #40
	movs	r1, r0, lsr r4		@ 0, C = 0
	MRSN	r2, cpsr
	and	r2, r2, #0xF0000000
	CHECK	r2, 0x40000000
	mov	r4, #200
	movs	r1, r0, asr r4		@ sign, C = sign
	MRSN	r2, cpsr
	CHECK	r1, 0xFFFFFFFF
	and	r2, r2, #0xF0000000
	CHECK	r2, 0xA0000000
	mov	r4, #32
	movs	r1, r0, ror r4		@ ROR 32: value, C = bit 31
	MRSN	r2, cpsr
	CHECK	r1, 0x80000001
	and	r2, r2, #0xF0000000
	CHECK	r2, 0xA0000000
	mov	r4, #36
	movs	r1, r0, ror r4		@ ROR 36 = ROR 4
	CHECK	r1, 0x18000000
	ldr	r4, =0x101		@ bottom byte 1
	movs	r1, r0, lsl r4
	CHECK	r1, 2
	CHECKPOINT

	@ shifts feeding arithmetic and logic ops
	mov	r1, #3
	add	r2, r1, r1, lsl #4	@ 3 + 48
	CHECK	r2, 51
	rsb	r2, r1, r1, lsl #3	@ 24 - 3
	CHECK	r2, 21
	mov	r4, #2
	sub	r2, r1, r1, asr r4	@ 3 - 0
	CHECK	r2, 3
	ldr	r0, =0x12345678
	eor	r2, r0, r0, ror #8
	CHECK	r2, 0x6A26622E
	mov	r4, #16
	orr	r2, r0, r0, lsr r4
	CHECK	r2, 0x1234567C
	bic	r2, r0, r0, lsl #4
	CHECK	r2, 0x10301078
	CHECKPOINT

	ldmfd	sp!, {pc}
	.ltorg
