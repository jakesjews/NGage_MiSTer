@ SPDX-License-Identifier: GPL-3.0-or-later
@ ARM9 retirement windows. Three invocations warm caches, next two are checked.
@ Table expected counts describe this implementation; docs/ARM9.md separates
@ completed TRM rows from explicit, still-unresolved serial-memory deviations.
@@ bench: --arm9-cycles --arm9-cycle-model arm9v2/arm9_cycles-cycles.txt
	.include "test.inc"
	.include "mmu.inc"
	.text
	.arm
	.global test_main
test_main:
	stmfd sp!,{r4-r11,lr}
	bl mmu_on
	ldr r0,=TTB
	ldr r1,=0x00000c1e
	mov r2,#16
1:	str r1,[r0],#4
	add r1,r1,#0x00100000
	subs r2,r2,#1
	bne 1b
	TLBFLUSH
	mrc p15,0,r0,c1,c0,0
	orr r0,r0,#(CR_C|CR_W)
	orr r0,r0,#CR_I
	mcr p15,0,r0,c1,c0,0
	ldr r9,=SCRATCH
	bl case_dp
	bl case_dp
	bl case_dp
	bl case_dp
	bl case_dp
	bl case_dp_dependency
	bl case_dp_dependency
	bl case_dp_dependency
	bl case_dp_dependency
	bl case_dp_dependency
	bl case_dp_flags
	bl case_dp_flags
	bl case_dp_flags
	bl case_dp_flags
	bl case_dp_flags
	bl case_dp_regshift
	bl case_dp_regshift
	bl case_dp_regshift
	bl case_dp_regshift
	bl case_dp_regshift
	bl case_failed_regshift
	bl case_failed_regshift
	bl case_failed_regshift
	bl case_failed_regshift
	bl case_failed_regshift
	bl case_dp_pc
	bl case_dp_pc
	bl case_dp_pc
	bl case_dp_pc
	bl case_dp_pc
	bl case_dp_regshift_pc
	bl case_dp_regshift_pc
	bl case_dp_regshift_pc
	bl case_dp_regshift_pc
	bl case_dp_regshift_pc
	bl case_ldr_independent
	bl case_ldr_independent
	bl case_ldr_independent
	bl case_ldr_independent
	bl case_ldr_independent
	bl case_ldr_alu
	bl case_ldr_alu
	bl case_ldr_alu
	bl case_ldr_alu
	bl case_ldr_alu
	bl case_ldr_base
	bl case_ldr_base
	bl case_ldr_base
	bl case_ldr_base
	bl case_ldr_base
	bl case_ldr_shift_amount
	bl case_ldr_shift_amount
	bl case_ldr_shift_amount
	bl case_ldr_shift_amount
	bl case_ldr_shift_amount
	bl case_ldr_shift_value
	bl case_ldr_shift_value
	bl case_ldr_shift_value
	bl case_ldr_shift_value
	bl case_ldr_shift_value
	bl case_ldr_store
	bl case_ldr_store
	bl case_ldr_store
	bl case_ldr_store
	bl case_ldr_store
	bl case_ldrb
	bl case_ldrb
	bl case_ldrb
	bl case_ldrb
	bl case_ldrb
	bl case_ldrh
	bl case_ldrh
	bl case_ldrh
	bl case_ldrh
	bl case_ldrh
	bl case_ldrsb
	bl case_ldrsb
	bl case_ldrsb
	bl case_ldrsb
	bl case_ldrsb
	bl case_ldrsh
	bl case_ldrsh
	bl case_ldrsh
	bl case_ldrsh
	bl case_ldrsh
	bl case_ldr_unaligned
	bl case_ldr_unaligned
	bl case_ldr_unaligned
	bl case_ldr_unaligned
	bl case_ldr_unaligned
	bl case_ldr_pc
	bl case_ldr_pc
	bl case_ldr_pc
	bl case_ldr_pc
	bl case_ldr_pc
	bl case_str
	bl case_str
	bl case_str
	bl case_str
	bl case_str
	bl case_ldm1
	bl case_ldm1
	bl case_ldm1
	bl case_ldm1
	bl case_ldm1
	bl case_stm1
	bl case_stm1
	bl case_stm1
	bl case_stm1
	bl case_stm1
	bl case_ldm3
	bl case_ldm3
	bl case_ldm3
	bl case_ldm3
	bl case_ldm3
	bl case_stm3
	bl case_stm3
	bl case_stm3
	bl case_stm3
	bl case_stm3
	bl case_ldm_pc
	bl case_ldm_pc
	bl case_ldm_pc
	bl case_ldm_pc
	bl case_ldm_pc
	bl case_swp
	bl case_swp
	bl case_swp
	bl case_swp
	bl case_swp
	bl case_swpb
	bl case_swpb
	bl case_swpb
	bl case_swpb
	bl case_swpb
	bl case_b
	bl case_b
	bl case_b
	bl case_b
	bl case_b
	bl case_bl
	bl case_bl
	bl case_bl
	bl case_bl
	bl case_bl
	bl case_bx
	bl case_bx
	bl case_bx
	bl case_bx
	bl case_bx
	bl case_mrs
	bl case_mrs
	bl case_mrs
	bl case_mrs
	bl case_mrs
	bl case_msr_flags
	bl case_msr_flags
	bl case_msr_flags
	bl case_msr_flags
	bl case_msr_flags
	bl case_msr_control
	bl case_msr_control
	bl case_msr_control
	bl case_msr_control
	bl case_msr_control
	bl case_mcr
	bl case_mcr
	bl case_mcr
	bl case_mcr
	bl case_mcr
	bl case_mrc
	bl case_mrc
	bl case_mrc
	bl case_mrc
	bl case_mrc
	bl case_mrc_use
	bl case_mrc_use
	bl case_mrc_use
	bl case_mrc_use
	bl case_mrc_use
	bl case_mrc_pc
	bl case_mrc_pc
	bl case_mrc_pc
	bl case_mrc_pc
	bl case_mrc_pc
	bl case_swi
	bl case_swi
	bl case_swi
	bl case_swi
	bl case_swi
	bl case_undefined
	bl case_undefined
	bl case_undefined
	bl case_undefined
	bl case_undefined
	bl case_cdp
	bl case_cdp
	bl case_cdp
	bl case_cdp
	bl case_cdp
	bl case_ldc
	bl case_ldc
	bl case_ldc
	bl case_ldc
	bl case_ldc
	bl case_stc
	bl case_stc
	bl case_stc
	bl case_stc
	bl case_stc
	bl case_mul_m1
	bl case_mul_m1
	bl case_mul_m1
	bl case_mul_m1
	bl case_mul_m1
	bl case_mul_m2
	bl case_mul_m2
	bl case_mul_m2
	bl case_mul_m2
	bl case_mul_m2
	bl case_mul_m3
	bl case_mul_m3
	bl case_mul_m3
	bl case_mul_m3
	bl case_mul_m3
	bl case_mul_m4
	bl case_mul_m4
	bl case_mul_m4
	bl case_mul_m4
	bl case_mul_m4
	bl case_mla_m1
	bl case_mla_m1
	bl case_mla_m1
	bl case_mla_m1
	bl case_mla_m1
	bl case_mla_m2
	bl case_mla_m2
	bl case_mla_m2
	bl case_mla_m2
	bl case_mla_m2
	bl case_mla_m3
	bl case_mla_m3
	bl case_mla_m3
	bl case_mla_m3
	bl case_mla_m3
	bl case_mla_m4
	bl case_mla_m4
	bl case_mla_m4
	bl case_mla_m4
	bl case_mla_m4
	bl case_smull_m1
	bl case_smull_m1
	bl case_smull_m1
	bl case_smull_m1
	bl case_smull_m1
	bl case_smull_m2
	bl case_smull_m2
	bl case_smull_m2
	bl case_smull_m2
	bl case_smull_m2
	bl case_smull_m3
	bl case_smull_m3
	bl case_smull_m3
	bl case_smull_m3
	bl case_smull_m3
	bl case_smull_m4
	bl case_smull_m4
	bl case_smull_m4
	bl case_smull_m4
	bl case_smull_m4
	bl case_umull_m1
	bl case_umull_m1
	bl case_umull_m1
	bl case_umull_m1
	bl case_umull_m1
	bl case_umull_m2
	bl case_umull_m2
	bl case_umull_m2
	bl case_umull_m2
	bl case_umull_m2
	bl case_umull_m3
	bl case_umull_m3
	bl case_umull_m3
	bl case_umull_m3
	bl case_umull_m3
	bl case_umull_m4
	bl case_umull_m4
	bl case_umull_m4
	bl case_umull_m4
	bl case_umull_m4
	bl case_smlal_m1
	bl case_smlal_m1
	bl case_smlal_m1
	bl case_smlal_m1
	bl case_smlal_m1
	bl case_smlal_m2
	bl case_smlal_m2
	bl case_smlal_m2
	bl case_smlal_m2
	bl case_smlal_m2
	bl case_smlal_m3
	bl case_smlal_m3
	bl case_smlal_m3
	bl case_smlal_m3
	bl case_smlal_m3
	bl case_smlal_m4
	bl case_smlal_m4
	bl case_smlal_m4
	bl case_smlal_m4
	bl case_smlal_m4
	bl case_umlal_m1
	bl case_umlal_m1
	bl case_umlal_m1
	bl case_umlal_m1
	bl case_umlal_m1
	bl case_umlal_m2
	bl case_umlal_m2
	bl case_umlal_m2
	bl case_umlal_m2
	bl case_umlal_m2
	bl case_umlal_m3
	bl case_umlal_m3
	bl case_umlal_m3
	bl case_umlal_m3
	bl case_umlal_m3
	bl case_umlal_m4
	bl case_umlal_m4
	bl case_umlal_m4
	bl case_umlal_m4
	bl case_umlal_m4
	bl case_load_distance1
	bl case_load_distance1
	bl case_load_distance1
	bl case_load_distance1
	bl case_load_distance1
	bl case_load_distance2
	bl case_load_distance2
	bl case_load_distance2
	bl case_load_distance2
	bl case_load_distance2
	bl case_load_distance3
	bl case_load_distance3
	bl case_load_distance3
	bl case_load_distance3
	bl case_load_distance3
	CHECKPOINT
	ldmfd sp!,{r4-r11,pc}
	.ltorg

	.balign 16
