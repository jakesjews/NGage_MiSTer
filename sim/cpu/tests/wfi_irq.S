@ SPDX-License-Identifier: GPL-3.0-or-later
@ WFI wake and EKA1's interrupt-mask helpers (ROM 5031c2cc/5031c2f4).
@ The observed 5031e394 hang is Kern::Fault, NOT this idle sequence.
@ Bench timers are deliberately much later than the cache/bus latency.
@@ qemu: irq
@@ trace: no
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
	SECT r1, BENCH, 3, 0, 0
	SETL1 BENCH, r1
	TLBFLUSH
	mrc p15, 0, r0, c1, c0, 0
	orr r0, r0, #(CR_C | CR_W)
	orr r0, r0, #CR_I
	mcr p15, 0, r0, c1, c0, 0
	VECTOR VEC_IRQ, irq_handler
	ldr r10, =BENCH
	ldr r11, =seen
	mov r0, #0
	str r0, [r11]

	@ Masked IRQ arriving during WFI wakes it without taking an exception.
	ldr r0, =3000
	str r0, [r10, #BENCH_IRQ_IN]
	mcr p15, 0, r0, c7, c0, 4
	ldr r0, [r11]
	CHECK r0, 0
	mov r0, #PSR_F
	bl restore_masks
	bl wait_irq
	CHECK r0, 1
	bl mask_irq
	CHECK r0, PSR_F

	@ IRQ already asserted before WFI, then restore masks as EKA1 does.
	mov r0, #1
	str r0, [r10, #BENCH_INT]
	mcr p15, 0, r0, c7, c0, 4
	ldr r0, [r11]
	CHECK r0, 1
	mov r0, #PSR_F
	bl restore_masks
	mov r4, #2
	bl wait_count
	bl mask_irq

	@ Unmasked IRQ during WFI. The saved LR must resume after the MCR,
	@ and a subsequent mask/unmask pair must not leave an old I bit live.
	mov r0, #PSR_F
	bl restore_masks
	ldr r0, =3000
	str r0, [r10, #BENCH_IRQ_IN]
	mcr p15, 0, r0, c7, c0, 4
	mov r4, #3
	bl wait_count
	bl mask_irq
	CHECK r0, PSR_F

	@ WFI returns on a masked IRQ; clear it, then a fresh IRQ arrives
	@ after the WFI while the firmware repeatedly saves/restores I/F.
	mov r0, #1
	str r0, [r10, #BENCH_INT]
	mcr p15, 0, r0, c7, c0, 4
	mov r0, #0
	str r0, [r10, #BENCH_INT]
	ldr r0, =3000
	str r0, [r10, #BENCH_IRQ_IN]
	mov r0, #PSR_F
	bl restore_masks
1:
	bl mask_irq
	bl restore_masks
	ldr r0, [r11]
	cmp r0, #4
	bne 1b
	bl mask_irq
	ldr r0, [r11]
	CHECK r0, 4
	MRSN r0, cpsr
	and r0, r0, #0xff
	CHECK r0, (M_SVC | PSR_I | PSR_F)
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}

wait_irq:
	mov r4, #1
wait_count:
	ldr r0, [r11]
	cmp r0, r4
	bne wait_count
	mov pc, lr

@ Exact instruction sequences from this ROM; both flags and control are
@ written, not just CPSR_c as in the older directed interrupt tests.
mask_irq:
	mrs r1, cpsr
	and r0, r1, #0xc0
	orr r1, r1, #0x80
	msr cpsr_fc, r1
	mov pc, lr
restore_masks:
	mrs r1, cpsr
	and r0, r0, #0xc0
	bic r1, r1, #0xc0
	orr r1, r1, r0
	msr cpsr_fc, r1
	mov pc, lr
irq_handler:
	stmfd sp!, {r0-r2, lr}
	mov r0, #0
	str r0, [r10, #BENCH_INT]
	ldr r0, [r11]
	add r0, r0, #1
	str r0, [r11]
	ldmfd sp!, {r0-r2, lr}
	subs pc, lr, #4
	.ltorg
	.data
	.align 2
seen: .word 0
