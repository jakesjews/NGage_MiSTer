@ SPDX-License-Identifier: GPL-3.0-or-later
@ W's return-target check (V2's REDIRECT_EQ: the predicted target is
@ compared with each load-word source in parallel) and the fetch queue's
@ Thumb halfword (THUMB_HALF). PC writes whose target comes from:
@   * a load hitting the D-cache (W's short word), a cold miss and an
@     uncached load (the deferred return word), LDM with the PC last;
@   * an ALU result (MOV PC), and a Thumb BL suffix (the record address);
@ each run four times with the target the same (the predictor learns
@ it) and alternating between two targets (every other run mispredicted),
@ the ARM targets differing in high bits, the Thumb ones in bit 1 only;
@ each run shifts its marker into a register, so the order is checked.
@ Thumb runs place every instruction at both halfword positions (pc[1] 0
@ and 1) by shifting the code by a halfword. Uncached, then cached cold
@ and warm; the trace is compared with QEMU.
	.include "test.inc"
	.include "mmu.inc"
	.equ	T0, SCRATCH + 0x300	@ the words holding targets
	.equ	UNC, 0x20000000
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	mov	r9, #0
	bl	runs				@ MMU off: uncached
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, SCRATCH, 3, 0, 3
	SETL1	SCRATCH, r1
	SECT	r1, SCRATCH, 3, 0, 0
	SETL1	UNC, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r9, =(UNC - SCRATCH)
	bl	runs				@ cold
	bl	runs				@ warm
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

	@ four ARM runs of a PC write \op (via r1 = T0 slot, or r2), targets
	@ ta/tb from \pat (0 same, 1 alternating); r10 collects markers
	.macro	ARMRUN form, pat
	mov	r10, #0
	mov	r11, #4
.Lloop\@:
	adr	r2, .La\@
	.if \pat
	tst	r11, #1
	adrne	r2, .Lb\@
	.endif
	ldr	r1, =T0
	.if \form == 3
	add	r1, r1, r9			@ the uncached alias once the MMU is on
	.endif
	str	r2, [r1]
	str	r2, [r1, #4]
	.if \form == 4
	mcr	p15, 0, r1, c7, c10, 1		@ clean, then invalidate the line: a cold miss
	mcr	p15, 0, r1, c7, c6, 1
	.endif
	.if \form == 0 || \form == 3 || \form == 4
	ldr	pc, [r1]
	.elseif \form == 1
	ldmia	r1, {r3, pc}
	.else
	mov	pc, r2
	.endif
	b	.Lbad\@
.La\@:
	mov	r10, r10, lsl #2
	orr	r10, r10, #1
	b	.Lnext\@
	nop
.Lb\@:
	mov	r10, r10, lsl #2
	orr	r10, r10, #2
.Lnext\@:
	subs	r11, r11, #1
	bne	.Lloop\@
	.if \pat
	CHECK	r10, 0x66			@ a, b, a, b
	.else
	CHECK	r10, 0x55
	.endif
	b	.Lend\@
.Lbad\@:
	FAIL
	.ltorg
.Lend\@:
	.endm

	@ four Thumb runs: pop {pc} from a stacked target (form 0), a BL
	@ call and its return (form 1), MOV PC (form 2); \half 1 shifts the
	@ code by a halfword
	.macro	THRUN form, pat, half
	adr	r0, .Lth\@ + 1
	bx	r0
	.thumb
	.balign	4
	.if \half
	nop
	.endif
.Lth\@:
	mov	r6, #0
	mov	r7, #4
.Ltl\@:
	adr	r2, .Lta\@
	.if \pat
	lsr	r3, r7, #1
	bcc	1f
	adr	r2, .Ltw\@
	add	r2, #2				@ .Ltb, a halfword address
1:
	.endif
	add	r2, #1
	.if \form == 0
	push	{r2}
	pop	{pc}
	.elseif \form == 1
	bl	.Ltf\@
	b	.Ltn\@
	.else
	mov	pc, r2
	.endif
	b	.Ltbad\@
	.balign	4
.Lta\@:
.Ltw\@:
	b	.Ltab\@			@ .Lta and .Ltb differ only in bit 1
.Ltb\@:
	lsl	r6, r6, #2
	mov	r3, #2
	orr	r6, r3
	b	.Ltn\@
.Ltab\@:
	lsl	r6, r6, #2
	mov	r3, #1
	orr	r6, r3
	b	.Ltn\@
	.balign	4
.Ltf\@:
	lsl	r6, r6, #2
	mov	r3, #3
	orr	r6, r3
	bx	lr
.Ltn\@:
	sub	r7, #1
	bne	.Ltl\@
	mov	r0, r6
	adr	r1, .Lta2\@
	bx	r1
.Ltbad\@:
	mov	r0, #0xFF
	adr	r1, .Lta2\@
	bx	r1
	.balign	4
	.arm
.Lta2\@:
	.if \form == 1
	CHECK	r0, 0xFF
	.elseif \pat
	CHECK	r0, 0x66
	.else
	CHECK	r0, 0x55
	.endif
	b	.Lte\@
	.ltorg
.Lte\@:
	.endm

runs:
	stmfd	sp!, {r4-r11, lr}
	.irp form, 0, 1, 2, 3, 4
	.irp pat, 0, 1
	ARMRUN	\form, \pat
	.endr
	.endr
	.irp form, 0, 1, 2
	.irp pat, 0, 1
	.irp half, 0, 1
	THRUN	\form, \pat, \half
	.endr
	.endr
	.endr
	ldmfd	sp!, {r4-r11, pc}
	.ltorg
