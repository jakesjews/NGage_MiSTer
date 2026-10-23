@ SPDX-License-Identifier: GPL-3.0-or-later
@ Sweep the IRQ arrival time across cold-load/ALU/shift/store dependencies.
@ Every iteration must finish with one interrupt and the same data; the
@ handler returns to the interrupted instruction with its flags restored.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	bl mmu_on
	SECT r1, 0, 3, 0, 3
	SETL1 0, r1
	SECT r1, SCRATCH, 3, 0, 3
	SETL1 SCRATCH, r1
	SECT r1, BENCH, 3, 0, 0
	SETL1 BENCH, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #(CR_C | CR_W)
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	VECTOR VEC_IRQ, handler
	ldr r4, =SCRATCH
	ldr r8, =irq_seen
	ldr r10, =BENCH
	mov r0, #3
	mov r1, #5
	stmia r4, {r0, r1}
	mov r7, #1
1:
	mov r0, #0
	str r0, [r8]
	mcr p15, 0, r4, c7, c14, 1
	str r7, [r10, #BENCH_IRQ_IN]
	msr cpsr_c, #(M_SVC | PSR_F)
	ldr r0, [r4]
	add r5, r0, r0
	ldr r1, [r4, #4]
	mov r6, r1, lsl r0
	ldr r2, [r4]
	str r2, [r4, #8]
2:
	ldr r0, [r8]
	cmp r0, #0
	beq 2b
	msr cpsr_c, #(M_SVC | PSR_I | PSR_F)
	CHECK r0, 1
	CHECK r5, 6
	CHECK r6, 40
	ldr r2, [r4, #8]
	CHECK r2, 3
	add r7, r7, #1
	cmp r7, #160
	bne 1b
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
handler:
	stmfd sp!, {r0-r2, lr}
	ldr r0, =BENCH
	mov r1, #0
	str r1, [r0, #BENCH_INT]
	ldr r0, =irq_seen
	ldr r1, [r0]
	add r1, r1, #1
	str r1, [r0]
	ldmfd sp!, {r0-r2, lr}
	subs pc, lr, #4
	.ltorg
	.data
	.align 2
irq_seen: .word 0
