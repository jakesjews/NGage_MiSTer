@ SPDX-License-Identifier: GPL-3.0-or-later
@ Posted WT/NCB stores: byte merging, ordering, clean-line state, W/C gates,
@ uncached SWP, and user permission faults. Cycle windows are observations.

    .include "test.inc"
    .include "mmu.inc"
    .equ WT, 0x00500000
    .equ NCB, 0x00600000
    .equ RAW_WT, 0x20500000
    .equ RAW_NCB, 0x20600000
    .equ USER_RO, 0x22000000
    .text
    .arm
    .global test_main

    .macro STREAM name, address, raw, value
    ldr r3, =\address
    ldr r2, =\value
    mov r0, #64
    .global pm_\name\()_begin, pm_\name\()_end, pm_\name\()_drained
pm_\name\()_begin:
    nop
1:  str r2, [r3], #4
    subs r0, r0, #1
    bne 1b
pm_\name\()_end:
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 4
pm_\name\()_drained:
    ldr r4, =\raw
    mov r5, #64
2:  ldr r0, [r4], #4
    CHECKR r0, r2
    subs r5, r5, #1
    bne 2b
    .endm

test_main:
    push {r4-r11, lr}
    bl mmu_on
    SECT r1, 0, 3, 0, 3
    SETL1 0, r1
    SECT r1, WT, 3, 0, 2
    SETL1 WT, r1
    SECT r1, NCB, 3, 0, 1
    SETL1 NCB, r1
    SECT r1, WT, 3, 0, 0
    SETL1 RAW_WT, r1
    SECT r1, NCB, 3, 0, 0
    SETL1 RAW_NCB, r1
    SECT r1, NCB, 1, 0, 1
    SETL1 USER_RO, r1
    TLBFLUSH
    mrc p15, 0, r0, c1, c0, 0
    orr r0, r0, #(CR_C | CR_W)
    orr r0, r0, #CR_I
    mcr p15, 0, r0, c1, c0, 0

    STREAM wt_cold, WT, RAW_WT, 0x12345678
    @ Explicitly read-allocate the WT lines before checking hit updates.
    ldr r4, =WT
    mov r5, #16
3:  ldr r0, [r4], #16
    CHECK r0, 0x12345678
    subs r5, r5, #1
    bne 3b
    STREAM wt_warm, WT, RAW_WT, 0x76543210
    ldr r4, =WT
    mov r0, #0xaa
    strb r0, [r4, #1]
    ldr r0, =0xbbcc
    strh r0, [r4, #2]
    ldr r0, [r4]
    CHECK r0, 0xbbccaa10
    ldr r5, =RAW_WT
    ldr r0, [r5]
    CHECK r0, 0xbbccaa10
    @ A WT hit must not make a clean line dirty. Simulate an external write
    @ via the uncached alias, then clean: it must not overwrite fresh memory.
    ldr r0, =0xaabbccdd
    str r0, [r5]
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 0
    mcr p15, 0, r0, c7, c10, 4
    ldr r0, [r5]
    CHECK r0, 0xaabbccdd
    mcr p15, 0, r0, c7, c6, 0
    ldr r0, [r4]
    CHECK r0, 0xaabbccdd
    CHECKPOINT

    STREAM ncb, NCB, RAW_NCB, 0x44332211
    ldr r4, =NCB
    mov r0, #0xee
    strb r0, [r4, #1]
    ldr r0, =0x9876
    strh r0, [r4, #2]
    ldr r0, [r4]
    CHECK r0, 0x9876ee11
    mov r2, #0x5a
    swp r0, r2, [r4]
    CHECK r0, 0x9876ee11
    ldr r0, [r4]
    CHECKR r0, r2
    mov r2, #0xa5
    swpb r0, r2, [r4]
    CHECK r0, 0x5a
    ldr r0, [r4]
    CHECKR r0, r2
    @ A denied user store must not enter the FIFO or change backing memory.
    ldr r4, =USER_RO
    mov r0, #0x44
    strt r0, [r4], #0
    DABT 0x0d, USER_RO
    ldr r4, =RAW_NCB
    ldr r0, [r4]
    CHECK r0, 0xa5
    CHECKPOINT

    @ Cache-off/W-on: C=0/B=1 remains bufferable, C=1/B=0 does not.
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 0
    mcr p15, 0, r0, c7, c6, 0
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #CR_C
    mcr p15, 0, r0, c1, c0, 0
    STREAM ncb_doff, NCB+0x1000, RAW_NCB+0x1000, 0x10203040
    STREAM wt_doff, WT+0x1000, RAW_WT+0x1000, 0x50607080
    CHECKPOINT

    @ Clearing W leaves already posted stores intact. Further stores are
    @ synchronous; restoring C alone must not enable WT buffering.
    ldr r4, =NCB+0x2000
    mov r0, #0x6a
    str r0, [r4]
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #CR_W
    orr r0, r0, #CR_C
    mcr p15, 0, r0, c1, c0, 0
    ldr r4, =RAW_NCB+0x2000
    ldr r0, [r4]
    CHECK r0, 0x6a
    STREAM ncb_woff, NCB+0x3000, RAW_NCB+0x3000, 0x11224488
    STREAM wt_woff, WT+0x3000, RAW_WT+0x3000, 0x88442211
    NOABT
    CHECKPOINT
    pop {r4-r11, pc}
    .ltorg
