@ SPDX-License-Identifier: GPL-3.0-or-later
@ TLB walks for a fixed access pattern, counted by the bench (BENCH_DWALKS,
@ BENCH_IWALKS): two code sections and N data sections, N = 4 to 12,
@ cycling. Every section has its own index in the 64-entry direct-mapped
@ section TLBs, so once each has been walked no walk is needed: after a
@ warm-up pass, 16 more passes must make 0 walks on either side.
@
@ The loop runs in a second code section (a copy of loop_b at VA
@ 0x12F00000, PA 0x00A00000) and calls a stub in the first (VA 0). Per
@ data section: a load of its address from a table (uncached), a load from
@ it (odd sections uncached, so the request is held; even sections cached,
@ a new line each pass, so it fills), ALU work on the loaded data (A-stage
@ addresses of non-memory instructions are data values), and the call.
@ This is the shape that made V2 re-walk: a check made stale by the hold
@ or the fill, and walks of W's address instead of the address that
@ missed (sim/harness/flashcopy.S showed 193,735 re-walks of one entry).
@ Results: SIG_DATA + 8*k = D walks, I walks for N = 4, 6, 8, 10, 12.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	BENCH_DWALKS, 0x50
	.equ	BENCH_IWALKS, 0x58
	.equ	CODEB_VA, 0x12F00000		@ TLB index 47
	.equ	CODEB_PA, 0x00A00000
	.equ	DATA_VA, 0x11000000		@ data section i: DATA_VA + i MB, index 16 + i
	.equ	CACHED_PA, 0x00B00000
	.equ	UNCACHED_PA, 0x00C00000
	.equ	TABLE, SIG_DATA + 0x100		@ the N data addresses (section 0x00F, index 15)
	.equ	PASSES, 16
	.text
	.arm
	.global	test_main

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3			@ code section A cached
	SETL1	0, r1
	SECT	r1, CODEB_PA, 3, 0, 3		@ code section B cached
	SETL1	CODEB_VA, r1
	.irp	i, 0, 2, 4, 6, 8, 10
	SECT	r1, CACHED_PA, 3, 0, 3
	SETL1	(DATA_VA + (\i << 20)), r1
	.endr
	.irp	i, 1, 3, 5, 7, 9, 11
	SECT	r1, UNCACHED_PA, 3, 0, 0
	SETL1	(DATA_VA + (\i << 20)), r1
	.endr
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	@ copy loop_b to code section B's memory (identity-mapped, uncached)
	ldr	r0, =loop_b
	ldr	r1, =loop_b_end
	ldr	r2, =CODEB_PA
1:	ldr	r3, [r0], #4
	str	r3, [r2], #4
	cmp	r0, r1
	blo	1b
	TLBFLUSH
	mov	r0, #0
	mcr	p15, 0, r0, c7, c7, 0		@ caches
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	@ the table of data addresses
	ldr	r0, =TABLE
	ldr	r1, =DATA_VA
	mov	r2, #12
1:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	1b
	ldr	r10, =SIG_DATA
	.irp	n, 4, 6, 8, 10, 12
	mov	r0, #\n
	bl	measure
	str	r0, [r10], #4
	str	r1, [r10], #4
	.endr
	ldr	r10, =SIG_DATA
	.irp	n, 4, 6, 8, 10, 12
	ldr	r0, [r10], #4
	ldr	r1, [r10], #4
	CHECK	r0, 0				@ D walks, N = \n
	CHECK	r1, 0				@ I walks
	.endr
	NOABT
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ r0 = N. One warm-up pass, then PASSES passes counted; returns r0 = D
@ walks, r1 = I walks during the counted passes.
measure:
	stmfd	sp!, {r4-r11, lr}
	mov	r11, r0				@ N
	ldr	r4, =BENCH
	ldr	r8, =stub			@ the call target in section A
	ldr	r9, =CODEB_VA + (loop_b - loop_b)
	mov	r7, #0				@ line offset, a new line each pass
	mov	r10, #1				@ the warm-up pass
	bl	run_passes
	ldr	r5, [r4, #BENCH_DWALKS]
	ldr	r6, [r4, #BENCH_IWALKS]
	stmfd	sp!, {r5, r6}
	mov	r10, #PASSES
	bl	run_passes
	ldr	r0, [r4, #BENCH_DWALKS]
	ldr	r1, [r4, #BENCH_IWALKS]
	ldmfd	sp!, {r5, r6}
	sub	r0, r0, r5
	sub	r1, r1, r6
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ r10 passes over N = r11 sections, from code section B; r7 advances a
@ line each pass. r4 (BENCH) is kept; no literal loads from section A
@ (TLB index 0, BENCH's) between the counter reads.
run_passes:
	stmfd	sp!, {lr}
	mov	lr, pc
	mov	pc, r9				@ loop_b in section B
	ldmfd	sp!, {pc}

@ The stub in section A: ALU only. The padding keeps the A-resident
@ original of loop_b (its literal load, section A = BENCH's TLB index)
@ off the wrong path after the return: without the predictor, V2 runs
@ on past `mov pc, r6`, and a wrong-path load that misses is walked too.
stub:
	eor	r2, r2, r3
	add	r3, r3, r2, ror #11
	mov	pc, r6
	.rept	12
	mov	r0, r0
	.endr

@ Position-independent; copied to CODEB_PA, run at CODEB_VA.
@ In: r7 line offset, r8 stub, r10 passes, r11 N. Uses r0-r3, r5, r6, ip.
loop_b:
1:	ldr	r5, =TABLE			@ a literal in section B (index 47)
	mov	ip, r11
2:	ldr	r0, [r5], #4			@ the section's address (uncached)
	ldr	r1, [r0, r7]			@ its data: held or filled
	str	r2, [r0, #4]!			@ a store to it: held or written back
	eor	r2, r2, r1
	add	r3, r1, r2, ror #7		@ data-valued "addresses" in A
	orr	r2, r3, r1, lsl #5
	adr	r6, 3f
	mov	pc, r8				@ the stub in section A
3:	subs	ip, ip, #1
	bne	2b
	add	r7, r7, #32
	subs	r10, r10, #1
	bne	1b
	mov	pc, lr				@ to run_passes
	.ltorg
loop_b_end:
