@ SPDX-License-Identifier: GPL-3.0-or-later
@ ARM925T behaviour that QEMU's ti925t does not model, checked on the RTL
@ only: control register read-as-0/1 bits, c13 PID masking, ARMv4
@ unaligned accesses with A clear (rotated LDR/SWP, aligned STR, LDM
@ ignoring the base's low bits), high vectors with the MMU off (64 KB of
@ RAM at 0xFFFF0000 on the bench), the Thumb BLX suffix, wait for
@ interrupt (c7,c0,4 and c15,c8,2) with a bench interrupt.
@@ qemu: no
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}

	@ control register: 31:14, 11:10 and 7 read 0, 6:4 read 1, W writable
	ldr	r1, =0xFFFFCC80
	mcr	p15, 0, r1, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	CHECK	r0, 0x70
	mov	r1, #0
	mcr	p15, 0, r1, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	CHECK	r0, 0x70
	mov	r1, #CR_W
	mcr	p15, 0, r1, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	CHECK	r0, 0x78
	mov	r1, #0x70
	mcr	p15, 0, r1, c1, c0, 0
	@ c13: only bits 31:25 (PID 0 here, so nothing moves)
	ldr	r1, =0x01FFFFFF
	mcr	p15, 0, r1, c13, c0, 0
	mrc	p15, 0, r0, c13, c0, 0
	CHECK	r0, 0
	@ c10 TLB lockdown: stored (base, victim, P)
	ldr	r1, =0xFFFFFFFF
	mcr	p15, 0, r1, c10, c0, 0
	mrc	p15, 0, r0, c10, c0, 0
	CHECK	r0, 0xFFF00001
	mov	r1, #0
	mcr	p15, 0, r1, c10, c0, 0
	mrc	p15, 0, r0, c10, c0, 1
	CHECK	r0, 0
	CHECKPOINT

	@ unaligned accesses with A clear (ARMv4)
	ldr	r4, =SCRATCH
	ldr	r1, =0x44332211
	str	r1, [r4]
	ldr	r2, =0x88776655
	str	r2, [r4, #4]
	ldr	r0, [r4, #1]		@ word at +0 rotated right by 8
	CHECK	r0, 0x11443322
	ldr	r0, [r4, #2]
	CHECK	r0, 0x22114433
	ldr	r0, [r4, #3]
	CHECK	r0, 0x33221144
	ldrh	r0, [r4, #1]		@ bit 0 ignored (UNPREDICTABLE on ARMv4)
	CHECK	r0, 0x2211
	add	r5, r4, #2
	ldmia	r5, {r6, r7}		@ base bits 1:0 ignored, no rotation
	CHECK	r6, 0x44332211
	CHECK	r7, 0x88776655
	mov	r0, #0xAB
	str	r0, [r4, #5]		@ stores the whole word at +4
	ldr	r0, [r4, #4]
	CHECK	r0, 0xAB
	add	r5, r4, #1
	ldr	r0, =0x99999999
	swp	r3, r0, [r5]		@ loads rotated, stores the word at +0
	CHECK	r3, 0x11443322
	ldr	r0, [r4]
	CHECK	r0, 0x99999999
	CHECKPOINT

	@ high vectors, MMU off: SWI goes to 0xFFFF0008
	ldr	r4, =0xFFFF0000
	ldr	r0, =0xE59FF018		@ ldr pc, [pc, #24]
	str	r0, [r4, #8]
	ldr	r0, =hv_swi
	str	r0, [r4, #0x28]
	mrc	p15, 0, r1, c1, c0, 0
	orr	r1, r1, #CR_V
	mcr	p15, 0, r1, c1, c0, 0
	mov	r0, #0
	swi	0x5
	CHECK	r0, 0x77
	bic	r1, r1, #CR_V
	mcr	p15, 0, r1, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	CHECK	r0, 0x70
	CHECKPOINT

	@ Thumb: BL prefix then the BLX suffix (ARMv5): undefined at the suffix
	VECTOR	VEC_UND, und_handler
	mov	r9, #0
	ldr	r0, =t_code + 1
	bx	r0
	.thumb
	.align	2
t_code:
	.short	0xF000			@ prefix, offset 0: LR = PC + 4
t_sfx:	.short	0xE800			@ BLX suffix
	ldr	r0, =a_back
	bx	r0
	.ltorg
	.arm
	.align	2
a_back:
	CHECK	r9, 1
	ldr	r0, =t_sfx + 2		@ LR_und = next Thumb instruction
	CHECKR	r10, r0
	CHECKPOINT

	@ wait for interrupt: the bench raises IRQ (masked here) after 3000
	@ cycles; the core waits until then
	ldr	r4, =BENCH
	ldr	r5, [r4, #BENCH_CYCLES]
	ldr	r0, =3000
	str	r0, [r4, #BENCH_IRQ_IN]
	mov	r0, #0
	mcr	p15, 0, r0, c7, c0, 4
	ldr	r6, [r4, #BENCH_CYCLES]
	sub	r6, r6, r5
	ldr	r7, =3000
	cmp	r6, r7
	movlo	r0, #0
	movhs	r0, #1
	CHECK	r0, 1
	mov	r0, #0
	str	r0, [r4, #BENCH_INT]	@ IRQ line low
	@ the legacy form, c15,c8,2, and again with FIQ
	ldr	r5, [r4, #BENCH_CYCLES]
	ldr	r0, =2000
	str	r0, [r4, #BENCH_FIQ_IN]
	mov	r0, #0
	mcr	p15, 0, r0, c15, c8, 2
	ldr	r6, [r4, #BENCH_CYCLES]
	sub	r6, r6, r5
	ldr	r7, =2000
	cmp	r6, r7
	movlo	r0, #0
	movhs	r0, #1
	CHECK	r0, 1
	mov	r0, #0
	str	r0, [r4, #BENCH_INT]
	@ with the line already high, no wait at all
	mov	r0, #1
	str	r0, [r4, #BENCH_INT]
	ldr	r5, [r4, #BENCH_CYCLES]
	mcr	p15, 0, r0, c7, c0, 4
	ldr	r6, [r4, #BENCH_CYCLES]
	sub	r6, r6, r5
	cmp	r6, #200
	movlo	r0, #1
	movhs	r0, #0
	CHECK	r0, 1
	mov	r0, #0
	str	r0, [r4, #BENCH_INT]

	ldmfd	sp!, {r4-r11, pc}

hv_swi:
	mov	r0, #0x77
	movs	pc, lr

und_handler:
	add	r9, r9, #1
	mov	r10, lr
	movs	pc, lr

	.ltorg
