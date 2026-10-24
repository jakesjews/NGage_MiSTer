@ SPDX-License-Identifier: GPL-3.0-or-later
@ The first loads after an exception entry or return (V2 flushes on both),
@ in the shapes of the EKA1 executive-call path: a store miss allocates
@ over the line holding lit1 (or the TLB was flushed), then the flush,
@ then a window whose first load reads lit1:
@
@ flush (fk): 0 SWI from SVC, 1 SWI from USR, 2 IRQ from SVC, 3 IRQ from
@ USR (right after the mode-change MSR), 4 movs pc,lr SVC->SVC, 5 movs
@ pc,lr SVC->USR, 6 ldmfd sp!,{r0,pc}^ SVC->SVC, 7 subs pc,lr,#4 SVC->SVC
@ window (wk): 0 ldr ip,lit1; ldr ip,lit2; ldr r0,[ip,#4]
@	1 the same with mov r0,#0; str r0,[ip] between (the kernel's shape)
@	2 ldr r1,lit1 (table base); ldr pc,[r1,r2,lsl #2]
@	3 ldr r1,lit1 (wrong table); ldr r1,lit2 (right); ldr pc,[r1,r2,lsl #2]
@	4 ldr r3,lit1 (target); mov r0,#0; bx r3
@	5 ldr r3,lit1 (wrong); ldr r3,lit2 (right); bx r3
@	6 ldr lr,lit1 (wrong); ldr lr,lit2 (right); mov pc,lr (the new bank)
@	7 ldr sp,lit1 (wrong); ldr sp,lit2 (right); mov r0,sp (the new bank)
@	8 the kernel's return: mov sp,lit1's line; pop {r0,lr} (lr = USR
@	  PSR); msr spsr_fc,lr; mov lr,pc; movs pc,lr; bx lr (lr_usr)
@	9 the kernel's SWI entry: ldr ip,[lr,#-4]; tst; bic; add ip,r9,ip,lsl
@	  #2; ldr ip,[ip] (lit1: the function); str ip,[r7]; ldr ip,lit2;
@	  ldr r0,[ip]; mov lr,pc; ldr pc,[r7] (SWI entries only)
@ victim (vk): 0 lit1's line departing beside a dirty line, 1 beside a
@ clean line, 2 as 0 with both TLBs flushed first, 3 lit1 not cached,
@ both ways dirty, both TLBs flushed, no store miss
@ delay (dk): 0 or 2 instructions between the store miss and the flush
@ Each case runs twice (cold and warm I-cache) in three configurations:
@ sections at the bench's latency, small pages at 24, sections at 12.
@ The test fails at the end with the first failing case: case number << 8
@ | 1. RES_TABLE holds 16 bytes a case: cold and warm error, r0, expected.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	COARSE, L2_AREA
	.equ	UNC, 0x20000000
	.equ	A2, 0x00410ED0		@ lit2's value in windows 0 and 1
	.equ	V2, 0x00000A24		@ the word at A2 + 4
	.equ	A1, 0x00410E90		@ lit1's value in windows 0 and 1
	.equ	V1, 0x00000A14
	.equ	SCR7, 0x00410F50	@ window 9's function slot (cached)
	.equ	XBASE1, 0x00420000
	.equ	XBASE2, 0x00440000
	.equ	SP_SVC_V, 0x006FFFDC	@ test_main's SVC sp in the cases
	.equ	SAVED, 0x00F07000	@ uncached: saved SVC sp
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	.macro	CASE fk, wk, vk, dk
	.if (\wk == 9) && (\fk > 1)
	.exitm
	.endif
	.if (\wk == 8) && (\fk == 5)
	.exitm
	.endif
	mov	r8, #2
.Lagain\@:
	@ lr_usr = the success target (window 8 returns through it)
	msr	cpsr_c, #0xDF
	adr	lr, .Lok\@
	msr	cpsr_c, #0xD3
	.if \fk <= 1
	adr	r0, .Lw\@
	mov	r1, #VEC_SWI
	str	r0, [r1]
	.elseif \fk <= 3
	adr	r0, .Lw\@
	mov	r1, #VEC_IRQ
	str	r0, [r1]
	.endif
	adr	r9, .Llit1\@
	.if \vk == 3
	mov	r1, #1
	.elseif \vk == 1
	mov	r1, #4
	.else
	mov	r1, #3
	.endif
	bl	prepare
	ldr	r7, =SCR7
	mov	r2, #1
	.if \fk >= 4
	.if \fk == 5
	mov	r0, #0x10
	.else
	mov	r0, #0xD3
	.endif
	msr	spsr_cxsf, r0
	.endif
	.if \fk == 6
	sub	sp, sp, #8
	adr	r0, .Lw\@
	str	r0, [sp, #4]
	str	r2, [sp]
	.endif
	.if (\fk == 4) || (\fk == 5)
	adr	lr, .Lw\@
	.elseif \fk == 7
	adr	lr, .Lw\@
	add	lr, lr, #4
	.endif
	.if \fk == 2 || \fk == 3
	ldr	r0, =BENCH
	mov	r1, #1
	str	r1, [r0, #BENCH_INT]	@ IRQ line high, masked
	.endif
	.if \vk >= 2
	mcr	p15, 0, r3, c8, c7, 0
	.endif
	.if \fk == 1
	msr	cpsr_c, #0x10
	.endif
	.if \vk <= 2
	str	r3, [r4]		@ store miss over lit1's line
	.endif
	.rept	\dk
	mov	r6, r6
	.endr
	@ the flush
	.if \fk <= 1
	svc	#0
	.elseif \fk == 2
	msr	cpsr_c, #0x53
	nop
	.elseif \fk == 3
	msr	cpsr_c, #0x10
	nop
	.elseif \fk <= 5
	movs	pc, lr
	.elseif \fk == 6
	ldmfd	sp!, {r0, pc}^
	.else
	subs	pc, lr, #4
	.endif
	b	.Lbad\@
.Lw\@:
	.if \wk == 0
	ldr	ip, .Llit1\@
	ldr	ip, .Llit2\@
	ldr	r0, [ip, #4]
	.elseif \wk == 1
	ldr	ip, .Llit1\@
	mov	r0, #0
	str	r0, [ip]
	ldr	ip, .Llit2\@
	ldr	r0, [ip, #4]
	.elseif \wk == 2
	ldr	r1, .Llit1\@
	ldr	pc, [r1, r2, lsl #2]
	.elseif \wk == 3
	ldr	r1, .Llit1\@
	ldr	r1, .Llit2\@
	ldr	pc, [r1, r2, lsl #2]
	.elseif \wk == 4
	ldr	r3, .Llit1\@
	mov	r0, #0
	bx	r3
	.elseif \wk == 5
	ldr	r3, .Llit1\@
	ldr	r3, .Llit2\@
	bx	r3
	.elseif \wk == 6
	ldr	lr, .Llit1\@
	ldr	lr, .Llit2\@
	mov	pc, lr
	.elseif \wk == 7
	ldr	sp, .Llit1\@
	ldr	sp, .Llit2\@
	mov	r0, sp
	.elseif \wk == 8
	mov	sp, r9
	pop	{r0, lr}
	msr	spsr_fc, lr
	mov	lr, pc
	movs	pc, lr
	bx	lr
	.else
	ldr	ip, [lr, #-4]
	tst	ip, #0x800000
	bic	ip, ip, #0x3FC00000
	add	ip, r9, ip, lsl #2
	ldr	ip, [ip]
	str	ip, [r7]
	ldr	ip, .Llit2\@
	ldr	r0, [ip]
	mov	lr, pc
	ldr	pc, [r7]
	.endif
	b	.Lafter\@
.Lok\@:
	mov	r0, #1
	b	.Lafter\@
.Lbad\@:
	mov	r0, #0xBA0
.Lafter\@:
	@ back to SVC, I/F masked, with the SVC sp and the IRQ line restored
	mrs	r1, cpsr
	and	r1, r1, #0x1F
	cmp	r1, #0x10
	ldreq	r1, =to_svc
	moveq	r6, #VEC_SWI
	streq	r1, [r6]
	svceq	#0
	msr	cpsr_c, #0xD3
	ldr	r1, =SAVED
	ldr	sp, [r1]
	ldr	r1, =BENCH
	mov	r6, #0
	str	r6, [r1, #BENCH_INT]
	.if \wk <= 1
	ldr	r2, =V2
	.elseif \wk == 7
	.if \fk == 5
	ldr	r2, =STACK_USR
	.elseif \fk == 2 || \fk == 3
	ldr	r2, =STACK_IRQ
	.else
	ldr	r2, =SP_SVC_V
	.endif
	.else
	mov	r2, #1
	.endif
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.ltorg
	.balign	256
.Llit1\@:
	.if \wk <= 1
	.word	A1, 0, 0, 0
	.elseif \wk == 2
	.word	.Ltab\@, 0, 0, 0
	.elseif \wk == 3
	.word	.Llit2\@, 0, 0, 0
	.elseif \wk == 4
	.word	.Lok\@, 0, 0, 0
	.elseif \wk == 5 || \wk == 6
	.word	.Lbad\@, 0, 0, 0
	.elseif \wk == 7
	.word	0x00F07100, 0, 0, 0
	.elseif \wk == 8
	.word	0x12345678, 0xD0, 0, 0
	.else
	.word	.Lok\@, 0, 0, 0
	.endif
.Llit2\@:
	.if \wk <= 1
	.word	A2
	.elseif \wk == 3
	.word	.Ltab\@
	.elseif \wk == 4
	.word	.Lbad\@
	.elseif \wk == 5 || \wk == 6
	.word	.Lok\@
	.elseif \wk == 7
	.if \fk == 5
	.word	STACK_USR
	.elseif \fk == 2 || \fk == 3
	.word	STACK_IRQ
	.else
	.word	SP_SVC_V
	.endif
	.else
	.word	SCR7
	.endif
.Ltab\@:
	.word	.Lbad\@, .Lok\@, .Lbad\@
.Lend\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	ldr	r0, =SAVED
	str	sp, [r0]
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	ldr	r0, =COARSE
	ldr	r1, =0x00000FFE
	mov	r2, #256
1:	str	r1, [r0], #4
	add	r1, r1, #0x1000
	subs	r2, r2, #1
	bne	1b
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r11, =RES_TABLE
	ldr	r0, =RES_FAILS
	mov	r1, #0
	str	r1, [r0]
	str	r1, [r0, #4]
	mov	r10, #0
	@ r5: 2 sections at the bench's latency, 1 pages at 24, 0 sections at 12
	mov	r5, #2
config:
	cmp	r5, #1
	SECT	r1, 0, 3, 0, 3
	ldreq	r1, =(COARSE | 0x10 | 1)
	SETL1	0, r1
	TLBFLUSH
	ldr	r0, =BENCH
	cmp	r5, #1
	movhi	r1, #0
	moveq	r1, #24
	movlo	r1, #12
	str	r1, [r0, #BENCH_LATENCY]
	ldr	r0, =SAVED
	str	r5, [r0, #4]
	b	cases
	.ltorg
cases:
	.irp fk, 0, 1, 2, 3, 4, 5, 6, 7
	.irp wk, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
	.irp vk, 0, 1, 2, 3
	.irp dk, 0, 2
	CASE	\fk, \wk, \vk, \dk
	.endr
	.endr
	.endr
	.endr
	ldr	r0, =SAVED
	ldr	r5, [r0, #4]
	subs	r5, r5, #1
	bpl	config
	ldr	r0, =BENCH
	mov	r1, #0
	str	r1, [r0, #BENCH_LATENCY]
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	TLBFLUSH
	ldr	r0, =RES_FIRST
	ldr	r0, [r0]
	CHECK	r0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ SWI from USR at the end of a case: continue in SVC after the svc.
to_svc:
	mov	pc, lr

@ r9 = lit1's address, r1 = victim kind (1 both ways dirty, 3 lit1 LRU
@ beside a dirty line, 4 beside a clean line). Returns r4 = X2 (lit1's
@ set), r3 = 0. No literal load after the invalidation.
prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r6, =(UNC + A1 - 0x00400000)
	mov	r0, #0xA1
	str	r0, [r6]
	ldr	r0, =V1
	str	r0, [r6, #4]
	ldr	r6, =(UNC + A2 - 0x00400000)
	mov	r0, #0xA2
	str	r0, [r6]
	ldr	r0, =V2
	str	r0, [r6, #4]
	ldr	r5, =A1
	ldr	r2, =A2
	ldr	r3, =SCR7
	ldr	r0, =0x1FF0
	and	r0, r9, r0
	ldr	r4, =XBASE2
	add	r4, r4, r0
	ldr	r6, =XBASE1
	add	r6, r6, r0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r0, [r5]
	ldr	r0, [r2]
	ldr	r0, [r3]
	ldr	r0, [r9, #16]
	mov	r0, #VEC_TABLE		@ the vector literals (crt0's ldr pc)
	ldr	r0, [r0]
	mov	r0, #VEC_TABLE + 16
	ldr	r0, [r0]
	cmp	r1, #1
	streq	r0, [r6]
	streq	r0, [r4]
	ldreq	r0, [r6]
	ldreq	r0, [r4]
	cmp	r1, #3
	ldreq	r0, [r9]
	streq	r0, [r6]
	ldreq	r0, [r6]
	cmp	r1, #4
	ldreq	r0, [r9]
	ldreq	r0, [r6]
	mov	r3, #0
	mov	pc, lr
	.ltorg

@ r0 = observed, r2 = expected; r8 = pass, r10 = case, r11 = table
verify:
	mov	r3, #0
	cmp	r0, r2
	movne	r3, #1
	add	r6, r11, r10, lsl #4
	cmp	r8, #2
	streq	r3, [r6]
	strne	r3, [r6, #4]
	str	r0, [r6, #8]
	str	r2, [r6, #12]
	cmp	r3, #0
	moveq	pc, lr
	ldr	r6, =RES_FAILS
	ldr	r1, [r6]
	add	r1, r1, #1
	str	r1, [r6]
	ldr	r1, [r6, #4]
	cmp	r1, #0
	orreq	r1, r3, r10, lsl #8
	streq	r1, [r6, #4]
	mov	pc, lr
	.ltorg
