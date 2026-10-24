@ SPDX-License-Identifier: GPL-3.0-or-later
@ Sweep IRQ arrival across the ROM TDesC16 flags-to-pointer sequence.
@ All five descriptor forms are tested after cleaning their cache lines;
@ the handler must restore the flags even beside a background load return.
@@ qemu: no
@@ trace: no
.include "test.inc"
.include "mmu.inc"
.text
.arm
.global test_main
test_main:
    stmfd sp!,{r4-r11,lr}
    bl mmu_on
    SECT r1,0,3,0,3
    SETL1 0,r1
    SECT r1,BENCH,3,0,0
    SETL1 BENCH,r1
    TLBFLUSH
    VECTOR VEC_IRQ,handler
    mrc p15,0,r0,c1,c0,0
    orr r0,r0,#(CR_C|CR_W)
    orr r0,r0,#CR_I
    mcr p15,0,r0,c1,c0,0
    ldr r8,=seen
    ldr r10,=BENCH
    mov r7,#1
again:
    mov r0,#0
    str r0,[r8]
    ldr r6,=table
    mov r5,#5
    ldr r0,=inline0
    .rept 5
    mcr p15,0,r0,c7,c14,1
    add r0,r0,#16
    .endr
    str r7,[r10,#BENCH_IRQ_IN]
    msr cpsr_c,#(M_SVC|PSR_F)
each:
    ldmia r6!,{r0,r4}
    mov r1,#1
    bl descriptor_at
    cmp r0,r4
    bne wrong
    subs r5,r5,#1
    bne each
wait_irq:
    ldr r0,[r8]
    cmp r0,#1
    bne wait_irq
    msr cpsr_c,#(M_SVC|PSR_I|PSR_F)
    add r7,r7,#1
    cmp r7,#1024
    bls again
    CHECKPOINT
    ldmfd sp!,{r4-r11,pc}
wrong:
    FAIL
@ Same pointer/classifier sequence as ROM 5039d3ac, without its bounds trap.
descriptor_at:
    ldr r2,[r0],#4
    bic r3,r2,#0xf0000000
    eor r2,r2,r2,lsr #1
    msr cpsr_f,r2
    addcs r0,r0,#4
    ldrle r0,[r0]
    addeq r0,r0,#4
    cmp r1,#0
    cmpge r3,r1
    addgt r0,r0,r1,lsl #1
    bxgt lr
    b wrong
handler:
    stmfd sp!,{r0-r3,lr}
    mov r0,#0
    str r0,[r10,#BENCH_INT]
    ldr r0,[r8]
    add r0,r0,#1
    str r0,[r8]
    ldmfd sp!,{r0-r3,lr}
    subs pc,lr,#4
.ltorg
.data
.align 2
seen: .word 0
inline0: .word 2,0x22221111
ptr1: .word 0x10000002,payload
ptr2: .word 0x20000002,2,payload
inline3: .word 0x30000002,2,0x22221111
bufptr4: .word 0x40000002,2,inline0
payload: .word 0x22221111
table:
    .word inline0,inline0+6
    .word ptr1,payload+2
    .word ptr2,payload+2
    .word inline3,inline3+10
    .word bufptr4,inline0+6