case_dp:
	mov r8,lr
	mov r0,#0
	.rept 8
	mov r10,r10
	.endr
start_dp:
	mov r10,r10
	add r0,r0,#1
	add r0,r0,#1
	add r0,r0,#1
	add r0,r0,#1
	add r0,r0,#1
	add r0,r0,#1
	add r0,r0,#1
	add r0,r0,#1
end_dp:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_dp_dependency:
	mov r8,lr
	mov r1,#1
	.rept 8
	mov r10,r10
	.endr
start_dp_dependency:
	mov r10,r10
	add r0,r1,#1
	add r1,r0,#1
	add r2,r1,#1
	add r3,r2,#1
end_dp_dependency:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_dp_flags:
	mov r8,lr
	mov r0,#-1
	mov r1,#0
	mov r2,#1
	mov r3,#0
	.rept 8
	mov r10,r10
	.endr
start_dp_flags:
	mov r10,r10
	adds r0,r0,#1
	adcs r1,r1,#0
	movs r2,r2,rrx
	adcs r3,r3,#0
end_dp_flags:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_dp_regshift:
	mov r8,lr
	mov r1,#1
	mov r2,#3
	mov r3,#2
	.rept 8
	mov r10,r10
	.endr
start_dp_regshift:
	mov r10,r10
	add r0,r1,r2,lsl r3
