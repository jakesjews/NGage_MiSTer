@ SPDX-License-Identifier: GPL-3.0-or-later
@ Count real arm925t debug events. A cold 16-byte-per-iteration store
@ stream allocates 64 lines, then explicit cleaning writes back 64 lines.
@ Also check read allocation, warm stores, dirty eviction, targeted clean,
@ invalidate-only, WT bypass and uncached events. Works at 8/16 KB, two ways.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ EVENTS_LOAD, 0x30
	.equ EVENTS_STORE, 0x34
	.equ EVENTS_WB, 0x38
	.equ EVENTS_UNC, 0x3C
	.equ STREAM, 0x00420000
	.equ WT, 0x00520000
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
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	SECT r1, 0x00400000, 3, 0, 3
	SETL1 0x00400000, r1
	SECT r1, 0x00500000, 3, 0, 2
	SETL1 0x00500000, r1
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
	EMPTY
	SNAP
	ldr r1, =STREAM
	mov r2, #64
	ldr r3, [r11, #BENCH_CYCLES]
store_stream:
	stmia r1!, {r4-r7}
	subs r2, r2, #1
	bne store_stream
	@ A load of the last word waits for the last fill and checks its merge.
	ldr r0, [r1, #-4]
	CHECKR r0, r7
	ldr r2, [r11, #BENCH_CYCLES]
	sub r2, r2, r3
	ldr r0, =SIG_DATA
	str r2, [r0]                  @ stream, including final dependency/check
	EVENTS 0, 64, 0
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	EVENTS 0, 64, 64
	CHECKPOINT

	@ Cold reads allocate; reading the second word in each line hits.
	EMPTY
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

	@ The same stores now hit: no fills; cleaning still writes 64 lines.
	SNAP
	ldr r1, =STREAM
	mov r2, #64
warm_stream:
	stmia r1!, {r4-r7}
	subs r2, r2, #1
	bne warm_stream
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	EVENTS 0, 0, 64
	CHECKPOINT

	@ Three dirty lines in one set: one eviction, then two line cleans.
	EMPTY
	SNAP
	ldr r1, =STREAM
	str r4, [r1]
	add r1, r1, #0x10000
	str r5, [r1]
	add r1, r1, #0x10000
	str r6, [r1]
	ldr r0, [r1]
	CHECKR r0, r6
	EVENTS 0, 3, 1
	mcr p15, 0, r1, c7, c10, 1
	EVENTS 0, 3, 2
	sub r1, r1, #0x10000
	mcr p15, 0, r1, c7, c14, 1
	EVENTS 0, 3, 3
	@ Invalidate-only of a newly dirtied hit must not count a write-back.
	add r1, r1, #0x10000
	str r4, [r1]
	mcr p15, 0, r1, c7, c6, 1
	EVENTS 0, 3, 3
	CHECKPOINT

	@ WT misses bypass allocation; a later read allocates, a WT hit updates.
	EMPTY
	SNAP
	ldr r1, =WT
	ldr r3, [r11, #EVENTS_UNC]
	stmia r1, {r4-r7}
	ldr r2, [r11, #EVENTS_UNC]
	sub r2, r2, r3
	CHECK r2, 1                   @ initial counter read itself, no WT stores
	EVENTS 0, 0, 0
	ldr r0, [r1, #12]
	CHECKR r0, r7
	str r4, [r1, #12]
	ldr r0, [r1, #12]
	CHECKR r0, r4
	mov r0, #0
	mcr p15, 0, r0, c7, c10, 0
	EVENTS 1, 0, 0
	CHECKPOINT

	@ Two uncached data accesses plus the first counter read = three.
	ldr r3, [r11, #EVENTS_UNC]
	str r4, [r11, #BENCH_SCRATCH]
	ldr r0, [r11, #BENCH_SCRATCH]
	CHECKR r0, r4
	ldr r2, [r11, #EVENTS_UNC]
	sub r2, r2, r3
	CHECK r2, 3
	CHECKPOINT
	EMPTY
	ldmfd sp!, {r4-r11, pc}
	.ltorg
