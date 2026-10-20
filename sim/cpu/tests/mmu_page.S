@ SPDX-License-Identifier: GPL-3.0-or-later
@ MMU with second-level tables: a coarse table (4 KB small pages, 64 KB
@ large pages), a fine table (1 KB tiny pages and a 4 KB page), subpage
@ access permissions, page translation/domain/permission faults with the
@ domain in the FSR, FAR, and an instruction fetch through a small page.
	.include "test.inc"
	.include "mmu.inc"
	.equ	COARSE, L2_AREA			@ 1 KB aligned
	.equ	FINE,   L2_AREA + 0x1000	@ 4 KB aligned
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_SWI, swi_svc
	bl	mmu_on
	@ clear the second-level tables
	ldr	r0, =COARSE
	mov	r1, #0
	ldr	r2, =(0x400 + 0x1000) / 4
1:	str	r1, [r0], #4
	subs	r2, r2, #1
	bne	1b
	@ level 1: VA 0x30000000 coarse, VA 0x30100000 fine, both domain 2
	ldr	r1, =(COARSE | (2 << 5) | 0x10 | 1)
	SETL1	0x30000000, r1
	ldr	r1, =(FINE | (2 << 5) | 0x10 | 3)
	SETL1	0x30100000, r1
	ldr	r0, =0x00000011		@ domains 0 and 2: client
	mcr	p15, 0, r0, c3, c0, 0
	@ coarse: small pages at 0x30000000 (PA 0x400000, all RW) and
	@ 0x30001000 (PA 0x401000, subpages RW / user RO / privileged / none)
	ldr	r0, =COARSE
	ldr	r1, =0x00400FF2
	str	r1, [r0, #0]
	ldr	r1, =0x004011B2
	str	r1, [r0, #4]
	@ large page at 0x30010000 (PA 0x500000): 16 identical entries
	ldr	r1, =0x00500FF1
	add	r2, r0, #16 * 4
	mov	r3, #16
2:	str	r1, [r2], #4
	subs	r3, r3, #1
	bne	2b
	@ fine: tiny pages at 0x30100000 (PA 0x402000, RW) and 0x30100400
	@ (PA 0x402400, user RO); a small page at 0x30101000 (PA 0x403000),
	@ four entries
	ldr	r0, =FINE
	ldr	r1, =0x00402033
	str	r1, [r0, #0]
	ldr	r1, =0x00402423
	str	r1, [r0, #4]
	ldr	r1, =0x00403FF2
	str	r1, [r0, #16]
	str	r1, [r0, #20]
	str	r1, [r0, #24]
	str	r1, [r0, #28]
	TLBFLUSH
	CHECKPOINT

	@ translations, written through the page and read at the PA
	ldr	r4, =0x30000000
	ldr	r0, =0x11110000
	str	r0, [r4, #0x44]
	CHECKM	0x00400044, 0x11110000
	ldr	r4, =0x30001000
	ldr	r0, =0x22220000
	str	r0, [r4, #0x48]		@ subpage 0: RW
	CHECKM	0x00401048, 0x22220000
	ldr	r4, =0x30018000		@ large page, offset 0x8000
	ldr	r0, =0x33330000
	str	r0, [r4, #0x4C]
	CHECKM	0x0050804C, 0x33330000
	ldr	r4, =0x30100000
	ldr	r0, =0x44440000
	str	r0, [r4, #0x50]
	CHECKM	0x00402050, 0x44440000
	ldr	r4, =0x30101000		@ small page in the fine table
	ldr	r0, =0x55550000
	str	r0, [r4, #0x3FC]
	CHECKM	0x004033FC, 0x55550000
	ldr	r4, =0x30101C00		@ its last 1 KB (fine entry 7)
	ldr	r0, =0x66660000
	str	r0, [r4]
	CHECKM	0x00403C00, 0x66660000
	NOABT
	CHECKPOINT

	@ subpage permissions of 0x30001000
	ldr	r4, =0x30001000
	add	r5, r4, #0x400		@ subpage 1: user read-only
	ldrt	r0, [r5]
	NOABT
	strt	r0, [r5]
	DABT	0x2F, 0x30001400
	str	r0, [r5]
	NOABT
	add	r5, r4, #0x800		@ subpage 2: privileged only
	ldrt	r0, [r5]
	DABT	0x2F, 0x30001800
	ldr	r0, [r5]
	NOABT
	add	r5, r4, #0xC00		@ subpage 3: no access
	ldr	r0, [r5]
	DABT	0x2F, 0x30001C00
	@ tiny page, user read-only
	ldr	r5, =0x30100400
	ldrt	r0, [r5]
	NOABT
	add	r5, r5, #4
	strt	r0, [r5]
	DABT	0x2F, 0x30100404
	CHECKPOINT

	@ page translation faults (coarse entry 2, fine entry 8)
	ldr	r5, =0x30002010
	ldr	r0, [r5]
	DABT	0x27, 0x30002010
	ldr	r5, =0x30102000
	str	r0, [r5]
	DABT	0x27, 0x30102000
	@ page domain fault: domain 2 no access
	mov	r0, #0x01
	mcr	p15, 0, r0, c3, c0, 0
	ldr	r5, =0x30000000
	ldr	r0, [r5]
	DABT	0x2B, 0x30000000
	@ manager: subpage 3 is reachable
	mov	r0, #0x31
	mcr	p15, 0, r0, c3, c0, 0
	ldr	r5, =0x30001C00
	ldr	r0, [r5]
	NOABT
	mov	r0, #0x11
	mcr	p15, 0, r0, c3, c0, 0
	CHECKPOINT

	@ code through a small page: copy a routine to PA 0x400800 and call it
	@ at VA 0x30000800
	ldr	r0, =page_code
	ldr	r1, =0x00400800
	ldmia	r0, {r2, r3}
	stmia	r1, {r2, r3}
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	@ (no I-cache here, but as software does)
	mov	r0, #5
	ldr	r1, =0x30000800
	mov	lr, pc
	mov	pc, r1
	CHECK	r0, 47
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}

page_code:
	add	r0, r0, #42
	mov	pc, lr

swi_svc:
	mrs	r12, spsr
	bic	r12, r12, #0x1F
	orr	r12, r12, #(M_SVC | PSR_I | PSR_F)
	msr	spsr_cxsf, r12
	movs	pc, lr
	.ltorg
