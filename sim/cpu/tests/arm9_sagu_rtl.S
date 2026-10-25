@ SPDX-License-Identifier: GPL-3.0-or-later
@ Memory addresses formed in S (V2's S_AGU): every way a base or register
@ offset can arrive, checked against the same access with its producer far
@ ahead (and against QEMU's trace, and ZAP).
@   * base from the instruction just ahead: an ALU result, a load (pointer
@     chase), a load into a register offset; then at distances 2 and 3
@   * scaled register offsets (LSL/LSR/ASR/ROR/RRX, +/-), with writeback,
@     post-indexed, and with the offset or base just produced
@   * pre/post-indexed and writeback forms, immediate and register, word,
@     byte, halfword, signed; writeback chains at distance 1 (the base comes
@     from the scalar MEM ahead: its registered sum), including a
@     condition-failed writer, a flag-passing one, and readers of the base
@   * block bases: from an ALU result, a load, a scalar writeback, a block
@     writeback, the base in the list, the four modes, push/pop
@   * PC-relative: literal loads, ADR, Thumb PC-relative (word-aligned PC)
@   * the pending load's lock on the base: the producer misses (cold line),
@     is uncached, or is a writeback chain whose producer misses
@   * a W flush (MSR control) between the producer and the access, and a
@     data abort on a chained access (FAR and the restored base)
@ Runs with the MMU off (all uncached), then cached cold and warm.
	.include "test.inc"
	.include "mmu.inc"
	.equ	T0, SCRATCH + 0x100	@ pointer table
	.equ	T1, SCRATCH + 0x200	@ data words
	.equ	T2, SCRATCH + 0x400	@ store area
	.equ	UNC, 0x20000000		@ uncached alias of SCRATCH's MB (MMU on)
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	fill
	bl	cases				@ MMU off: uncached
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, SCRATCH, 3, 0, 3
	SETL1	SCRATCH, r1
	SECT	r1, SCRATCH, 3, 0, 0
	SETL1	UNC, r1
	ldr	r0, =TTB + ((0x01000000 >> 20) << 2)
	mov	r1, #0				@ VA 0x01000000: translation fault
	str	r1, [r0]
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0		@ D-cache cold
	bl	cases
	bl	cases				@ warm
	bl	mmu_cases
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ T0[0] = &T1, T0[1] = 8, T0[2] = &T2, T0[3] = &T0; T1[i] = 0x1000 * i + 0x11
fill:
	ldr	r0, =T0
	ldr	r1, =T1
	str	r1, [r0]
	mov	r2, #8
	str	r2, [r0, #4]
	ldr	r2, =T2
	str	r2, [r0, #8]
	str	r0, [r0, #12]
	mov	r2, #0x11
	mov	r3, #64
1:	str	r2, [r1], #4
	add	r2, r2, #0x1000
	subs	r3, r3, #1
	bne	1b
	mov	pc, lr
	.ltorg

	@ "fast" and "slow" forms must leave the same value in \reg
	.macro	SAME reg, tmp
	CHECKR	\reg, \tmp
	.endm

cases:
	stmfd	sp!, {lr}
	ldr	r9, =T0
	@ --- base from the instruction just ahead: ALU, distances 1/2/3
	add	r1, r9, #0x100
	ldr	r2, [r1, #4]
	add	r1, r9, #0x100
	mov	r0, r0
	ldr	r3, [r1, #8]
	add	r1, r9, #0x100
	mov	r0, r0
	mov	r0, r0
	ldr	r4, [r1, #12]
	ldr	r5, =T1 + 4
	nop
	nop
	nop
	ldr	r5, [r5]
	SAME	r2, r5
	add	r1, r9, #0x300			@ ALU base into a store
	str	r2, [r1, #4]
	nop
	nop
	ldr	r6, =T2 + 4
	nop
	nop
	ldr	r6, [r6]
	SAME	r6, r2
	@ --- base from a load just ahead (pointer chase), distances 1/2/3
	ldr	r1, [r9]
	ldr	r2, [r1, #8]
	ldr	r1, [r9]
	mov	r0, r0
	ldr	r3, [r1, #8]
	ldr	r1, [r9]
	mov	r0, r0
	mov	r0, r0
	ldr	r4, [r1, #8]
	SAME	r2, r3
	SAME	r2, r4
	ldr	r1, [r9, #12]			@ two-level chase: T0[3] = &T0
	ldr	r1, [r1]
	ldr	r2, [r1, #8]
	SAME	r2, r4
	@ --- a load into the register offset, just ahead
	ldr	r1, [r9]
	ldr	r10, [r9, #4]			@ 8
	ldr	r2, [r1, r10]
	ldr	r3, [r1, #8]
	SAME	r2, r3
	add	r11, r1, #32
	ldr	r10, [r9, #4]
	ldr	r2, [r11, -r10]
	ldr	r4, [r1, #24]
	SAME	r2, r4
	@ --- an ALU result into the register offset, and a load into a byte base
	mov	r10, #12
	ldr	r2, [r1, r10]
	ldr	r3, [r1, #12]
	SAME	r2, r3
	ldrb	r10, [r9, #4]			@ 8
	ldrb	r2, [r1, r10]
	ldrb	r3, [r1, #8]
	SAME	r2, r3
	@ --- scaled offsets
	mov	r10, #3
	ldr	r2, [r1, r10, lsl #2]
	ldr	r3, [r1, #12]
	SAME	r2, r3
	add	r11, r1, #32			@ base just ahead and scaled
	ldr	r2, [r11, -r10, lsl #2]
	ldr	r3, [r1, #20]
	SAME	r2, r3
	mov	r10, #16
	ldr	r2, [r1, r10, lsr #1]
	ldr	r3, [r1, #8]
	SAME	r2, r3
	mvn	r10, #7				@ -8
	ldr	r2, [r11, r10, asr #1]		@ r11 - 4
	ldr	r3, [r1, #28]
	SAME	r2, r3
	mov	r10, #0x40000000
	ldr	r2, [r1, r10, ror #28]		@ +4
	ldr	r3, [r1, #4]
	SAME	r2, r3
	mov	r10, #8
	msr	cpsr_f, #0
	ldr	r2, [r1, r10, rrx]		@ C=0: +4
	ldr	r3, [r1, #4]
	SAME	r2, r3
	mov	r10, #1
	mov	r11, r1
	ldr	r2, [r11, r10, lsl #3]!		@ pre-indexed, scaled, writeback
	ldr	r3, [r11]			@ base just written back
	SAME	r2, r3
	sub	r4, r11, r1
	CHECK	r4, 8
	ldr	r2, [r11], r10, lsl #2		@ post-indexed scaled
	ldr	r3, [r11, #-4]
	SAME	r2, r3
	ldr	r4, [r1, #8]
	SAME	r2, r4
	@ --- writeback chains at distance 1 (base = the MEM ahead's sum)
	mov	r11, r1
	ldr	r2, [r11], #4
	ldr	r3, [r11], #4
	ldr	r4, [r11], #4
	ldr	r5, [r11], #4
	add	r6, r2, r3
	add	r6, r6, r4
	add	r6, r6, r5
	ldr	r7, =0x6044			@ 0x11+0x1011+0x2011+0x3011
	CHECKR	r6, r7
	sub	r4, r11, r1
	CHECK	r4, 16
	ldr	r11, =T2
	str	r2, [r11], #4
	str	r3, [r11], #4
	str	r4, [r11, #4]!
	str	r5, [r11, #-4]!
	ldr	r6, =T2 + 8
	ldr	r6, [r6]
	CHECKR	r6, r5
	ldr	r11, =T2
	ldr	r6, [r11], #4			@ load chain after store chain
	ldr	r7, [r11, #4]!
	ldr	r0, =T2
	sub	r0, r11, r0
	CHECK	r0, 8
	mov	r11, r1
	ldrh	r2, [r11], #2			@ halfword chains, immediate and register
	ldrh	r3, [r11], #2
	mov	r10, #2
	ldrsh	r4, [r11, r10]!
	ldrsb	r5, [r11], -r10
	sub	r0, r11, r1
	CHECK	r0, 4
	mov	r11, r1
	mov	r10, #4
	ldr	r2, [r11], r10			@ register post-index chain
	ldr	r3, [r11], r10
	ldr	r4, [r11], r10
	sub	r0, r11, r1
	CHECK	r0, 12
	@ a condition-failed writer: its writeback does not happen
	mov	r11, r1
	cmp	r0, r0
	ldrne	r2, [r11], #4
	ldr	r3, [r11], #4
	ldr	r4, [r1]
	SAME	r3, r4
	sub	r0, r11, r1
	CHECK	r0, 4
	@ a passing conditional writer, then readers of the written-back base
	mov	r11, r1
	cmp	r0, r0
	ldreq	r2, [r11], #8
	ldr	r3, [r11]
	add	r4, r11, #0			@ late reader
	add	r5, r0, r11, lsl #0		@ unshifted
	add	r6, r0, r11, lsl #1		@ early reader (shifted)
	sub	r0, r4, r1
	CHECK	r0, 8
	ldr	r4, [r1, #8]
	SAME	r3, r4
	@ --- block bases
	add	r8, r9, #0x300			@ ALU base into STM, just ahead
	stmia	r8, {r2-r5}
	ldr	r8, [r9, #8]			@ loaded base into LDM, just ahead
	ldmia	r8, {r4-r7}
	SAME	r4, r2
	SAME	r5, r3
	ldr	r8, [r9]
	ldmia	r8!, {r2, r3}			@ block writeback, then a scalar on it
	ldr	r4, [r8]
	ldr	r5, [r1, #8]
	SAME	r4, r5
	ldr	r8, [r9]
	ldr	r2, [r8], #4			@ scalar writeback into a block base
	ldmia	r8, {r3, r4}
	ldr	r5, [r1, #4]
	SAME	r3, r5
	ldr	r8, [r9, #8]
	stmia	r8!, {r2, r3}			@ block writeback chain
	stmia	r8!, {r4, r5}
	ldr	r0, [r9, #8]
	sub	r0, r8, r0
	CHECK	r0, 16
	add	r8, r9, #0x100			@ the four modes from an ALU base
	ldmib	r8, {r2, r3}
	ldr	r4, [r1, #4]
	SAME	r2, r4
	add	r8, r9, #0x108
	ldmda	r8, {r2, r3}
	ldr	r4, [r1, #4]
	SAME	r2, r4
	add	r8, r9, #0x108
	ldmdb	r8, {r2, r3}
	ldr	r4, [r1]
	SAME	r2, r4
	ldr	r8, [r9, #12]			@ base in the list: T0[0..1] -> r7, r8
	ldmia	r8, {r7, r8}
	ldr	r2, [r7]			@ r7 = &T1
	ldr	r3, [r1]
	SAME	r2, r3
	CHECK	r8, 8
	stmdb	sp!, {r2-r5}			@ push, then an sp-relative load
	ldr	r6, [sp, #4]
	SAME	r6, r3
	ldmia	sp!, {r2-r5}
	@ --- PC-relative
	ldr	r2, lit
	ldr	r3, =0x5A5A0F0F
	SAME	r2, r3
	adr	r4, lit
	ldr	r5, [r4]
	SAME	r5, r3
	adr	r0, thumb_part + 1
	bx	r0
	.balign	4
lit:	.word	0x5A5A0F0F
	.ltorg

	.thumb
	.thumb_func
thumb_part:
	ldr	r0, tlit			@ PC-relative (word-aligned PC)
	ldr	r1, tlit2
	add	r2, pc, #4
	ldr	r3, [r2, #0]			@ ADR'd base just ahead
	add	r4, r1, #4			@ ALU base just ahead
	ldr	r5, [r4, #0]
	push	{r0-r3}
	ldr	r6, [sp, #4]
	pop	{r0-r3}
	adr	r7, arm_back
	bx	r7
	.balign	4
tlit:	.word	0x12345678
tlit2:	.word	T1
	.arm
arm_back:
	mov	r0, #0x78
	orr	r0, r0, #0x5600
	orr	r0, r0, #0x340000
	orr	r0, r0, #0x12000000
	ldr	r7, =T1 + 4
	ldr	r7, [r7]
	CHECKR	r5, r7
	@ --- a W flush (MSR control, same mode) between producer and access
	add	r1, r9, #0x100
	mrs	r0, cpsr
	msr	cpsr_c, r0
	ldr	r2, [r1, #4]
	ldr	r3, [r1, #4]
	SAME	r2, r3
	ldr	r1, [r9]
	msr	cpsr_c, r0
	ldr	r2, [r1, #8]
	ldr	r3, [r1, #8]
	SAME	r2, r3
	ldmfd	sp!, {pc}
	.ltorg

@ MMU on only: the pending load's lock on the base, and an abort
mmu_cases:
	stmfd	sp!, {lr}
	ldr	r9, =T0
	ldr	r1, =T1
	@ base from an uncached load (long), just ahead
	ldr	r8, =UNC + (T0 - SCRATCH)
	ldr	r2, [r8]			@ &T1 via the uncached alias
	ldr	r3, [r2, #4]
	ldr	r4, [r1, #4]
	SAME	r3, r4
	@ base from a load that misses (cold line), and a chain whose producer misses
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r2, [r9]
	ldr	r3, [r2, #16]
	ldr	r4, [r1, #16]
	SAME	r3, r4
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	mov	r11, r1
	ldr	r2, [r11], #32			@ misses; its writeback feeds the next base
	ldr	r3, [r11], #32			@ misses too (another line)
	ldr	r4, [r11]
	ldr	r5, [r1, #64]
	SAME	r4, r5
	sub	r0, r11, r1
	CHECK	r0, 64
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r11, =T2 + 0x40
	str	r4, [r11], #4			@ store miss, chained
	ldr	r6, [r11, #-4]
	SAME	r6, r4
	@ a chained access that aborts: FAR = the forwarded base, base restored
	ldr	r11, =0x00FFFFF8
	mov	r0, #0x77
	str	r0, [r11]
	str	r0, [r11, #4]
	ldr	r11, =0x00FFFFFC
	ldr	r2, [r11], #4			@ fine, r11 -> 0x01000000
	ldr	r3, [r11], #4			@ translation fault at 0x01000000
	DABT	0x5, 0x01000000
	ldr	r0, =0x01000000
	CHECKR	r11, r0
	ldr	r11, =0x00FFFFF8
	ldmia	r11!, {r2, r3}			@ block writeback 0x01000000, then
	ldr	r4, [r11]			@ a scalar on it: aborts
	DABT	0x5, 0x01000000
	ldmfd	sp!, {pc}
	.ltorg
