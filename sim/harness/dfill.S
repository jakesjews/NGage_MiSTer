@ SPDX-License-Identifier: GPL-3.0-or-later
@ What a data line fill costs on the whole core (sim/harness/
@ coreboot_main.cpp, `make -C sim dfill`): this program is the CS0 image.
@ It maps the SDRAM cached (C = B = 1), switches the MMU and both caches
@ on with the write buffer, and times loops of loads with UPP timer 1
@ (34.67 MHz, three clocks a tick), so the CPU's real request stream goes
@ through the cache, the bus, the SDRAM controller and the chip model.
@
@ Every loop makes N loads and is run twice (the second run has the loop's
@ code in the I-cache; its ticks are reported). The loops:
@   hit    the same line every time: the loop's own cost
@   seq    a new line each load, 16 bytes on (a walk through a buffer)
@   use    the same, the loaded word added up at once
@   row    a new line each load, 1040 bytes on: another SDRAM row each
@          time (the controller's rows are 1 KB), another bank every fourth
@   copy   seq, with a store of the word to a second buffer, 16 bytes on
@          each time (a store miss a load: posted, no line is fetched)
@   two    two loads a pass from two buffers, a new line each
@   rmw    seq, with a store of the word back to its own line (a hit once
@          the line is in): every line leaves the cache dirty, so every
@          fill but the first thousand has a victim to write back
@   hit8, seq8    hit and seq with eight adds of the loaded word after it
@   hit8i, seq8i  the same with eight adds that do not use the word: what
@          of a fill the instructions behind the load can run under
@ Output on the STI window (kern.log): "dfill: NAME ticks", then
@ "dfill: done" and "#END". Clocks a load = ticks * 3 / N; a fill's cost
@ is a loop's clocks a load less hit's.

	.equ	SD,	0x0A000000		@ SDRAM, cached (VA = PA)
	.equ	STI,	0x0DE00000		@ the STI text window
	.equ	TTB,	0x0A100000
	.equ	STACK,	0x0B200000		@ the SDRAM's mirror, uncached: the D-cache is
						@ invalidated between loops, so nothing of the
						@ program's own may sit dirty in it
	.equ	BUFA,	0x0A400000
	.equ	BUFB,	0x0A800000
	.equ	TMR1,	0x0C120A20		@ UPP timer 1
	.equ	N,	8192
	.equ	CR_M, 0x0001
	.equ	CR_C, 0x0004
	.equ	CR_W, 0x0008
	.equ	CR_I, 0x1000

	.text
	.arm
	.global	_start
_start:
	b	start
	.rept	7
	b	exception
	.endr

exception:
	ldr	r0, =s_exc
	bl	puts
	ldr	r0, =s_end
	bl	puts
1:	b	1b

start:
	ldr	sp, =STACK
	@ the level-1 table: everything identity, uncached, AP 11, domain 0
	ldr	r0, =TTB
	ldr	r1, =0xC12
	mov	r2, #0
1:	orr	r3, r1, r2, lsl #20
	str	r3, [r0, r2, lsl #2]
	add	r2, r2, #1
	cmp	r2, #4096
	bne	1b
	@ CS0 (the code) and the SDRAM cached and bufferable
	mov	r2, #0
1:	add	r3, r1, r2, lsl #20
	orr	r3, r3, #0xC
	str	r3, [r0, r2, lsl #2]
	add	r3, r1, #(SD >> 20) << 20
	add	r3, r3, r2, lsl #20
	orr	r3, r3, #0xC
	add	r5, r0, #(SD >> 20) << 2
	str	r3, [r5, r2, lsl #2]
	add	r2, r2, #1
	cmp	r2, #16
	bne	1b
	mcr	p15, 0, r0, c2, c0, 0		@ TTB
	mvn	r1, #0
	mcr	p15, 0, r1, c3, c0, 0		@ every domain manager
	mov	r1, #0
	mcr	p15, 0, r1, c8, c7, 0		@ TLBs
	mcr	p15, 0, r1, c7, c7, 0		@ caches
	mrc	p15, 0, r1, c1, c0, 0
	orr	r1, r1, #(CR_M | CR_C | CR_W)
	orr	r1, r1, #CR_I
	mcr	p15, 0, r1, c1, c0, 0
	nop
	nop
	@ timer 1: free-running down from all ones
	ldr	r0, =TMR1
	mvn	r1, #0
	str	r1, [r0, #0x18]
	str	r1, [r0, #0x10]
	mov	r1, #2
	str	r1, [r0, #0x04]

	ldr	r0, =s_hello
	bl	puts
	ldr	r4, =table
1:	ldr	r5, [r4], #4			@ the loop
	cmp	r5, #0
	beq	2f
	ldr	r6, [r4], #4			@ its name
	bl	once				@ warm the code
	bl	once
	mov	r7, r0
	ldr	r0, =s_name
	bl	puts
	mov	r0, r6
	bl	puts
	mov	r0, #' '
	bl	putc
	mov	r0, r7
	bl	puthex
	mov	r0, #'\n'
	bl	putc
	b	1b
2:	ldr	r0, =s_done
	bl	puts
	ldr	r0, =s_end
	bl	puts
1:	b	1b

@ r5 = the loop. Both caches' data are put out first (the D-cache
@ invalidated, so every line of the buffers is absent), then the loop is
@ timed; returns r0 = ticks.
once:
	stmfd	sp!, {r4-r11, lr}
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 4		@ drain the write buffer
	mcr	p15, 0, r0, c7, c6, 0		@ invalidate the D-cache
	ldr	r8, =TMR1
	ldr	r0, =BUFA
	ldr	r3, =BUFB
	mov	r2, #N
	mov	r4, #0
	ldr	r9, [r8, #0x10]
	mov	lr, pc
	mov	pc, r5
	ldr	r10, [r8, #0x10]
	sub	r0, r9, r10
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ The loops: r0 = BUFA, r3 = BUFB, r2 = N, r4 = 0; r1, r6, r7 free.
	.align	5
l_hit:
1:	ldr	r1, [r0]
	add	r6, r6, #16
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.align	5
l_seq:
1:	ldr	r1, [r0], #16
	add	r6, r6, #16
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.align	5
l_use:
1:	ldr	r1, [r0], #16
	add	r4, r4, r1
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.align	5
l_row:
	ldr	r7, =1040
1:	ldr	r1, [r0], r7
	add	r6, r6, #16
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.ltorg
	.align	5
l_copy:
1:	ldr	r1, [r0], #16
	str	r1, [r3], #16
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.align	5
l_two:
1:	ldr	r1, [r0], #16
	ldr	r6, [r3], #16
	subs	r2, r2, #2
	bne	1b
	mov	pc, lr

	.align	5
l_rmw:
1:	ldr	r1, [r0]
	str	r1, [r0], #16
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr

	.align	5
l_hit8:
1:	ldr	r1, [r0]
	.rept	8
	add	r4, r4, r1
	.endr
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.align	5
l_seq8:
1:	ldr	r1, [r0], #16
	.rept	8
	add	r4, r4, r1
	.endr
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.align	5
l_hit8i:
1:	ldr	r1, [r0]
	.rept	8
	add	r6, r6, #1
	.endr
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr
	.align	5
l_seq8i:
1:	ldr	r1, [r0], #16
	.rept	8
	add	r6, r6, #1
	.endr
	subs	r2, r2, #1
	bne	1b
	mov	pc, lr

putc:
	ldr	r1, =STI
	strb	r0, [r1]
	mov	pc, lr
puts:
	ldr	r1, =STI
1:	ldrb	r2, [r0], #1
	cmp	r2, #0
	strneb	r2, [r1]
	bne	1b
	mov	pc, lr
puthex:
	ldr	r1, =STI
	mov	r3, #28
1:	mov	r2, r0, lsr r3
	and	r2, r2, #15
	cmp	r2, #10
	addlo	r2, r2, #'0'
	addhs	r2, r2, #('a' - 10)
	strb	r2, [r1]
	subs	r3, r3, #4
	bpl	1b
	mov	pc, lr
	.ltorg

table:
	.word	l_hit, n_hit, l_seq, n_seq, l_use, n_use, l_row, n_row
	.word	l_copy, n_copy, l_two, n_two, l_rmw, n_rmw
	.word	l_hit8, n_hit8, l_seq8, n_seq8, l_hit8i, n_hit8i, l_seq8i, n_seq8i, 0
n_hit:	.asciz	"hit"
n_seq:	.asciz	"seq"
n_use:	.asciz	"use"
n_row:	.asciz	"row"
n_copy:	.asciz	"copy"
n_two:	.asciz	"two"
n_rmw:	.asciz	"rmw"
n_hit8:	.asciz	"hit8"
n_seq8:	.asciz	"seq8"
n_hit8i: .asciz	"hit8i"
n_seq8i: .asciz	"seq8i"
s_hello: .asciz	"dfill: start\n"
s_name:	.asciz	"dfill: "
s_done:	.asciz	"dfill: done\n"
s_exc:	.asciz	"dfill: exception\n"
s_end:	.asciz	"\n#END\n"
	.align	2
