@ SPDX-License-Identifier: GPL-3.0-or-later
@ A functional copy of EUser Mem::Copy (0x503A1D38 in the v4.60 ROM), the
@ routine medint.pdd moves LFFS sectors out of the flash window with: see
@ arm9_unc_copy_rtl.S (the CPU bench) and sim/harness/flashcopy.S (the
@ whole core). Defines mcopy, mcopy_down and mcopy_sdown.

@ Mem::Copy (EUser 0x503A1D38), r0 = dst, r1 = src, r2 = n. Ascending
@ when src >= dst; the descending half is also entered directly as
@ mcopy_down (the src < dst case). Returns as the ROM does (bx lr).
	@ ascending 32-byte block for a source sh/8 mod 4: fp carries the
	@ previous aligned word
	.macro	UPBLK sh
	mov	r3, fp, lsr #\sh
	ldmia	r1!, {r4, r5, r6, r7, r8, r9, sl, fp}
	orr	r3, r3, r4, lsl #(32 - \sh)
	mov	r4, r4, lsr #\sh
	orr	r4, r4, r5, lsl #(32 - \sh)
	mov	r5, r5, lsr #\sh
	orr	r5, r5, r6, lsl #(32 - \sh)
	mov	r6, r6, lsr #\sh
	orr	r6, r6, r7, lsl #(32 - \sh)
	mov	r7, r7, lsr #\sh
	orr	r7, r7, r8, lsl #(32 - \sh)
	mov	r8, r8, lsr #\sh
	orr	r8, r8, r9, lsl #(32 - \sh)
	mov	r9, r9, lsr #\sh
	orr	r9, r9, sl, lsl #(32 - \sh)
	mov	sl, sl, lsr #\sh
	orr	sl, sl, fp, lsl #(32 - \sh)
	stmia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endm

	.macro	UPMIS sh
	movs	lr, r2, lsr #5
	beq	2f
1:	UPBLK	\sh
	subs	lr, lr, #1
	bne	1b
2:	mov	r2, r2, lsl #26
	msr	CPSR_f, r2
	moveq	r3, fp, lsr #\sh
	ldmeqia	r1!, {r4, r5, r6, fp}
	orreq	r3, r3, r4, lsl #(32 - \sh)
	moveq	r4, r4, lsr #\sh
	orreq	r4, r4, r5, lsl #(32 - \sh)
	moveq	r5, r5, lsr #\sh
	orreq	r5, r5, r6, lsl #(32 - \sh)
	moveq	r6, r6, lsr #\sh
	orreq	r6, r6, fp, lsl #(32 - \sh)
	stmeqia	r0!, {r3, r4, r5, r6}
	movcs	r3, fp, lsr #\sh
	ldmcsia	r1!, {r4, fp}
	orrcs	r3, r3, r4, lsl #(32 - \sh)
	movcs	r4, r4, lsr #\sh
	orrcs	r4, r4, fp, lsl #(32 - \sh)
	stmcsia	r0!, {r3, r4}
	movvs	r3, fp, lsr #\sh
	ldmvsia	r1!, {fp}
	orrvs	r3, r3, fp, lsl #(32 - \sh)
	stmvsia	r0!, {r3}
	b	.Lup_bytes
	.endm

	@ descending 32-byte block: r3 carries the previous (higher) word
	.macro	DNBLK sh
	mov	fp, r3, lsl #(32 - \sh)
	ldmdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	orr	fp, fp, sl, lsr #\sh
	mov	sl, sl, lsl #(32 - \sh)
	orr	sl, sl, r9, lsr #\sh
	mov	r9, r9, lsl #(32 - \sh)
	orr	r9, r9, r8, lsr #\sh
	mov	r8, r8, lsl #(32 - \sh)
	orr	r8, r8, r7, lsr #\sh
	mov	r7, r7, lsl #(32 - \sh)
	orr	r7, r7, r6, lsr #\sh
	mov	r6, r6, lsl #(32 - \sh)
	orr	r6, r6, r5, lsr #\sh
	mov	r5, r5, lsl #(32 - \sh)
	orr	r5, r5, r4, lsr #\sh
	mov	r4, r4, lsl #(32 - \sh)
	orr	r4, r4, r3, lsr #\sh
	stmdb	r0!, {r4, r5, r6, r7, r8, r9, sl, fp}
	.endm

	.macro	DNMIS sh
	movs	lr, r2, lsr #5
	beq	2f
