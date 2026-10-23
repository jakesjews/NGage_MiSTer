@ SPDX-License-Identifier: GPL-3.0-or-later
@ Registered BTB: hot taken branch and trained-taken/actually-not-taken repair.
@@ bench: --arm9-cycles --arm9-cycle-model arm9/predict-cycles.txt
    .include "test.inc"
    .include "mmu.inc"
    .text
    .arm
    .global test_main
test_main:
    stmfd sp!,{r4-r11,lr}
    @ No cache or CP15 operation may clear this prediction between the
    @ branch training and replacement. The stale entry must be repaired in E.
    mov r7,#0
    .rept 4
    bl mutable
    .endr
    ldr r0,=mutable
    ldr r1,=0xe2877001
    str r1,[r0]
    @ Readback orders the store; an untrained, data-dependent redirect keeps
    @ the following call outside the old sequential prefetch window.
    ldr r2,[r0]
    eor r2,r2,r1
    adr r3,call_modified
    add r3,r3,r2
    mov pc,r3
    .rept 32
    mov r10,r10
    .endr
call_modified:
    bl mutable
    CHECK r7,19
    CHECKPOINT
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
    mov r7,#0
    .rept 5
    bl case_predicted
    .endr
    .rept 5
    bl case_mispredicted
    .endr
    CHECKPOINT
    ldmfd sp!,{r4-r11,pc}
    .ltorg

    .balign 16
case_predicted:
    .rept 8
    mov r10,r10
    .endr
start_predicted:
    mov r10,r10
    b end_predicted
    add r7,r7,#0x100
    add r7,r7,#0x100
end_predicted:
    mov r10,r10
    add r7,r7,#1
    mov pc,lr

    .balign 16
case_mispredicted:
    mov r0,#3
train:
    cmp r0,#0
    b tested_branch
    .rept 8
    mov r10,r10
    .endr
start_mispredicted:
    mov r10,r10
tested_branch:
    bne trained_target
end_mispredicted:
    mov r10,r10
    add r7,r7,#1
    mov pc,lr
trained_target:
    subs r0,r0,#1
    bne train
    cmp r0,#0
    b start_mispredicted

    .balign 16
mutable:
    b mutable_target
    add r7,r7,#2
    mov pc,lr
mutable_target:
    add r7,r7,#4
    mov pc,lr

    .section .rodata
    .balign 4
    .word 0x59433941,0x31574f44,2
    .word start_predicted,end_predicted,3,name_predicted,5
    .word start_mispredicted,end_mispredicted,5,name_mispredicted,5
name_predicted: .asciz "predicted_taken"
name_mispredicted: .asciz "mispredicted_not_taken"
