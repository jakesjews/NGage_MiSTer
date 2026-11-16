@ SPDX-License-Identifier: GPL-3.0-or-later
@ STM with writeback and the base in the list, not first, and the LDM that
@ takes it back. ARMv4 leaves the stored value UNPREDICTABLE; the ARM7TDMI
@ stores the base as written back. The phone's ARM925T must store it as it
@ was before the instruction: Glimmerati's span drawer opens with
@ STMDB sp!, {r4-r12, sp, lr} and closes with LDMIA sp!, {r4-r12, sp, lr},
@ and needs sp back where it was (found by the Analogue Pocket core,
@ github.com/plasticbugs/n-gage, release 1.4.0). An LDM with the base in
@ the list leaves the base holding the loaded word.
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}

	@ the game's pair
	mov	r7, sp
	stmdb	sp!, {r4-r12, sp, lr}
	sub	r6, r7, sp
	CHECK	r6, 44
	ldr	r6, [sp, #36]		@ sp's slot: after r4-r12
	CHECKR	r6, r7
	ldmia	sp!, {r4-r12, sp, lr}
	CHECKR	sp, r7

	@ ascending, the base in the middle of the list
	ldr	r5, =SCRATCH
	mov	r8, r5
	mov	r4, #0x44
	mov	r6, #0x66
	stmia	r5!, {r4, r5, r6}
	sub	r9, r5, r8
	CHECK	r9, 12
	ldr	r9, [r8, #4]
	CHECKR	r9, r8
	ldr	r9, [r8, #8]
	CHECK	r9, 0x66

	@ and last in the list
	mov	r5, r8
	stmib	r5!, {r3, r4, r5}
	sub	r9, r5, r8
	CHECK	r9, 12
	ldr	r9, [r8, #12]
	CHECKR	r9, r8

	ldmfd	sp!, {r4-r11, pc}
	.ltorg