1:	DNBLK	\sh
	subs	lr, lr, #1
	bne	1b
2:	mov	r2, r2, lsl #26
	msr	CPSR_f, r2
	moveq	r7, r3, lsl #(32 - \sh)
	ldmeqdb	r1!, {r3, r4, r5, r6}
	orreq	r7, r7, r6, lsr #\sh
	moveq	r6, r6, lsl #(32 - \sh)
	orreq	r6, r6, r5, lsr #\sh
	moveq	r5, r5, lsl #(32 - \sh)
	orreq	r5, r5, r4, lsr #\sh
	moveq	r4, r4, lsl #(32 - \sh)
	orreq	r4, r4, r3, lsr #\sh
	stmeqdb	r0!, {r4, r5, r6, r7}
	movcs	r5, r3, lsl #(32 - \sh)
	ldmcsdb	r1!, {r3, r4}
	orrcs	r5, r5, r4, lsr #\sh
	movcs	r4, r4, lsl #(32 - \sh)
	orrcs	r4, r4, r3, lsr #\sh
	stmcsdb	r0!, {r4, r5}
	movvs	r4, r3, lsl #(32 - \sh)
	ldmvsdb	r1!, {r3}
	orrvs	r4, r4, r3, lsr #\sh
	stmvsdb	r0!, {r4}
	b	.Ldn_bytes
	.endm

mcopy:
	cmp	r2, #0
	cmpne	r0, r1
	addeq	r0, r0, r2
	bxeq	lr
	cmp	r2, #15
	bhi	1f
	cmp	r1, r0
	bhi	.Lsm_up
	b	mcopy_sdown
1:	cmp	r1, r0
	bcc	mcopy_down
	stmfd	sp!, {r4-r11, lr}
	movs	r3, r0, lsl #30		@ dest alignment -> head bytes
	rsbne	r3, r3, #0
	msr	CPSR_f, r3
	ldrmib	lr, [r1], #1
	strmib	lr, [r0], #1
	ldrmib	lr, [r1], #1
	strmib	lr, [r0], #1
	ldreqb	lr, [r1], #1
	streqb	lr, [r0], #1
	sub	r2, r2, r3, lsr #30
	ands	ip, r1, #3
	beq	.Lup_al
	bic	r1, r1, #3
	ldr	fp, [r1], #4
	cmp	ip, #2
	beq	.Lup2
	bhi	.Lup3
	UPMIS	8
.Lup2:	UPMIS	16
.Lup3:	UPMIS	24
.Lup_bytes:
	sub	r1, r1, #4
	mov	r2, r2, lsl #2
	msr	CPSR_f, r2
	add	r1, r1, ip
	ldrcsb	lr, [r1], #1
	strcsb	lr, [r0], #1
	ldrcsb	lr, [r1], #1
	strcsb	lr, [r0], #1
	ldrvsb	lr, [r1], #1
	strvsb	lr, [r0], #1
	ldmfd	sp!, {r4-r11, lr}
	bx	lr
.Lup_al:
	movs	ip, r2, lsr #8
	beq	2f
1:	.rept	8
	ldmia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	subs	ip, ip, #1
	bne	1b
	ands	r2, r2, #255
	beq	3f
