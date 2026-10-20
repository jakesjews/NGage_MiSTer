/*
 * NOS stand-in, part 2 (model shortcut, see model/rom-patches.txt): the two
 * exports of the hidden NOS DLL (TRomImageHeader at 0x51168FF0, uid3
 * 0x10005A05, export directory 0x511690BC) that point into the encrypted
 * NOS code. nosdriver.ldd (the NOSDRIVER logical device, loaded by EStart)
 * imports them through 0x511690C8 and 0x511690D0:
 *   ordinal 6 = 0x514A261C (obj, unit): called on an 8-byte allocation
 *     (nosdriver 0x511691EC); the channel later calls methods through the
 *     vtable at obj+4: +0x08 with 3 (delete, 0x511691A4), +0x0C, +0x10,
 *     +0x14 (0x51169288, 0x51169270, 0x51169258).
 *   ordinal 4 = 0x514A1CA0 (channel, unit & 0xFF) (nosdriver 0x511691FC).
 * The stand-in builds the object with a vtable whose methods return 0, and
 * makes ordinal 4 a no-op. Linked at 0x514A1CA0 (CS0 0xA1CA0); the space
 * between the two entry points is encrypted NOS code that nothing else
 * reads.
 */
    .arm
    .text
    .global _start
_start:                                 @ 0x514A1CA0: NOS DLL ordinal 4
    mov     r0, #0
    bx      lr

ret0:
    mov     r0, #0
    bx      lr

vtable:
    .rept   32
    .word   ret0
    .endr

    .org    0x514A261C - 0x514A1CA0
nos_obj_ctor:                           @ 0x514A261C: NOS DLL ordinal 6
    mov     r1, #0
    str     r1, [r0]
    ldr     r1, =vtable
    str     r1, [r0, #4]
    bx      lr
    .ltorg
