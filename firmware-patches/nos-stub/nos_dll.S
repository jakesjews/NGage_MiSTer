/*
 * NOS stand-in, part 2 (firmware patch, see firmware-patches/rom-patches.txt):
 * the two exports of the hidden NOS DLL (TRomImageHeader at 0x51168FF0, uid3
 * 0x10005A05, export directory 0x511690BC) that point into the encrypted
 * NOS code. nosdriver.ldd (the NOSDRIVER logical device, loaded by EStart)
 * imports them through 0x511690C8 and 0x511690D0:
 *   ordinal 6 = 0x514A261C (obj, unit): called on an 8-byte allocation
 *     (nosdriver 0x511691EC); the channel later calls methods through the
 *     vtable at obj+4: +0x08 with 3 (delete, 0x511691A4), +0x0C cancel,
 *     +0x10 request, +0x14 control (0x51169288, 0x51169270, 0x51169258).
 *   ordinal 4 = 0x514A1CA0 (channel, unit & 0xFF) (nosdriver 0x511691FC).
 * Both branch to the ISI responder in nos_isi.c. Linked by nos_dll.ld at
 * 0x514A1CA0 (CS0 0xA1CA0); the space between the two entry points and
 * after them is encrypted NOS code that nothing else reads.
 */
    .arm
    .section .entry4, "ax"
    .global _start
_start:                                 @ 0x514A1CA0: NOS DLL ordinal 4
    b       nos_channel_open
    b       nos_rtc_base                @ 0x514A1CA4: for the entry stub (nos_stub.S)

    .section .entry6, "ax"
    b       nos_obj_ctor                @ 0x514A261C: NOS DLL ordinal 6
