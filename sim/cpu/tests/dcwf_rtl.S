@ SPDX-License-Identifier: GPL-3.0-or-later
@ Preserve the existing cacheable-fill error contract: consume bus data
@ on ERR, including errors after the requested word, with no data abort.
@ The bench supplies DEADBEEF on ERR. QEMU cannot model this contract or
@ ARM925T unaligned word rotation, so these cases are RTL-only.
@@ qemu: no
@@ bench: --read-error 0x00420000 --read-error 0x00420024 --read-error 0x00420048 --read-error 0x0042006C
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main

	.macro ERROR line, word
	ldr	r4, =0x00420000 + (32*\line)
	@ Requested word errors: it must still write and unlock exactly once.
	ldr	r0, [r4, #(4*\word)]
	CHECK	r0, 0xDEADBEEF
	@ Rotate the starting word to put the error at each remaining beat.
	.irp step, 1, 2, 3
	mcr	p15, 0, r4, c7, c6, 1
	ldr	r0, [r4, #(4*((\word+\step)%4))]
	add	r0, r0, #1
	.rept 32
	mov	r1, r1
	.endr
	CHECK	r0, 1
	ldr	r0, [r4, #(4*\word)]
	CHECK	r0, 0xDEADBEEF
	NOABT
	.endr
	CHECKPOINT
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	ldr	r4, =0x00420100
	ldr	r0, =0x98765432
	str	r0, [r4, #0]
	str	r0, [r4, #4]
	str	r0, [r4, #8]
	str	r0, [r4, #12]
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ERROR	0, 0
	ERROR	1, 1
	ERROR	2, 2
	ERROR	3, 3
	ldr	r4, =0x00420100
	.irp word, 0, 1, 2, 3
	mcr	p15, 0, r4, c7, c6, 1
	ldr	r0, [r4, #(4*\word+1)]
	CHECK	r0, 0x32987654
	mcr	p15, 0, r4, c7, c6, 1
	ldr	r0, [r4, #(4*\word+2)]
	CHECK	r0, 0x54329876
	mcr	p15, 0, r4, c7, c6, 1
	ldr	r0, [r4, #(4*\word+3)]
	CHECK	r0, 0x76543298
	.endr
	@ An uncached external abort still reports the original FSR and FAR.
	SECT	r1, NOWHERE, 3, 0, 0
	SETL1	NOWHERE, r1
	TLBFLUSH
	ldr	r4, =NOWHERE
	ldr	r0, [r4]
	DABT	8, NOWHERE
	CHECKPOINT
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg
