@ SPDX-License-Identifier: GPL-3.0-or-later
@ ARMv5(TE) instructions are UNDEFINED on the ARM925T (ARMv4T): CLZ, BLX
@ (both forms), BKPT, QADD and friends, the 16-bit multiplies, LDRD/STRD,
@ PLD, MCR2/MRC2/CDP2/LDC2/STC2 and anything with condition NV; in Thumb
@ state BLX (register) and BKPT. QEMU's ti925t agrees.
	.include "test.inc"

	@ UND32 word: run the ARM instruction, which must trap
	.macro	UND32 word
	ldr	r0, [r11]
	.word	\word
	ldr	r1, [r11]
	sub	r1, r1, r0
	CHECK	r1, 1
	.endm

	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_UND, und_handler
	ldr	r11, =count
	ldr	r4, =SCRATCH
	mov	r5, #0x40
	mov	r6, #0x80

	UND32	0xE16F0F15		@ clz r0, r5
	UND32	0xE12FFF35		@ blx r5
	UND32	0xFA000000		@ blx (immediate)
	UND32	0xE1200070		@ bkpt 0
	UND32	0xE1050056		@ qadd r0, r6, r5
	UND32	0xE1250056		@ qsub
	UND32	0xE1450056		@ qdadd
	UND32	0xE1650056		@ qdsub
	UND32	0xE1600685		@ smulbb r0, r5, r6
	UND32	0xE10006C5		@ smlatb
	UND32	0xE12006A5		@ smulwb
	UND32	0xE1200685		@ smlawb
	UND32	0xE14106E5		@ smlaltt
	UND32	0xE1C400D0		@ ldrd r0, [r4]
	UND32	0xE1C400F0		@ strd r0, [r4]
	UND32	0xF5D4F000		@ pld [r4]
	UND32	0xFE000F10		@ mcr2 p15
	UND32	0xFE100F10		@ mrc2 p15
	UND32	0xFE000000		@ cdp2 p0
	UND32	0xFD940500		@ ldc2 p5, c0, [r4]
	UND32	0xF0000000		@ andnv r0, r0, r0
	CHECKPOINT
	ldr	r0, [r4]
	CHECK	r0, 0			@ STRD stored nothing

	@ Thumb: BLX register, BKPT (the BLX suffix is in rtl_misc.S: QEMU
	@ runs it as on ARMv5)
	ldr	r0, [r11]
	mov	r7, r0
	ldr	r0, =t_code + 1
	bx	r0
	.thumb
	.align	2
t_code:
	.short	0x47A8			@ blx r5
	.short	0xBE00			@ bkpt 0
	ldr	r0, =a_back
	bx	r0
	.ltorg
	.arm
	.align	2
a_back:
	ldr	r0, [r11]
	sub	r0, r0, r7
	CHECK	r0, 2
	CHECKPOINT
	ldmfd	sp!, {r4-r11, pc}

und_handler:				@ count, return to the next instruction
	stmfd	sp!, {r0}
	ldr	r0, [r11]
	add	r0, r0, #1
	str	r0, [r11]
	ldmfd	sp!, {r0}
	movs	pc, lr

	.ltorg
	.data
	.align	2
count:	.word	0
