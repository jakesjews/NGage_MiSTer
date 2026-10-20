@ SPDX-License-Identifier: GPL-3.0-or-later
@
@ Shared definitions for the CPU tests (sim/cpu/tests). Every test is linked
@ with crt0.S at address 0 and defines test_main, which runs in SVC mode with
@ IRQ and FIQ masked, every mode's stack set and r0-r12 zero. Returning from
@ test_main (or branching to test_pass) passes; a failed CHECK ends the test.
@
@ Result area (the "signature", dumped by the RTL bench and by QEMU through
@ GDB, then compared word for word):
@   SIG_BASE + 0x00  result: 1 = pass, 0xBAD0nnnn = CHECK number nnnn failed
@          + 0x04  next CHECKPOINT record
@          + 0x08  failing CHECK: address, value found, value expected
@          + 0x100 CHECKPOINT records, 16 words each: r0-r14, CPSR
@          + 0x8000 free for test results (SIG_DATA)
@
@ The CHECK macros use r12 and the flags. CHECKPOINT changes nothing.
@ Read PSRs with MRSN: QEMU sets the ARMv6 A bit (8) in its PSRs even on an
@ ARMv4 CPU, so values that are compared must have it cleared.

	.equ	SIG_BASE,	0x00F00000
	.equ	SIG_PTR,	SIG_BASE + 0x04
	.equ	SIG_FAIL,	SIG_BASE + 0x08
	.equ	SIG_RECORDS,	SIG_BASE + 0x100
	.equ	SIG_DATA,	SIG_BASE + 0x8000

	.equ	STACK_SVC,	0x00700000
	.equ	STACK_IRQ,	0x006F0000
	.equ	STACK_FIQ,	0x006E0000
	.equ	STACK_ABT,	0x006D0000
	.equ	STACK_UND,	0x006C0000
	.equ	STACK_USR,	0x006B0000

	@ RAM the tests may use freely
	.equ	SCRATCH,	0x00400000
	@ MMU tests: level-1 table (16 KB aligned) and level-2 tables
	.equ	TTB,		0x00800000
	.equ	L2_AREA,	0x00804000

	@ Vector table (crt0.S): the vector at 4*n loads pc from VEC_TABLE+4*n
	.equ	VEC_TABLE,	0x20
	.equ	VEC_UND,	VEC_TABLE + 0x04
	.equ	VEC_SWI,	VEC_TABLE + 0x08
	.equ	VEC_PABT,	VEC_TABLE + 0x0C
	.equ	VEC_DABT,	VEC_TABLE + 0x10
	.equ	VEC_IRQ,	VEC_TABLE + 0x18
	.equ	VEC_FIQ,	VEC_TABLE + 0x1C

	@ Bench registers (RTL only: QEMU aborts on them)
	.equ	BENCH,		0xF0000000
	.equ	BENCH_PUTC,	0x00
	.equ	BENCH_STOP,	0x04
	.equ	BENCH_INT,	0x08
	.equ	BENCH_IRQ_IN,	0x0C
	.equ	BENCH_FIQ_IN,	0x10
	.equ	BENCH_CYCLES,	0x14
	.equ	BENCH_RETIRED,	0x18
	.equ	BENCH_SCRATCH,	0x1C
	.equ	BENCH_LATENCY,	0x20
	@ an address that answers with a bus error on both RTL and QEMU
	.equ	NOWHERE,	0x08000000

	@ CPSR modes and bits
	.equ	M_USR, 0x10
	.equ	M_FIQ, 0x11
	.equ	M_IRQ, 0x12
	.equ	M_SVC, 0x13
	.equ	M_ABT, 0x17
	.equ	M_UND, 0x1B
	.equ	M_SYS, 0x1F
	.equ	PSR_T, 0x20
	.equ	PSR_F, 0x40
	.equ	PSR_I, 0x80

	@ CP15 control register bits
	.equ	CR_M, 0x0001
	.equ	CR_A, 0x0002
	.equ	CR_C, 0x0004
	.equ	CR_W, 0x0008
	.equ	CR_S, 0x0100
	.equ	CR_R, 0x0200
	.equ	CR_I, 0x1000
	.equ	CR_V, 0x2000

	.set	_chk, 0

@ CHECK reg, value: fail unless reg == value (r12 and flags are used)
	.macro	CHECK reg, val
	.set	_chk, _chk + 1
	ldr	r12, =\val
	cmp	\reg, r12
	beq	.Lok\@
	mov	r0, \reg
	mov	r1, r12
	ldr	r2, =_chk
	bl	check_failed
.Lok\@:
	.endm

@ CHECKR ra, rb: fail unless ra == rb
	.macro	CHECKR ra, rb
	.set	_chk, _chk + 1
	cmp	\ra, \rb
	beq	.Lok\@
	mov	r12, \rb
	mov	r0, \ra
	mov	r1, r12
	ldr	r2, =_chk
	bl	check_failed
.Lok\@:
	.endm

@ CHECKM addr, value: fail unless the word at addr == value (r11, r12)
	.macro	CHECKM addr, val
	ldr	r11, =\addr
	ldr	r11, [r11]
	CHECK	r11, \val
	.endm

@ FAIL: fail unconditionally (r0 = 0xDEAD)
	.macro	FAIL
	.set	_chk, _chk + 1
	ldr	r0, =0xDEAD
	mov	r1, #0
	ldr	r2, =_chk
	bl	check_failed
	.endm

@ MRSN reg, psr: MRS without the A bit QEMU adds
	.macro	MRSN reg, psr
	mrs	\reg, \psr
	bic	\reg, \reg, #0x100
	.endm

@ CHECKPOINT: append r0-r14 and the CPSR to the record area. ARM state,
@ any mode; changes no register and no flag. The code area must be writable.
	.macro	CHECKPOINT
	str	r0, .Lsv0\@
	ldr	r0, .Lptr\@
	ldr	r0, [r0]
	stmia	r0, {r0-r14}
	str	r1, .Lsv1\@
	mrs	r1, cpsr
	bic	r1, r1, #0x100
	str	r1, [r0, #60]
	ldr	r1, .Lsv0\@
	str	r1, [r0]
	add	r1, r0, #64
	ldr	r0, .Lptr\@
	str	r1, [r0]
	ldr	r1, .Lsv1\@
	ldr	r0, .Lsv0\@
	b	.Lend\@
.Lsv0\@: .word	0
.Lsv1\@: .word	0
.Lptr\@: .word	SIG_PTR
.Lend\@:
	.endm

@ VECTOR vec, handler: install an exception handler (VEC_* address)
	.macro	VECTOR vec, handler
	stmfd	sp!, {r11}
	ldr	r11, =\handler
	ldr	r12, =\vec
	str	r11, [r12]
	ldmfd	sp!, {r11}
	.endm

@ MODE m: switch mode with interrupts masked
	.macro	MODE m
	msr	cpsr_c, #(\m | PSR_I | PSR_F)
	.endm

@ STORE_RESULT reg, index: SIG_DATA[index] = reg (r12)
	.macro	STORE_RESULT reg, idx
	ldr	r12, =SIG_DATA + 4 * \idx
	str	\reg, [r12]
	.endm
