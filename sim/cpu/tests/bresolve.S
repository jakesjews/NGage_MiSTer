@ SPDX-License-Identifier: GPL-3.0-or-later
@ Direct branches with stable flags and an immediately preceding flag writer.
@ Default @@ conventions: compare signature and trace with QEMU.
	.include "test.inc"
	.text
	.arm
	.global test_main
	.macro PROBE gap
	mov r0, #9
1:
	subs r0, r0, #1
	.rept \gap
	nop
	.endr
	bne 1b
	CHECK r0, 0
	@ Change direction at the same branch PC on every iteration.
	mov r0, #12
	mov r1, #0
2:
	tst r0, #1
	.rept \gap
	nop
	.endr
	beq 3f
	add r1, r1, #1
3:
	subs r0, r0, #1
	bne 2b
	CHECK r1, 6
	.endm
test_main:
	stmfd sp!, {r4-r11, lr}
	PROBE 0
	PROBE 1
	PROBE 2
	CHECKPOINT
	@ FMOV/MSR changes flags despite not using an ordinary S-bit operation.
	mov r0, #0
	msr cpsr_f, r0
	beq fail_target
	ldr r0, =0x40000000
	msr cpsr_f, r0
	bne fail_target
	@ Preserve link writes when a conditional BL is resolved early.
	adr r4, returned
	mov r0, #0
	cmp r0, #0
	nop
	nop
	bleq callee
returned:
	CHECKR lr, r4
	CHECK r1, 47
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
callee:
	mov r1, #47
	bx lr
fail_target:
	FAIL
	.ltorg
