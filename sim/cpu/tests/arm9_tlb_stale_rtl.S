@ SPDX-License-Identifier: GPL-3.0-or-later
@ Stale TLB entries from V2's garbage-address walks (the second lead of the
@ TLB-walk fix, fe65a2d). Before that fix V2's D-side walker walked W's
@ address even when the real miss came from M. For a non-memory instruction
@ at W that address is the ALU result (arm9v2_execute o_address = alu_result
@ in the default case), so a real miss behind an ALU op whose result is some
@ section's VA made the walker read that section's L1 descriptor and cache
@ it, though the program never addresses that section. At the time of
@ fe65a2d, the shared walker also cached fault descriptors (id 2'b00), so
@ an unmapped speculative walk could poison a subsequent valid mapping.
@ That separate bug is covered by mmu_fault_retry.S and has since been fixed.
@
@ ARM DDI0100I B4.5.1 prohibits caching translation-fault descriptors;
@ the former comment claiming that this required a TLB flush was wrong.
@ Valid entries do still need invalidation when remapped. Thus case (c)
@ continues to distinguish a walk of the wrong address from a proper walk.
@
@ Trigger: S (0x13000000, MOV-able, never loaded or stored by the program)
@ is garbage-walked by placing `mov r3,#S` (ALU, o_address = S) between a
@ load that hits the TLB (so the pipeline is in RUN) and a load that misses
@ (so the walk fires while W still holds the MOV). Pre-fix V2 walks S; ZAP
@ and fixed V2 walk the missing load.
@
@   (a) S unmapped at the trigger, then mapped valid, no flush, then loaded:
@       pre-fix V2 aborts (stale fault entry); ZAP and fixed V2 read the RAM.
@   (b) the same but a TLB flush (all, then single-by-VA) before the load:
@       every core is clean - the kernel's switch flush covers the entry.
@   (c) S mapped valid to PA_A at the trigger (only the garbage walk reads
@       it), then remapped to PA_B, no flush, then loaded: pre-fix V2 returns
@       PA_A's marker (wrong data, no abort); ZAP and fixed V2 return PA_B's.
@
@ SIG_DATA: R_A abort count; R_A_D data; R_B_ALL/R_B_ONE abort counts;
@ R_C data (PA_B marker when correct); R_C_AB abort count for (c). The test
@ CHECKs the ZAP/fixed-V2 expectation, so the pre-fix run fails and shows it.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"

	.equ	S_VA,   0x13000000		@ never addressed by the program; MOV-able
	.equ	S_PA,   0x00500000		@ PA_A
	.equ	S_PB,   0x00700000		@ PA_B for (c)
	.equ	L1_VA,  0x19000000		@ load that hits (index 0x10)
	.equ	L2_VA,  0x16000000		@ base of the miss sections (indices 0x20..0x2f)
	.equ	L2_N,   16			@ distinct never-cached sections, none aliasing S/L1
	.equ	L1_PA,  0x00500000
	.equ	L2_PA,  0x00600000
	.equ	MARK_A, 0xAA00AA00
	.equ	MARK_B, 0xBB00BB00

	.equ	R_A, 0
	.equ	R_A_D, 1
	.equ	R_B_ALL, 2
	.equ	R_B_ONE, 3
	.equ	R_C, 4
	.equ	R_C_AB, 5

	.text
	.arm
	.global	test_main

	@ write \d to the L1 entry for the VA in \reg (r12)
	.macro	SETL1_R reg, d
	ldr	r12, =TTB
	add	r12, r12, \reg, lsr #18
	str	\d, [r12]
	.endm

	@ write \desc (or 0) to S's L1 entry (r11, r12)
	.macro	SETS desc
	ldr	r12, =TTB + ((S_VA >> 20) << 2)
	.ifc	\desc, zero
	mov	r11, #0
	.else
	mov	r11, \desc
	.endif
	str	r11, [r12]
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, L1_PA, 3, 0, 0
	SETL1	L1_VA, r1
	SECT	r1, L2_PA, 3, 0, 0
	ldr	r4, =L2_VA
	mov	r5, #L2_N
9:	SETL1_R	r4, r1
	add	r4, r4, #0x00100000
	subs	r5, r5, #1
	bne	9b
	ldr	r0, =S_PA
	ldr	r1, =MARK_A
	str	r1, [r0]
	ldr	r0, =S_PB
	ldr	r1, =MARK_B
	str	r1, [r0]

@ ---------------- (a) fault entry cached, map valid, no flush ----------
	SETS	zero				@ S unmapped
	bl	trigger				@ garbage-walk S (fault) on pre-fix
	SECT	r1, S_PA, 3, 0, 0
	SETS	r1				@ map S valid -> PA_A, no flush
	bl	ab_clear
	ldr	r0, =S_VA
	ldr	r4, [r0]			@ pre-fix: abort; else MARK_A
	ldr	r5, =ab_state
	ldr	r5, [r5]
	STORE_RESULT r5, R_A
	STORE_RESULT r4, R_A_D

@ ---------------- (b) same, with a flush before the load --------------
	SETS	zero
	bl	trigger
	SECT	r1, S_PA, 3, 0, 0
	SETS	r1
	TLBFLUSH				@ flush-all
	bl	ab_clear
	ldr	r0, =S_VA
	ldr	r4, [r0]
	ldr	r5, =ab_state
	ldr	r5, [r5]
	add	r5, r5, r4			@ abort count (data is MARK_A if clean)
	ldr	r6, =MARK_A
	sub	r5, r5, r6
	STORE_RESULT r5, R_B_ALL		@ 0 when clean (no abort, data=MARK_A)
	SETS	zero
	bl	trigger
	SECT	r1, S_PA, 3, 0, 0
	SETS	r1
	ldr	r0, =S_VA
	mcr	p15, 0, r0, c8, c7, 1		@ flush D-TLB single
	mcr	p15, 0, r0, c8, c5, 1		@ flush I-TLB single
	bl	ab_clear
	ldr	r0, =S_VA
	ldr	r4, [r0]
	ldr	r5, =ab_state
	ldr	r5, [r5]
	add	r5, r5, r4
	ldr	r6, =MARK_A
	sub	r5, r5, r6
	STORE_RESULT r5, R_B_ONE

@ ---------------- (c) valid entry cached, remap, no flush -------------
	SECT	r1, S_PA, 3, 0, 0
	SETS	r1				@ S valid -> PA_A at the trigger
	bl	trigger				@ garbage-walk S (valid -> PA_A)
	SECT	r1, S_PB, 3, 0, 0
	SETS	r1				@ remap S -> PA_B, no flush
	bl	ab_clear
	ldr	r0, =S_VA
	ldr	r4, [r0]			@ pre-fix: MARK_A (stale); else MARK_B
	ldr	r5, =ab_state
	ldr	r5, [r5]
	STORE_RESULT r4, R_C
	STORE_RESULT r5, R_C_AB

@ ---------------- expectations (ZAP and fixed V2) ----------------
	ldr	r10, =SIG_DATA
	ldr	r4, [r10, #(4*R_A)]
	CHECK	r4, 0				@ (a) no stale-fault abort
	ldr	r4, [r10, #(4*R_A_D)]
	CHECK	r4, MARK_A			@ (a) reads the newly mapped RAM
	ldr	r4, [r10, #(4*R_B_ALL)]
	CHECK	r4, 0				@ (b) flush-all clean
	ldr	r4, [r10, #(4*R_B_ONE)]
	CHECK	r4, 0				@ (b) flush-single clean
	ldr	r4, [r10, #(4*R_C_AB)]
	CHECK	r4, 0				@ (c) no abort
	ldr	r4, [r10, #(4*R_C)]
	CHECK	r4, MARK_B			@ (c) reads the remapped RAM

	NOABT
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ Garbage-walk S. Assumes S's L1 entry is already set (fault or valid).
@ Flush, warm L1 (so it hits), then L1 hit; MOV result=S; L2 miss.
@ One flush, warm L1, then several variants of `L1 hit; <pad>; mov S;
@ L2 miss`, each with distinct never-cached L2 and a different number of
@ filler NOPs, so some alignment lands the MOV at W when L2's miss-walk
@ fires in RUN, across latencies. No flush between variants, and S's index
@ (0x30) is not aliased by L1 (0x10) or the L2 sections (0x20..0x2f), so S
@ persists once any variant poisons it.
	.macro	TRIG pad
	ldr	r0, [r5]			@ L1 hit -> RUN
	.rept	\pad
	nop
	.endr
	mov	r3, #S_VA			@ W = ALU, o_address = S
	ldr	r1, [r7]			@ L2 miss -> pre-fix walks W = S
	add	r7, r7, #0x00100000		@ next never-cached L2 section
	.endm
trigger:
	stmfd	sp!, {r4-r8, lr}
	TLBFLUSH
	ldr	r5, =L1_VA
	ldr	r0, [r5]			@ warm L1
	ldr	r7, =L2_VA
	TRIG	0
	TRIG	1
	TRIG	2
	TRIG	3
	TRIG	0
	TRIG	1
	TRIG	2
	TRIG	3
	ldmfd	sp!, {r4-r8, pc}
	.ltorg
