@ SPDX-License-Identifier: GPL-3.0-or-later
@ ARM DDI0100I B4.5.1: translation-fault descriptors must not enter a TLB.
@ Repair failed L1/L2 translations without invalidating the TLB, then retry.
@ Exercise repeated faults, loads, stores, and instruction fetches.
.include "test.inc"
.include "mmu.inc"
.text
.arm
.global test_main

@ Fetch at the end of a descriptor's range. The lookahead visits the next
@ range during retry bubbles; it must not cancel the real fault response.
.macro FETCH_END va, pa, pte, desc
    ldr r5, =ab_state
    adr r0, resume_\@
    str r0, [r5, #20]
    ldr r4, =\va
    mov pc, r4
resume_\@:
    ldr r0, [r5]
    CHECK r0, 1
    ldr r0, [r5, #24]
    CHECK r0, 2
    bl ab_clear
    ldr r0, =0xe1a0f00e             @ mov pc, lr
    ldr r1, =\pa
    str r0, [r1]
    ldr r0, =\desc
    ldr r1, =\pte
    str r0, [r1]
    bl drain
    mov r0, #5
    mov lr, pc
    mov pc, r4
    NOABT
    CHECK r0, 5
.endm

test_main:
    stmfd sp!, {r4-r11,lr}
    bl mmu_on

    @ A failed L1 load cannot poison a later section mapping.
    ldr r5, =0x00400100
    ldr r0, =0x12abcdef
    str r0, [r5]
    ldr r4, =0xfff00100
    ldr r0, [r4]
    DABT 0x05, 0xfff00100
    ldr r0, [r4]
    DABT 0x05, 0xfff00100
    SECT r1, 0x00400000, 3, 0, 0
    SETL1 0xfff00000, r1
    bl drain
    ldr r0, [r4]
    NOABT
    CHECK r0, 0x12abcdef
    STORE_RESULT r0, 0

    @ The same guarantee applies to stores.
    ldr r4, =0xffe00104
    ldr r0, =0x87654321
    str r0, [r4]
    DABT 0x05, 0xffe00104
    SECT r1, 0x00400000, 3, 0, 0
    SETL1 0xffe00000, r1
    bl drain
    ldr r0, =0x87654321
    str r0, [r4]
    NOABT
    CHECKM 0x00400104, 0x87654321

    @ Domain 2, coarse table: failed L2 walk, then a valid small page.
    ldr r5, =L2_AREA
    mov r0, #0
    str r0, [r5]
    ldr r1, =(L2_AREA | (2 << 5) | 0x10 | 1)
    SETL1 0x30000000, r1
    mov r0, #0x11
    mcr p15, 0, r0, c3, c0, 0
    bl drain
    ldr r4, =0x30000100
    ldr r0, [r4]
    DABT 0x27, 0x30000100
    ldr r1, =0x00400ff2
    str r1, [r5]
    bl drain
    ldr r0, [r4]
    NOABT
    CHECK r0, 0x12abcdef
    STORE_RESULT r0, 1

    @ Fine table: failed L2 store, then a valid tiny page.
    ldr r5, =(L2_AREA + 0x1000)
    mov r0, #0
    str r0, [r5]
    ldr r1, =((L2_AREA + 0x1000) | (2 << 5) | 0x10 | 3)
    SETL1 0x30100000, r1
    bl drain
    ldr r4, =0x30100108
    str r0, [r4]
    DABT 0x27, 0x30100108
    ldr r1, =0x00400033
    str r1, [r5]
    bl drain
    ldr r0, =0xfeedbac0
    str r0, [r4]
    NOABT
    CHECKM 0x00400108, 0xfeedbac0

    @ I-side: failed fetch, then install code and retry without TLB flush.
    ldr r5, =ab_state
    adr r0, after_pabt
    str r0, [r5, #20]
    ldr r4, =0x30200800
    mov pc, r4
after_pabt:
    ldr r0, [r5]
    CHECK r0, 1
    ldr r0, [r5, #24]
    CHECK r0, 2
    bl ab_clear
    adr r0, page_code
    ldr r1, =0x00400800
    ldmia r0, {r2,r3}
    stmia r1, {r2,r3}
    SECT r1, 0x00400000, 3, 0, 0
    SETL1 0x30200000, r1
    bl drain
    mov r0, #5
    mov lr, pc
    mov pc, r4
    NOABT
    CHECK r0, 47
    STORE_RESULT r0, 2

    FETCH_END 0x303ffffc, 0x004ffffc, (TTB + (0x303 * 4)), 0x00400c12

    @ Coarse table entry 1 is still invalid; repair it as a small page.
    ldr r1, =(L2_AREA + 4)
    mov r0, #0
    str r0, [r1]
    bl drain
    FETCH_END 0x30001ffc, 0x00401ffc, (L2_AREA + 4), 0x00401ff2

    @ A new fine table, so both the last word and next tiny page start unmapped.
    ldr r5, =(L2_AREA + 0x2000)
    mov r0, #0
    str r0, [r5]
    str r0, [r5, #4]
    ldr r1, =((L2_AREA + 0x2000) | (2 << 5) | 0x10 | 3)
    SETL1 0x30500000, r1
    bl drain
    FETCH_END 0x305003fc, 0x004003fc, (L2_AREA + 0x2000), 0x00400033
    ldmfd sp!, {r4-r11,pc}

page_code:
    add r0, r0, #42
    mov pc, lr

drain:
    mov r12, #0
    mcr p15, 0, r12, c7, c10, 4
    mov pc, lr
.ltorg
