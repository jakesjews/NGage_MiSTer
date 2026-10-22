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
 *   5. rtc.dll (service 1) fetches service 3 only inside its service method
 *      +0x20 with event 1 (0x50349394 -> 0x50349088), which nothing in the
 *      Symbian ROM calls. Until then its service-3 pointer (+0x120) is 0, and
 *      HelperDrv control 7 (DosServer, rtc method +0x10 -> 0x5034A8F8) faults
 *      the kernel at 0x5034A944. Event 1 carries three 64-bit values (time
 *      pointers in r2, r3 and on the stack); rtc treats A != B or A == 0 as
 *      "time not valid" (state 9, 0x5034910C) and then reads the UEMK RTC
 *      itself. Read further (0x50349088): the first two are the base date
 *      (NOS keeps it in its flash: the UEMK RTC has only the time of day
 *      and an 8-bit day counter, see model/hw/ngage_cbus.c), to which
 *      rtc.dll adds the UEMK time (0x5034A678); the third is the alarm (0 =
 *      none). The stub gets the base date from nos_rtc_base (0x514A1CA4,
 *      nos_isi.c), which reads the HLE RTC date register, an emulator
 *      invention fed from the host or MiSTer clock, and sends it twice with
 *      no alarm. With no date (0) rtc.dll asks for the time at start-up.
 * This stub registers placeholder objects for 3, 6 and 7, installs a
 * placeholder object for item 3, and sends rtc.dll event 1 with the base
 * date; all placeholder
 * methods return 0 (KErrNone) without touching their arguments. It is assembled to
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
    ldr     r4, =0x8000038C         @ rtc.dll event 1, see 5. above
    ldr     r4, [r4]
    mov     r0, r4
    mov     r1, #1
    ldr     r3, [r4]
    mov     lr, pc
    ldr     pc, [r3, #0x100]        @ variant->GetService(1)
    subs    r4, r0, #0
    beq     3f
    ldr     r0, =0x8000C378 + 0x200 @ the base date: 8 bytes in NOS BSS
    ldr     r3, =0x514A1CA4         @ nos_rtc_base (nos_dll.S, nos_isi.c)
    mov     lr, pc
    mov     pc, r3
    ldr     r2, =0x8000C378 + 0x200
    add     r3, r2, #8              @ 8 zero bytes after it
    sub     sp, sp, #8
    str     r3, [sp]                @ third value: no alarm
    mov     r3, r2                  @ second value = first, as rtc.dll checks
    mov     r0, r4
    mov     r1, #1
    ldr     r12, [r4]
    mov     lr, pc
    ldr     pc, [r12, #0x20]
    add     sp, sp, #8
3:  mov     r0, #0
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
@ Id 12 is HelperDrv's "auxstart" query, which EStart makes at every boot
@ (up to seven times): 105 makes it erase and format C: and the boot goes
@ on; 0 leaves C: as it is. With a blank C: (a fresh image) 0 would leave
@ C: a RAM drive, Starter then takes the (0, 210) list, finds no backup
@ server and the kernel faults (docs/UPP_WD2.md, docs/PROGRESS-LOG.md
@ 2026-10-21); with a formatted C: 105 erased all 71 sectors at every boot
@ (50 s at the chip's erase time, and the Time dialog at every start, the
@ format having removed the first-boot marker; 2026-10-22). So the answer
@ is 105 only while C: is blank, which the core and the model report in
@ the HLE register 0x0C1F0104 (bit 0: the C: area's first word is erased).
svc3_read:
    stmfd   sp!, {r4, lr}
    ldr     r12, [sp, #12]          @ length (caller's [sp+4])
    mov     r4, r2
    cmp     r3, #0
    beq     2f
    cmp     r12, #64
    movhi   r12, #64
    mov     lr, #0
1:  subs    r12, r12, #1
    strgeb  lr, [r3, r12]
    bgt     1b
    cmp     r1, #12                 @ auxstart: 105 = format C:, only while it is blank
    bne     2f
    ldr     r12, =0x581F0104        @ HLE: C: area blank (core upp_periph, model hw/ngage_cbus.c)
    ldr     r12, [r12]
    tst     r12, #1
    movne   lr, #105
    strh    lr, [r3]                @ 0 when C: has a file system
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
