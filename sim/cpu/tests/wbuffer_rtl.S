@ SPDX-License-Identifier: GPL-3.0-or-later
@ Merger-owned victim: misses, device publication, maintenance and I contention.
@ A/B/C share a set at every
@ supported cache size; B is LRU and dirty. D is a second miss elsewhere.
@ Values are exact; the overlap assertion only requires eight retirements
@ while the accepted store is still in the background transaction.
@ Cases 0-9 retain the original deferred-writeback value/order checks;
@ 10 adds an uncached victim read, 11 an I miss, 12 a second dirty miss.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ LA, 0x00421E00
	.equ LB, 0x00431E00
	.equ LC, 0x00441E00
	.equ LD, 0x00451D00
	.equ UB, 0x20031E00
	.equ UC, 0x20041E00
	.equ STORE_RETIRED, 0x40
	.text
	.arm
	.global test_main

	.macro CASE kind, dirty
	mov r8, #2
.Lagain\@:
	bl prepare
	.if !\dirty
	mcr p15, 0, r5, c7, c10, 1
	.endif
	.if \kind == 11
	ldr r9, =0x00490000
	mcr p15, 0, r9, c7, c5, 0  @ force a separate instruction fill
	.elseif \kind == 12
	ldr r9, =0x00471D00
	.elseif \kind == 10
	ldr r9, =UB
	.elseif \kind == 3
	ldr r9, =0x00481C00
	.endif
	ldr r10, [r11, #STORE_RETIRED]
	mov r2, #0x55
	strb r2, [r6, #1]
	.if \kind == 0
	.rept 32
	add r2, r2, #1
	.endr
	.endif
	.if \kind == 1
	ldr r1, [r5]               @ victim read must see its written-back bytes
	CHECK r1, 0xB2
	.elseif \kind == 2
	mov r2, #0x66
	str r2, [r5]               @ buffered-line write must wait and reallocate
	.elseif \kind == 3
	ldr r1, [r9]               @ a clean second miss may overtake the buffer
	CHECK r1, 0xE1
	.elseif \kind == 4
	mcr p15, 0, r6, c7, c10, 1 @ clean the new line
	.elseif \kind == 5
	mcr p15, 0, r5, c7, c6, 1  @ invalidate buffered old VA after draining
	.elseif \kind == 6
	mcr p15, 0, r5, c7, c14, 1 @ clean/invalidate buffered old VA
	.elseif \kind == 7
	mcr p15, 0, r0, c7, c10, 0 @ full clean drains, then cleans installed line
	.elseif \kind == 8
	mcr p15, 0, r0, c7, c6, 0  @ full invalidate drains victim, discards new line
	.elseif \kind == 9
	mcr p15, 0, r0, c7, c10, 4 @ explicit write-buffer drain
	.elseif \kind == 10
	ldr r1, [r9]               @ uncached read publishes older victim first
	CHECK r1, 0xB2
	.elseif \kind == 11
	mov lr, pc
	mov pc, r9                @ cold I line competes with buffered victim
	CHECK r2, 0x56
	.elseif \kind == 12
	ldr r1, [r9]               @ second dirty miss needs the single buffer
	CHECK r1, 0xF1
	.endif
	ldr r1, [r6, #4]           @ untouched bytes of the filling line
	CHECK r1, 0xC4
	ldr r1, [r6]
	.if \kind == 8
	CHECK r1, 0xC1
	.else
	CHECK r1, 0x55C1
	.endif
	ldr r9, [r11, #STORE_RETIRED]
	sub r9, r9, r10
	.if \kind == 0
	cmp r8, #1                @ second pass has warm instruction lines
	bne .Lcold\@
	cmp r9, #8
	bhs .Lcold\@
	FAIL
.Lcold\@:
	.endif
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	ldr r9, =UB
	ldr r1, [r9]
	.if \kind == 2
	CHECK r1, 0x66
	.else
	CHECK r1, 0xB2
	.endif
	ldr r1, [r9, #4]
	CHECK r1, 0xB4
	ldr r1, [r9, #8]
	CHECK r1, 0xB8
	ldr r1, [r9, #12]
	CHECK r1, 0xBC
	subs r8, r8, #1
	bne .Lagain\@
	CHECKPOINT
	b .Lpool\@
	.ltorg
.Lpool\@:
	.endm

test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	SECT r1, 0, 3, 0, 3
	SETL1 0, r1
	SECT r1, 0x00400000, 3, 0, 3
	SETL1 0x00400000, r1
	SECT r1, 0x00400000, 3, 0, 0
	SETL1 0x20000000, r1
	SECT r1, 0x00400000, 3, 0, 3
	SETL1 0x10400000, r1
	SECT r1, BENCH, 3, 0, 0
	SETL1 BENCH, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #(CR_C | CR_W)
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	ldr r4, =LA
	ldr r5, =LB
	ldr r6, =LC
	ldr r7, =LD
	ldr r11, =BENCH
	mov r0, #24
	str r0, [r11, #BENCH_LATENCY]
	.irp dirty, 0, 1
	.irp kind, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
	CASE \kind, \dirty
	.endr
	.endr
	@ Same-PA dirty victim via a distinct VA: preserve clean-before-fill.
	bl prepare
	ldr r10, =0x10431E00
	ldr r1, [r10]
	CHECK r1, 0xB2
	ldr r1, [r10, #4]
	CHECK r1, 0xB4
	mov r2, #0x55
	strb r2, [r10, #1]
	ldr r1, [r4]               @ ensure alias is the victim of the next miss
	ldr r1, [r5]
	CHECK r1, 0x55B2
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	CHECKPOINT
	mov r0, #0
	str r0, [r11, #BENCH_LATENCY]
	mcr p15, 0, r0, c7, c10, 0
	ldmfd sp!, {r4-r11, pc}
	.ltorg

prepare:
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	mcr p15, 0, r0, c7, c6, 0
	ldr r9, =UC
	mov r0, #0xC1
	str r0, [r9]
	mov r0, #0xC4
	str r0, [r9, #4]
	ldr r9, =0x20051D00
	mov r0, #0xD1
	str r0, [r9]
	ldr r9, =0x20081C00
	mov r0, #0xE1
	str r0, [r9]
	ldr r9, =0x20071D00
	mov r0, #0xF1
	str r0, [r9]
	ldr r9, =0x20090000
	ldr r0, =0xE2822001        @ add r2,r2,#1
	str r0, [r9]
	ldr r0, =0xE1A0F00E        @ mov pc,lr
	str r0, [r9, #4]
	ldr r0, [r7]               @ D and E occupy both ways of the other set
	ldr r9, =0x00461D00
	ldr r0, [r9]
	mov r0, #0xD1
	str r0, [r7]               @ D dirty, then E MRU makes D the victim
	ldr r0, [r9]
	ldr r0, [r4]
	ldr r0, [r5]
	mov r0, #0xB2
	str r0, [r5]
	mov r0, #0xB4
	str r0, [r5, #4]
	mov r0, #0xB8
	str r0, [r5, #8]
	mov r0, #0xBC
	str r0, [r5, #12]
	ldr r0, [r4]               @ A MRU; B the victim
	mov pc, lr
	.ltorg
