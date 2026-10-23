@ SPDX-License-Identifier: GPL-3.0-or-later
@ ARM BL's link write and branch share a slot, including immediate LR use.
@ Default @@ conventions: compare signature and trace with QEMU.
	.include "test.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!, {r4-r11, lr}
	adr r4, next
	bl next
next:
	CHECKR lr, r4
	@ Failed condition leaves LR and the fallthrough unchanged.
	mov lr, #37
	cmp r4, r4
	blne fail_target
	CHECK lr, 37
	@ The callee consumes LR on its first instruction.
	adr r4, returned
	bl callee
returned:
	CHECKR r0, r4
	CHECKR lr, r4
	@ Both ALU inputs can consume the link at the immediately adjacent PC.
	adr r4, adjacent
	bl adjacent
adjacent:
	add r0, lr, lr
	add r4, r4, r4
	CHECKR r0, r4
	CHECKPOINT
	@ The destination must be the current bank's LR.
	mov r7, lr
	MODE (M_IRQ | PSR_I | PSR_F)
	adr r4, irq_next
	bl irq_next
irq_next:
	CHECKR lr, r4
	MODE (M_SVC | PSR_I | PSR_F)
	CHECKR lr, r7
	CHECKPOINT
	ldmfd sp!, {r4-r11, pc}
callee:
	mov r0, lr
	bx lr
fail_target:
	FAIL
	.ltorg
