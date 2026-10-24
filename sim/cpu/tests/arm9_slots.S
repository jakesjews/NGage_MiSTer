@ SPDX-License-Identifier: GPL-3.0-or-later
@ Long blocks, adjacent dependent blocks, multiply pair forwarding, and squash.
@@ bench: --arm9-cycles --arm9-cycle-model arm9v2/arm9_slots-cycles.txt
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
1:  str r1,[r0],#4
    add r1,r1,#0x00100000
    subs r2,r2,#1
    bne 1b
    TLBFLUSH
    mrc p15,0,r0,c1,c0,0
    orr r0,r0,#(CR_C|CR_W)
    orr r0,r0,#CR_I
    mcr p15,0,r0,c1,c0,0
    ldr r9,=SCRATCH
    add r8,r9,#64
    mov r0,#1
    mov r1,#2
    mov r2,#3
    mov r3,#4
    mov r4,#5
    mov r5,#6
    mov r6,#7
    mov r7,#8
    .rept 5
    bl case_stm8
    .endr
    .rept 5
    bl case_ldm8
    .endr
    .rept 5
    bl case_blocks
    .endr
    .rept 5
    bl case_pair
    .endr
    CHECKPOINT
    @ A load feeding a later STM register must interlock the sequencer,
    @ even though the first store and base register are ready in E.
    mov r0,#0x11
    mov r1,#0x22
    str r1,[r9]
    ldr r1,[r9]
    stmia r8,{r0-r3}
    ldr r6,[r8,#4]
    CHECK r6,0x22
    VECTOR VEC_DABT,slot_abort
    ldr r4,=NOWHERE
    mov r0,#0x11
    mov r1,#0x22
    adr r5,after_pair_abort
    ldr r6,[r4]
    umull r0,r1,r2,r3
    mov r0,#0x99
after_pair_abort:
    CHECK r0,0x11
    CHECK r1,0x22
    mov r6,#0x55
    str r6,[r8]
    mov r7,r8
    adr r5,after_block_abort
    ldr r6,[r4]
    stmia r8!,{r0-r3}
    mov r0,#0x99
after_block_abort:
    CHECKR r8,r7
    ldr r6,[r8]
    CHECK r6,0x55
    CHECK r0,0x11
    CHECKPOINT
    ldmfd sp!,{r4-r11,pc}
slot_abort:
    movs pc,r5
    .ltorg

    .macro PAD
    .rept 8
    mov r10,r10
    .endr
    .endm
    .balign 16
case_stm8:
    PAD
start_stm8:
    mov r10,r10
    stmia r9,{r0-r7}
end_stm8:
    mov r10,r10
    mov pc,lr
    .balign 16
case_ldm8:
    PAD
start_ldm8:
    mov r10,r10
    ldmia r9,{r0-r7}
end_ldm8:
    mov r10,r10
    mov pc,lr
    .balign 16
case_blocks:
    PAD
start_blocks:
    mov r10,r10
    ldmia r9,{r0-r3}
    stmia r8,{r0-r3}
end_blocks:
    mov r10,r10
    mov pc,lr
    .balign 16
case_pair:
    mov r2,#3
    mov r3,#7
    PAD
start_pair:
    mov r10,r10
    umull r0,r1,r2,r3
    mla r4,r0,r3,r1
end_pair:
    mov r10,r10
    CHECK r4,147
    mov pc,lr

    .section .rodata
    .balign 4
    .word 0x59433941,0x31574f44,4
    .word start_stm8,end_stm8,10,name_stm8,5
    .word start_ldm8,end_ldm8,10,name_ldm8,5
    .word start_blocks,end_blocks,12,name_blocks,5
    .word start_pair,end_pair,8,name_pair,5
name_stm8: .asciz "stm8"
name_ldm8: .asciz "ldm8"
name_blocks: .asciz "dependent_blocks"
name_pair: .asciz "multiply_pair_forward"
