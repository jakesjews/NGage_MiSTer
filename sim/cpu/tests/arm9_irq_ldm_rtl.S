@ SPDX-License-Identifier: GPL-3.0-or-later
@ Interrupts swept across the flash sector copy: EUser Mem::Copy's own
@ sequence (mem_copy.inc, a functional copy of 0x503A1D38) moving 512 or
@ 511 bytes from an UNCACHED source (the CS1 window's class, C=0 B=0) at
@ an offset k mod 4 to a CACHED destination, with an IRQ or FIQ raised at
@ every clock across its 8-word ldm / shift-merge / 8-word stm blocks, its
@ head (the aligned ldr fp,[r1],#4) and its tail (msr CPSR_f, the
@ conditional 16/8/4-byte ldm/stm tails, the byte tail, the return). On
@ ARMv4 an LDM or STM is not interruptible part-way: the interrupt waits
@ for the instruction to complete and lands on a later one. Each copy must
@ come out exact, with the routine's final registers and flags those of
@ an uninterrupted run, and with exactly the interrupts raised.
@
@ Kinds:
@   0  SVC copy, IRQ; the handler has the kernel's shape: it saves on the
@      IRQ stack, reads the timer (an uncached device word), acknowledges,
@      counts, then loads/stores two other tags of the sets of the
@      interrupted r0 (Mem::Copy's dest pointer) and of r0-4, so the dest
@      lines being written leave the cache (dirty ones written back), and
@      returns with subs pc,lr,#4.
@   1  SVC copy, FIQ: the handler works in the banked r8-r12 (the copy's
@      ldm/stm registers are r3-fp) and checks on entry that the bank
@      still holds what it left there.
@   2  USR copy, IRQ; the handler returns as EKA1's does (ekern
@      0x50321a80-0x50321a88): a DACR write, then ldmfd sp!,{r0-r3,ip,pc}^.
@   3  USR copy, IRQ; the handler saves the thread's context as the
@      scheduler does (stm {r0-r12}, stm {sp,lr}^), poisons every user
@      register, restores them with ldm {sp,lr}^ and ldm {r0-r12}, and
@      returns with ldm ^.
@   4  SVC copy, IRQ then an FIQ 0-22 clocks later (nested in the IRQ
@      entry or handler).
@ Sweeps: kinds 0 and 1, both directions, k 0 and 2, n 512 and 511; kinds
@ 2, 3 and 4 ascending, k 2, n 512. Assembled with --defsym FULL=1 also
@ kinds 0 and 1 at k 1 and 3, kinds 2 and 3 at k 0 and descending, kind 2
@ with n 511 and kind 4 descending.
@
@ Each sweep first times an uninterrupted copy (T clocks from arming to
@ the return; its registers are the reference). W = max(200, 1.25*T/16 +
@ 16) is more than one 32-byte block (T/16). The interrupt is then raised
@ at every delay of 1-200 (the head), of W clocks in the middle of the
@ copy and of the W clocks before T + 48 (the last block and the tails),
@ then at 36 delays every max(5, T/32) clocks from 1. Even iterations
@ start with the dest lines present and dirty, odd ones with them cleaned
@ and invalidated. The dest and 32 bytes either side are poisoned first;
@ each copy is compared word for word with a byte-loop reference made
@ into the same poison, and r0-r12, sp, lr and the CPSR must equal the
@ uninterrupted run's.
@
@ Results (SIG_DATA): +0 failing iterations, +4 first failure
@ (sweep << 16 | bits: 1 a word of the dest or its margins, 4 registers,
@ 8 interrupt count, 16 handler check, 32 no interrupt), +8 its delay,
@ +12 iterations, +16 sweeps, +20 landings right after an ldm, +24 after
@ an stm, +28 handler check errors, +32 landings inside Mem::Copy, +36
@ the first failure's differing registers (bit n = r0-r14, CPSR), whose
@ captured and reference values are at +0x800 and +0x840. +0x40: 16
@ bytes a sweep (T, iterations, W, the middle window's start). +0x1000:
@ the landing histogram, one word per instruction of mem_copy.inc.
@@ qemu: no
@@ bench: --max-cycles 1500000000
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000			@ uncached alias of PA 0x00400000
	.equ	SRC, 0x004C0000			@ source, read through UNC
	.equ	USRC, UNC + SRC - 0x00400000
	.equ	DST, 0x00410000			@ cached dest
	.equ	REF, 0x00414000			@ cached reference copy
	.equ	XB1, 0x00420000			@ DST's sets, two other tags
	.equ	XB2, 0x00440000
	.equ	NB, 512
	.equ	MARGIN, 32
	.equ	NW, (NB + 2 * MARGIN) / 4	@ poisoned words
	.equ	RES, SIG_DATA
	.equ	RES_FAILS, RES + 0
	.equ	RES_FIRST, RES + 4
	.equ	RES_FDELAY, RES + 8
	.equ	RES_ITERS, RES + 12
	.equ	RES_SWEEPS, RES + 16
	.equ	RES_AFTER_LDM, RES + 20
	.equ	RES_AFTER_STM, RES + 24
	.equ	RES_HERR, RES + 28
	.equ	RES_INSIDE, RES + 32
	.equ	RES_TABLE, RES + 0x40
	.equ	HIST, SIG_DATA + 0x1000
	@ sweep state (sw)
	.equ	SW_DIR, 0
	.equ	SW_K, 4
	.equ	SW_KIND, 8
	.equ	SW_DELAY, 12
	.equ	SW_ITER, 16
	.equ	SW_ID, 20
	.equ	SW_T0, 24
	.equ	SW_T, 28
	.equ	SW_CPSR, 32
	.equ	SW_ARM, 36
	.equ	SW_NIRQ, 40
	.equ	SW_NFIQ, 44
	.equ	SW_COUNT, 48
	.equ	SW_N, 52
	@ handler state (hs)
	.equ	HS_IRQ, 0
	.equ	HS_FIQ, 4
	.equ	HS_TIME, 8
	.equ	FIQ_POISON, 0xF1F00000
	.equ	IRQ_MAGIC, 0x1C1C1C1C
	.text
	.arm
	.global	test_main

	@ SWEEP kind, dir, k, n
	.macro	SWEEP kind, dir, k, n
	mov	r0, #\dir
	mov	r1, #\k
	mov	r2, #\kind
	ldr	r3, =\n
	bl	run_sweep
	.set	_sweeps, _sweeps + 1
	.endm
	.set	_sweeps, 0

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3			@ code and data: cached
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3		@ dest, reference, evictors
	SETL1	0x00400000, r1
	SECT	r1, 0x00600000, 3, 0, 3		@ every mode's stack
	SETL1	0x00600000, r1
	SECT	r1, 0x00400000, 3, 0, 0		@ UNC: the source's class
	SETL1	UNC, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	VECTOR	VEC_SWI, swi_h
	VECTOR	VEC_FIQ, fiq_h
	@ the source, through the uncached alias: byte b = (b*0x6D+0x3B)&FF
	ldr	r1, =USRC
	mov	r2, #0x3B
	mov	r3, #0
1:	and	r4, r2, #0xFF
	strb	r4, [r1, r3]
	add	r2, r2, #0x6D
	add	r3, r3, #1
	cmp	r3, #(NB + 8)
	bne	1b
	@ results and histogram cleared
	ldr	r0, =RES
	mov	r1, #0
	mov	r2, #0x40
2:	str	r1, [r0], #4
	subs	r2, r2, #1
	bne	2b
	ldr	r0, =HIST
	ldr	r2, =mc_end
	ldr	r3, =mc_begin
	sub	r2, r2, r3
	mov	r2, r2, lsr #2
3:	str	r1, [r0], #4
	subs	r2, r2, #1
	bne	3b
	@ the FIQ bank's poison, which only the FIQ handler may change
	msr	cpsr_c, #(M_FIQ | PSR_I | PSR_F)
	ldr	r8, =(FIQ_POISON + 8)
	add	r9, r8, #1
	add	r10, r8, #2
	add	r11, r8, #3
	add	r12, r8, #4
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, =sw
	mov	r1, #0
	str	r1, [r0, #SW_ID]
	str	r1, [r0, #SW_ITER]

	@ every build: k 0 (the aligned ldm/stm pairs) and 2 (the board's
	@ sectors), n 512 (no tails) and 511 (every tail)
	.irp	dir, 0, 1
	.irp	k, 0, 2
	.irp	n, 512, 511
	SWEEP	0, \dir, \k, \n
	SWEEP	1, \dir, \k, \n
	.endr
	.endr
	.endr
	SWEEP	2, 0, 2, 512
	SWEEP	3, 0, 2, 512
	SWEEP	4, 0, 2, 512
	.ifdef	FULL
	@ --defsym FULL=1: k 1 and 3, and the other kinds' other shapes
	.irp	dir, 0, 1
	.irp	k, 1, 3
	SWEEP	0, \dir, \k, 512
	SWEEP	1, \dir, \k, 512
	.endr
	.endr
	.irp	kind, 2, 3
	SWEEP	\kind, 0, 0, 512
	SWEEP	\kind, 1, 2, 512
	.endr
	SWEEP	2, 0, 2, 511
	SWEEP	4, 1, 2, 512
	.endif

	ldr	r0, =RES_FIRST
	ldr	r0, [r0]
	CHECK	r0, 0
	ldr	r0, =RES_FAILS
	ldr	r0, [r0]
	CHECK	r0, 0
	ldr	r0, =RES_HERR
	ldr	r0, [r0]
	CHECK	r0, 0
	ldr	r0, =RES_SWEEPS
	ldr	r0, [r0]
	CHECK	r0, _sweeps
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ run_sweep: r0 = direction (0 ascending, 1 descending), r1 = k, r2 = kind,
@ r3 = n. SVC, interrupts masked.
run_sweep:
	stmfd	sp!, {r4-r11, lr}
	ldr	r11, =sw
	str	r0, [r11, #SW_DIR]
	str	r1, [r11, #SW_K]
	str	r2, [r11, #SW_KIND]
	str	r3, [r11, #SW_N]
	mov	r0, #0
	str	r0, [r11, #SW_COUNT]
	@ the kind's handler, copy mode and interrupts
	ldr	r3, =kinds
	add	r3, r3, r2, lsl #4
	add	r3, r3, r2, lsl #2		@ 20 bytes a kind
	ldmia	r3, {r4-r8}
	ldr	r12, =VEC_IRQ
	str	r4, [r12]
	str	r5, [r11, #SW_CPSR]
	str	r6, [r11, #SW_ARM]
	str	r7, [r11, #SW_NIRQ]
	str	r8, [r11, #SW_NFIQ]
	@ this sweep's poison: word i of the dest area = base + i
	ldr	r0, [r11, #SW_ID]
	ldr	r1, =0x5A000000
	add	r1, r1, r0, lsl #12
	ldr	r2, =pbase
	str	r1, [r2]
	@ the reference: the same poison, then a byte loop from the same
	@ uncached bytes
	ldr	r0, =(REF - MARGIN)
	bl	poison
	ldr	r0, =REF
	ldr	r1, [r11, #SW_K]
	ldr	r2, =USRC
	add	r2, r2, r1
	ldr	r3, [r11, #SW_N]
1:	ldrb	r4, [r2], #1
	strb	r4, [r0], #1
	subs	r3, r3, #1
	bne	1b
	@ uninterrupted run (through window, for the same sp): T and the
	@ reference registers
	mvn	r0, #0
	mov	r1, #1
	mov	r2, #0
	bl	window
	ldr	r4, [r11, #SW_T]		@ T
	@ W = max(200, T/16 + T/64 + 16): more than one 32-byte block
	mov	r5, r4, lsr #4
	add	r5, r5, r4, lsr #6
	add	r5, r5, #16
	cmp	r5, #200
	movlo	r5, #200
	rsbs	r6, r5, r4			@ the middle window: from (T - W)/2
	mov	r6, r6, asr #1
	cmp	r6, #1
	movlt	r6, #1
	ldr	r0, [r11, #SW_ID]
	ldr	r1, =RES_TABLE
	add	r1, r1, r0, lsl #4
	str	r4, [r1]
	str	r5, [r1, #8]
	str	r6, [r1, #12]
	@ the head: every clock of the first 200 (entry, the aligned ldr fp,
	@ the first block's start)
	mov	r0, #1
	mov	r1, #200
	mov	r2, #1
	bl	window
	@ the middle: every clock of W
	mov	r0, r6
	mov	r1, r5
	mov	r2, #1
	bl	window
	@ the tail: every clock of W before T + 48 (the last block, the
	@ msr CPSR_f-chosen tails, the byte tail, the return)
	add	r0, r4, #48
	subs	r0, r0, r5
	movle	r0, #1
	mov	r1, r5
	mov	r2, #1
	bl	window
	@ coarse: 36 delays every max(5, T/32) clocks from 1
	mov	r2, r4, lsr #5
	cmp	r2, #5
	movlo	r2, #5
	mov	r0, #1
	mov	r1, #36
	bl	window
	ldr	r0, [r11, #SW_ID]
	ldr	r1, =RES_TABLE
	add	r1, r1, r0, lsl #4
	ldr	r2, [r11, #SW_COUNT]
	str	r2, [r1, #4]
	add	r0, r0, #1
	str	r0, [r11, #SW_ID]
	ldr	r1, =RES_SWEEPS
	str	r0, [r1]
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ window: r0 = first delay, r1 = copies, r2 = step; r11 = sw
window:
	stmfd	sp!, {r4-r6, lr}
	mov	r4, r0
	mov	r5, r1
	mov	r6, r2
1:	str	r4, [r11, #SW_DELAY]
	bl	one_copy
	add	r4, r4, r6
	subs	r5, r5, #1
	bne	1b
	ldmfd	sp!, {r4-r6, pc}

@ poison: r0 = area of NW words, word i = pbase + i (r1-r9 used)
poison:
	ldr	r1, =pbase
	ldr	r1, [r1]
	add	r2, r1, #1
	add	r3, r1, #2
	add	r4, r1, #3
	add	r5, r1, #4
	add	r6, r1, #5
	add	r7, r1, #6
	add	r8, r1, #7
	mov	r9, #(NW / 8)
1:	stmia	r0!, {r1-r8}
	add	r1, r1, #8
	add	r2, r2, #8
	add	r3, r3, #8
	add	r4, r4, #8
	add	r5, r5, #8
	add	r6, r6, #8
	add	r7, r7, #8
	add	r8, r8, #8
	subs	r9, r9, #1
	bne	1b
	mov	pc, lr
	.ltorg

@ one_copy: one copy with the interrupt(s) at sw.delay (< 0: none, the
@ reference run). SVC, interrupts masked on entry and exit.
one_copy:
	stmfd	sp!, {r4-r11, lr}
	ldr	r11, =sw
	ldr	r0, [r11, #SW_ITER]
	add	r0, r0, #1
	str	r0, [r11, #SW_ITER]
	@ poison the dest and its margins
	ldr	r0, =(DST - MARGIN)
	bl	poison
	@ odd iterations: the dest lines cleaned and invalidated
	ldr	r0, [r11, #SW_ITER]
	tst	r0, #1
	beq	3f
	ldr	r2, =(DST - MARGIN)
	mov	r3, #(NW / 4)
2:	mcr	p15, 0, r2, c7, c14, 1
	add	r2, r2, #16
	subs	r3, r3, #1
	bne	2b
3:	ldr	r10, =hs
	mov	r0, #0
	str	r0, [r10, #HS_IRQ]
	str	r0, [r10, #HS_FIQ]
	@ arm the interrupt(s), then the copy's mode with I and F clear
	ldr	r9, =BENCH
	ldr	r1, [r11, #SW_DELAY]
	ldr	r2, [r11, #SW_ARM]
	ldr	r3, [r11, #SW_ITER]
	and	r3, r3, #15			@ the nested FIQ's offset: 0-22
	add	r3, r3, r3, lsr #1
	ldr	r4, [r9, #BENCH_CYCLES]
	str	r4, [r11, #SW_T0]
	cmp	r1, #0
	blt	4f
	tst	r2, #1
	strne	r1, [r9, #BENCH_IRQ_IN]
	add	r3, r1, r3
	tst	r2, #2
	beq	4f
	cmp	r2, #3
	moveq	r1, r3
	str	r1, [r9, #BENCH_FIQ_IN]
4:	ldr	r12, [r11, #SW_CPSR]
	ldr	r0, [r11, #SW_DIR]
	ldr	r1, [r11, #SW_K]
	ldr	r2, =USRC
	add	r1, r1, r2
	ldr	r2, [r11, #SW_N]
	cmp	r0, #0
	ldr	r0, =DST
	ldr	r3, =0x33333333
	ldr	r4, =0x44444444
	ldr	r5, =0x55555555
	ldr	r6, =0x66666666
	ldr	r7, =0x77777777
	ldr	r8, =0x88888888
	ldr	r9, =0x99999999
	ldr	r10, =0xAAAAAAAA
	ldr	r11, =0xBBBBBBBB
	msr	cpsr_c, r12			@ (flags kept: Z = ascending)
	ldr	r12, =0xCCCCCCCC
	bne	5f
	bl	mcopy
	b	cap_point
5:	bl	mcopy_down
cap_point:
	str	r0, cap_r
	adr	r0, cap_r
	stmib	r0, {r1-r12}
	str	sp, [r0, #52]
	str	lr, [r0, #56]
	mrs	r1, cpsr
	bic	r1, r1, #0x100
	str	r1, [r0, #60]
	and	r1, r1, #0x1F
	cmp	r1, #M_USR
	swieq	0				@ back to SVC
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r11, =sw
	ldr	r10, =hs
	ldr	r9, =BENCH
	ldr	r4, [r9, #BENCH_CYCLES]
	ldr	r5, [r11, #SW_T0]
	sub	r4, r4, r5
	mov	r8, #0				@ error bits
	ldr	r0, [r11, #SW_DELAY]
	cmp	r0, #0
	blt	8f
	@ wait for the interrupt(s), with I and F clear in SVC
	ldr	r2, [r11, #SW_NIRQ]
	ldr	r3, [r11, #SW_NFIQ]
	add	r2, r2, r3
	ldr	r3, =100000
	msr	cpsr_c, #M_SVC
6:	ldr	r0, [r10, #HS_IRQ]
	ldr	r1, [r10, #HS_FIQ]
	add	r0, r0, r1
	cmp	r0, r2
	bhs	7f
	subs	r3, r3, #1
	bne	6b
	orr	r8, r8, #32
7:	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	ldr	r0, [r10, #HS_IRQ]
	ldr	r1, [r11, #SW_NIRQ]
	cmp	r0, r1
	orrne	r8, r8, #8
	ldr	r0, [r10, #HS_FIQ]
	ldr	r1, [r11, #SW_NFIQ]
	cmp	r0, r1
	orrne	r8, r8, #8
	@ the registers against the uninterrupted run's
	adr	r0, cap_r
	ldr	r1, =cal_r
	mov	r2, #16
	mov	r6, #0
	mov	r7, #1
9:	ldr	r3, [r0], #4
	ldr	r5, [r1], #4
	cmp	r3, r5
	orrne	r8, r8, #4
	orrne	r6, r6, r7			@ which registers
	mov	r7, r7, lsl #1
	subs	r2, r2, #1
	bne	9b
	ldr	r0, =regmask
	str	r6, [r0]
	b	10f
8:	@ the reference run: keep T and the registers
	str	r4, [r11, #SW_T]
	adr	r0, cap_r
	ldr	r1, =cal_r
	mov	r2, #16
9:	ldr	r3, [r0], #4
	str	r3, [r1], #4
	subs	r2, r2, #1
	bne	9b
10:	@ the dest and its margins against the reference area
	ldr	r0, =(DST - MARGIN)
	ldr	r1, =(REF - MARGIN)
	mov	r2, #(NW / 4)
11:	ldmia	r0!, {r3-r6}
	ldmia	r1!, {r7, r9, r10, r12}
	cmp	r3, r7
	orrne	r8, r8, #1
	cmp	r4, r9
	orrne	r8, r8, #1
	cmp	r5, r10
	orrne	r8, r8, #1
	cmp	r6, r12
	orrne	r8, r8, #1
	subs	r2, r2, #1
	bne	11b
	@ the handlers' own checks
	ldr	r0, =hs_err
	ldr	r1, [r0]
	cmp	r1, #0
	orrne	r8, r8, #16
	mov	r2, #0
	str	r2, [r0]
	ldr	r0, =RES_HERR
	ldr	r2, [r0]
	add	r2, r2, r1
	str	r2, [r0]
	@ record
	ldr	r0, =RES_ITERS
	ldr	r1, [r0]
	add	r1, r1, #1
	str	r1, [r0]
	ldr	r1, [r11, #SW_COUNT]
	add	r1, r1, #1
	str	r1, [r11, #SW_COUNT]
	cmp	r8, #0
	beq	14f
	ldr	r0, =RES_FAILS
	ldr	r1, [r0]
	add	r1, r1, #1
	str	r1, [r0]
	ldr	r0, =RES_FIRST
	ldr	r1, [r0]
	cmp	r1, #0
	bne	14f
	ldr	r1, [r11, #SW_ID]
	orr	r1, r8, r1, lsl #16
	str	r1, [r0]
	ldr	r1, [r11, #SW_DELAY]
	str	r1, [r0, #4]
	ldr	r1, =regmask
	ldr	r1, [r1]
	str	r1, [r0, #32]			@ RES + 36: the registers that differed
	adr	r1, cap_r			@ RES + 0x800: their values
	ldr	r2, =(RES + 0x800)
	mov	r3, #16
15:	ldr	r4, [r1], #4
	str	r4, [r2], #4
	subs	r3, r3, #1
	bne	15b
	ldr	r1, =cal_r			@ RES + 0x840: the reference's
	mov	r3, #16
16:	ldr	r4, [r1], #4
	str	r4, [r2], #4
	subs	r3, r3, #1
	bne	16b
14:	ldmfd	sp!, {r4-r11, pc}
	.ltorg
	.align	2
cap_r:	.space	64

@ SWI from the USR copy: back to the caller in SVC, interrupts masked
swi_h:
	msr	cpsr_c, #(M_SVC | PSR_I | PSR_F)
	mov	pc, lr

@ Where the interrupt landed: where = the interrupted instruction (t1, t2
@ used). Counts landings inside mem_copy.inc and right after an ldm/stm.
	.macro	LAND where, t1, t2
	ldr	\t1, =mc_end
	cmp	\where, \t1
	bhs	.Lout\@
	ldr	\t1, =mc_begin
	subs	\t2, \where, \t1
	blo	.Lout\@
	ldr	\t1, =HIST
	add	\t2, \t1, \t2
	ldr	\t1, [\t2]
	add	\t1, \t1, #1
	str	\t1, [\t2]
	ldr	\t2, =RES_INSIDE
	ldr	\t1, [\t2]
	add	\t1, \t1, #1
	str	\t1, [\t2]
	ldr	\t1, [\where, #-4]		@ the instruction before
	and	\t2, \t1, #0x0E000000
	cmp	\t2, #0x08000000
	bne	.Lout\@
	tst	\t1, #0x00100000
	ldrne	\t2, =RES_AFTER_LDM
	ldreq	\t2, =RES_AFTER_STM
	ldr	\t1, [\t2]
	add	\t1, \t1, #1
	str	\t1, [\t2]
.Lout\@:
	.endm

@ The dest lines around addr (addr-4 and addr) leave: two other tags of
@ each set are loaded and one stored (t1, t2, t3 used)
	.macro	EVICT addr, t1, t2, t3
	ldr	\t3, =0x1FF0
	sub	\t1, \addr, #4
	and	\t1, \t1, \t3
	ldr	\t2, =XB1
	ldr	\t2, [\t2, \t1]
	ldr	\t2, =XB2
	ldr	\t2, [\t2, \t1]
	ldr	\t2, =XB1
	str	\t1, [\t2, \t1]
	and	\t1, \addr, \t3
	ldr	\t2, =XB1
	ldr	\t2, [\t2, \t1]
	ldr	\t2, =XB2
	ldr	\t2, [\t2, \t1]
	ldr	\t2, =XB2
	str	\t1, [\t2, \t1]
	.endm

@ IRQ handler body: the frame {r0-r3, ip, lr} is at sp; adj = 4 when the
@ saved lr is the raw IRQ lr (return + 4). Uses r0-r3; ip holds a magic
@ word throughout and sp the frame, both checked at the end.
	.macro	IRQ_BODY adj
	ldr	ip, =IRQ_MAGIC
	ldr	r0, =BENCH
	ldr	r1, [r0, #BENCH_CYCLES]		@ the timer
	mrs	r3, cpsr			@ acknowledge the IRQ line only
	orr	r2, r3, #PSR_F
	msr	cpsr_c, r2
	ldr	r2, [r0, #BENCH_INT]
	bic	r2, r2, #1
	str	r2, [r0, #BENCH_INT]
	msr	cpsr_c, r3
	ldr	r3, =hs
	ldr	r2, [r3, #HS_IRQ]
	add	r2, r2, #1
	str	r2, [r3, #HS_IRQ]
	str	r1, [r3, #HS_TIME]
	ldr	r1, [sp, #20]
	sub	r1, r1, #\adj
	LAND	r1, r2, r3
	ldr	r1, [sp]			@ the interrupted r0
	EVICT	r1, r2, r3, r0
	ldr	r0, =IRQ_MAGIC
	cmp	ip, r0
	bne	.Lbad\@
	ldr	r0, =(STACK_IRQ - 24)
	cmp	sp, r0
	beq	.Lok\@
.Lbad\@:
	ldr	r0, =hs_err
	ldr	r1, [r0]
	add	r1, r1, #1
	str	r1, [r0]
.Lok\@:
	@ leave garbage for the restore to replace
	ldr	r0, =0xDEAD0000
	add	r1, r0, #1
	add	r2, r0, #2
	add	r3, r0, #3
	add	ip, r0, #12
	.endm

@ kinds 0, 1 and 4: the kernel's shape, returning with subs pc, lr, #4
irq_h0:
	stmfd	sp!, {r0-r3, ip, lr}
	IRQ_BODY 4
	ldmfd	sp!, {r0-r3, ip, lr}
	subs	pc, lr, #4
	.ltorg

@ kind 2: EKA1's exit (ekern 0x50321a80): a DACR write, then ldm ^
irq_h1:
	sub	lr, lr, #4
	stmfd	sp!, {r0-r3, ip, lr}
	IRQ_BODY 0
	mov	r0, #1				@ domain 0 client, as before
	mcr	p15, 0, r0, c3, c0, 0
	ldmfd	sp!, {r0-r3, ip, pc}^
	.ltorg

@ kind 3: the scheduler's context save (ekern 0x50321a60) and a restore
irq_h2:
	sub	lr, lr, #4
	stmfd	sp!, {r0-r3, ip, lr}
	IRQ_BODY 0
	ldmia	sp, {r0-r3, ip}			@ the thread's r0-r3, ip again
	ldr	lr, =ctx
	stmia	lr!, {r0-r12}
	stmia	lr, {sp, lr}^			@ the thread's sp, lr
	nop
	ldr	r0, =ctx_poison
	ldmia	r0, {r1-r12}
	ldmia	r0, {sp, lr}^
	nop
	ldr	r0, =(ctx + 52)
	ldmia	r0, {sp, lr}^
	nop
	ldr	lr, =ctx
	ldmia	lr, {r0-r12}
	ldmfd	sp!, {r0-r3, ip, pc}^
	.ltorg

@ FIQ: works in the banked r8-r12 only; on entry they must hold what the
@ last FIQ left (FIQ_POISON + 8..12)
fiq_h:
	str	r0, [sp, #-4]!
	ldr	r0, =(FIQ_POISON + 8)
	cmp	r8, r0
	addeq	r0, r0, #1
	cmpeq	r9, r0
	addeq	r0, r0, #1
	cmpeq	r10, r0
	addeq	r0, r0, #1
	cmpeq	r11, r0
	addeq	r0, r0, #1
	cmpeq	r12, r0
	ldr	r8, =hs_err
	ldrne	r9, [r8]
	addne	r9, r9, #1
	strne	r9, [r8]
	ldr	r0, [sp], #4
	ldr	r8, =BENCH
	ldr	r9, [r8, #BENCH_CYCLES]		@ the timer
	ldr	r10, [r8, #BENCH_INT]		@ acknowledge the FIQ line only
	bic	r10, r10, #2
	str	r10, [r8, #BENCH_INT]
	ldr	r11, =hs
	ldr	r10, [r11, #HS_FIQ]
	add	r10, r10, #1
	str	r10, [r11, #HS_FIQ]
	str	r9, [r11, #HS_TIME]
	sub	r9, lr, #4
	LAND	r9, r10, r11
	EVICT	r0, r10, r11, r12
	ldr	r8, =(FIQ_POISON + 8)
	add	r9, r8, #1
	add	r10, r8, #2
	add	r11, r8, #3
	add	r12, r8, #4
	subs	pc, lr, #4
	.ltorg

	.align	4
mc_begin:
	.include "mem_copy.inc"
	.align	2
mc_end:
	.ltorg

	.data
	.align	4
@ kinds: IRQ handler, the copy's CPSR (I, F clear), interrupts raised
@ (bit 0 IRQ, bit 1 FIQ), IRQs and FIQs expected
kinds:
	.word	irq_h0, M_SVC, 1, 1, 0
	.word	irq_h0, M_SVC, 2, 0, 1
	.word	irq_h1, M_USR, 1, 1, 0
	.word	irq_h2, M_USR, 1, 1, 0
	.word	irq_h0, M_SVC, 3, 1, 1
sw:	.space	64
hs:	.space	16
hs_err:	.word	0
pbase:	.word	0
regmask: .word	0
cal_r:	.space	64
ctx:	.space	64
ctx_poison:
	.word	0xC0DE0001, 0xC0DE0002, 0xC0DE0003, 0xC0DE0004
	.word	0xC0DE0005, 0xC0DE0006, 0xC0DE0007, 0xC0DE0008
	.word	0xC0DE0009, 0xC0DE000A, 0xC0DE000B, 0xC0DE000C
