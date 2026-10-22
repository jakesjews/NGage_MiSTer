@ SPDX-License-Identifier: GPL-3.0-or-later
@ The two-way instruction cache (RTL only): three code lines whose addresses
@ share the set index VA[12:4] (and VA[13:4], so a direct-mapped 16 KB cache
@ would hold only one of them) are run in turn and rewritten in memory
@ behind the cache; which of them still returns its old code tells which
@ lines the set holds, and so that the set has two ways and that the least
@ recently used line is the one replaced (TI SPRU671: fixed LRU).
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	LA,  0x00481000		@ set 0x100 of either 8 KB way,
	.equ	LB,  0x00491000		@ three tags; VA[13:4] alike too
	.equ	LC,  0x004A1000
	.equ	MOV_R0, 0xE3A00000	@ mov r0, #imm8
	.equ	MOV_PC_LR, 0xE1A0F00E	@ mov pc, lr
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	ldr	r0, =TTB
	ldr	r1, =0x00000C1E		@ RAM write-back, cacheable
	mov	r2, #16
1:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	1b
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r4, =LA
	ldr	r5, =LB
	ldr	r6, =LC

@ CODE line, imm: the line's code becomes "mov r0, #imm; mov pc, lr" in
@ memory (the D-cache line cleaned)
	.macro	CODE line, imm
	ldr	r0, =(MOV_R0 | \imm)
	ldr	r1, =MOV_PC_LR
	stmia	\line, {r0, r1}
	mcr	p15, 0, \line, c7, c10, 1
	.endm
@ CALL line: run the line's code, r0 = its imm
	.macro	CALL line
	mov	lr, pc
	mov	pc, \line
	.endm

	@ 1. A and B in the set together: after B, A is still cached
	CODE	r4, 0x11
	CODE	r5, 0x21
	CODE	r6, 0x31
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	@ flush I
	CALL	r4
	CHECK	r0, 0x11
	CALL	r5
	CHECK	r0, 0x21
	CALL	r4
	CHECK	r0, 0x11		@ A, B, A: the LRU line is B
	CODE	r4, 0x12
	CODE	r5, 0x22
	CALL	r4
	CHECK	r0, 0x11		@ old code: A was not replaced by B
	CALL	r5
	CHECK	r0, 0x21		@ nor B by A
	CHECKPOINT

	@ 2. a third line replaces the least recently used: A, B, A, B -> A
	CALL	r6
	CHECK	r0, 0x31		@ C replaces A (set: C, B; LRU B)
	CALL	r5
	CHECK	r0, 0x21		@ B still cached (set: C, B; LRU C)
	CALL	r4
	CHECK	r0, 0x12		@ A refetched: new code (replaces C; set: A, B; LRU B)
	CODE	r6, 0x32
	CALL	r6
	CHECK	r0, 0x32		@ C refetched (replaces B; set: A, C; LRU A)
	CALL	r5
	CHECK	r0, 0x22		@ B refetched (replaces A; set: B, C; LRU C)
	CALL	r6
	CHECK	r0, 0x32		@ C still cached (LRU B)
	CHECKPOINT

	@ 3. the order of use decides, not the order of filling: B then C
	@ filled, B used last -> C replaced
	CALL	r5
	CHECK	r0, 0x22		@ set: B, C; LRU C
	CODE	r5, 0x23
	CODE	r6, 0x33
	CALL	r4
	CHECK	r0, 0x12		@ A replaces C (set: B, A; LRU B)
	CALL	r5
	CHECK	r0, 0x22		@ old code: B was kept
	CALL	r6
	CHECK	r0, 0x33		@ new code: C was the one replaced
	CHECKPOINT

	@ 4. flush I empties both ways
	CODE	r4, 0x14
	CODE	r6, 0x34
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	CALL	r4
	CHECK	r0, 0x14
	CALL	r6
	CHECK	r0, 0x34
	CALL	r5
	CHECK	r0, 0x23
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}
