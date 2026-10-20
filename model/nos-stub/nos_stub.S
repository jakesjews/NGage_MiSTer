/*
 * NOS stand-in (model shortcut, see model/rom-patches.txt).
 *
 * NOS, the cellular RTOS, is encrypted in our flash image. Symbian reaches it
 * in two ways that matter for boot:
 *   1. nosstarter.ext calls its entry at 0x5149E4D4 (ARM, r0 = -1) once,
 *      after copying NOS data and clearing NOS BSS (0x8000C378, 0xC1ED8 bytes).
 *   2. NOS registers kernel "services" with the variant (ecust.dll):
 *      variant = *(0x8000038C) (ekern 0x5032E7AC); vtable +0xFC =
 *      RegisterService(n, obj) (ecust 0x503430C8), +0x100 = GetService(n)
 *      (ecust 0x503430F4), n = 0..8. Symbian registers 0 and 5 (ecust),
 *      1 (rtc.dll), 2 (ekeyb.dll), 4 (lcd.ldd), 8 (product_info.dll); nothing
 *      in the Symbian ROM registers 3, 6 or 7, yet they are used:
 *        3  ekern, ecust, rtc.dll, helper.ldd, product_info.dll
 *           (+0x48 read(id, ...), +0x50 write(id, ...); ids 5, 13, 14, 15, 0x1FF)
 *        6  medint.pdd (internal flash, drive C:)
 *        7  (no user found yet)
 *   3. NOS installs a kernel object through ekern export ordinal 394
 *      (0x50336A08: stores its argument at 0x80006BC4, Kern::Fault 34 if
 *      already set). No Symbian ROM file imports ordinal 394. After the
 *      extensions the kernel calls its vtable +0x0C (0x5032B934), and
 *      later +0x18 (0x5032F80C) and +0x20 (0x503367F8); it adds time
 *      deltas into its word +8 (0x50334368, 0x5033666C) and sets bit 31
 *      of word +12 (0x5033647C). It looks like EKA1's power-model object.
 *      Its base class is in ekern: constructor = ordinal 493 (0x50336694),
 *      vtable 0x503414B8 whose slots from 7 (+0x1C) are pure virtual
 *      (0x5033F720); power handlers (epbus.dll, via ordinal 5) are queued
 *      on its TDblQue at +16.
 *   4. NOS sets the variant's flag word +0x90 through variant vtable +0x128
 *      (ecust 0x50343F5C); nothing in the Symbian ROM calls it. ecust
 *      0x50342B68 spins until bit 1 is set, then faults (12) unless bit 0
 *      is set (0x50342BB0) and reads service 3 id 5. The stub sets 3.
 * This stub registers placeholder objects for 3, 6 and 7 and installs a
 * placeholder object for item 3; all their methods return 0 (KErrNone) without
 * touching their arguments. It is assembled to
 * model/.build/nos-stub.bin and placed at the NOS entry by rom-patches.txt.
 * It deliberately implements nothing else: every behaviour added here is a
 * guess about NOS and must be justified by the caller's code.
 */
    .arm
    .text
    .global _start
_start:
    stmfd   sp!, {r4-r6, lr}
    ldr     r4, =0x8000038C         @ kernel's pointer to the variant object
    ldr     r4, [r4]
    adr     r5, services
1:  ldr     r1, [r5], #4            @ service number, -1 ends the list
    cmn     r1, #1
    beq     2f
    ldr     r2, =0x8000C378         @ NOS BSS, zeroed by nosstarter.ext
    add     r2, r2, r1, lsl #4      @ one 16-byte object per service
    cmp     r1, #3
    adreq   r3, svc3_vtable
    adrne   r3, vtable
    str     r3, [r2]
    mov     r0, r4
    ldr     r3, [r4]
    mov     lr, pc
    ldr     pc, [r3, #0xFC]         @ variant->RegisterService(n, obj)
    b       1b
2:  mov     r0, r4                  @ variant->SetFlags(3), vtable +0x128
    mov     r1, #3
    ldr     r3, [r4]
    mov     lr, pc
    ldr     pc, [r3, #0x128]
    ldr     r4, =0x8000C378 + 0x100 @ power-model object (0x100 zero bytes)
    mov     r0, r4
    ldr     r3, =0x50342818         @ ekern ordinal 493: base constructor 0x50336694
    ldr     r3, [r3]                @ (CBase, vtable 0x503414B8, TDblQue at +16 offset 4)
    mov     lr, pc
    mov     pc, r3
    adr     r3, pm_vtable
    str     r3, [r4]
    mov     r0, r4
    ldr     r3, =0x5034268C         @ ekern ordinal 394: install it (0x50336A08)
    ldr     r3, [r3]
    mov     lr, pc
    mov     pc, r3
    mov     r0, #0
    ldmfd   sp!, {r4-r6, lr}
    bx      lr

services:
    .word   3, 6, 7, -1

ret0:
    mov     r0, #0
    bx      lr

@ Service 3, vtable +0x48: read(this, id, dfc, buf, [sp] ?, [sp+4] length, [sp+8] ?)
@ Synchronous when dfc is 0 (product_info.dll 0x5041AD5C ids 14, 15; ekern
@ 0x5032BB7C id 13). With a DFC (a kernel TDfc made by ekern ordinal 504:
@ {next, prev, callback function, callback pointer}) the read completes
@ later: helper.ldd 0x5037F1C8 (id 12, 2 bytes, DFC at channel+0x44 whose
@ callback 0x5037F840 completes the client request with the value) and
@ ecust 0x50342BE0 (id 5). The value NOS returns is unknown; the stand-in
@ returns zeros, then queues the DFC with TDfc::Add (ekern ordinal 7,
@ 0x5033F304). product_info then takes its "known product, variant 0" path.
svc3_read:
    stmfd   sp!, {r4, lr}
    ldr     r12, [sp, #12]          @ length (caller's [sp+4])
    mov     r4, r2
    cmp     r3, #0
    beq     2f
    cmp     r12, #64
    movhi   r12, #64
    mov     r1, #0
1:  subs    r12, r12, #1
    strgeb  r1, [r3, r12]
    bgt     1b
2:  cmp     r4, #0
    beq     3f
    mov     r0, r4
    ldr     r3, =0x50342080         @ ekern ordinal 7: TDfc::Add
    ldr     r3, [r3]
    mov     lr, pc
    mov     pc, r3
3:  mov     r0, #0
    ldmfd   sp!, {r4, lr}
    bx      lr

    .ltorg
@ Power-model vtable: slots 0-6 as the kernel's base class (0x503414B8);
@ slots 7 on are pure virtual there (0x5033F720) and NOS's: return 0.
pm_vtable:
    .word   0, 0, 0x503400E0, 0x503366C0, 0x5033675C, 0x50336810, 0x50336A04
    .rept   57
    .word   ret0
    .endr
vtable:
    .rept   64
    .word   ret0
    .endr
svc3_vtable:
    .rept   18
    .word   ret0
    .endr
    .word   svc3_read               @ +0x48
    .rept   45
    .word   ret0
    .endr
