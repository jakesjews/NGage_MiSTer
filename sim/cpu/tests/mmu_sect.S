@ SPDX-License-Identifier: GPL-3.0-or-later
@ MMU with sections: translation, translation faults, domains (no access,
@ client, manager), access permissions with the S and R bits, user-mode
@ accesses (LDRT/STRT and USR mode), FSR (status and domain) and FAR,
@ prefetch aborts (FSR/FAR untouched), TLB flush after a remap.
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global	test_main
test_main:
	stmfd	sp!, {r4-r11, lr}
	VECTOR	VEC_SWI, swi_svc
	bl	mmu_on

	@ VA 0x10000000 -> PA 0x00400000 (SCRATCH)
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	0x10000000, r1
	TLBFLUSH
	ldr	r4, =0x10000000
	ldr	r5, =SCRATCH
	ldr	r0, =0xC0FFEE00
	str	r0, [r4, #0x10]
	ldr	r1, [r5, #0x10]
	CHECK	r1, 0xC0FFEE00
	ldr	r0, =0x12345678
	str	r0, [r5, #0x20]
	ldr	r1, [r4, #0x20]
	CHECK	r1, 0x12345678
	NOABT
	CHECKPOINT

	@ translation fault (section): FSR 0x05 (descriptor domain 0)
	ldr	r6, =0x20000000
	ldr	r0, [r6, #4]
	DABT	0x05, 0x20000004
	str	r0, [r6, #8]
	DABT	0x05, 0x20000008
	CHECKPOINT

	@ domain: VA 0x10100000 in domain 3; DACR domain 3 = 00 (no access)
	SECT	r1, 0x00400000, 3, 3, 0
	SETL1	0x10100000, r1
	TLBFLUSH
	ldr	r6, =0x10100000
	ldr	r0, [r6]
	DABT	0x39, 0x10100000
	ldr	r0, =0x00000041		@ domain 3 manager, 0 client
	mcr	p15, 0, r0, c3, c0, 0
	ldr	r0, [r6]		@ manager: no checks
	NOABT
	ldr	r0, =0x00000081		@ domain 3 = 10, reserved: no access
	mcr	p15, 0, r0, c3, c0, 0
	str	r0, [r6]
	DABT	0x39, 0x10100000
	ldr	r0, =0x00000041
	mcr	p15, 0, r0, c3, c0, 0
	CHECKPOINT

	@ permissions (client domain 0) on VA 0x10200000.. with AP 0..2
	SECT	r1, 0x00400000, 0, 0, 0	@ AP 00
	SETL1	0x10200000, r1
	SECT	r1, 0x00400000, 1, 0, 0	@ AP 01: privileged RW
	SETL1	0x10300000, r1
	SECT	r1, 0x00400000, 2, 0, 0	@ AP 10: user read-only
	SETL1	0x10400000, r1
	TLBFLUSH
	ldr	r6, =0x10200000
	ldr	r7, =0x10300000
	ldr	r8, =0x10400000
	ldr	r0, [r6]		@ AP 00, S=R=0: no access
	DABT	0x0D, 0x10200000
	ldr	r0, [r7]		@ AP 01, privileged
	NOABT
	str	r0, [r7]
	NOABT
	ldrt	r0, [r7]		@ as user: fault
	DABT	0x0D, 0x10300000
	ldrt	r0, [r8]		@ AP 10, user read
	NOABT
	strt	r0, [r8]		@ user write: fault
	DABT	0x0D, 0x10400000
	str	r0, [r8]		@ privileged write
	NOABT
	CHECKPOINT

	@ S and R with AP 00: S = privileged read-only, R = read-only for all
	mrc	p15, 0, r9, c1, c0, 0
	orr	r0, r9, #CR_S
	mcr	p15, 0, r0, c1, c0, 0
	TLBFLUSH
	ldr	r0, [r6]		@ privileged read
	NOABT
	str	r0, [r6]		@ privileged write: fault
	DABT	0x0D, 0x10200000
	ldrt	r0, [r6]		@ user: fault
	DABT	0x0D, 0x10200000
	orr	r0, r9, #CR_R
	mcr	p15, 0, r0, c1, c0, 0
	TLBFLUSH
	ldrt	r0, [r6]		@ user read
	NOABT
	strt	r0, [r6]
	DABT	0x0D, 0x10200000
	mcr	p15, 0, r9, c1, c0, 0
	TLBFLUSH
	CHECKPOINT

	@ USR mode itself
	msr	cpsr_c, #(M_USR | PSR_I | PSR_F)
	ldr	r0, [r8]		@ AP 10 read
	str	r0, [r8]		@ write: fault
	swi	0
	DABT	0x0D, 0x10400000
	ldr	r0, [r8]
	NOABT
	CHECKPOINT

	@ a prefetch abort leaves FSR and FAR alone
	ldr	r0, =0x0000ABCD
	mcr	p15, 0, r0, c5, c0, 0
	mcr	p15, 0, r0, c6, c0, 0
	ldr	r10, =ab_state
	adr	r0, 1f
	str	r0, [r10, #20]
	ldr	r0, =0x20000000
	mov	pc, r0
1:	ldr	r10, =ab_state
	ldr	r0, [r10, #24]
	CHECK	r0, 2
	ldr	r0, [r10, #4]		@ LR_abt = faulting address + 4
	CHECK	r0, 0x20000004
	mrc	p15, 0, r0, c5, c0, 0
	CHECK	r0, 0xABCD
	mrc	p15, 0, r0, c6, c0, 0
	CHECK	r0, 0xABCD
	bl	ab_clear
	CHECKPOINT

	@ remap a section and flush: the new mapping is used
	ldr	r0, =0xAAAA5555
	str	r0, [r5, #0x100]	@ PA 0x00400100
	ldr	r0, =0x5555AAAA
	ldr	r1, =0x00500100
	str	r0, [r1]
	ldr	r0, [r4, #0x100]
	CHECK	r0, 0xAAAA5555
	SECT	r1, 0x00500000, 3, 0, 0
	SETL1	0x10000000, r1
	TLBFLUSH
	ldr	r0, [r4, #0x100]
	CHECK	r0, 0x5555AAAA
	SECT	r1, 0x00400000, 3, 0, 0
	SETL1	0x10000000, r1
	mov	r0, #0
	mcr	p15, 0, r0, c8, c6, 1	@ D-TLB entry (flushes the D-TLB here)
	ldr	r0, [r4, #0x100]
	CHECK	r0, 0xAAAA5555
	CHECKPOINT

	ldmfd	sp!, {r4-r11, pc}

swi_svc:				@ SWI: return in SVC mode
	mrs	r12, spsr
	bic	r12, r12, #0x1F
	orr	r12, r12, #(M_SVC | PSR_I | PSR_F)
	msr	spsr_cxsf, r12
	movs	pc, lr
	.ltorg
