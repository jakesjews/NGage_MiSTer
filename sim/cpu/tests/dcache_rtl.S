@ SPDX-License-Identifier: GPL-3.0-or-later
@ The two-way data cache (RTL only): three write-back lines whose addresses
@ share the set index VA[11:4] (and VA[12:4], so a direct-mapped 8 KB cache
@ would hold only one of them) are dirtied in turn; what reaches memory,
@ read through an uncached alias, tells which lines the set holds and which
@ one a fill replaces (the least recently used, TI SPRU671), and that the
@ index operations with TI configuration C = 1 act on the named way.
@ Set 0xE0: nothing else in the test touches it (the signature pointer the
@ checkpoints update is in set 0, the stack ends above 0x006FFE00).
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	LA,  0x00421E00		@ set 0xE0 of either 4 KB way, three
	.equ	LB,  0x00431E00		@ tags; VA[12:4] alike too
	.equ	LC,  0x00441E00
	.equ	UNC, 0x20000000		@ uncached alias of PA 0x00400000
	.equ	UA,  UNC + 0x21E00
	.equ	UB,  UNC + 0x31E00
	.equ	UC,  UNC + 0x41E00
	.equ	IDX_W0, 0x00000E00	@ TI index operand: set 0xE0, way 0
	.equ	IDX_W1, 0x80000E00	@ way 1 (bit 31, with C = 1)
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	ldr	r0, =TTB
	ldr	r1, =0x00000C1E		@ RAM write-back
	mov	r2, #16
1:	str	r1, [r0], #4
	add	r1, r1, #0x00100000
	subs	r2, r2, #1
	bne	1b
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	mcr	p15, 0, r0, c1, c0, 0
	ldr	r4, =LA
	ldr	r5, =LB
	ldr	r6, =LC
	ldr	r7, =UA
	ldr	r8, =UB
	ldr	r9, =UC

@ MEM alias, value: memory behind the cache
	.macro	MEM alias, val
	ldr	r0, =\val
	str	r0, [\alias]
	.endm
@ STORE line, value: the cached line (dirty afterwards)
	.macro	STORE line, val
	ldr	r0, =\val
	str	r0, [\line]
	.endm

	@ 1. two dirty lines of one set stay cached together
	MEM	r7, 0x0A1
	MEM	r8, 0x0B1
	MEM	r9, 0x0C1
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0	@ clean D
	mcr	p15, 0, r0, c7, c6, 0	@ flush D: the set is empty
	ldr	r1, [r4]		@ A into way 0 (LRU: 1)
	CHECK	r1, 0x0A1
	STORE	r4, 0x0A2		@ dirty
	ldr	r1, [r5]		@ B into way 1 (LRU: 0)
	CHECK	r1, 0x0B1
	STORE	r5, 0x0B2		@ dirty
	ldr	r1, [r7]
	CHECK	r1, 0x0A1		@ A not written back: B did not replace it
	ldr	r1, [r8]
	CHECK	r1, 0x0B1
	CHECKPOINT

	@ 2. a third line replaces the least recently used and writes it back:
	@ A, B, A -> B goes
	ldr	r1, [r4]
	CHECK	r1, 0x0A2		@ hit way 0 (LRU: 1)
	ldr	r1, [r6]
	CHECK	r1, 0x0C1		@ C replaces B in way 1 (LRU: 0)
	ldr	r1, [r8]
	CHECK	r1, 0x0B2		@ B was written back
	ldr	r1, [r7]
	CHECK	r1, 0x0A1		@ A still dirty in the cache
	STORE	r6, 0x0C2		@ C dirty, hit way 1 (LRU: 0)
	ldr	r1, [r5]
	CHECK	r1, 0x0B2		@ B refetched, replaces A in way 0 (LRU: 1)
	ldr	r1, [r7]
	CHECK	r1, 0x0A2		@ A was written back
	ldr	r1, [r9]
	CHECK	r1, 0x0C1		@ C not
	CHECKPOINT

	@ 3. the order of use decides, not the order of filling: B then C
	@ filled, C used last -> B goes
	ldr	r1, [r6]
	CHECK	r1, 0x0C2		@ hit way 1 (LRU: 0)
	ldr	r1, [r4]
	CHECK	r1, 0x0A2		@ A replaces B, clean, in way 0 (LRU: 1)
	ldr	r1, [r9]
	CHECK	r1, 0x0C1		@ C still only in the cache
	ldr	r1, [r5]
	CHECK	r1, 0x0B2		@ B replaces C in way 1 (LRU: 0)
	ldr	r1, [r9]
	CHECK	r1, 0x0C2		@ C written back
	CHECKPOINT

	@ 4. index operations name a way (TI config C = 1, way in bit 31).
	@ A is in way 0, B in way 1.
	STORE	r4, 0x0A3
	STORE	r5, 0x0B3		@ both dirty; memory A2, B2
	mov	r0, #0x04
	mcr	p15, 0, r0, c15, c1, 0	@ C = 1
	ldr	r0, =IDX_W1
	mcr	p15, 0, r0, c7, c10, 2	@ clean way 1 only
	ldr	r1, [r7]
	CHECK	r1, 0x0A2		@ A (way 0) not written back
	ldr	r1, [r8]
	CHECK	r1, 0x0B3		@ B (way 1) was
	ldr	r0, =IDX_W0
	mcr	p15, 0, r0, c7, c10, 2	@ clean way 0
	ldr	r1, [r7]
	CHECK	r1, 0x0A3
	STORE	r4, 0x0A4
	STORE	r5, 0x0B4
	ldr	r0, =IDX_W1
	mcr	p15, 0, r0, c7, c6, 2	@ flush way 1 (B) without cleaning
	ldr	r1, [r5]
	CHECK	r1, 0x0B3		@ B refetched: 0x0B4 lost (into way 1, LRU: 0)
	ldr	r1, [r4]
	CHECK	r1, 0x0A4		@ A untouched
	mov	r0, #0x01
	mcr	p15, 0, r0, c15, c1, 0	@ C = 0: an index operation takes both ways
	ldr	r0, =IDX_W0
	mcr	p15, 0, r0, c7, c14, 2	@ clean and flush the set, both ways
	ldr	r1, [r7]
	CHECK	r1, 0x0A4		@ A written back
	MEM	r7, 0x0A5
	MEM	r8, 0x0B5
	ldr	r1, [r4]
	CHECK	r1, 0x0A5		@ both refetched: they were invalidated
	ldr	r1, [r5]
	CHECK	r1, 0x0B5
	CHECKPOINT

	@ 5. the whole-cache clean covers both ways
	STORE	r4, 0x0A6
	STORE	r5, 0x0B6
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r1, [r7]
	CHECK	r1, 0x0A6
	ldr	r1, [r8]
	CHECK	r1, 0x0B6
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}