end_dp_regshift:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_failed_regshift:
	mov r8,lr
	mov r0,#1
	cmp r0,#0
	.rept 8
	mov r10,r10
	.endr
start_failed_regshift:
	mov r10,r10
	addeq r0,r1,r2,lsl r3
end_failed_regshift:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_dp_pc:
	mov r8,lr
	adr r4,end_dp_pc
	.rept 8
	mov r10,r10
	.endr
start_dp_pc:
	mov r10,r10
	mov pc,r4
end_dp_pc:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_dp_regshift_pc:
	mov r8,lr
	adr r4,end_dp_regshift_pc
	mov r3,#0
	.rept 8
	mov r10,r10
	.endr
start_dp_regshift_pc:
	mov r10,r10
	mov pc,r4,lsl r3
end_dp_regshift_pc:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_independent:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldr_independent:
	mov r10,r10
	ldr r0,[r9]
	add r2,r2,#1
end_ldr_independent:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_alu:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldr_alu:
	mov r10,r10
	ldr r0,[r9]
	add r2,r0,#1
end_ldr_alu:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_base:
	mov r8,lr
	str r9,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldr_base:
	mov r10,r10
	ldr r0,[r9]
	ldr r2,[r0]
end_ldr_base:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_shift_amount:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldr_shift_amount:
	mov r10,r10
	ldr r0,[r9]
	mov r2,r1,lsl r0
end_ldr_shift_amount:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_shift_value:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldr_shift_value:
	mov r10,r10
	ldr r0,[r9]
	mov r2,r0,lsl #1
