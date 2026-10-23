@ SPDX-License-Identifier: GPL-3.0-or-later
@ ARM9 exception-return operand/abort boundaries. A register-shift PC write
@ needs Rm, Rs AND SPSR; an aborted LDM^ must not restore SPSR before DABT.
@ These are architectural tests, shared by ZAP, ARM9 and the QEMU reference.
	.include "test.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r8, lr}
	VECTOR VEC_DABT, state_dabt

	ldr r0, =0x900000D3
	msr spsr_cxsf, r0
	adr r1, shifted_return
	add r1, r1, r1
	mov r2, #1
	movs pc, r1, lsr r2
	FAIL
shifted_return:
	MRSN r3, cpsr
	CHECK r3, 0x900000D3
	CHECKPOINT

	@ The second transfer (PC) faults beyond RAM. The first transfer remains;
	@ base writeback and the exception return do not take effect.
	ldr r4, =0x00FFFFFC
	ldr r0, =0xA1B2C3D4
	str r0, [r4]
	mov r0, #0
	mov r5, #M_USR
	msr spsr_cxsf, r5
	cmp r1, r1
faulting_return:
	ldmia r4!, {r0, pc}^
after_fault:
	CHECK r0, 0xA1B2C3D4
	CHECK r4, 0x00FFFFFC
	CHECK r6, 0x600000D3
	adr r8, faulting_return + 8
	CHECKR r7, r8
	CHECKPOINT
	ldmfd sp!, {r4-r8, pc}

state_dabt:
	MRSN r6, spsr
	mov r7, lr
	subs pc, lr, #4
	.ltorg
