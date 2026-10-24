@ SPDX-License-Identifier: GPL-3.0-or-later
@ A store, then a reload through the D-cache 0-6 instructions later, in
@ every state the shared cache can hold that line in:
@
@ store (sk): 0 str word 1, 1 strh word 1 upper half, 2 strb word 1 byte 1,
@	3 stmia {r0-r2} words 0-2
@ reload (rk): 0 the same word (sk 3: word 2, its last), 1 word 3 (not
@	stored), 2 ldrb word 1 byte 1, 3 ldrh word 1 upper half
@ line state (ms): 0 present, 1 present and dirty (word 3), 2 absent (the
@	store allocates and is merged into its fill), 3 present as the LRU
@	way and departing under a store miss to the same set, 4 dirty, LRU
@	and departing under a load miss (its write-back deferred behind the
@	fill), 5 being filled by a load miss to word 3, 6 present through a
@	write-through alias (the store goes to the bus and updates the line)
@ gap (g): 0, 1, 2, 4 or 6 instructions between the store and the reload
@ mode (md): 0 SVC, 1 USR, 2 SVC store, mode change to UND, UND reload
@ Then the EKA1 context save and resume (0x50321624-0x50321670) copied
@ literally in UND mode: stm ^, the PC and SPSR words stored and reloaded
@ into msr spsr, ldm ^ / ldm {..pc}^ and movs pc, for a USR and a SYS
@ thread, over save-area lines present, dirty, absent and departing.
@ Each case runs twice (cold and warm I-cache), at the bench latency and
@ at a fixed latency of 24. Values are computed here, independently of
@ either core. The test fails with the first case: number << 8 | 1.
@@ qemu: no
	.include "test.inc"
	.include "mmu.inc"
	.equ	UNC, 0x20000000
	.equ	WTA, 0x10000000		@ write-through alias of 0x00400000
	.equ	LINE, 0x00430A00	@ the line (set 0xA0)
	.equ	X1, 0x00470A00		@ the other way of its set
	.equ	X2, 0x00450A00		@ the line that evicts it
	.equ	W0, 0x11223300
	.equ	W1, 0x44556610
	.equ	W2, 0x77889920
	.equ	W3, 0xAABBCC30
	.equ	DM, 0xD0D0D0D3		@ word 3 in the dirty states
	.equ	S0, 0xA1B2C3D4
	.equ	S1, 0xE5F60718
	.equ	S2, 0x293A4B5C
	@ the kernel case: thread block (two pointers to it, as the kernel's
	@ current and next thread), its save area at +0x124
	.equ	TPTR, 0x00410100
	.equ	THREAD, 0x00412000
	.equ	SAVE, THREAD + 0x124
	.equ	RES_FAILS, SIG_DATA
	.equ	RES_FIRST, SIG_DATA + 4
	.equ	RES_TABLE, SIG_DATA + 0x10
	.text
	.arm
	.global	test_main

	@ word 1 after each store kind
	.equ	WA_0, S0
	.equ	WA_1, (W1 & 0x0000FFFF) | ((S0 & 0xFFFF) << 16)
	.equ	WA_2, (W1 & 0xFFFF00FF) | ((S0 & 0xFF) << 8)
	.equ	WA_3, S1

	.macro	CASE sk, rk, ms, g, md
	mov	r8, #2