end_ldr_shift_value:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_store:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldr_store:
	mov r10,r10
	ldr r0,[r9]
	str r0,[r9,#8]
end_ldr_store:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldrb:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldrb:
	mov r10,r10
	ldrb r0,[r9]
	add r2,r0,#1
end_ldrb:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldrh:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldrh:
	mov r10,r10
	ldrh r0,[r9]
	add r2,r0,#1
end_ldrh:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldrsb:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldrsb:
	mov r10,r10
	ldrsb r0,[r9]
	add r2,r0,#1
end_ldrsb:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldrsh:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldrsh:
	mov r10,r10
	ldrsh r0,[r9]
	add r2,r0,#1
end_ldrsh:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_unaligned:
	mov r8,lr
	ldr r0,=0x01010101
	str r0,[r9]
	str r0,[r9,#4]
	.rept 8
	mov r10,r10
	.endr
start_ldr_unaligned:
	mov r10,r10
	ldr r0,[r9,#1]
	add r2,r0,#1
end_ldr_unaligned:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldr_pc:
	mov r8,lr
	adr r0,end_ldr_pc
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_ldr_pc:
	mov r10,r10
	ldr pc,[r9]
end_ldr_pc:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_str:
	mov r8,lr
	mov r0,#1
	.rept 8
	mov r10,r10
	.endr
start_str:
	mov r10,r10
	str r0,[r9]
end_str:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldm1:
	mov r8,lr
	mov r0,#1
	mov r1,#2
	mov r2,#3
	stmia r9,{r0-r2}
	.rept 8
	mov r10,r10
	.endr
start_ldm1:
	mov r10,r10
	ldmia r9,{r0}
end_ldm1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_stm1:
	mov r8,lr
	mov r0,#1
	mov r1,#2
	mov r2,#3
	.rept 8
	mov r10,r10
	.endr
start_stm1:
	mov r10,r10
	stmia r9,{r0}
end_stm1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldm3:
	mov r8,lr
	mov r0,#1
	mov r1,#2
	mov r2,#3
	stmia r9,{r0-r2}
	.rept 8
	mov r10,r10
	.endr
start_ldm3:
	mov r10,r10
	ldmia r9,{r0-r2}
end_ldm3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_stm3:
	mov r8,lr
	mov r0,#1
	mov r1,#2
	mov r2,#3
	.rept 8
	mov r10,r10
	.endr
start_stm3:
	mov r10,r10
	stmia r9,{r0-r2}
end_stm3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_ldm_pc:
	mov r8,lr
	adr r2,end_ldm_pc
	stmia r9,{r0-r2}
	.rept 8
	mov r10,r10
	.endr
start_ldm_pc:
	mov r10,r10
	ldmia r9,{r0,r1,pc}
end_ldm_pc:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_swp:
	mov r8,lr
	mov r1,#1
	str r1,[r9]
	.rept 8
	mov r10,r10
	.endr
start_swp:
	mov r10,r10
	swp r0,r1,[r9]
end_swp:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_swpb:
	mov r8,lr
	mov r1,#1
	str r1,[r9]
	.rept 8
	mov r10,r10
	.endr
start_swpb:
	mov r10,r10
	swpb r0,r1,[r9]
	add r2,r0,#1
end_swpb:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_b:
	mov r8,lr
	adr r4,end_b
	.rept 8
	mov r10,r10
	.endr
start_b:
	mov r10,r10
	b end_b
end_b:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_bl:
	mov r8,lr
	adr r4,end_bl
	.rept 8
	mov r10,r10
	.endr
start_bl:
	mov r10,r10
	bl end_bl
end_bl:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_bx:
	mov r8,lr
	adr r4,end_bx
	.rept 8
	mov r10,r10
	.endr
start_bx:
	mov r10,r10
	bx r4
end_bx:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mrs:
	mov r8,lr
	.rept 8
	mov r10,r10
	.endr
start_mrs:
	mov r10,r10
	mrs r0,cpsr
end_mrs:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_msr_flags:
	mov r8,lr
	mov r0,#0x60000000
	.rept 8
	mov r10,r10
	.endr
start_msr_flags:
	mov r10,r10
	msr cpsr_f,r0
end_msr_flags:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_msr_control:
	mov r8,lr
	mov r0,#0xd3
	.rept 8
	mov r10,r10
	.endr
start_msr_control:
	mov r10,r10
	msr cpsr_c,r0
end_msr_control:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mcr:
	mov r8,lr
	mov r0,#1
	.rept 8
	mov r10,r10
	.endr
start_mcr:
	mov r10,r10
	mcr p15,0,r0,c3,c0,0
end_mcr:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mrc:
	mov r8,lr
	.rept 8
	mov r10,r10
	.endr
start_mrc:
	mov r10,r10
	mrc p15,0,r0,c0,c0,0
end_mrc:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mrc_use:
	mov r8,lr
	.rept 8
	mov r10,r10
	.endr
start_mrc_use:
	mov r10,r10
	mrc p15,0,r0,c0,c0,0
	mov r1,r0
end_mrc_use:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mrc_pc:
	mov r8,lr
	@ ZAP predates the MRC-R15 flags fix: keep this shared timing case
	@ flag-neutral. ARM9's flag update was separately observed against QEMU.
	mov r0,#0x50000000
	msr cpsr_f,r0
	.rept 8
	mov r10,r10
	.endr
start_mrc_pc:
	mov r10,r10
	mrc p15,0,pc,c0,c0,0
end_mrc_pc:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_swi:
	mov r8,lr
	VECTOR VEC_SWI,handler_swi
	.rept 8
	mov r10,r10
	.endr
start_swi:
	mov r10,r10
	swi 0
end_swi:
	mov r10,r10
	mov lr,r8
	bx lr
handler_swi:
	mov r10,r10
	movs pc,lr
	.ltorg

	.balign 16
case_undefined:
	mov r8,lr
	VECTOR VEC_UND,handler_undefined
	.rept 8
	mov r10,r10
	.endr
start_undefined:
	mov r10,r10
	.word 0xe7f000f0
end_undefined:
	mov r10,r10
	mov lr,r8
	bx lr
handler_undefined:
	mov r10,r10
	movs pc,lr
	.ltorg

	.balign 16
case_cdp:
	mov r8,lr
	VECTOR VEC_UND,handler_cdp
	.rept 8
	mov r10,r10
	.endr
start_cdp:
	mov r10,r10
	cdp p15,0,c0,c0,c0,0
end_cdp:
	mov r10,r10
	mov lr,r8
	bx lr
handler_cdp:
	mov r10,r10
	movs pc,lr
	.ltorg

	.balign 16
case_ldc:
	mov r8,lr
	VECTOR VEC_UND,handler_ldc
	.rept 8
	mov r10,r10
	.endr
start_ldc:
	mov r10,r10
	ldc p15,c0,[r9]
end_ldc:
	mov r10,r10
	mov lr,r8
	bx lr
handler_ldc:
	mov r10,r10
	movs pc,lr
	.ltorg

	.balign 16
case_stc:
	mov r8,lr
	VECTOR VEC_UND,handler_stc
	.rept 8
	mov r10,r10
	.endr
start_stc:
	mov r10,r10
	stc p15,c0,[r9]
end_stc:
	mov r10,r10
	mov lr,r8
	bx lr
handler_stc:
	mov r10,r10
	movs pc,lr
	.ltorg

	.balign 16
case_mul_m1:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x0000007f
	.rept 8
	mov r10,r10
	.endr
start_mul_m1:
	mov r10,r10
	mul r0,r2,r3
end_mul_m1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mul_m2:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x00007fff
	.rept 8
	mov r10,r10
	.endr
start_mul_m2:
	mov r10,r10
	mul r0,r2,r3
end_mul_m2:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mul_m3:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x007fffff
	.rept 8
	mov r10,r10
	.endr
start_mul_m3:
	mov r10,r10
	mul r0,r2,r3
end_mul_m3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mul_m4:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x7fffffff
	.rept 8
	mov r10,r10
	.endr
start_mul_m4:
	mov r10,r10
	mul r0,r2,r3
end_mul_m4:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mla_m1:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x0000007f
	.rept 8
	mov r10,r10
	.endr
start_mla_m1:
	mov r10,r10
	mla r0,r2,r3,r1
end_mla_m1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mla_m2:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x00007fff
	.rept 8
	mov r10,r10
	.endr
start_mla_m2:
	mov r10,r10
	mla r0,r2,r3,r1
end_mla_m2:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mla_m3:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x007fffff
	.rept 8
	mov r10,r10
	.endr
start_mla_m3:
	mov r10,r10
	mla r0,r2,r3,r1
end_mla_m3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_mla_m4:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x7fffffff
	.rept 8
	mov r10,r10
	.endr
start_mla_m4:
	mov r10,r10
	mla r0,r2,r3,r1
end_mla_m4:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smull_m1:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x0000007f
	.rept 8
	mov r10,r10
	.endr
start_smull_m1:
	mov r10,r10
	smull r0,r1,r2,r3
end_smull_m1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smull_m2:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x00007fff
	.rept 8
	mov r10,r10
	.endr
start_smull_m2:
	mov r10,r10
	smull r0,r1,r2,r3
end_smull_m2:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smull_m3:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x007fffff
	.rept 8
	mov r10,r10
	.endr
start_smull_m3:
	mov r10,r10
	smull r0,r1,r2,r3
end_smull_m3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smull_m4:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x7fffffff
	.rept 8
	mov r10,r10
	.endr
start_smull_m4:
	mov r10,r10
	smull r0,r1,r2,r3
end_smull_m4:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umull_m1:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x0000007f
	.rept 8
	mov r10,r10
	.endr
start_umull_m1:
	mov r10,r10
	umull r0,r1,r2,r3
end_umull_m1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umull_m2:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x00007fff
	.rept 8
	mov r10,r10
	.endr
start_umull_m2:
	mov r10,r10
	umull r0,r1,r2,r3
end_umull_m2:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umull_m3:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x007fffff
	.rept 8
	mov r10,r10
	.endr
start_umull_m3:
	mov r10,r10
	umull r0,r1,r2,r3
end_umull_m3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umull_m4:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x7fffffff
	.rept 8
	mov r10,r10
	.endr
start_umull_m4:
	mov r10,r10
	umull r0,r1,r2,r3
end_umull_m4:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smlal_m1:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x0000007f
	.rept 8
	mov r10,r10
	.endr
start_smlal_m1:
	mov r10,r10
	smlal r0,r1,r2,r3
end_smlal_m1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smlal_m2:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x00007fff
	.rept 8
	mov r10,r10
	.endr
start_smlal_m2:
	mov r10,r10
	smlal r0,r1,r2,r3
end_smlal_m2:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smlal_m3:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x007fffff
	.rept 8
	mov r10,r10
	.endr
start_smlal_m3:
	mov r10,r10
	smlal r0,r1,r2,r3
end_smlal_m3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_smlal_m4:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x7fffffff
	.rept 8
	mov r10,r10
	.endr
start_smlal_m4:
	mov r10,r10
	smlal r0,r1,r2,r3
end_smlal_m4:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umlal_m1:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x0000007f
	.rept 8
	mov r10,r10
	.endr
start_umlal_m1:
	mov r10,r10
	umlal r0,r1,r2,r3
end_umlal_m1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umlal_m2:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x00007fff
	.rept 8
	mov r10,r10
	.endr
start_umlal_m2:
	mov r10,r10
	umlal r0,r1,r2,r3
end_umlal_m2:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umlal_m3:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x007fffff
	.rept 8
	mov r10,r10
	.endr
start_umlal_m3:
	mov r10,r10
	umlal r0,r1,r2,r3
end_umlal_m3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_umlal_m4:
	mov r8,lr
	mov r0,#0
	mov r1,#0
	mov r2,#3
	ldr r3,=0x7fffffff
	.rept 8
	mov r10,r10
	.endr
start_umlal_m4:
	mov r10,r10
	umlal r0,r1,r2,r3
end_umlal_m4:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_load_distance1:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_load_distance1:
	mov r10,r10
	ldr r0,[r9]
	mov r1,r1
	add r2,r0,#1
end_load_distance1:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_load_distance2:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_load_distance2:
	mov r10,r10
	ldr r0,[r9]
	mov r1,r1
	mov r1,r1
	add r2,r0,#1
end_load_distance2:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.balign 16
case_load_distance3:
	mov r8,lr
	mov r0,#1
	str r0,[r9]
	.rept 8
	mov r10,r10
	.endr
start_load_distance3:
	mov r10,r10
	ldr r0,[r9]
	mov r1,r1
	mov r1,r1
	mov r1,r1
	add r2,r0,#1
end_load_distance3:
	mov r10,r10
	mov lr,r8
	bx lr
	.ltorg

	.section .rodata
	.balign 4
@ Magic, version, number of 20-byte records; read by --arm9-cycles.
	.word 0x59433941, 0x31574f44
	.word 69
	.word start_dp, end_dp, 9, name_dp, 5
	.word start_dp_dependency, end_dp_dependency, 5, name_dp_dependency, 5
	.word start_dp_flags, end_dp_flags, 5, name_dp_flags, 5
	.word start_dp_regshift, end_dp_regshift, 3, name_dp_regshift, 5
	.word start_failed_regshift, end_failed_regshift, 2, name_failed_regshift, 5
	.word start_dp_pc, end_dp_pc, 11, name_dp_pc, 5
	.word start_dp_regshift_pc, end_dp_regshift_pc, 12, name_dp_regshift_pc, 5
	.word start_ldr_independent, end_ldr_independent, 13, name_ldr_independent, 5
	.word start_ldr_alu, end_ldr_alu, 13, name_ldr_alu, 5
	.word start_ldr_base, end_ldr_base, 20, name_ldr_base, 5
	.word start_ldr_shift_amount, end_ldr_shift_amount, 14, name_ldr_shift_amount, 5
	.word start_ldr_shift_value, end_ldr_shift_value, 13, name_ldr_shift_value, 5
	.word start_ldr_store, end_ldr_store, 20, name_ldr_store, 5
	.word start_ldrb, end_ldrb, 13, name_ldrb, 5
	.word start_ldrh, end_ldrh, 13, name_ldrh, 5
	.word start_ldrsb, end_ldrsb, 13, name_ldrsb, 5
	.word start_ldrsh, end_ldrsh, 13, name_ldrsh, 5
	.word start_ldr_unaligned, end_ldr_unaligned, 13, name_ldr_unaligned, 5
	.word start_ldr_pc, end_ldr_pc, 17, name_ldr_pc, 5
	.word start_str, end_str, 12, name_str, 5
	.word start_ldm1, end_ldm1, 12, name_ldm1, 5
	.word start_stm1, end_stm1, 12, name_stm1, 5
	.word start_ldm3, end_ldm3, 28, name_ldm3, 5
	.word start_stm3, end_stm3, 28, name_stm3, 5
	.word start_ldm_pc, end_ldm_pc, 33, name_ldm_pc, 5
	.word start_swp, end_swp, 17, name_swp, 5
	.word start_swpb, end_swpb, 18, name_swpb, 5
	.word start_b, end_b, 7, name_b, 5
	.word start_bl, end_bl, 7, name_bl, 5
	.word start_bx, end_bx, 11, name_bx, 5
	.word start_mrs, end_mrs, 7, name_mrs, 5
	.word start_msr_flags, end_msr_flags, 11, name_msr_flags, 5
	.word start_msr_control, end_msr_control, 11, name_msr_control, 5
	.word start_mcr, end_mcr, 18, name_mcr, 5
	.word start_mrc, end_mrc, 16, name_mrc, 5
	.word start_mrc_use, end_mrc_use, 17, name_mrc_use, 5
	.word start_mrc_pc, end_mrc_pc, 16, name_mrc_pc, 5
	.word start_swi, handler_swi, 24, name_swi, 5
	.word start_undefined, handler_undefined, 24, name_undefined, 5
	.word start_cdp, handler_cdp, 24, name_cdp, 5
	.word start_ldc, handler_ldc, 24, name_ldc, 5
	.word start_stc, handler_stc, 24, name_stc, 5
	.word start_mul_m1, end_mul_m1, 9, name_mul_m1, 5
	.word start_mul_m2, end_mul_m2, 10, name_mul_m2, 5
	.word start_mul_m3, end_mul_m3, 11, name_mul_m3, 5
	.word start_mul_m4, end_mul_m4, 12, name_mul_m4, 5
	.word start_mla_m1, end_mla_m1, 9, name_mla_m1, 5
	.word start_mla_m2, end_mla_m2, 10, name_mla_m2, 5
	.word start_mla_m3, end_mla_m3, 11, name_mla_m3, 5
	.word start_mla_m4, end_mla_m4, 12, name_mla_m4, 5
	.word start_smull_m1, end_smull_m1, 10, name_smull_m1, 5
	.word start_smull_m2, end_smull_m2, 11, name_smull_m2, 5
	.word start_smull_m3, end_smull_m3, 12, name_smull_m3, 5
	.word start_smull_m4, end_smull_m4, 13, name_smull_m4, 5
	.word start_umull_m1, end_umull_m1, 10, name_umull_m1, 5
	.word start_umull_m2, end_umull_m2, 11, name_umull_m2, 5
	.word start_umull_m3, end_umull_m3, 12, name_umull_m3, 5
	.word start_umull_m4, end_umull_m4, 13, name_umull_m4, 5
	.word start_smlal_m1, end_smlal_m1, 10, name_smlal_m1, 5
	.word start_smlal_m2, end_smlal_m2, 11, name_smlal_m2, 5
	.word start_smlal_m3, end_smlal_m3, 12, name_smlal_m3, 5
	.word start_smlal_m4, end_smlal_m4, 13, name_smlal_m4, 5
	.word start_umlal_m1, end_umlal_m1, 10, name_umlal_m1, 5
	.word start_umlal_m2, end_umlal_m2, 11, name_umlal_m2, 5
	.word start_umlal_m3, end_umlal_m3, 12, name_umlal_m3, 5
	.word start_umlal_m4, end_umlal_m4, 13, name_umlal_m4, 5
	.word start_load_distance1, end_load_distance1, 14, name_load_distance1, 5
	.word start_load_distance2, end_load_distance2, 15, name_load_distance2, 5
	.word start_load_distance3, end_load_distance3, 16, name_load_distance3, 5
name_dp: .asciz "dp"
name_dp_dependency: .asciz "dp_dependency"
name_dp_flags: .asciz "dp_flags"
name_dp_regshift: .asciz "dp_regshift"
name_failed_regshift: .asciz "failed_regshift"
name_dp_pc: .asciz "dp_pc"
name_dp_regshift_pc: .asciz "dp_regshift_pc"
name_ldr_independent: .asciz "ldr_independent"
name_ldr_alu: .asciz "ldr_alu"
name_ldr_base: .asciz "ldr_base"
name_ldr_shift_amount: .asciz "ldr_shift_amount"
name_ldr_shift_value: .asciz "ldr_shift_value"
name_ldr_store: .asciz "ldr_store"
name_ldrb: .asciz "ldrb"
name_ldrh: .asciz "ldrh"
name_ldrsb: .asciz "ldrsb"
name_ldrsh: .asciz "ldrsh"
name_ldr_unaligned: .asciz "ldr_unaligned"
name_ldr_pc: .asciz "ldr_pc"
name_str: .asciz "str"
name_ldm1: .asciz "ldm1"
name_stm1: .asciz "stm1"
name_ldm3: .asciz "ldm3"
name_stm3: .asciz "stm3"
name_ldm_pc: .asciz "ldm_pc"
name_swp: .asciz "swp"
name_swpb: .asciz "swpb"
name_b: .asciz "b"
name_bl: .asciz "bl"
name_bx: .asciz "bx"
name_mrs: .asciz "mrs"
name_msr_flags: .asciz "msr_flags"
name_msr_control: .asciz "msr_control"
name_mcr: .asciz "mcr"
name_mrc: .asciz "mrc"
name_mrc_use: .asciz "mrc_use"
name_mrc_pc: .asciz "mrc_pc"
name_swi: .asciz "swi"
name_undefined: .asciz "undefined"
name_cdp: .asciz "cdp"
name_ldc: .asciz "ldc"
name_stc: .asciz "stc"
name_mul_m1: .asciz "mul_m1"
name_mul_m2: .asciz "mul_m2"
name_mul_m3: .asciz "mul_m3"
name_mul_m4: .asciz "mul_m4"
name_mla_m1: .asciz "mla_m1"
name_mla_m2: .asciz "mla_m2"
name_mla_m3: .asciz "mla_m3"
name_mla_m4: .asciz "mla_m4"
name_smull_m1: .asciz "smull_m1"
name_smull_m2: .asciz "smull_m2"
name_smull_m3: .asciz "smull_m3"
name_smull_m4: .asciz "smull_m4"
name_umull_m1: .asciz "umull_m1"
name_umull_m2: .asciz "umull_m2"
name_umull_m3: .asciz "umull_m3"
name_umull_m4: .asciz "umull_m4"
name_smlal_m1: .asciz "smlal_m1"
name_smlal_m2: .asciz "smlal_m2"
name_smlal_m3: .asciz "smlal_m3"
name_smlal_m4: .asciz "smlal_m4"
name_umlal_m1: .asciz "umlal_m1"
name_umlal_m2: .asciz "umlal_m2"
name_umlal_m3: .asciz "umlal_m3"
name_umlal_m4: .asciz "umlal_m4"
name_load_distance1: .asciz "load_distance1"
name_load_distance2: .asciz "load_distance2"
name_load_distance3: .asciz "load_distance3"
