@ SPDX-License-Identifier: GPL-3.0-or-later
@ Small pages with the same TLB index: N pages at the same offset in N
@ megabytes (VA 0x30005000 + i MB for data, 0x31005000 + i MB for code),
@ used in turn. EKA1 puts every chunk on a megabyte boundary, so this is
@ a bitmap and a stack, or two modules' code, at the same offset in their
@ chunks. The ARM925T's TLBs are fully associative and walk each page
@ once. A direct-mapped small-page TLB indexed by VA[19:12] holds one of
@ them and walks at every access (the phone's 2D drawing lost 15 to 40 %
@ of its rate to that, docs/PROGRESS-LOG.md 2026-11-15); with two ways or
@ more, two pages stay.
@
@ After a warm-up pass, 16 passes over N = 2 pages must make no walk on
@ either side. The walks for N = 3 and 4 are recorded only: they are 0
@ with four ways and a walk an access with two (the set keeps the last
@ two pages installed).
@ Results: SIG_DATA + 4*k = D walks for N = 2, 3, 4, then I walks.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	BENCH_DWALKS, 0x50
	.equ	BENCH_IWALKS, 0x58
	.equ	COARSE, L2_AREA			@ eight coarse tables, 1 KB each
	.equ	DATA_VA, 0x30005000
	.equ	CODE_VA, 0x31005000
	.equ	DATA_PA, 0x00400000
	.equ	CODE_PA, 0x00410000
	.equ	PASSES, 16
	.text
	.arm
	.global	test_main

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	ldr	r0, =COARSE
	mov	r1, #0
	ldr	r2, =(8 * 0x400) / 4
1:	str	r1, [r0], #4
	subs	r2, r2, #1
	bne	1b
	@ megabyte i of each kind: a coarse table with one small page, at
	@ table index 5 (AP 11 in every subpage, uncached)
	.irp	i, 0, 1, 2, 3
	ldr	r1, =((COARSE + \i * 0x400) | 0x10 | 1)
	SETL1	(0x30000000 + (\i << 20)), r1
	ldr	r1, =((COARSE + (4 + \i) * 0x400) | 0x10 | 1)
	SETL1	(0x31000000 + (\i << 20)), r1
	ldr	r0, =(COARSE + \i * 0x400)
	ldr	r1, =((DATA_PA + \i * 0x1000) | 0xFF2)
	str	r1, [r0, #5 * 4]
	ldr	r0, =(COARSE + (4 + \i) * 0x400)
	ldr	r1, =((CODE_PA + \i * 0x1000) | 0xFF2)
	str	r1, [r0, #5 * 4]
	@ the stub, copied to the code page (identity-mapped, uncached)
	ldr	r0, =stub
	ldr	r1, =stub_end
	ldr	r2, =(CODE_PA + \i * 0x1000)
2:	ldr	r3, [r0], #4
	str	r3, [r2], #4
	cmp	r0, r1
	blo	2b
	.endr
	TLBFLUSH

	ldr	r9, =SIG_DATA
	.irp	n, 2, 3, 4
	mov	r0, #\n
	adr	r1, d_passes
	mov	r2, #BENCH_DWALKS
	ldr	r3, =DATA_VA
	bl	measure
	str	r0, [r9], #4
	.endr
	.irp	n, 2, 3, 4
	mov	r0, #\n
	adr	r1, i_passes
	mov	r2, #BENCH_IWALKS
	ldr	r3, =CODE_VA
	bl	measure
	str	r0, [r9], #4
	.endr
	ldr	r9, =SIG_DATA
	ldr	r0, [r9, #0]
	CHECK	r0, 0				@ D walks, two pages
	ldr	r0, [r9, #12]
	CHECK	r0, 0				@ I walks, two pages
	NOABT
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ r0 = N, r1 = the pass routine, r2 = the bench's walk counter, r3 = the
@ first page. One warm-up pass, then PASSES passes counted; returns r0 =
@ walks in them. Between the two counter reads there is no data access to
@ the code's own section: it has the bench's index in the section TLB, and
@ the two would walk in turn (as in arm9_tlb_walks_rtl.S).
measure:
	stmfd	sp!, {r4-r11, lr}
	mov	r11, r0
	mov	r8, r1
	mov	r7, r2
	mov	r9, r3
	ldr	r4, =BENCH
	mov	r10, #1
	mov	lr, pc
	mov	pc, r8
	ldr	r5, [r4, r7]
	mov	r10, #PASSES
	mov	lr, pc
	mov	pc, r8
	ldr	r0, [r4, r7]
	sub	r0, r0, r5
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ r10 passes over r11 data pages: a load and a store in each
d_passes:
1:	mov	r6, r9
	mov	ip, r11
2:	ldr	r1, [r6]
	add	r2, r2, r1
	str	r2, [r6, #4]
	add	r6, r6, #0x00100000
	subs	ip, ip, #1
	bne	2b
	subs	r10, r10, #1
	bne	1b
	mov	pc, lr
	.ltorg

@ r10 passes over r11 code pages: a call of the stub in each
i_passes:
	stmfd	sp!, {lr}
1:	mov	r6, r9
	mov	ip, r11
2:	mov	lr, pc
	mov	pc, r6
	add	r6, r6, #0x00100000
	subs	ip, ip, #1
	bne	2b
	subs	r10, r10, #1
	bne	1b
	ldmfd	sp!, {pc}
	.ltorg

@ Position-independent; the padding keeps the fetches that run on past
@ the return inside the page.
stub:
	eor	r2, r2, r3
	add	r3, r3, r2, ror #11
	mov	pc, lr
	.rept	12
	mov	r0, r0
	.endr
stub_end:
