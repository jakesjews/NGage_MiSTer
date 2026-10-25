@ SPDX-License-Identifier: GPL-3.0-or-later
@ Block copies from an UNCACHED source (the flash window's class: C=0,B=0,
@ long latency) to a CACHED destination, then a consumer reads the copied
@ words back. This is the LFFS/file-server read path's shape: a sector is
@ moved out of the memory-mapped flash into the server's buffer, often
@ from a source misaligned 2 mod 4 (the C: Cdbv2.dat sectors), then the
@ store code reads the buffer.
@
@ The real path (medint.pdd 0x50381864) copies a whole 0x200-byte sector
@ in one EUser Mem::Copy (0x503A1D38). Its sequence is reproduced in
@ `mcopy` below: dest-alignment head bytes chosen by msr CPSR_f; for a
@ source k mod 4 (k != 0) one aligned word, then 32-byte blocks of
@ ldm 8 words + a carried lsr/orr-lsl chain + stm 8 words, msr-chosen
@ 16/8/4-byte tails and 0-2 tail bytes; for k = 0, eight back-to-back
@ ldm/stm pairs per 256 bytes and msr-chosen tails; n <= 15 jumps
@ (sub pc, ip, r2, lsl #3) into an unrolled ldrb/strb run. memmove
@ semantics: src < dst takes the descending copy (ldmdb/stmdb, lsl/orr-
@ lsr chain; ldrb/strb with pre-decrement for n <= 15).
@
@ Cases (dest line: present / departing - its set's other way made MRU,
@ then a store miss to a third tag evicts it just before the copy - /
@ absent; each run cold then warm):
@   m 1  word-at-a-time shift-merge (ldr per source word), n 512/1024,
@        k 0-3 (k 0 = plain word copy)
@   m 4  plain 8-word ldm/stm loop, k 0
@   m 2  mcopy ascending, m 3 mcopy descending: k 0-3, n 512, 1024 (crosses
@        1 KB) and 511 (every tail), source uncached (c 0) or cached (c 1)
@   m 2/3 with a misaligned dest (d 1-3: the head bytes), k 0 and 2
@   m 2/3 small copies, n 1/2/3/7/15 (the computed jump), k 0-3, d 0/3
@   m 5  a 2-byte copy then the 510-byte rest (an LFFS header, then the
@        body), k 0-3, n 512
@ Each copy is compared word for word against a byte-loop reference copy
@ of the same bytes (ground truth, core-independent), and the consumer
@ sums both. Fail: case<<8 | 1 (a word wrong) | 2 (the sum wrong).
@ DST/REF are zeroed in memory (after a clean+invalidate) before each run.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000			@ uncached alias of PA 0x00400000
	.equ	SRC, 0x004C0000		@ source (within the UNC-aliased MB)
	.equ	DST, 0x00410000			@ cached test destination
	.equ	REF, 0x00414000			@ cached reference destination
	.equ	XB1, 0x00420000			@ DST set, other way (cached)
	.equ	XB2, 0x00440000			@ DST set, third tag (cached)
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_CASE, SIG_DATA + 8
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	@ r0 = dst (word aligned), r1 = src+k, r2 = n bytes.
	@ Clobbers r3-r10, ip, lr; r11 (pass) is preserved.
	.macro	COPY m
	.if \m == 0
1:	ldrb	r3, [r1], #1		@ byte loop: the reference copy
	strb	r3, [r0], #1
	subs	r2, r2, #1
	bne	1b
	.elseif \m == 1
	@ word-at-a-time shift-merge: aligned loads reassembled by 8*k, one
	@ output word per source word carried in r9. For k = 0 the shift is 0
	@ and lr = 32 (ARM register LSL #32 = 0): a plain word copy.
	and	ip, r1, #3
	bic	r1, r1, #3
	mov	ip, ip, lsl #3		@ shift = 8*k
	rsb	lr, ip, #32		@ 32 - 8*k
	ldr	r9, [r1], #4		@ previous aligned word
1:	ldr	r10, [r1], #4		@ next aligned word
	mov	r3, r9, lsr ip
	orr	r3, r3, r10, lsl lr
	str	r3, [r0], #4
	mov	r9, r10
	subs	r2, r2, #4
	bne	1b
	.else
1:	ldmia	r1!, {r3, r4, r5, r6, r7, r8, r9, r10}
	stmia	r0!, {r3, r4, r5, r6, r7, r8, r9, r10}
	subs	r2, r2, #32
	bne	1b
	.endif
	.endm

	@ m, k (source mod 4), n (bytes), ts (0 present, 1 departing,
	@ 2 absent), c (1: cached source), d (dest offset). m 4 only k 0.
	.macro	CASE m, k, n, ts, c=0, d=0
	.if (\m == 4) && (\k != 0)
	.exitm
	.endif
	mov	r11, #2
.Lagain\@:
	bl	zero_bufs
	@ reference: a byte-loop copy of the same bytes (ground truth)
	ldr	r0, =(REF + \d)
	ldr	r1, =(UNC + SRC - 0x00400000 + \k)
	ldr	r2, =\n
	COPY	0
	mov	r1, #\ts
	bl	set_state		@ r4 = cacheable evictor of DST's set
	.if \ts == 1
	mov	r3, #0
	str	r3, [r4]		@ store miss evicts DST's LRU first line
	.endif
	@ the copy under test, to DST
	ldr	r0, =(DST + \d)
	.if \c
	ldr	r1, =(SRC + \k)
	.else
	ldr	r1, =(UNC + SRC - 0x00400000 + \k)
	.endif
	ldr	r2, =\n
	.if \m == 2
	bl	mcopy
	.elseif (\m == 3) && (\n > 15)
	bl	mcopy_down
	.elseif \m == 3
	bl	mcopy_sdown
	.elseif \m == 5
	mov	r2, #2			@ the header ...
	bl	mcopy
	ldr	r0, =(DST + \d + 2)	@ ... then the body
	.if \c
	ldr	r1, =(SRC + \k + 2)
	.else
	ldr	r1, =(UNC + SRC - 0x00400000 + \k + 2)
	.endif
	ldr	r2, =(\n - 2)
	bl	mcopy
	.else
	COPY	\m
	.endif
	@ consumer: DST vs REF word for word, and sum both
	ldr	r5, =DST
	ldr	r6, =REF
	ldr	r7, =((\n + \d + 3) / 4)
	mov	r8, #0
	mov	r9, #0
	mov	r10, #0
.Lcmp\@:
	ldr	r0, [r5], #4
	ldr	r1, [r6], #4
	add	r9, r9, r0
	add	r10, r10, r1
	cmp	r0, r1
	orrne	r8, r8, #1
	subs	r7, r7, #1
	bne	.Lcmp\@
	cmp	r9, r10
	orrne	r8, r8, #2
	mov	r0, r8
	bl	verify
	subs	r11, r11, #1
	bne	.Lagain\@
	ldr	r0, =RES_CASE
	ldr	r1, [r0]
	add	r1, r1, #1
	str	r1, [r0]
	b	.Lend\@
	.ltorg
.Lend\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3		@ RAM cached (code, dest, ref)
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0		@ UNC: uncached alias of RAM
	SETL1	UNC, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	@ fill the source through the uncached alias: byte b = (b*0x6D+0x3B)&FF
	ldr	r1, =(UNC + SRC - 0x00400000)
	mov	r2, #0x3B
	mov	r3, #0
1:	and	r4, r2, #0xFF
	strb	r4, [r1, r3]
	add	r2, r2, #0x6D
	add	r3, r3, #1
	ldr	r6, =(0x1000 + 8)
	cmp	r3, r6
	bne	1b
	ldr	r0, =RES_FAILS
	mov	r1, #0
	str	r1, [r0]
	str	r1, [r0, #4]
	str	r1, [r0, #8]
	@ bus latency is set by the model's --lat flag (run at 0:0, 8:12, 16:40)
	.irp m, 1, 4
	.irp k, 0, 1, 2, 3
	.irp n, 512, 1024
	.irp ts, 0, 1, 2
	CASE	\m, \k, \n, \ts
	.endr
	.endr
	.endr
	.endr
	@ Mem::Copy's own sequence, ascending (m 2) and descending (m 3)
	.irp m, 2, 3
	.irp c, 0, 1
	.irp k, 0, 1, 2, 3
	.irp n, 512, 1024, 511
	.irp ts, 0, 1, 2
	CASE	\m, \k, \n, \ts, \c, 0
	.endr
	.endr
	.endr
	.endr
	.endr
	@ ... with a misaligned destination (the head bytes)
	.irp m, 2, 3
	.irp d, 1, 2, 3
	.irp k, 0, 2
	CASE	\m, \k, 512, 2, 0, \d
	.endr
	.endr
	.endr
	@ ... small copies (the computed jump into ldrb/strb)
	.irp m, 2, 3
	.irp d, 0, 3
	.irp k, 0, 1, 2, 3
	.irp n, 1, 2, 3, 7, 15
	CASE	\m, \k, \n, 2, 0, \d
	.endr
	.endr
	.endr
	.endr
	@ an LFFS header (2 bytes) then the body
	.irp k, 0, 1, 2, 3
	.irp ts, 0, 1, 2
	CASE	5, \k, 512, \ts
	.endr
	.endr
	ldr	r0, =RES_FIRST
	ldr	r0, [r0]
	CHECK	r0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

@ Mem::Copy (EUser 0x503A1D38), r0 = dst, r1 = src, r2 = n. Ascending
@ when src >= dst; the descending half is also entered directly as
@ mcopy_down (the src < dst case). Returns as the ROM does (bx lr).
	@ ascending 32-byte block for a source sh/8 mod 4: fp carries the
	@ previous aligned word
	.macro	UPBLK sh
	mov	r3, fp, lsr #\sh
	ldmia	r1!, {r4, r5, r6, r7, r8, r9, sl, fp}
	orr	r3, r3, r4, lsl #(32 - \sh)
	mov	r4, r4, lsr #\sh
	orr	r4, r4, r5, lsl #(32 - \sh)
	mov	r5, r5, lsr #\sh
	orr	r5, r5, r6, lsl #(32 - \sh)
	mov	r6, r6, lsr #\sh
	orr	r6, r6, r7, lsl #(32 - \sh)
	mov	r7, r7, lsr #\sh
	orr	r7, r7, r8, lsl #(32 - \sh)
	mov	r8, r8, lsr #\sh
	orr	r8, r8, r9, lsl #(32 - \sh)
	mov	r9, r9, lsr #\sh
	orr	r9, r9, sl, lsl #(32 - \sh)
	mov	sl, sl, lsr #\sh
	orr	sl, sl, fp, lsl #(32 - \sh)
	stmia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endm

	.macro	UPMIS sh
	movs	lr, r2, lsr #5
	beq	2f
1:	UPBLK	\sh
	subs	lr, lr, #1
	bne	1b
2:	mov	r2, r2, lsl #26
	msr	CPSR_f, r2
	moveq	r3, fp, lsr #\sh
	ldmeqia	r1!, {r4, r5, r6, fp}
	orreq	r3, r3, r4, lsl #(32 - \sh)
	moveq	r4, r4, lsr #\sh
	orreq	r4, r4, r5, lsl #(32 - \sh)
	moveq	r5, r5, lsr #\sh
	orreq	r5, r5, r6, lsl #(32 - \sh)
	moveq	r6, r6, lsr #\sh
	orreq	r6, r6, fp, lsl #(32 - \sh)
	stmeqia	r0!, {r3, r4, r5, r6}
	movcs	r3, fp, lsr #\sh
	ldmcsia	r1!, {r4, fp}
	orrcs	r3, r3, r4, lsl #(32 - \sh)
	movcs	r4, r4, lsr #\sh
	orrcs	r4, r4, fp, lsl #(32 - \sh)
	stmcsia	r0!, {r3, r4}
	movvs	r3, fp, lsr #\sh
	ldmvsia	r1!, {fp}
	orrvs	r3, r3, fp, lsl #(32 - \sh)
	stmvsia	r0!, {r3}
	b	.Lup_bytes
	.endm

	@ descending 32-byte block: r3 carries the previous (higher) word
	.macro	DNBLK sh
	mov	fp, r3, lsl #(32 - \sh)
	ldmdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	orr	fp, fp, sl, lsr #\sh
	mov	sl, sl, lsl #(32 - \sh)
	orr	sl, sl, r9, lsr #\sh
	mov	r9, r9, lsl #(32 - \sh)
	orr	r9, r9, r8, lsr #\sh
	mov	r8, r8, lsl #(32 - \sh)
	orr	r8, r8, r7, lsr #\sh
	mov	r7, r7, lsl #(32 - \sh)
	orr	r7, r7, r6, lsr #\sh
	mov	r6, r6, lsl #(32 - \sh)
	orr	r6, r6, r5, lsr #\sh
	mov	r5, r5, lsl #(32 - \sh)
	orr	r5, r5, r4, lsr #\sh
	mov	r4, r4, lsl #(32 - \sh)
	orr	r4, r4, r3, lsr #\sh
	stmdb	r0!, {r4, r5, r6, r7, r8, r9, sl, fp}
	.endm

	.macro	DNMIS sh
	movs	lr, r2, lsr #5
	beq	2f
1:	DNBLK	\sh
	subs	lr, lr, #1
	bne	1b
2:	mov	r2, r2, lsl #26
	msr	CPSR_f, r2
	moveq	r7, r3, lsl #(32 - \sh)
	ldmeqdb	r1!, {r3, r4, r5, r6}
	orreq	r7, r7, r6, lsr #\sh
	moveq	r6, r6, lsl #(32 - \sh)
	orreq	r6, r6, r5, lsr #\sh
	moveq	r5, r5, lsl #(32 - \sh)
	orreq	r5, r5, r4, lsr #\sh
	moveq	r4, r4, lsl #(32 - \sh)
	orreq	r4, r4, r3, lsr #\sh
	stmeqdb	r0!, {r4, r5, r6, r7}
	movcs	r5, r3, lsl #(32 - \sh)
	ldmcsdb	r1!, {r3, r4}
	orrcs	r5, r5, r4, lsr #\sh
	movcs	r4, r4, lsl #(32 - \sh)
	orrcs	r4, r4, r3, lsr #\sh
	stmcsdb	r0!, {r4, r5}
	movvs	r4, r3, lsl #(32 - \sh)
	ldmvsdb	r1!, {r3}
	orrvs	r4, r4, r3, lsr #\sh
	stmvsdb	r0!, {r4}
	b	.Ldn_bytes
	.endm

mcopy:
	cmp	r2, #0
	cmpne	r0, r1
	addeq	r0, r0, r2
	bxeq	lr
	cmp	r2, #15
	bhi	1f
	cmp	r1, r0
	bhi	.Lsm_up
	b	mcopy_sdown
1:	cmp	r1, r0
	bcc	mcopy_down
	stmfd	sp!, {r4-r11, lr}
	movs	r3, r0, lsl #30		@ dest alignment -> head bytes
	rsbne	r3, r3, #0
	msr	CPSR_f, r3
	ldrmib	lr, [r1], #1
	strmib	lr, [r0], #1
	ldrmib	lr, [r1], #1
	strmib	lr, [r0], #1
	ldreqb	lr, [r1], #1
	streqb	lr, [r0], #1
	sub	r2, r2, r3, lsr #30
	ands	ip, r1, #3
	beq	.Lup_al
	bic	r1, r1, #3
	ldr	fp, [r1], #4
	cmp	ip, #2
	beq	.Lup2
	bhi	.Lup3
	UPMIS	8
.Lup2:	UPMIS	16
.Lup3:	UPMIS	24
.Lup_bytes:
	sub	r1, r1, #4
	mov	r2, r2, lsl #2
	msr	CPSR_f, r2
	add	r1, r1, ip
	ldrcsb	lr, [r1], #1
	strcsb	lr, [r0], #1
	ldrcsb	lr, [r1], #1
	strcsb	lr, [r0], #1
	ldrvsb	lr, [r1], #1
	strvsb	lr, [r0], #1
	ldmfd	sp!, {r4-r11, lr}
	bx	lr
.Lup_al:
	movs	ip, r2, lsr #8
	beq	2f
1:	.rept	8
	ldmia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	subs	ip, ip, #1
	bne	1b
	ands	r2, r2, #255
	beq	3f
2:	movs	r2, r2, lsl #24
	msr	CPSR_f, r2
	.rept	4
	ldmmiia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmmiia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	.rept	2
	ldmeqia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmeqia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	ldmcsia	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmcsia	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	ldmvsia	r1!, {r3, r4, r5, r6}
	stmvsia	r0!, {r3, r4, r5, r6}
	movs	r2, r2, lsl #4
	beq	3f
	msr	CPSR_f, r2
	ldmmiia	r1!, {r3, r4}
	stmmiia	r0!, {r3, r4}
	ldmeqia	r1!, {r3}
	stmeqia	r0!, {r3}
	ldrcsb	r3, [r1], #1
	strcsb	r3, [r0], #1
	ldrcsb	r3, [r1], #1
	strcsb	r3, [r0], #1
	ldrvsb	r3, [r1], #1
	strvsb	r3, [r0], #1
3:	ldmfd	sp!, {r4-r11, lr}
	bx	lr
.Lsm_up:				@ n <= 15, src > dst: the last n pairs
	adr	ip, 1f
	sub	pc, ip, r2, lsl #3
	.rept	15
	ldrb	ip, [r1], #1
	strb	ip, [r0], #1
	.endr
1:	bx	lr

mcopy_sdown:				@ n <= 15, src <= dst
	add	r0, r0, r2
	add	r1, r1, r2
	mov	r3, r0
	adr	ip, 1f
	sub	pc, ip, r2, lsl #3
	.rept	15
	ldrb	ip, [r1, #-1]!
	strb	ip, [r3, #-1]!
	.endr
1:	bx	lr

mcopy_down:
	add	r0, r0, r2
	add	r1, r1, r2
	stmfd	sp!, {r0, r4-r11, lr}
	mov	r3, r0, lsl #30		@ dest end alignment -> head bytes
	msr	CPSR_f, r3
	ldrmib	lr, [r1, #-1]!
	strmib	lr, [r0, #-1]!
	ldrmib	lr, [r1, #-1]!
	strmib	lr, [r0, #-1]!
	ldreqb	lr, [r1, #-1]!
	streqb	lr, [r0, #-1]!
	sub	r2, r2, r3, lsr #30
	ands	ip, r1, #3
	beq	.Ldn_al
	bic	r1, r1, #3
	ldr	r3, [r1]
	cmp	ip, #2
	beq	.Ldn2
	bhi	.Ldn3
	DNMIS	8
.Ldn2:	DNMIS	16
.Ldn3:	DNMIS	24
.Ldn_bytes:
	mov	r2, r2, lsl #2
	msr	CPSR_f, r2
	add	r1, r1, ip
	ldrcsb	lr, [r1, #-1]!
	strcsb	lr, [r0, #-1]!
	ldrcsb	lr, [r1, #-1]!
	strcsb	lr, [r0, #-1]!
	ldrvsb	lr, [r1, #-1]!
	strvsb	lr, [r0, #-1]!
	ldmfd	sp!, {r0, r4-r11, lr}
	bx	lr
.Ldn_al:
	movs	ip, r2, lsr #8
	beq	2f
1:	.rept	8
	ldmdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmdb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	subs	ip, ip, #1
	bne	1b
	ands	r2, r2, #255
	beq	3f
2:	movs	r2, r2, lsl #24
	msr	CPSR_f, r2
	.rept	4
	ldmmidb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmmidb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	.rept	2
	ldmeqdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmeqdb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	.endr
	ldmcsdb	r1!, {r3, r4, r5, r6, r7, r8, r9, sl}
	stmcsdb	r0!, {r3, r4, r5, r6, r7, r8, r9, sl}
	ldmvsdb	r1!, {r3, r4, r5, r6}
	stmvsdb	r0!, {r3, r4, r5, r6}
	movs	r2, r2, lsl #4
	beq	3f
	msr	CPSR_f, r2
	ldmmidb	r1!, {r3, r4}
	stmmidb	r0!, {r3, r4}
	ldreq	r3, [r1, #-4]!
	streq	r3, [r0, #-4]!
	ldrcsb	r3, [r1, #-1]!
	strcsb	r3, [r0, #-1]!
	ldrcsb	r3, [r1, #-1]!
	strcsb	r3, [r0, #-1]!
	ldrvsb	r3, [r1, #-1]!
	strvsb	r3, [r0, #-1]!
3:	ldmfd	sp!, {r0, r4-r11, lr}
	bx	lr

@ Clean+invalidate the D-cache, then zero DST and REF in memory through
@ their uncached aliases, so every compared word is deterministic.
zero_bufs:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r3, =(UNC + DST - 0x00400000)
	ldr	r1, =(UNC + REF - 0x00400000)
	mov	r2, #0x420
1:	str	r0, [r3], #4
	str	r0, [r1], #4
	subs	r2, r2, #4
	bne	1b
	mov	pc, lr
	.ltorg

@ r1 = ts. Cleans+invalidates the D-cache (REF written back), then: ts 0
@ DST's first line present (MRU); ts 1 DST's first line present then its
@ set's other way made MRU, so DST is LRU; ts 2 DST absent. r4 = a
@ cacheable third-tag line of DST's set (the evictor for ts 1).
set_state:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	mcr	p15, 0, r0, c7, c6, 0
	ldr	r3, =DST
	ldr	r0, =0x1FF0
	and	r0, r3, r0
	ldr	r4, =XB2
	add	r4, r4, r0
	ldr	r6, =XB1
	add	r6, r6, r0
	cmp	r1, #2
	ldrne	r0, [r3]		@ DST first line present
	cmp	r1, #1
	ldreq	r0, [r6]		@ other way MRU -> DST LRU
	mov	pc, lr
	.ltorg

@ r0 = error bits; r11 = pass (2 cold, 1 warm); case number at RES_CASE.
@ Table at RES_TABLE: 16 bytes a case (cold error, warm error, last).
verify:
	ldr	r2, =RES_CASE
	ldr	r2, [r2]
	ldr	r3, =RES_TABLE
	add	r3, r3, r2, lsl #4
	cmp	r11, #2
	streq	r0, [r3]
	strne	r0, [r3, #4]
	str	r0, [r3, #8]
	cmp	r0, #0
	moveq	pc, lr
	ldr	r3, =RES_FAILS
	ldr	r1, [r3]
	add	r1, r1, #1
	str	r1, [r3]
	ldr	r1, [r3, #4]
	cmp	r1, #0
	orreq	r1, r0, r2, lsl #8
	streq	r1, [r3, #4]
	mov	pc, lr
	.ltorg
