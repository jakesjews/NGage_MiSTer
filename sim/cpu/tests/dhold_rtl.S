@ SPDX-License-Identifier: GPL-3.0-or-later
@ Data accesses behind a background fill. Every pair is separated by 0-5
@ independent instructions (issue distances 1-6). A/B/C share a D-cache
@ set; A and B are dirty, A is MRU, so C evicts B. D is a hit in another
@ set, E a miss. The two immediate followers use different sets too: a
@ repair of only the held lookup must not lose the younger lookups.
@ Each case runs twice so its second pass has warm instruction lines.
@ Uncached aliases check dirty write-back and bypass. Only architecturally
@ coherent values are checked, so the same checks run on QEMU.
	.include "test.inc"
	.include "mmu.inc"
	.equ LA, 0x00421E00
	.equ LB, 0x00431E00
	.equ LC, 0x00441E00
	.equ LD, 0x00451D00
	.equ LE, 0x00461C00
	.equ UNC, 0x20000000
	.equ UA, UNC + 0x21E00
	.equ UB, UNC + 0x31E00
	.equ UC, UNC + 0x41E00
	.equ UD, UNC + 0x51D00
	.equ UE, UNC + 0x61C00
	.text
	.arm
	.global test_main

@ miss=0: background load, miss=1: background store (already acknowledged).
@ store=0: held load, store=1: held store with independent data.
	.macro PAIR gap, miss, store, target, expected
	mov	r8, #2
.Lpair\@:
	ldr	r10, =\target
	bl	prepare
	mov	r3, #0xC2
	mov	r11, #0x55
	.if \miss
	str	r3, [r6]
	.else
	ldr	r0, [r6]
	.endif
	.rept \gap - 1
	mov	r11, r11
	.endr
	.if \store
	str	r11, [r10]
	.else
	ldr	r1, [r10]
	.endif
	ldr	r2, [r7, #4]
	ldr	r3, [r4, #4]
	.if !\miss
	CHECK	r0, 0xC1
	.endif
	.if !\store
	CHECK	r1, \expected
	.endif
	CHECK	r2, 0xD4
	CHECK	r3, 0xA4
	.if \store
	ldr	r1, [r10]
	CHECK	r1, 0x55
	.endif
	@ Also verify the initiating store and that a victim access did not
	@ falsely hit the replacement C tag/data.
	ldr	r0, [r6]
	.if \miss
	CHECK	r0, 0xC2
	.else
	CHECK	r0, 0xC1
	.endif
	subs	r8, r8, #1
	bne	.Lpair\@
	b	.Lpool\@
	.ltorg
.Lpool\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	@ Cache only the code and test data sections. Stack/signature remain
	@ uncached, so they cannot change the test set's replacement order.
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r4, =LA
	ldr	r5, =LB
	ldr	r6, =LC
	ldr	r7, =LD

	.irp gap, 1, 2, 3, 4, 5, 6
	.irp miss, 0, 1
	.irp store, 0, 1
	PAIR	\gap, \miss, \store, LA, 0xA2
	PAIR	\gap, \miss, \store, LB, 0xB2
	PAIR	\gap, \miss, \store, LC+4, 0xC4
	PAIR	\gap, \miss, \store, LD, 0xD1
	PAIR	\gap, \miss, \store, LE, 0xE1
	PAIR	\gap, \miss, \store, UB, 0xB2
	PAIR	\gap, \miss, \store, UC+4, 0xC4
	PAIR	\gap, \miss, \store, UE, 0xE1
	.endr
	.endr
	CHECKPOINT
	.endr

	@ A dependent store must wait at issue for the background register,
	@ then use the newly loaded value (never hold stale data in memory).
	bl	prepare
	ldr	r0, [r6]
	str	r0, [r7]
	ldr	r1, [r7]
	CHECK	r1, 0xC1
	CHECKPOINT

	@ Held accesses still take their normal MMU and external aborts.
	bl	prepare
	ldr	r10, =0x30000000	@ unmapped section
	ldr	r0, [r6]
	ldr	r1, [r10]
	CHECK	r0, 0xC1
	DABT	5, 0x30000000
	SECT	r1, NOWHERE, 3, 0, 0
	SETL1	NOWHERE, r1
	TLBFLUSH
	bl	prepare
	ldr	r10, =NOWHERE
	ldr	r0, [r6]
	ldr	r1, [r10]
	CHECK	r0, 0xC1
	DABT	8, NOWHERE
	CHECKPOINT

	@ Flush dirty code/data before crt0 inspects the signature.
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ No stack or literal loads between priming the set and returning. r10 is
@ preserved; prepare returns after the background priming loads complete.
prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r9, =UA
	mov	r0, #0xA1
	str	r0, [r9]
	mov	r0, #0xA4
	str	r0, [r9, #4]
	ldr	r9, =UB
	mov	r0, #0xB1
	str	r0, [r9]
	ldr	r9, =UC
	mov	r0, #0xC1
	str	r0, [r9]
	mov	r0, #0xC4
	str	r0, [r9, #4]
	ldr	r9, =UD
	mov	r0, #0xD1
	str	r0, [r9]
	mov	r0, #0xD4
	str	r0, [r9, #4]
	ldr	r9, =UE
	mov	r0, #0xE1
	str	r0, [r9]
	ldr	r0, [r4]
	CHECK	r0, 0xA1
	ldr	r0, [r5]
	CHECK	r0, 0xB1
	ldr	r0, [r7]
	CHECK	r0, 0xD1
	mov	r0, #0xA2
	str	r0, [r4]
	mov	r0, #0xB2
	str	r0, [r5]
	ldr	r0, [r4]
	CHECK	r0, 0xA2
	mov	pc, lr
	.ltorg
