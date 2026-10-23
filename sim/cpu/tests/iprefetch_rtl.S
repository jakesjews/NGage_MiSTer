@ SPDX-License-Identifier: GPL-3.0-or-later
@ Directed test for instruction-cache sequential next-line prefetch (RTL only):
@   1. Sequential code across 32 cache lines: exact result, three-point
@      cycle shape (warm < cold sequential < cold non-sequential), and proof
@      that a line served from the prefetch buffer is installed into the
@      I-cache. 1b: the same with execution-bound lines (cold vs warm).
@   2. Branch away from a prefetched line: the results are exact, the line
@      and the next prefetch's line run correctly afterwards, and an MVA
@      invalidate of the abandoned line makes new code visible.
@   3. Invalidation (c7,c5,0 flush I-cache and c7,c5,1 invalidate I-cache
@      line by MVA) clears the prefetch buffer so modified memory is fetched
@      fresh.
@   4. Sequential code across a 4 KB page end: both into a non-contiguously
@      mapped physical page (proving no cross-page PA+16 prefetch) and up to
@      the end of a page before an unmapped/faulting page.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"

	.equ	SEQ_BASE,	0x00480000	@ 32 sequential lines (512 B)
	.equ	NONSEQ_BASE,	0x00481000	@ 32 backward-stepped lines (512 B)
	.equ	SLOW_BASE,	0x00482000	@ 32 execution-bound lines (512 B)
	.equ	BR_BASE,	0x00484000	@ branch-away test lines
	.equ	BR_TARGET,	0x00485000	@ branch target in another set
	.equ	INV_BASE,	0x00486000	@ invalidation test lines
	.equ	PAGE_TEST_VA,	0x00500000	@ section mapped via coarse L2 table
	.equ	PAGE0_VA,	0x00500000	@ -> PA 0x00500000
	.equ	PAGE1_VA,	0x00501000	@ -> PA 0x00504000 (non-contiguous PA)
	.equ	PAGE1_WRONG_PA,	0x00501000	@ contiguous PA after PAGE0 (trap)
	.equ	PAGE1_TRUE_PA,	0x00504000	@ mapped PA for PAGE1_VA
	.equ	PAGE2_VA,	0x00502000	@ -> PA 0x00502000; PAGE3 unmapped

	.equ	INSN_ADD_R0_1,	0xE2800001	@ add r0, r0, #1
	.equ	INSN_MLA_R3,	0xE0233291	@ mla r3, r1, r2, r3
	.equ	INSN_MOV_R0,	0xE3A00000	@ mov r0, #imm8
	.equ	INSN_MOV_PC_LR,	0xE1A0F00E	@ mov pc, lr
	.equ	INSN_B_PREV,	0xEAFFFFF7	@ b .-36 (from line+12, PC=line+20, to line-16)

	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}

	@ Set up MMU: 16 MB RAM cacheable write-back sections, except
	@ section 0x00500000 which uses a coarse L2 page table at L2_AREA.
	bl	mmu_on
	ldr	r0, =TTB
	ldr	r1, =0x00000C1E		@ section, AP=11, dom=0, C=1, B=1
	mov	r2, #16
1:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	1b

	@ Clear coarse L2 table (256 entries) at L2_AREA
	ldr	r0, =L2_AREA
	mov	r1, #0
	mov	r2, #256
