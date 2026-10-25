@ SPDX-License-Identifier: GPL-3.0-or-later
@ The LFFS sector copy on the whole core (sim/harness/coreboot_main.cpp,
@ `make -C sim flashcopy`): this program is the CS0 image. It maps C:
@ (CS1 0x400000-0x7FFFFF) where the kernel has it, uncached at 0x59200000
@ and 0x59600000, and copies sectors out of it with Mem::Copy's own
@ sequence (sim/cpu/tests/mem_copy.inc), so the CPU's real request stream
@ (uncached LDM words, each two 16-bit flash reads, its own I-fetch line
@ reads from CS0, the destination's SDRAM traffic) goes through the real
@ ngage_mem / upp_bus / nor_flash / ddram_flash RTL and the DDRAM model.
@ The bench's --check-flash compares every flash read beat with the image;
@ this program compares each copy with a byte-loop reference copy.
@
@ Each case runs twice. The copy under test comes first, so in the first
@ run the sector is cold in ddram_flash's read cache and beat buffer;
@ the reference copy follows. Cases (the source sector moves through C:
@ from case to case, 0x20200 bytes on, so its read-cache lines change):
@   * Mem::Copy of 512 bytes from every offset 0-35 in a sector, to a
@     cached (write-back) SDRAM dest whose first line is present, with the
@     I-cache invalidated first (the copy loop is fetched from CS0 while
@     it reads CS1); and again to a dest above the window (the descending
@     copy, ldmdb), dest line absent, I-cache warm;
@   * dests uncached and write-through; a cached source (a C=1 alias, line
@     fills of CS1); copies straddling a sector end; 511 and 1024 bytes;
@   * small copies (2, 7, 15 bytes: the ldrb/strb run) and a 2-byte
@     header then the 510-byte body;
@   * a flash word program (AMD command set) of a halfword in the line the
@     first run just read (its first, middle and last halfword: the last is
@     the beat buffer's), then the copy again: the copy must show the new
@     halfword (old & data) and match the reference.
@ Output on the STI window (kern.log): one line a failure, then
@ "flashcopy: N cases, F failures" and "#END".

	.equ	SD,	0x0A000000		@ SDRAM, cached (VA = PA)
	.equ	STI,	0x0DE00000		@ the STI text window
	.equ	TTB,	0x0A100000
	.equ	STACK,	0x0A200000
	.equ	DSTO,	0x00010000		@ dest and reference, offsets in SDRAM
	.equ	REFO,	0x00014000
	.equ	WIN,	0x59200000		@ C:, uncached (the kernel's window)
	.equ	WIN2,	0x59600000		@ its alias
	.equ	CWIN,	0x22000000		@ C:, cached (C=1, B=0)
	.equ	UNC,	0x2A000000		@ SDRAM uncached
	.equ	WT,	0x3A000000		@ SDRAM write-through
	.equ	HI,	0x8A000000		@ SDRAM cached, above the window
	.equ	CR_M, 0x0001
	.equ	CR_C, 0x0004
	.equ	CR_W, 0x0008
	.equ	CR_I, 0x1000
	@ case flags
	.equ	F_IINV, 1			@ invalidate the I-cache before the copy
	.equ	F_PRES, 2			@ dest's first line present
	.equ	F_HDR,  4			@ 2 bytes, then the rest
	.equ	F_PROG, 8			@ program a halfword between the runs

	.text
	.arm
	.global	_start
_start:
	b	start
	.rept	7
	b	exception
	.endr

exception:
	mov	r4, lr
	mrs	r5, cpsr
	ldr	r0, =s_exc
	bl	puts
	and	r0, r5, #0x1F
	bl	puthex
	mov	r0, #' '
	bl	putc
	mov	r0, r4
	bl	puthex
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
	@ CS0 (code) and SDRAM cached; the aliases
	mov	r2, #0
1:	add	r3, r1, r2, lsl #20
	orr	r3, r3, #0xC			@ CS0 cached
	str	r3, [r0, r2, lsl #2]
	add	r3, r1, #(SD >> 20) << 20
	add	r3, r3, r2, lsl #20
	orr	r4, r3, #0xC			@ SDRAM cached
	add	r5, r0, #(SD >> 20) << 2
	str	r4, [r5, r2, lsl #2]
	add	r5, r0, #(HI >> 20) << 2
	str	r4, [r5, r2, lsl #2]		@ HI: SDRAM cached
	add	r5, r0, #(UNC >> 20) << 2
	str	r3, [r5, r2, lsl #2]		@ UNC: SDRAM uncached
	orr	r4, r3, #0x8
	add	r5, r0, #(WT >> 20) << 2
	str	r4, [r5, r2, lsl #2]		@ WT: SDRAM write-through
	add	r2, r2, #1
	cmp	r2, #16
	bne	1b
	mov	r2, #0
1:	ldr	r3, =0x02400000 | 0xC12		@ C: = CS1 + 4 MB
	add	r3, r3, r2, lsl #20
	ldr	r5, =TTB + ((WIN >> 20) << 2)
	str	r3, [r5, r2, lsl #2]
	ldr	r5, =TTB + ((WIN2 >> 20) << 2)
	str	r3, [r5, r2, lsl #2]
	orr	r3, r3, #0x8
	ldr	r5, =TTB + ((CWIN >> 20) << 2)
	str	r3, [r5, r2, lsl #2]
	add	r2, r2, #1
	cmp	r2, #4
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
	ldr	r0, =s_hello
	bl	puts

	mov	r10, #0				@ failures
	mov	r9, #0				@ cases
	ldr	r4, =table
	ldr	r5, =table_end
2:	cmp	r4, r5
	bhs	3f
	mov	r6, #0				@ run
1:	bl	run_case
	add	r6, r6, #1
	cmp	r6, #2
	bne	1b
	add	r9, r9, #1
	add	r4, r4, #32
	b	2b
3:	adr	r0, s_sum1
	bl	puts
	mov	r0, r9
	bl	puthex
	ldr	r0, =s_sum2
	bl	puts
	mov	r0, r10
	bl	puthex
	ldr	r0, =s_sum3
	bl	puts
	ldr	r0, =s_end
	bl	puts
1:	b	1b

@ r4 = the case entry (src, n, dst, flags, reference src, program
@ address, program mask, -); r6 = run (0, 1); r9 = case, r10 failures.
run_case:
	stmfd	sp!, {r4-r9, lr}
	ldr	r7, [r4, #12]			@ flags
	tst	r7, #F_PROG
	beq	1f
	cmp	r6, #1
	bleq	program				@ between the runs
1:	@ zero dest and reference in SDRAM (after a clean+invalidate)
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r1, =UNC + DSTO
	ldr	r2, =UNC + REFO
	mov	r3, #0x440
1:	str	r0, [r1], #4
	str	r0, [r2], #4
	subs	r3, r3, #4
	bne	1b
	ldr	r8, [r4, #8]			@ dest
	tst	r7, #F_PRES
	ldrne	r0, [r8]
	tst	r7, #F_IINV
	mcrne	p15, 0, r0, c7, c5, 0		@ I-cache
	@ the copy under test
	mov	r0, r8
	ldr	r1, [r4]
	ldr	r2, [r4, #4]
	tst	r7, #F_HDR
	movne	r2, #2
	bl	mcopy
	tst	r7, #F_HDR
	beq	1f
	add	r0, r8, #2
	ldr	r1, [r4]
	add	r1, r1, #2
	ldr	r2, [r4, #4]
	sub	r2, r2, #2
	bl	mcopy
1:	@ the reference: a byte loop from the uncached window
	ldr	r0, =UNC + REFO
	ldr	r1, [r4, #16]
	ldr	r2, [r4, #4]
1:	ldrb	r3, [r1], #1
	strb	r3, [r0], #1
	subs	r2, r2, #1
	bne	1b
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	@ compare through the uncached alias
	ldr	r1, =UNC + DSTO
	ldr	r2, =UNC + REFO
	ldr	r3, [r4, #4]
	add	r3, r3, #3
	mov	r3, r3, lsr #2
	mov	r5, #0				@ word
1:	ldr	r7, [r1, r5, lsl #2]
	ldr	r8, [r2, r5, lsl #2]
	cmp	r7, r8
	blne	report
	add	r5, r5, #1
	cmp	r5, r3
	bne	1b
	@ after a program: the copy shows the new halfword
	ldr	r7, [r4, #12]
	tst	r7, #F_PROG
	beq	2f
	cmp	r6, #1
	bne	2f
	ldr	r0, [r4, #20]			@ the programmed address
	ldr	r1, [r4]
	sub	r0, r0, r1			@ its offset in the copy
	ldr	r1, =UNC + DSTO
	ldrh	r7, [r1, r0]
	ldr	r8, =prog_new
	ldr	r8, [r8]
	cmp	r7, r8
	movne	r5, #0xFFFFFFFF
	blne	report
2:	ldmfd	sp!, {r4-r9, pc}

@ r5 word (0xFFFFFFFF: the programmed halfword), r7 got, r8 want
report:
	stmfd	sp!, {r0-r3, lr}
	add	r10, r10, #1
	cmp	r10, #24
	bhi	1f
	ldr	r0, =s_fail
	bl	puts
	mov	r0, r9
	bl	puthex
	mov	r0, #' '
	bl	putc
	mov	r0, r6
	bl	puthex
	mov	r0, #' '
	bl	putc
	mov	r0, r5
	bl	puthex
	mov	r0, #' '
	bl	putc
	mov	r0, r7
	bl	puthex
	mov	r0, #' '
	bl	putc
	mov	r0, r8
	bl	puthex
	mov	r0, #'\n'
	bl	putc
1:	ldmfd	sp!, {r0-r3, pc}

@ program the halfword at [r4+20] to old & [r4+24]; wait for the end
program:
	stmfd	sp!, {r4-r8, lr}
	ldr	r5, [r4, #20]
	ldr	r6, [r4, #24]
	ldrh	r7, [r5]
	and	r7, r7, r6			@ the new value
	ldr	r0, =prog_new
	str	r7, [r0]
	ldr	r0, =WIN + 0xAAA
	ldr	r1, =WIN + 0x554
	mov	r2, #0xAA
	strh	r2, [r0]
	mov	r2, #0x55
	strh	r2, [r1]
	mov	r2, #0xA0
	strh	r2, [r0]
	strh	r7, [r5]
	ldr	r8, =200000
1:	subs	r8, r8, #1
	beq	2f
	ldrh	r0, [r5]
	ldrh	r1, [r5]
	cmp	r0, r1				@ DQ6 toggles while it runs
	bne	1b
	cmp	r0, r7
	bne	1b
	ldmfd	sp!, {r4-r8, pc}
2:	adr	r0, s_prog
	bl	puts
	add	r10, r10, #1
	ldmfd	sp!, {r4-r8, pc}

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

s_hello: .asciz	"flashcopy: start\n"
s_exc:	.asciz	"flashcopy: exception, mode "
s_fail:	.asciz	"FAIL case run word got want "
s_prog:	.asciz	"FAIL program did not finish\n"
s_sum1:	.asciz	"flashcopy: "
s_sum2:	.asciz	" cases, "
s_sum3:	.asciz	" failures\n"
s_end:	.asciz	"\n#END\n"
	.align	2

	.include "mem_copy.inc"

@ ---------------------------------------------------------------- cases
	@ the sector base (offset in C:) of the next case
	.set	CI, 0
	.macro	ENT off, n, dkind, flags, skind=0, prog=-1, mask=0
	.set	SB, ((CI * 0x20200) % 0x3E0000) & 0xFFFFFE00
	.if \skind
	.set	SRCV, CWIN + SB + \off
	.else
	.set	SRCV, WIN + SB + \off
	.endif
	.if \dkind == 0
	.set	DSTV, SD + DSTO
	.elseif \dkind == 1
	.set	DSTV, HI + DSTO
	.elseif \dkind == 2
	.set	DSTV, UNC + DSTO
	.else
	.set	DSTV, WT + DSTO
	.endif
	.if \prog >= 0
	.set	PROGA, WIN + SB + \prog
	.else
	.set	PROGA, 0
	.endif
	.word	SRCV, \n, DSTV, \flags, WIN + SB + \off, PROGA, \mask, 0
	.set	CI, CI + 1
	.endm

	.align	5
table:
	@ every offset 0-35: ascending to a present cached dest, I-cache cold
	.irp	o, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35
	ENT	\o, 512, 0, F_IINV | F_PRES
	.endr
	@ ... descending (dest above the window), dest absent, I-cache warm
	.irp	o, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35
	ENT	\o, 512, 1, 0
	.endr
	@ uncached and write-through dests
	.irp	o, 0, 2, 6, 30
	ENT	\o, 512, 2, F_IINV
	ENT	\o, 512, 3, F_IINV
	.endr
	@ straddling a sector end; 511 and 1024 bytes
	.irp	o, 0x1E2, 0x1F0, 0x1FC, 0x1FE
	ENT	\o, 512, 0, F_IINV | F_PRES
	.endr
	.irp	o, 0, 2, 3, 30
	ENT	\o, 511, 0, F_IINV
	ENT	\o, 1024, 0, F_IINV | F_PRES
	ENT	\o, 1024, 1, F_IINV
	.endr
	@ a cached source (line fills of CS1)
	.irp	o, 0, 2, 6, 30
	ENT	\o, 512, 0, F_IINV | F_PRES, 1
	ENT	\o, 512, 1, 0, 1
	.endr
	@ small copies; a header then the body
	.irp	o, 0, 1, 2, 3
	ENT	\o, 2, 0, F_PRES
	ENT	\o, 7, 0, F_IINV
	ENT	\o, 15, 1, 0
	.endr
	.irp	o, 0, 2
	ENT	\o, 512, 0, F_IINV | F_PRES | F_HDR
	.endr
	@ a program between the runs: the sector's first, middle and last
	@ halfword (the last is in the beat buffer after the first run)
	.irp	o, 0, 2
	ENT	\o, 512, 0, F_IINV | F_PRES | F_PROG, 0, \o, 0x5A5A
	ENT	\o, 512, 0, F_PROG, 0, (\o + 0x100), 0xA5A5
	ENT	\o, 512, 0, F_PROG, 0, (\o + 0x1FE), 0x0F0F
	ENT	\o, 512, 1, F_PROG, 0, (\o + 0x1FE), 0x3C3C
	.endr
table_end:

	.data
prog_new: .word	0
