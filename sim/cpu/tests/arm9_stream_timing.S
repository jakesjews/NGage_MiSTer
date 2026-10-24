@ SPDX-License-Identifier: GPL-3.0-or-later
@ Eight adjacent hit requests must retire in eight clocks plus the end marker.
@ Three warmups, then two exact hot checks. Shared architecture with ZAP/QEMU.
@@ bench: --arm9-cycles --arm9-cycle-model arm9v2/arm9_stream_timing-cycles.txt
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
    mov r0,#1
    mov r1,#2
    mov r2,#3
    mov r3,#4
    mov r4,#5
    mov r5,#6
    mov r6,#7
    mov r7,#8
    bl case_stores_same
    bl case_stores_same
    bl case_stores_same
    bl case_stores_same
    bl case_stores_same
    bl case_stores_sets
    bl case_stores_sets
    bl case_stores_sets
    bl case_stores_sets
    bl case_stores_sets
    bl case_loads_same
    bl case_loads_same
    bl case_loads_same
    bl case_loads_same
    bl case_loads_same
    bl case_loads_sets
    bl case_loads_sets
    bl case_loads_sets
    bl case_loads_sets
    bl case_loads_sets
    bl case_stores_index
    bl case_stores_index
    bl case_stores_index
    bl case_stores_index
    bl case_stores_index
    bl case_loads_index
    bl case_loads_index
    bl case_loads_index
    bl case_loads_index
    bl case_loads_index
    bl case_mixed
    bl case_mixed
    bl case_mixed
    bl case_mixed
    bl case_mixed
    CHECKPOINT
    ldmfd sp!,{r4-r11,pc}
    .ltorg
case_stores_same:
    mov r8,r9
    .balign 16
start_stores_same:
    mov r10,r10
    str r0,[r9]
    str r1,[r9]
    str r2,[r9]
    str r3,[r9]
    str r4,[r9]
    str r5,[r9]
    str r6,[r9]
    str r7,[r9]
end_stores_same:
    mov r10,r10
    mov pc,lr
case_stores_sets:
    mov r8,r9
    .balign 16
start_stores_sets:
    mov r10,r10
    str r0,[r9,#0]
    str r1,[r9,#16]
    str r2,[r9,#32]
    str r3,[r9,#48]
    str r4,[r9,#64]
    str r5,[r9,#80]
    str r6,[r9,#96]
    str r7,[r9,#112]
end_stores_sets:
    mov r10,r10
    mov pc,lr
case_loads_same:
    mov r8,r9
    .balign 16
start_loads_same:
    mov r10,r10
    ldr r0,[r9]
    ldr r1,[r9]
    ldr r2,[r9]
    ldr r3,[r9]
    ldr r4,[r9]
    ldr r5,[r9]
    ldr r6,[r9]
    ldr r7,[r9]
end_loads_same:
    mov r10,r10
    mov pc,lr
case_loads_sets:
    mov r8,r9
    .balign 16
start_loads_sets:
    mov r10,r10
    ldr r0,[r9,#0]
    ldr r1,[r9,#16]
    ldr r2,[r9,#32]
    ldr r3,[r9,#48]
    ldr r4,[r9,#64]
    ldr r5,[r9,#80]
    ldr r6,[r9,#96]
    ldr r7,[r9,#112]
end_loads_sets:
    mov r10,r10
    mov pc,lr
case_stores_index:
    mov r8,r9
    .balign 16
start_stores_index:
    mov r10,r10
    str r0,[r8],#4
    str r1,[r8],#4
    str r2,[r8],#4
    str r3,[r8],#4
    str r4,[r8],#4
    str r5,[r8],#4
    str r6,[r8],#4
    str r7,[r8],#4
end_stores_index:
    mov r10,r10
    mov pc,lr
case_loads_index:
    mov r8,r9
    .balign 16
start_loads_index:
    mov r10,r10
    ldr r0,[r8],#4
    ldr r1,[r8],#4
    ldr r2,[r8],#4
    ldr r3,[r8],#4
    ldr r4,[r8],#4
    ldr r5,[r8],#4
    ldr r6,[r8],#4
    ldr r7,[r8],#4
end_loads_index:
    mov r10,r10
    mov pc,lr
case_mixed:
    mov r8,r9
    .balign 16
start_mixed:
    mov r10,r10
    str r0,[r9]
    ldr r1,[r9]
    str r2,[r9]
    ldr r3,[r9]
    str r4,[r9,#16]
    ldr r5,[r9,#16]
    str r6,[r9,#16]
    ldr r7,[r9,#16]
end_mixed:
    mov r10,r10
    mov pc,lr
    .balign 4
    .word 0x59433941,0x31574f44,7
    .word start_stores_same,end_stores_same,9,name_stores_same,5
    .word start_stores_sets,end_stores_sets,9,name_stores_sets,5
    .word start_loads_same,end_loads_same,9,name_loads_same,5
    .word start_loads_sets,end_loads_sets,9,name_loads_sets,5
    .word start_stores_index,end_stores_index,9,name_stores_index,5
    .word start_loads_index,end_loads_index,9,name_loads_index,5
    .word start_mixed,end_mixed,9,name_mixed,5
name_stores_same: .asciz "stores_same"
name_stores_sets: .asciz "stores_sets"
name_loads_same: .asciz "loads_same"
name_loads_sets: .asciz "loads_sets"
name_stores_index: .asciz "stores_index"
name_loads_index: .asciz "loads_index"
name_mixed: .asciz "mixed"