2:	str	r1, [r0], #4
	subs	r2, r2, #1
	bne	2b

	@ Map PAGE0_VA (0x00500000) -> PA 0x00500000 (small page, AP=11, C=1, B=1)
	ldr	r0, =L2_AREA
	ldr	r1, =0x00500FFE
	str	r1, [r0, #(0 * 4)]

	@ Map PAGE1_VA (0x00501000) -> PA 0x00504000 (non-contiguous PA!)
	ldr	r1, =0x00504FFE
	str	r1, [r0, #(1 * 4)]

	@ Map PAGE2_VA (0x00502000) -> PA 0x00502000; PAGE3 (0x00503000) left 0 (fault)
	ldr	r1, =0x00502FFE
	str	r1, [r0, #(2 * 4)]

	@ Install coarse L1 descriptor for 0x00500000 -> L2_AREA (domain 0)
	ldr	r1, =(L2_AREA | 0x11)
	SETL1	PAGE_TEST_VA, r1

	@ Map BENCH MMIO (0xF0000000) uncached
	SECT	r0, 0xF0000000, 3, 0, 0
	SETL1	0xF0000000, r0

	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0

	@ ================================================================
	@ 1. Sequential code across 32 cache lines (512 bytes)
	@    Each 16-byte line has:
	@      +0: mla r3, r1, r2, r3  (gives bus time to prefetch L+1)
	@      +4: add r0, r0, #1
	@      +8: add r0, r0, #1
	@      +12: add r0, r0, #1     (last line +12: mov pc, lr)
	@ ================================================================
	ldr	r4, =SEQ_BASE
	ldr	r5, =INSN_MLA_R3
	ldr	r6, =INSN_ADD_R0_1
	mov	r7, #32
10:	str	r5, [r4, #0]
	str	r6, [r4, #4]
	str	r6, [r4, #8]
	str	r6, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1	@ clean D-cache line
	add	r4, r4, #16
	subs	r7, r7, #1
	bne	10b
	@ Overwrite very last word (SEQ_BASE + 32*16 - 4) with mov pc, lr
	sub	r4, r4, #16
	ldr	r0, =INSN_MOV_PC_LR
	str	r0, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1

	@ Also populate 32 backward-stepped lines at NONSEQ_BASE (lines 31..0)
	ldr	r4, =NONSEQ_BASE
	ldr	r7, =INSN_B_PREV
	mov	r8, #32
11:	str	r5, [r4, #0]
	str	r6, [r4, #4]
	str	r6, [r4, #8]
	str	r7, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1
	add	r4, r4, #16
	subs	r8, r8, #1
	bne	11b
	@ Line 0 at NONSEQ_BASE returns via mov pc, lr
	ldr	r4, =NONSEQ_BASE
	ldr	r0, =INSN_MOV_PC_LR
	str	r0, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1

	@ Flush I-cache and measure cold sequential pass over 32 lines
	ldr	r8, =BENCH
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	@ flush I-cache + prefetch buffer

	mov	r0, #0
	mov	r1, #3
	mov	r2, #5
	mov	r3, #0
	ldr	r9, [r8, #BENCH_CYCLES]
	ldr	r4, =SEQ_BASE
	mov	lr, pc
	mov	pc, r4
	ldr	r10, [r8, #BENCH_CYCLES]
	sub	r9, r10, r9		@ r9 = cold sequential cycles

	@ Exact result check: 31 lines * 3 adds + 2 adds = 95, 32 * 15 = 480
	CHECK	r0, 95
	CHECK	r3, 480

	@ Prove that line 1 (SEQ_BASE + 16, served from the prefetch buffer
	@ during the cold pass while later lines overwrote the 1-line buffer)
	@ was installed into the I-cache: rewrite SEQ_BASE + 16 in memory
	@ behind the I-cache before running the warm pass.
	ldr	r4, =(SEQ_BASE + 16)
	ldr	r0, =(INSN_MOV_R0 | 0xEE)
	ldr	r1, =INSN_MOV_PC_LR
	stmia	r4, {r0, r1}
	mcr	p15, 0, r4, c7, c10, 1	@ clean D-cache line (no I-cache flush)

	@ Warm pass over the same 32 lines (all in I-cache now, including +16)
	mov	r0, #0
	mov	r1, #3
	mov	r2, #5
	mov	r3, #0
	ldr	r10, [r8, #BENCH_CYCLES]
	ldr	r4, =SEQ_BASE
	mov	lr, pc
	mov	pc, r4
	ldr	r11, [r8, #BENCH_CYCLES]
	sub	r10, r11, r10		@ r10 = warm sequential cycles

	CHECK	r0, 95
	CHECK	r3, 480

	@ Cold backward-stepped pass over 32 lines (starting at line 31 -> 0)
	mov	r0, #0
	mov	r1, #3
	mov	r2, #5
	mov	r3, #0
	ldr	r11, [r8, #BENCH_CYCLES]
	ldr	r4, =(NONSEQ_BASE + 31 * 16)
	mov	lr, pc
	mov	pc, r4
	ldr	r7, [r8, #BENCH_CYCLES]
	sub	r11, r7, r11		@ r11 = cold non-sequential cycles

	CHECK	r0, 64			@ 32 lines * 2 adds
	CHECK	r3, 480			@ 32 lines * 15

	@ Loose cycle shape check:
	@   warm_seq (r10) < cold_seq (r9) < cold_nonseq (r11)
	cmp	r10, r9
	movlo	r0, #1
	movhs	r0, #0
	CHECK	r0, 1
	cmp	r9, r11
	movlo	r0, #1
	movhs	r0, #0
	CHECK	r0, 1
	CHECKPOINT

	@ ================================================================
	@ 1b. Execution-bound sequential code: 32 lines of three MLAs and an
	@     ADD, slower than a line fill, so that the fetch FIFO fills and
	@     the bus idles between demand misses (where a prefetch helps).
	@     r9 = cold cycles, r10 = warm cycles (read at slow_measured).
	@ ================================================================
	ldr	r4, =SLOW_BASE
	ldr	r5, =INSN_MLA_R3
	ldr	r6, =INSN_ADD_R0_1
	mov	r7, #32
12:	str	r5, [r4, #0]
	str	r5, [r4, #4]
	str	r5, [r4, #8]
	str	r6, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1
	add	r4, r4, #16
	subs	r7, r7, #1
	bne	12b
	sub	r4, r4, #16
	ldr	r0, =INSN_MOV_PC_LR
	str	r0, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1

	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	mov	r1, #3
	mov	r2, #5
	mov	r3, #0
	ldr	r9, [r8, #BENCH_CYCLES]
	ldr	r4, =SLOW_BASE
	mov	lr, pc
	mov	pc, r4
	ldr	r10, [r8, #BENCH_CYCLES]
	sub	r9, r10, r9		@ r9 = cold cycles
	CHECK	r0, 31
	CHECK	r3, 1440		@ 96 MLAs * 15

	mov	r0, #0
	mov	r3, #0
	ldr	r10, [r8, #BENCH_CYCLES]
	ldr	r4, =SLOW_BASE
	mov	lr, pc
	mov	pc, r4
	ldr	r11, [r8, #BENCH_CYCLES]
	sub	r10, r11, r10		@ r10 = warm cycles
slow_measured:
	CHECK	r0, 31
	CHECK	r3, 1440
	cmp	r10, r9
	movlo	r0, #1
	movhs	r0, #0
	CHECK	r0, 1
	CHECKPOINT

	@ ================================================================
	@ 2. Branch away from a prefetched line:
	@    Line BR_BASE (+0x00) executes mlas (so BR_BASE + 0x10 is
	@    prefetched into the buffer) and then branches to BR_TARGET
	@    (0x00485000), never entering BR_BASE + 0x10.
	@    BR_TARGET prefetches BR_TARGET + 0x10, overwriting the buffer.
	@    Check the results, then that both lines run correctly.
	@ ================================================================
	ldr	r4, =BR_BASE
	ldr	r5, =INSN_MLA_R3
	ldr	r6, =(INSN_MOV_R0 | 0x41)
	@ branch from BR_BASE + 12 (PC = BR_BASE + 20) to BR_TARGET:
	@ offset = (BR_TARGET - (BR_BASE + 20)) >> 2 = (0x1000 - 20) >> 2 = 0x3FB
	ldr	r7, =0xEA0003FB
	str	r5, [r4, #0]
	str	r5, [r4, #4]
	str	r6, [r4, #8]
	str	r7, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1

	@ Put initial code at BR_BASE + 0x10 (will be prefetched, not executed)
	add	r4, r4, #16
	ldr	r0, =(INSN_MOV_R0 | 0x11)
	ldr	r1, =INSN_MOV_PC_LR
	stmia	r4, {r0, r1}
	mcr	p15, 0, r4, c7, c10, 1

	@ Put target code at BR_TARGET (0x00485000) and BR_TARGET + 0x10
	ldr	r4, =BR_TARGET
	str	r5, [r4, #0]
	str	r5, [r4, #4]
	ldr	r0, =0xE2800009		@ add r0, r0, #9
	str	r0, [r4, #8]
	ldr	r1, =INSN_MOV_PC_LR
	str	r1, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1
	add	r4, r4, #16
	stmia	r4, {r0, r1}
	mcr	p15, 0, r4, c7, c10, 1

	@ Flush I-cache and run BR_BASE -> branches to BR_TARGET -> returns
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	mov	r1, #2
	mov	r2, #3
	mov	r3, #0
	ldr	r4, =BR_BASE
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x4A		@ 0x41 + 9
	CHECK	r3, 24			@ 4 mlas * 6

	@ The line branched away from (BR_BASE + 0x10) may be in the cache:
	@ the wrong-path fetches past the branch fill it even with the
	@ prefetch off, so only its contents are architectural. Run it, and
	@ the branch target's next line (prefetched last, in the buffer).
	ldr	r4, =(BR_BASE + 16)
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x11
	mov	r0, #0x30
	ldr	r4, =(BR_TARGET + 16)
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x39		@ 0x30 + 9

	@ Rewrite BR_BASE + 0x10, invalidate its I-cache line by MVA: the new
	@ code must run (from a fresh fill, not a stale line or buffer).
	ldr	r4, =(BR_BASE + 16)
	ldr	r0, =(INSN_MOV_R0 | 0x22)
	ldr	r1, =INSN_MOV_PC_LR
	stmia	r4, {r0, r1}
	mcr	p15, 0, r4, c7, c10, 1
	mcr	p15, 0, r4, c7, c5, 1
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x22
	CHECKPOINT

	@ ================================================================
	@ 3. Invalidation of a prefetched line in the buffer:
	@    INV_BASE (+0x00) runs mlas and returns to cached caller while
	@    INV_BASE + 0x10 sits in the prefetch buffer.
	@    Test both c7,c5,0 (invalidate all) and c7,c5,1 (invalidate MVA).
	@ ================================================================
	ldr	r4, =INV_BASE
	ldr	r5, =INSN_MLA_R3
	ldr	r6, =(INSN_MOV_R0 | 0x50)
	ldr	r7, =INSN_MOV_PC_LR
	str	r5, [r4, #0]
	str	r5, [r4, #4]
	str	r6, [r4, #8]
	str	r7, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1

	add	r4, r4, #16
	ldr	r6, =(INSN_MOV_R0 | 0x51)
	stmia	r4, {r6, r7}
	mcr	p15, 0, r4, c7, c10, 1

	@ 3a. Invalidate all I-cache (c7, c5, 0)
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	mov	r1, #1
	mov	r2, #1
	mov	r3, #0
	ldr	r4, =INV_BASE
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x50		@ INV_BASE+16 (0x51) is now prefetched

	@ Rewrite INV_BASE + 16 to 0x52, clean D, flush I (c7, c5, 0)
	ldr	r4, =(INV_BASE + 16)
	ldr	r6, =(INSN_MOV_R0 | 0x52)
	ldr	r7, =INSN_MOV_PC_LR
	stmia	r4, {r6, r7}
	mcr	p15, 0, r4, c7, c10, 1
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x52

	@ 3b. Invalidate I-cache line by MVA (c7, c5, 1)
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	ldr	r4, =INV_BASE
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x50		@ INV_BASE+16 (0x52) is now prefetched

	@ Rewrite INV_BASE + 16 to 0x53, clean D, invalidate I line by MVA
	ldr	r4, =(INV_BASE + 16)
	ldr	r6, =(INSN_MOV_R0 | 0x53)
	ldr	r7, =INSN_MOV_PC_LR
	stmia	r4, {r6, r7}
	mcr	p15, 0, r4, c7, c10, 1
	mcr	p15, 0, r4, c7, c5, 1	@ invalidate I-cache line by MVA
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 0x53
	CHECKPOINT

	@ ================================================================
	@ 4. Sequential execution across a 4 KB page boundary:
	@    4a. PAGE0_VA (0x00500FC0..0x00500FFF, PA 0x00500FC0) into
	@        PAGE1_VA (0x00501000..0x0050103F, mapped to PA 0x00504000).
	@        At PA 0x00501000 (the unmapped contiguous physical page after
	@        PAGE0) we plant poison code (mov r0, #0xEE; mov pc, lr).
	@        At PA 0x00504000 (the true mapped physical page for PAGE1_VA)
	@        we plant valid code. If prefetch ever crossed the 4 KB page
	@        boundary using PA+16, it would fetch the poison at 0x00501000!
	@ ================================================================
	ldr	r4, =PAGE1_WRONG_PA
	ldr	r0, =(INSN_MOV_R0 | 0xEE)
	ldr	r1, =INSN_MOV_PC_LR
	stmia	r4, {r0, r1}
	mcr	p15, 0, r4, c7, c10, 1

	@ Populate 4 lines at end of PAGE0 (0x00500FC0..0x00500FFF): 16 insns
	ldr	r4, =(PAGE0_VA + 0xFC0)
	ldr	r5, =INSN_MLA_R3
	ldr	r6, =INSN_ADD_R0_1
	mov	r7, #4
40:	str	r5, [r4, #0]
	str	r6, [r4, #4]
	str	r6, [r4, #8]
	str	r6, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1
	add	r4, r4, #16
	subs	r7, r7, #1
	bne	40b

	@ Populate 4 lines at start of PAGE1 (VA 0x00501000 -> PA 0x00504000)
	ldr	r4, =PAGE1_VA
	mov	r7, #4
41:	str	r5, [r4, #0]
	str	r6, [r4, #4]
	str	r6, [r4, #8]
	str	r6, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1
	add	r4, r4, #16
	subs	r7, r7, #1
	bne	41b
	sub	r4, r4, #16
	ldr	r0, =INSN_MOV_PC_LR
	str	r0, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1

	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	mov	r0, #0
	mov	r1, #2
	mov	r2, #4
	mov	r3, #0
	ldr	r4, =(PAGE0_VA + 0xFC0)
	mov	lr, pc
	mov	pc, r4
	@ 8 lines total: 7 * 3 + 2 = 23 adds; 8 * 8 = 64 mla
	CHECK	r0, 23
	CHECK	r3, 64

	@ 4b. Execute up to the very last instruction of PAGE2_VA
	@     (0x00502FF0..0x00502FFC) where PAGE3 (0x00503000) is unmapped.
	@     Must not prefetch across the page end or trigger any abort.
	bl	ab_clear
	ldr	r4, =(PAGE2_VA + 0xFE0)
	ldr	r5, =INSN_MLA_R3
	ldr	r6, =INSN_ADD_R0_1
	ldr	r7, =INSN_MOV_PC_LR
	@ Line 0xFE0
	str	r5, [r4, #0]
	str	r6, [r4, #4]
	str	r6, [r4, #8]
	str	r6, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1
	@ Line 0xFF0 (last line of page before unmapped 0x00503000)
	add	r4, r4, #16
	str	r5, [r4, #0]
	str	r6, [r4, #4]
	str	r6, [r4, #8]
	str	r7, [r4, #12]
	mcr	p15, 0, r4, c7, c10, 1

	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	mov	r0, #0
	mov	r1, #3
	mov	r2, #3
	mov	r3, #0
	ldr	r4, =(PAGE2_VA + 0xFE0)
	mov	lr, pc
	mov	pc, r4
	CHECK	r0, 5
	CHECK	r3, 18
	NOABT
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}

	.ltorg