.Lagain\@:
	mov	r1, #\ms
	bl	prepare			@ r9 = LINE (or its WT alias), r4 = X2
	ldr	r0, =S0
	ldr	r1, =S1
	ldr	r2, =S2
	.if \md == 1
	msr	cpsr_c, #0xD0
	.endif
	@ the setup access
	.if \ms == 3
	str	r3, [r4]
	.elseif \ms == 4
	ldr	r6, [r4]
	.elseif \ms == 5
	ldr	r6, [r9, #12]
	.endif
	@ the store
	.if \sk == 0
	str	r0, [r9, #4]
	.elseif \sk == 1
	strh	r0, [r9, #6]
	.elseif \sk == 2
	strb	r0, [r9, #5]
	.else
	stmia	r9, {r0-r2}
	.endif
	.if \md == 2
	msr	cpsr_c, #0xDB
	.endif
	.rept	\g
	mov	r3, r3
	.endr
	@ the reload
	.if \rk == 0
	.if \sk == 3
	ldr	r7, [r9, #8]
	.else
	ldr	r7, [r9, #4]
	.endif
	.elseif \rk == 1
	ldr	r7, [r9, #12]
	.elseif \rk == 2
	ldrb	r7, [r9, #5]
	.else
	ldrh	r7, [r9, #6]
	.endif
	mov	r0, r7
	.if \md == 1
	ldr	r1, =to_svc
	mov	r6, #VEC_SWI
	str	r1, [r6]
	svc	#0
	.endif
	msr	cpsr_c, #0xD3
	.if \rk == 0
	.if \sk == 3
	ldr	r2, =S2
	.else
	ldr	r2, =WA_\sk
	.endif
	.elseif \rk == 1
	.if \ms == 1 || \ms == 4
	ldr	r2, =DM
	.else
	ldr	r2, =W3
	.endif
	.elseif \rk == 2
	mov	r2, #((WA_\sk >> 8) & 0xFF)
	.else
	ldr	r2, =((WA_\sk >> 16) & 0xFFFF)
	.endif
	bl	verify
	subs	r8, r8, #1
	bne	.Lagain\@
	add	r10, r10, #1
	b	.Lend\@
	.ltorg
.Lend\@:
	.endm

	@ The kernel's context save and resume, in UND mode, for one thread
	@ whose saved SPSR is \psr (0xD0 USR or 0xDF SYS), its save area in
	@ line state \ms (0 present, 1 dirty, 2 absent, 3 departing).
	.macro	KCASE psr, ms
	mov	r8, #2
.Lkagain\@:
	@ lr_usr = the resume target's lr; the user registers to save
	msr	cpsr_c, #0xDF
	adr	lr, .Lkok\@
	ldr	sp, =0x0055AA00
	msr	cpsr_c, #0xD3
	mov	r1, #(0x10 + \ms)
	bl	prepare			@ r4 = the evictor of the save area's PC line
	ldr	r1, =0x01010101
	ldr	r2, =0x02020202
	ldr	r5, =0x05050505
	msr	cpsr_c, #0xDB		@ UND, as after pop {r0, lr}
	mov	lr, #\psr		@ lr = the popped SPSR
	.if \ms == 3
	str	r3, [r4]
	.endif
	ldr	ip, =TPTR + 4		@ 0x50321624: the current thread
	ldr	ip, [ip]
	add	ip, ip, #0x124
	stm	ip, {r0-r14}^
	adr	r0, .Lkbx\@		@ sub r0, pc, #0x1c: its saved PC
	str	r0, [ip, #0x3c]
	str	lr, [ip, #0x40]
	ldr	lr, =TPTR		@ 0x50321640: the next thread (the same)
	ldr	lr, [lr]
	add	lr, lr, #0x124
	ldr	r0, [lr, #0x40]
	msr	spsr_fc, r0
	tst	r0, #0xF
	ldr	r0, [lr, #0x44]
	mcr	p15, 0, r0, c3, c0, 0
	ldmnefd	lr, {r0-r15}^
	ldmfd	lr, {r0-r14}^
	mov	r0, r0
	ldr	lr, [lr, #0x3c]
	movs	pc, lr
	b	.Lkbad\@
.Lkbx\@:
	bx	lr			@ 0x50321620, in the resumed mode
	b	.Lkbad\@
.Lkok\@:
	@ resumed: mode and the restored registers
	mrs	r0, cpsr
	and	r0, r0, #0x1F
	cmp	r0, #(\psr & 0x1F)
	movne	r0, #2
	bne	.Lkafter\@
	ldr	r0, =0x01010101
	cmp	r1, r0
	ldreq	r0, =0x02020202
	cmpeq	r2, r0
	ldreq	r0, =0x05050505
	cmpeq	r5, r0
	moveq	r0, #1
	movne	r0, #3
	b	.Lkafter\@
.Lkbad\@:
	mov	r0, #4
.Lkafter\@:
	ldr	r1, =to_svc
	mov	r6, #VEC_SWI
	str	r1, [r6]
	mrs	r1, cpsr
	and	r1, r1, #0x1F
	cmp	r1, #0x10
	svceq	#0
	msr	cpsr_c, #0xD3
	mov	r1, #1
	mcr	p15, 0, r1, c3, c0, 0
	mov	r2, #1
	bl	verify
	subs	r8, r8, #1
	bne	.Lkagain\@
	add	r10, r10, #1
	b	.Lkend\@
	.ltorg
.Lkend\@:
	.endm

test_main:
	stmfd	sp!, {r4-r11, lr}
	bl	mmu_on
	SECT	r1, 0, 3, 0, 3
	SETL1	0, r1
	SECT	r1, 0x00400000, 3, 0, 3
	SETL1	0x00400000, r1
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	UNC, r1
	SECT	r1, 0x00400000, 3, 0, 2
	SETL1	WTA, r1
	SECT	r1, BENCH, 3, 0, 0
	SETL1	BENCH, r1
	TLBFLUSH
	mrc	p15, 0, r0, c1, c0, 0
	orr	r0, r0, #(CR_C | CR_W)
	orr	r0, r0, #CR_I
	mcr	p15, 0, r0, c1, c0, 0
	@ thread pointers (current at +4, next at +0), both to THREAD
	ldr	r0, =TPTR
	ldr	r1, =THREAD
	str	r1, [r0]
	str	r1, [r0, #4]
	ldr	r0, =(SAVE + 0x44)	@ the thread's saved DACR
	mov	r1, #1
	str	r1, [r0]
	ldr	r11, =RES_TABLE
	ldr	r0, =RES_FAILS
	mov	r1, #0
	str	r1, [r0]
	str	r1, [r0, #4]
	mov	r10, #0
	@ the saved config counter: 1 bench latency, 0 latency 24
	mov	r1, #1
	ldr	r0, =CONFIG
	str	r1, [r0]
config:
	ldr	r0, =CONFIG
	ldr	r1, [r0]
	cmp	r1, #1
	moveq	r1, #0
	movne	r1, #24
	ldr	r0, =BENCH
	str	r1, [r0, #BENCH_LATENCY]
	b	cases
	.ltorg
cases:
	.irp md, 0, 1, 2
	.irp ms, 0, 1, 2, 3, 4, 5, 6
	.irp sk, 0, 1, 2, 3
	.irp rk, 0, 1, 2, 3
	.irp g, 0, 1, 2, 4, 6
	CASE	\sk, \rk, \ms, \g, \md
	.endr
	.endr
	.endr
	.endr
	.endr
	.irp psr, 0xD0, 0xDF
	.irp ms, 0, 1, 2, 3
	KCASE	\psr, \ms
	.endr
	.endr
	ldr	r0, =CONFIG
	ldr	r1, [r0]
	subs	r1, r1, #1
	str	r1, [r0]
	bpl	config
	ldr	r0, =BENCH
	mov	r1, #0
	str	r1, [r0, #BENCH_LATENCY]
	ldr	r0, =RES_FIRST
	ldr	r0, [r0]
	CHECK	r0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldmfd	sp!, {r4-r11, pc}
	.ltorg

to_svc:
	mov	pc, lr

@ r1 = line state (0-6 for CASE; 0x10 + 0-3 for KCASE). Writes the
@ line's words through the uncached alias, cleans and invalidates the
@ D-cache, then builds the state. Returns r9 = the line (or its WT
@ alias), r4 = the evicting line, r3 = 0.
prepare:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c10, 0
	ldr	r6, =(UNC + LINE - 0x00400000)
	ldr	r0, =W0
	str	r0, [r6]
	ldr	r0, =W1
	str	r0, [r6, #4]
	ldr	r0, =W2
	str	r0, [r6, #8]
	ldr	r0, =W3
	str	r0, [r6, #12]
	ldr	r9, =LINE
	ldr	r4, =X2
	ldr	r5, =X1
	ldr	r7, =DM
	ldr	r12, =(SAVE + 0x3C)	@ the save area's PC/SPSR line
	mov	r0, #0
	mcr	p15, 0, r0, c7, c6, 0
	cmp	r1, #0x10
	bhs	prepare_k
	cmp	r1, #6
	ldreq	r9, =(LINE + WTA - 0x00400000)
	cmp	r1, #2
	cmpne	r1, #5
	ldrne	r0, [r9]		@ present
	cmp	r1, #1
	cmpne	r1, #4
	streq	r7, [r9, #12]		@ dirty
	cmp	r1, #3
	cmpne	r1, #4
	ldreq	r0, [r5]		@ the other way, MRU
	mov	r3, #0
	mov	pc, lr
prepare_k:
	@ save area lines: present (0), dirty (1), absent (2), the PC/SPSR
	@ line LRU beside the other way and departing (3)
	ldr	r0, =TPTR
	ldr	r0, [r0]
	and	r1, r1, #0xF
	cmp	r1, #2
	beq	1f
	ldr	r6, =SAVE
	ldr	r0, [r6]
	ldr	r0, [r6, #0x10]
	ldr	r0, [r6, #0x20]
	ldr	r0, [r6, #0x30]
	ldr	r0, [r6, #0x40]
	cmp	r1, #1
	streq	r7, [r6, #0x3C]
	streq	r7, [r6, #0x40]
1:	cmp	r1, #3
	addeq	r0, r12, #0x2000	@ the other way of the PC/SPSR line's set
	ldreq	r0, [r0]
	add	r4, r12, #0x4000	@ the evictor (same set)
	ldr	r0, =TPTR
	ldr	r0, [r0]
	mov	r3, #0
	mov	pc, lr
	.ltorg

@ r0 = observed, r2 = expected; r8 = pass, r10 = case, r11 = table
verify:
	mov	r3, #0
	cmp	r0, r2
	movne	r3, #1
	add	r6, r11, r10, lsl #4
	cmp	r8, #2
	streq	r3, [r6]
	strne	r3, [r6, #4]
	str	r0, [r6, #8]
	str	r2, [r6, #12]
	cmp	r3, #0
	moveq	pc, lr
	ldr	r6, =RES_FAILS
	ldr	r1, [r6]
	add	r1, r1, #1
	str	r1, [r6]
	ldr	r1, [r6, #4]
	cmp	r1, #0
	orreq	r1, r3, r10, lsl #8
	streq	r1, [r6, #4]
	mov	pc, lr
	.ltorg

	.data
	.align	2
CONFIG:	.word	0