2:	movs	r2, r2, lsl #24
	msr	CPSR_f, r2
	.rept	4
	ldmmiia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmmiia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	.rept	2
	ldmeqia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmeqia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	ldmcsia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmcsia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	ldmvsia	r1!, {r3, r4, r5, r6}
	stmvsia	r0!, {r3, r4, r5, r6}
	movs	r2, r2, lsl #4
	beq	3f
	msr	CPSR_f, r2
	ldmmiia	r1!, {r3, r4}
	stmmiia	r0!, {r3, r4}
	ldmeqia	r1!, {r3}
	stmeqia	r0!, {r3}
	ldrcsb	r3, [r1], #1
	strcsb	r3, [r0], #1
	ldrcsb	r3, [r1], #1
	strcsb	r3, [r0], #1
	ldrvsb	r3, [r1], #1
	strvsb	r3, [r0], #1
3:	ldmfd	sp!, {r4-r11, lr}
	bx	lr
.Lsm_up:				@ n <= 15, src > dst: the last n pairs
	adr	ip, 1f
	sub	pc, ip, r2, lsl #3
	.rept	15
	ldrb	ip, [r1], #1
	strb	ip, [r0], #1
	.endr
1:	bx	lr

mcopy_sdown:				@ n <= 15, src <= dst
	add	r0, r0, r2
	add	r1, r1, r2
	mov	r3, r0
	adr	ip, 1f
	sub	pc, ip, r2, lsl #3
	.rept	15
	ldrb	ip, [r1, #-1]!
	strb	ip, [r3, #-1]!
	.endr
1:	bx	lr

mcopy_down:
	add	r0, r0, r2
	add	r1, r1, r2
	stmfd	sp!, {r0, r4-r11, lr}
	mov	r3, r0, lsl #30		@ dest end alignment -> head bytes
	msr	CPSR_f, r3
	ldrmib	lr, [r1, #-1]!
	strmib	lr, [r0, #-1]!
	ldrmib	lr, [r1, #-1]!
	strmib	lr, [r0, #-1]!
	ldreqb	lr, [r1, #-1]!
	streqb	lr, [r0, #-1]!
	sub	r2, r2, r3, lsr #30
	ands	ip, r1, #3
	beq	.Ldn_al
	bic	r1, r1, #3
	ldr	r3, [r1]
	cmp	ip, #2
	beq	.Ldn2
	bhi	.Ldn3
	DNMIS	8
.Ldn2:	DNMIS	16
.Ldn3:	DNMIS	24
.Ldn_bytes:
	mov	r2, r2, lsl #2
	msr	CPSR_f, r2
	add	r1, r1, ip
	ldrcsb	lr, [r1, #-1]!
	strcsb	lr, [r0, #-1]!
	ldrcsb	lr, [r1, #-1]!
	strcsb	lr, [r0, #-1]!
	ldrvsb	lr, [r1, #-1]!
	strvsb	lr, [r0, #-1]!
	ldmfd	sp!, {r0, r4-r11, lr}
	bx	lr
.Ldn_al:
	movs	ip, r2, lsr #8
	beq	2f
1:	.rept	8
	ldmdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmdb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	subs	ip, ip, #1
	bne	1b
	ands	r2, r2, #255
	beq	3f
2:	movs	r2, r2, lsl #24
	msr	CPSR_f, r2
	.rept	4
	ldmmidb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmmidb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	.rept	2
	ldmeqdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmeqdb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	ldmcsdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmcsdb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	ldmvsdb	r1!, {r3, r4, r5, r6}
	stmvsdb	r0!, {r3, r4, r5, r6}
	movs	r2, r2, lsl #4
	beq	3f
	msr	CPSR_f, r2
	ldmmidb	r1!, {r3, r4}
	stmmidb	r0!, {r3, r4}
	ldreq	r3, [r1, #-4]!
	streq	r3, [r0, #-4]!
	ldrcsb	r3, [r1, #-1]!
	strcsb	r3, [r0, #-1]!
	ldrcsb	r3, [r1, #-1]!
	strcsb	r3, [r0, #-1]!
	ldrvsb	r3, [r1, #-1]!
	strvsb	r3, [r0, #-1]!
3:	ldmfd	sp!, {r0, r4-r11, lr}
	bx	lr

