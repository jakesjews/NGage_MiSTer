@ SPDX-License-Identifier: GPL-3.0-or-later
@ Posted write-back store misses (control bit W = 1), counted on the real
@ arm925t debug events like walloc_rtl.S. A cold 16-byte-per-iteration
@ store stream allocates no line and writes no line back: the words reach
@ memory through the store queue. Loads then allocate the 64 lines and read
@ what was stored; the same stores now hit, and cleaning writes 64 lines.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ EVENTS_LOAD, 0x30
	.equ EVENTS_STORE, 0x34
	.equ EVENTS_WB, 0x38
	.equ STREAM, 0x00420000
	.equ RAW, 0x20420000
	.macro SNAP
	ldr r8, [r11, #EVENTS_LOAD]
	ldr r9, [r11, #EVENTS_STORE]
	ldr r10, [r11, #EVENTS_WB]
	.endm
	.macro EVENTS loads, stores, wbs
	ldr r0, [r11, #EVENTS_LOAD]
	sub r0, r0, r8
	CHECK r0, \loads
	ldr r0, [r11, #EVENTS_STORE]
	sub r0, r0, r9
	CHECK r0, \stores
	ldr r0, [r11, #EVENTS_WB]
	sub r0, r0, r10
	CHECK r0, \wbs
	.endm
	.macro EMPTY
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	mcr p15, 0, r0, c7, c6, 0
	.endm
	@ The 64 lines through the uncached alias: \a \b \c \d in every line.
	.macro RAWCHECK a, b, c, d
	ldr r1, =RAW
	mov r2, #64
1:	ldr r0, [r1]
	CHECKR r0, \a
	ldr r0, [r1, #4]
	CHECKR r0, \b
	ldr r0, [r1, #8]
	CHECKR r0, \c
	ldr r0, [r1, #12]
	CHECKR r0, \d
	add r1, r1, #16
	subs r2, r2, #1
	bne 1b
	.endm
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	SECT r1, 0x00400000, 3, 0, 3
	SETL1 0x00400000, r1
	SECT r1, 0x00400000, 3, 0, 0
	SETL1 0x20400000, r1
	SECT r1, BENCH, 3, 0, 0
	SETL1 BENCH, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #(CR_C | CR_W)
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	ldr r11, =BENCH
	mov r4, #0x11
	mov r5, #0x22
	mov r6, #0x33
	mov r7, #0x44

	@ Cold stores: posted, no allocation, nothing to write back.
	EMPTY
	SNAP
	ldr r1, =STREAM
	mov r2, #64
store_stream:
	stmia r1!, {r4-r7}
	subs r2, r2, #1
	bne store_stream
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 4
	EVENTS 0, 0, 0
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	EVENTS 0, 0, 0
	RAWCHECK r4, r5, r6, r7
	CHECKPOINT

	@ Cold reads allocate and see the posted words.
	SNAP
	ldr r1, =STREAM
	mov r2, #64
load_stream:
	ldr r0, [r1]
	CHECKR r0, r4
	ldr r0, [r1, #12]
	CHECKR r0, r7
	add r1, r1, #16
	subs r2, r2, #1
	bne load_stream
	EVENTS 64, 0, 0
	CHECKPOINT

	@ The lines are present: stores hit and dirty them, cleaning writes 64.
	SNAP
	ldr r1, =STREAM
	mov r2, #64
warm_stream:
	stmia r1!, {r5-r7}
	str r4, [r1], #4
	subs r2, r2, #1
	bne warm_stream
	EVENTS 0, 0, 0
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	mcr p15, 0, r0, c7, c10, 4
	EVENTS 0, 0, 64
	RAWCHECK r5, r6, r7, r4
	CHECKPOINT

	@ A store miss beside a dirty line of another tag posts too, and the
	@ dirty line stays in the cache until it is cleaned.
	EMPTY
	SNAP
	ldr r1, =STREAM
	ldr r0, [r1]
	str r4, [r1]
	ldr r2, =(STREAM + 0x10000)
	str r6, [r2, #4]
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 4
	EVENTS 1, 0, 0
	ldr r3, =(RAW + 0x10000)
	ldr r0, [r3, #4]
	CHECKR r0, r6
	ldr r0, [r1]
	CHECKR r0, r4
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	EVENTS 1, 0, 1
	ldr r3, =RAW
	ldr r0, [r3]
	CHECKR r0, r4
	NOABT
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
	.ltorg
