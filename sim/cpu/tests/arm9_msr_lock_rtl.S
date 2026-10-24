@ SPDX-License-Identifier: GPL-3.0-or-later
@ A load whose line is the victim of an in-flight fill, with a younger
@ writer of the same register (the EKA1 system-call path that killed
@ V2's kernel, 0x50321564):
@
@	str	r3, [x2]		@ store miss: allocates over lit1's line
@	msr	cpsr_fc, r0		@ mode or mask change (or none)
@	ldr	ip, lit1		@ hits the departing line: not accepted,
@					@ then a miss with a dirty victim
@	mov	r0, #0
@	str	r0, [ip]		@ reader inside the miss window
@	ldr	ip, lit2		@ hit: the younger writer of ip
@	ldr	r0, [ip, #4]		@ must use lit2's value
@
@ lit2's line (the next one) is cached. Victim kinds 3 and 4 put lit1's
@ line in the cache as the LRU way of its set and evict it with the store
@ miss just before the window; the other kinds (lit1 not cached, the set
@ empty or dirty) and the TLB flushes are the neighbouring cases. Each
@ case runs twice (cold and warm I-cache), first over section-mapped code
@ at the bench's bus latency, then over small-page-mapped code at a fixed
@ latency of 24. A case records its errors and the test fails at the end
@ with the first: case number << 8 | error bits (1 wrong r0, 2 wrong final
@ ip, 4 the reader's store missing or misplaced, 8 the old ip's word
@ overwritten). The result table is at RES_TABLE, 16 bytes a case.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	COARSE, L2_AREA
	.equ	UNC, 0x20000000		@ uncached alias of PA 0x00400000
	.equ	A0, 0x00410E50		@ ip before the sequence
	.equ	A1, 0x00410E90		@ lit1's value
	.equ	A2, 0x00410ED0		@ lit2's value
	.equ	V0, 0x00000A04		@ the words at A0+4, A1+4, A2+4
	.equ	V1, 0x00000A14
	.equ	V2, 0x00000A24
	.equ	XBASE1, 0x00420000	@ other lines of lit1's set
	.equ	XBASE2, 0x00440000
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

@ msrv: 0 none, 1 SVC -> UND (mode), 2 UND -> UND masked (mask only, as
@ the kernel), 3 SVC -> SVC masked (mask only), 4 UND -> SVC (mode)
@ tlb: 0 none, 1 D-TLB flush, 2 both TLBs
@ victim: 0 empty set, 1 both ways dirty, 2 one dirty way and a store
@ miss allocating the other just before the MSR, 3 lit1's line cached
@ (LRU) beside a dirty line and evicted by that store miss's fill, 4 the
@ same beside a clean line
@ dr: instructions between the miss and the younger writer:
@ 0 none, 1 mov, 2 str, 3 mov mov, 4 mov str, 5 mov mov mov, 6 mov str mov
	.macro	CASE msrv, tlb, victim, dr
	mov	r8, #2
.Lagain\@:
	adr	r9, .Llit1\@
	mov	r1, #\victim
	bl	prepare
	mov	ip, r5
	.if \msrv == 1
	msr	cpsr_c, #0xD3
	mov	r0, #0xDB
	.elseif \msrv == 2
	msr	cpsr_c, #0x1B
	mov	r0, #0xDB
	.elseif \msrv == 3
	msr	cpsr_c, #0x13
	mov	r0, #0xD3
	.elseif \msrv == 4
	msr	cpsr_c, #0xDB
	mov	r0, #0xD3
	.endif
	.if \tlb == 1
	mcr	p15, 0, r3, c8, c6, 0
	.elseif \tlb == 2
	mcr	p15, 0, r3, c8, c7, 0
	.endif
	.if \victim >= 2
	str	r3, [r4]
	.endif
	.if \msrv
	msr	cpsr_fc, r0
	.endif
	ldr	ip, .Llit1\@
	.if \dr == 1
	mov	r0, #0
	.elseif \dr == 2
	str	r3, [ip]
	.elseif \dr == 3
	mov	r0, #0
	mov	r2, #0
	.elseif \dr == 4
	mov	r0, #0
	str	r0, [ip]
	.elseif \dr == 5
	mov	r0, #0
	mov	r2, #0
	mov	r2, #0
	.elseif \dr == 6
	mov	r0, #0
	str	r0, [ip]
	mov	r2, #0
	.endif
	ldr	ip, .Llit2\@
	ldr	r0, [ip, #4]
	mov	r1, ip
	msr	cpsr_c, #0xD3
	mov	r2, #\dr
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.balign	256
.Llit1\@:
	.word	A1, 0, 0, 0
.Llit2\@:
	.word	A2, 0, 0, 0
.Lend\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	@ the same code mapping as 4 KB pages (C=B=1, AP 11)
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
	@ r7: 1 sections at the bench's latency, 0 pages at latency 24
	mov	r7, #1
config:
	cmp	r7, #1
	SECT	r1, 0, 3, 0, 3
	ldrne	r1, =(COARSE | 0x10 | 1)
	SETL1	0, r1
	TLBFLUSH
	ldr	r0, =BENCH
	moveq	r1, #0
	movne	r1, #24
	str	r1, [r0, #BENCH_LATENCY]
	b	cases
	.ltorg
cases:
	.irp msrv, 0, 1, 2, 3, 4
	.irp tlb, 0, 1, 2
	.irp victim, 0, 1, 2, 3, 4
	.irp dr, 0, 1, 2, 3, 4, 5, 6
	CASE	\msrv, \tlb, \victim, \dr
	.endr
	.endr
	.endr
	.endr
	subs	r7, r7, #1
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

@ r9 = lit1's address, r1 = victim kind. Returns r4 = X2 (lit1's set),
@ r5 = A0, r3 = 0. No literal load after the invalidation: it could
@ fill a way of lit1's set.
prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r6, =(UNC + A0 - 0x00400000)
	mov	r0, #0xA0
	str	r0, [r6]
	ldr	r0, =V0
	str	r0, [r6, #4]
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
	ldr	r5, =A0
	ldr	r2, =A1
	ldr	r3, =A2
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
	cmp	r1, #1
	streq	r0, [r6]
	streq	r0, [r4]
	ldreq	r0, [r6]
	ldreq	r0, [r4]
	cmp	r1, #2
	streq	r0, [r6]
	ldreq	r0, [r6]
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

@ r0 = the consumer's word, r1 = the final ip, r2 = dr; r8 = pass,
@ r10 = case number, r11 = result table (4 words a case: error bits of
@ the cold and the warm pass, r0 and r1 of the last)
verify:
	mov	r3, #0
	ldr	r6, =V2
	cmp	r0, r6
	orrne	r3, r3, #1
	ldr	r6, =A2
	cmp	r1, r6
	orrne	r3, r3, #2
	cmp	r2, #2
	cmpne	r2, #4
	cmpne	r2, #6
	moveq	r2, #0
	movne	r2, #0xA1
	ldr	r6, =A1
	ldr	r6, [r6]
	cmp	r6, r2
	orrne	r3, r3, #4
	ldr	r6, =A0
	ldr	r6, [r6]
	cmp	r6, #0xA0
	orrne	r3, r3, #8
	add	r6, r11, r10, lsl #4
	cmp	r8, #2
	streq	r3, [r6]
	strne	r3, [r6, #4]
	str	r0, [r6, #8]
	str	r1, [r6, #12]
	cmp	r3, #0
	moveq	pc, lr
	ldr	r6, =RES_FAILS
	ldr	r2, [r6]
	add	r2, r2, #1
	str	r2, [r6]
	ldr	r2, [r6, #4]
	cmp	r2, #0
	orreq	r2, r3, r10, lsl #8
	streq	r2, [r6, #4]
	mov	pc, lr
	.ltorg
