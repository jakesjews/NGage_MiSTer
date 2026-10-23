@ SPDX-License-Identifier: GPL-3.0-or-later
@ Hit-under-miss: exact values and observed overlap, loose elapsed bounds.
@ A/B/C share a set (B is the dirty victim); D/E share another set, in
@ opposite ways. Every case runs twice to warm its instruction lines.
@ The bench's watched-line counters count actual CPU acknowledgements in
@ CLEAN_SINGLE/FETCH_SINGLE/UNLOCK_WR, independently of HUM eligibility.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ LA, 0x00421E00
	.equ LB, 0x00431E00
	.equ LC, 0x00441E00
	.equ LD, 0x00451D00
	.equ LE, 0x00461D00
	.equ UNC, 0x20000000
	.equ FAULT, 0x00521B00
	.equ WT, 0x00621C00
	.equ HUM_LOADS, 0x24
	.equ HUM_STORES, 0x28
	.equ HUM_WATCH, 0x2C
	.text
	.arm
	.global test_main

	.macro PAIR gap, store, target, expected, overlap
	mov	r8, #2
.Lpair\@:
	ldr	r10, =\target
	bl	prepare
	@ This uncached write fences prepare's final fill and resets counts.
	str	r10, [r11, #HUM_WATCH]
	mov	r2, #0x55
	ldr	r3, [r11, #BENCH_CYCLES]
	ldr	r0, [r6]
	.rept \gap - 1
	mov	r2, r2
	.endr
	.if \store
	str	r2, [r10]
	.else
	ldr	r1, [r10]
	.endif
	ldr	r9, [r11, #BENCH_CYCLES]
	sub	r9, r9, r3
	cmp	r8, #1
	bne	.Lcold\@
	@ Includes the 8-beat dirty eviction/fill and the counter read.
	@ Broad enough to tolerate scheduling changes, but catches deadlock
	@ or a repeated transaction. Overlap itself is checked separately.
	cmp	r9, #768
	blo	.Ltime\@
	FAIL
.Ltime\@:
	.if \store
	ldr	r9, [r11, #HUM_STORES]
	.else
	ldr	r9, [r11, #HUM_LOADS]
	.endif
	.if \overlap
	CHECK	r9, 1
	.else
	CHECK	r9, 0
	.endif
.Lcold\@:
	CHECK	r0, 0xC1
	.if \store
	ldr	r1, [r10]
	CHECK	r1, 0x55
	.else
	CHECK	r1, \expected
	.endif
	ldr	r2, [r7, #4]
	ldr	r3, [r4, #4]
	CHECK	r2, 0xD4
	CHECK	r3, 0xA4
	@ Verify dirty HUM stores reach memory when cleaned.
	mov	r9, #0
	mcr	p15, 0, r9, c7, c10, 0
	.if \store
	ldr	r9, =(UNC + (\target - 0x00400000))
	ldr	r1, [r9]
	CHECK	r1, 0x55
	.endif
	subs	r8, r8, #1
	bne	.Lpair\@
	b	.Lpool\@
	.ltorg
.Lpool\@:
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
	SECT	r1, 0x00500000, 3, 1, 3
	SETL1	0x00500000, r1
	SECT	r1, 0x00600000, 3, 0, 2
	SETL1	0x00600000, r1
	SECT	r1, 0x00600000, 3, 0, 0
	SETL1	0x20600000, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	SECT	r1, NOWHERE, 3, 0, 0
	SETL1	NOWHERE, r1
	TLBFLUSH
	mov	r0, #5		@ domains 0 and 1 client
	mcr	p15, 0, r0, c3, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r4, =LA
	ldr	r5, =LB
	ldr	r6, =LC
	ldr	r7, =LD
	ldr	r11, =BENCH
	mov	r0, #24
	str	r0, [r11, #BENCH_LATENCY]

	.irp gap, 1, 2, 3, 4, 5, 6
	.irp store, 0, 1
	PAIR	\gap, \store, LA, 0xA2, 1
	PAIR	\gap, \store, LD, 0xD1, 1
	PAIR	\gap, \store, LE, 0xE1, 1
	PAIR	\gap, \store, LC+4, 0xC4, 0
	PAIR	\gap, \store, LB, 0xB2, 0
	.endr
	.endr
	CHECKPOINT

	@ Partial store allocation in the background, with a stream of byte
	@ and halfword hit stores and dependent reads in both ways. The warm
	@ pass spans the final fill write, exercising its priority and repair.
	mov	r8, #2
stream:
	bl	prepare
	ldr	r10, =LE
	str	r7, [r11, #HUM_WATCH]
	mov	r2, #0x55
	strb	r2, [r6, #1]
	.rept 48
	strb	r2, [r7, #1]
	ldrh	r1, [r7]
	strh	r2, [r10, #2]
	ldr	r9, [r10]
	.endr
	CHECK	r1, 0x55D1
	CHECK	r9, 0x005500E1
	ldr	r0, [r6]
	CHECK	r0, 0x55C1
	ldr	r9, [r11, #HUM_STORES]
	cmp	r8, #1
	bne	stream_cold
	cmp	r9, #1
	bhs	stream_cold
	FAIL
stream_cold:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r9, =(UNC + LD - 0x00400000)
	ldr	r1, [r9]
	CHECK	r1, 0x55D1
	ldr	r9, =(UNC + LE - 0x00400000)
	ldr	r1, [r9]
	CHECK	r1, 0x005500E1
	ldr	r9, =(UNC + LC - 0x00400000)
	ldr	r1, [r9]
	CHECK	r1, 0x55C1
	subs	r8, r8, #1
	bne	stream
	CHECKPOINT

	@ A cached domain fault behind the fill must not let the following
	@ store become visible before the abort. Skip BOTH instructions on
	@ exception return so an erroneously early store cannot be hidden.
	bl	prepare
	ldr	r10, =FAULT
	ldr	r1, [r10]
	ldr	r9, [r11, #BENCH_CYCLES]
	mov	r0, #1		@ domain 1 now inaccessible; cached tag remains
	mcr	p15, 0, r0, c3, c0, 0
	VECTOR	VEC_DABT, skip_store
	mov	r2, #0x77
	ldr	r0, [r6]
	ldr	r1, [r10]
	str	r2, [r7]
	CHECK	r0, 0xC1
	ldr	r1, [r7]
	CHECK	r1, 0xD1
	DABT	0x19, FAULT
	VECTOR	VEC_DABT, ab_dabt

	@ A TLB miss and an uncached external error are still ordered after
	@ the fill and retain their precise FSR/FAR.
	bl	prepare
	ldr	r10, =0x30000000
	ldr	r0, [r6]
	ldr	r1, [r10]
	CHECK	r0, 0xC1
	DABT	5, 0x30000000
	bl	prepare
	ldr	r10, =NOWHERE
	ldr	r0, [r6]
	ldr	r1, [r10]
	CHECK	r0, 0xC1
	DABT	8, NOWHERE

	@ Write-through hits retain their bus-completion path.
	bl	prepare
	ldr	r10, =WT
	ldr	r1, [r10]
	str	r10, [r11, #HUM_WATCH]
	mov	r2, #0x66
	ldr	r0, [r6]
	str	r2, [r10]
	ldr	r9, [r11, #HUM_STORES]
	CHECK	r9, 0
	ldr	r1, [r10]
	CHECK	r1, 0x66
	ldr	r10, =0x20621C00
	ldr	r1, [r10]
	CHECK	r1, 0x66
	NOABT
	CHECKPOINT
	mov	r0, #0
	str	r0, [r11, #BENCH_LATENCY]
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

skip_store:
	add	lr, lr, #4
	b	ab_dabt

prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	.irp pair, 0, 1, 2, 3, 4
	.if \pair == 0
	ldr	r9, =(UNC + LA - 0x00400000)
	mov	r0, #0xA1
	.elseif \pair == 1
	ldr	r9, =(UNC + LB - 0x00400000)
	mov	r0, #0xB1
	.elseif \pair == 2
	ldr	r9, =(UNC + LC - 0x00400000)
	mov	r0, #0xC1
	.elseif \pair == 3
	ldr	r9, =(UNC + LD - 0x00400000)
	mov	r0, #0xD1
	.else
	ldr	r9, =(UNC + LE - 0x00400000)
	mov	r0, #0xE1
	.endif
	str	r0, [r9]
	add	r0, r0, #3
	str	r0, [r9, #4]
	.endr
	ldr	r0, [r4]
	CHECK	r0, 0xA1
	ldr	r0, [r5]
	CHECK	r0, 0xB1
	ldr	r0, [r7]
	CHECK	r0, 0xD1
	ldr	r9, =LE
	ldr	r0, [r9]
	CHECK	r0, 0xE1
	mov	r0, #0xA2
	str	r0, [r4]
	mov	r0, #0xB2
	str	r0, [r5]
	ldr	r0, [r4]
	CHECK	r0, 0xA2
	mov	pc, lr
	.ltorg
