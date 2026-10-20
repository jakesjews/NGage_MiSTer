@ SPDX-License-Identifier: GPL-3.0-or-later
@ CP15 as QEMU's ti925t and the ARM925T agree on it: ID and cache type,
@ writes to c0 ignored, control register values the firmware uses, TTB,
@ DACR, FSR/FAR, the TI c15 registers (configuration with the O bit
@ changing the ID, I_max/I_min reset by cache operations, thread ID), and
@ every cache and TLB operation the boot code and Symbian use.
	.include "test.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}

	mrc	p15, 0, r0, c0, c0, 0
	CHECK	r0, 0x54029252
	mrc	p15, 0, r0, c0, c0, 1
	CHECK	r0, 0x05109149
	mov	r1, #0
	mcr	p15, 0, r1, c0, c0, 0	@ ignored
	mrc	p15, 0, r0, c0, c0, 0
	CHECK	r0, 0x54029252
	CHECKPOINT

	@ control register: the boot code's values
	mrc	p15, 0, r0, c1, c0, 0
	CHECK	r0, 0x70
	ldr	r1, =0x1272
	mcr	p15, 0, r1, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	CHECK	r0, 0x1272
	ldr	r1, =0x70
	mcr	p15, 0, r1, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	CHECK	r0, 0x70
	CHECKPOINT

	@ TTB, DACR, FSR, FAR, PID
	ldr	r1, =0x0A078000
	mcr	p15, 0, r1, c2, c0, 0
	mrc	p15, 0, r0, c2, c0, 0
	CHECK	r0, 0x0A078000
	ldr	r1, =0x55555557
	mcr	p15, 0, r1, c3, c0, 0
	mrc	p15, 0, r0, c3, c0, 0
	CHECK	r0, 0x55555557
	ldr	r1, =0x000000F5
	mcr	p15, 0, r1, c5, c0, 0
	mrc	p15, 0, r0, c5, c0, 0
	CHECK	r0, 0x000000F5
	ldr	r1, =0x12345678
	mcr	p15, 0, r1, c6, c0, 0
	mrc	p15, 0, r0, c6, c0, 0
	CHECK	r0, 0x12345678
	@ (c13, the FCSE PID, is in cp15_ti.S: QEMU adds the unmasked value)
	mov	r1, #0
	mcr	p15, 0, r1, c3, c0, 0
	mcr	p15, 0, r1, c5, c0, 0
	mcr	p15, 0, r1, c6, c0, 0
	CHECKPOINT

	@ TI configuration: kept as value & 0xE7; O (bit 5) selects ID 0x915
	mov	r1, #0xFF
	mcr	p15, 0, r1, c15, c1, 0
	mrc	p15, 0, r0, c15, c1, 0
	CHECK	r0, 0xE7
	mrc	p15, 0, r0, c0, c0, 0
	CHECK	r0, 0x54029152
	mov	r1, #0x81
	mcr	p15, 0, r1, c15, c1, 0
	mrc	p15, 0, r0, c15, c1, 0
	CHECK	r0, 0x81
	mrc	p15, 0, r0, c0, c0, 0
	CHECK	r0, 0x54029252
	@ I_max, I_min: plain until a cache operation resets them
	ldr	r1, =0x123
	mcr	p15, 0, r1, c15, c2, 0
	ldr	r1, =0x456
	mcr	p15, 0, r1, c15, c3, 0
	mrc	p15, 0, r0, c15, c2, 0
	CHECK	r0, 0x123
	mrc	p15, 0, r0, c15, c3, 0
	CHECK	r0, 0x456
	mcr	p15, 0, r1, c7, c10, 4	@ drain write buffer
	mrc	p15, 0, r0, c15, c2, 0
	CHECK	r0, 0
	mrc	p15, 0, r0, c15, c3, 0
	CHECK	r0, 0xFF0
	@ thread ID: 16 bits
	ldr	r1, =0xABCD1234
	mcr	p15, 0, r1, c15, c4, 0
	mrc	p15, 0, r0, c15, c4, 0
	CHECK	r0, 0x1234
	mrc	p15, 0, r0, c15, c8, 0	@ status: nothing to report
	CHECK	r0, 0
	mrc	p15, 0, r0, c9, c0, 0	@ no cache lockdown
	CHECK	r0, 0
	CHECKPOINT

	@ every cache and TLB operation (caches and MMU are off)
	mov	r1, #0
	mcr	p15, 0, r1, c7, c7, 0	@ flush I+D
	mcr	p15, 0, r1, c7, c5, 0	@ flush I
	mcr	p15, 0, r1, c7, c5, 1	@ flush I entry
	mcr	p15, 0, r1, c7, c6, 0	@ flush D
	mcr	p15, 0, r1, c7, c6, 1	@ flush D entry (VA)
	mcr	p15, 0, r1, c7, c6, 2	@ flush D entry (index)
	mcr	p15, 0, r1, c7, c10, 0	@ clean D
	mcr	p15, 0, r1, c7, c10, 1	@ clean D entry (VA)
	mcr	p15, 0, r1, c7, c10, 2	@ clean D entry (index)
	mcr	p15, 0, r1, c7, c10, 4	@ drain write buffer
	mcr	p15, 0, r1, c7, c14, 1	@ clean+flush D entry (VA)
	mcr	p15, 0, r1, c7, c14, 2	@ clean+flush D entry (index)
	mcr	p15, 0, r1, c7, c13, 1	@ prefetch I line
	mcr	p15, 0, r1, c8, c7, 0	@ flush TLBs
	mcr	p15, 0, r1, c8, c5, 0	@ flush I-TLB
	mcr	p15, 0, r1, c8, c5, 1	@ flush I-TLB entry
	mcr	p15, 0, r1, c8, c6, 0	@ flush D-TLB
	mcr	p15, 0, r1, c8, c6, 1	@ flush D-TLB entry
	mcr	p15, 0, r1, c15, c0, 0	@ TI no-op
	CHECKPOINT

	@ the instructions after an MCR see its effect
	ldr	r1, =0x1272
	mcr	p15, 0, r1, c1, c0, 0
	mrc	p15, 0, r2, c1, c0, 0
	add	r3, r2, #1
	CHECK	r3, 0x1273
	ldr	r1, =0x70
	mcr	p15, 0, r1, c1, c0, 0
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}
	.ltorg
