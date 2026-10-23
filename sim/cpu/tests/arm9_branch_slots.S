@ SPDX-License-Identifier: GPL-3.0-or-later
@ Branch immediates are not register operands; both Thumb BL alignments.
@@ bench: --arm9-cycles --arm9-cycle-model arm9/branch-slots-cycles.txt
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
    ldr r8,=SCRATCH
    mov r0,#0x55
    str r0,[r8]
    .rept 5
    bl case_no_registers
    .endr
    CHECK r0,0x55
    adr r11,thumb_done
    adr r0,thumb_main+1
    bx r0
thumb_done:
    CHECK r7,0
    CHECKPOINT
    ldmfd sp!,{r4-r11,pc}
    .ltorg

    .balign 16
case_no_registers:
    cmp r1,r1
    .rept 8
    mov r10,r10
    .endr
start_no_registers:
    mov r10,r10
    ldr r0,[r8]
    @ Offset zero aliases r0 in every nominal register field. B uses none.
    beq end_no_registers
    mov r0,#99
end_no_registers:
    mov r10,r10
    mov pc,lr

    .thumb
    .balign 4
thumb_main:
    movs r7,#0
    movs r5,#5
2:  bl case_cross_word
    sub r5,#1
    bne 2b
    movs r5,#5
3:  bl case_same_word
    sub r5,#1
    bne 3b
    @ A standalone BL suffix consumes a ready LR without a fused prefix.
    adr r0,standalone_suffix_target
    mov lr,r0
    .hword 0xf800
    movs r7,#99
    .balign 4
standalone_suffix_target:
    bx r11
    .balign 16
case_cross_word:
    mov r4,lr
    .rept 7
    movs r7,r7
    .endr
start_cross_word:
    movs r7,r7
    bl end_cross_word
    movs r7,#99
end_cross_word:
    movs r7,r7
    bx r4
    .balign 16
case_same_word:
    mov r4,lr
    .rept 8
    movs r7,r7
    .endr
start_same_word:
    movs r7,r7
    bl end_same_word
    movs r7,#99
end_same_word:
    movs r7,r7
    bx r4

    .section .rodata
    .balign 4
    .word 0x59433941,0x31574f44,3
    .word start_no_registers,end_no_registers,4,name_no_registers,5
    .word start_cross_word,end_cross_word,4,name_cross_word,5
    .word start_same_word,end_same_word,4,name_same_word,5
name_no_registers: .asciz "branch_no_registers"
name_cross_word: .asciz "thumb_bl_cross_word"
name_same_word: .asciz "thumb_bl_same_word"
