/*
 * The cellular side of the UPP_WD2's CTSI block (0x0C150000): the counters
 * and interrupt bits the phone's cellular software (NOS) runs on, as the
 * core has them (rtl/upp/upp_uif.sv). Found by running the unmodified RH-29
 * 4.10 firmware (docs/FIRMWARE-PROFILES.md has the evidence per register):
 *
 *   0x0C150010  write 1s: disable. Bit 7 the deadline compare, bits 10:9 the
 *               MDI events, bits 13:12 the two software interrupts, which a
 *               write here also withdraws (NOS 0x514C1BF2 requests one with
 *               0x1000 at +0x012 and clears it here)
 *   0x0C150012  write 1s: enable; bits 13:12 also raise the software
 *               interrupt. A read gives the enables; the other bits of the
 *               word are storage
 *   0x0C150100  status (the register is in ngage_keypad.c): bits 13:12, 10:9
 *               and 7 are these events, latched until written 1
 *   0x0C150112  delay calibration: a down-counter at 32.768 kHz, from the
 *               window through 0 and then from the window again (NOS
 *               0x514C2C7C takes start minus current, plus window + 1 when
 *               current is the larger)
 *   0x0C150114  the window; 0 counts and reads as 0x0080. A write starts the
 *               count again at the new window
 *   0x0C150116  the slow counter, 64 Hz: one step every 512 calibration
 *               ticks
 *   0x0C150118  its compare: status bit 7 is set when the counter comes to
 *               this value, or holds it when it is written, and again every
 *               65,536 steps
 *
 * The 32.768 kHz rate and the default window are the original N-Gage
 * model's, taken over with the core's; the phone's are not measured. Time
 * is guest time (QEMU_CLOCK_VIRTUAL), counted from the start of the run.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "hw/arm/ngage.h"

#define CAL_HZ          32768
#define CAL_DEFAULT     0x0080u
#define EN_BASE         0x0C150010
#define CAL_BASE        0x0C150110

typedef struct NGageCtsi {
    MemoryRegion en_mr, cal_mr;
    uint32_t st010, st110, st118;   /* the bits behind the registers: storage */
    uint16_t window, compare;
    uint64_t cal_k0;                /* the calibration tick of the last window write */
    bool compare_valid;
    bool nos_enable, nos_pending;
    uint8_t soft_enable, soft_pending, mdi_enable, mdi_pending;
    QEMUTimer *cmp_timer;
} NGageCtsi;

static NGageCtsi *the_ctsi;

static uint64_t cal_ticks(void)
{
    return muldiv64(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL), CAL_HZ, NANOSECONDS_PER_SECOND);
}

static uint32_t cal_reload(NGageCtsi *s)
{
    return s->window ? s->window : CAL_DEFAULT;
}

static uint16_t cal_counter(NGageCtsi *s)
{
    uint32_t r = cal_reload(s);

    return r - (uint32_t)((cal_ticks() - s->cal_k0) % (r + 1));
}

static uint16_t nos_counter(void)
{
    return cal_ticks() >> 9;
}

static void ctsi_update(NGageCtsi *s)
{
    ngage_ctsi_set(2, (s->nos_pending && s->nos_enable) ||
                      (s->soft_pending & s->soft_enable) ||
                      (s->mdi_pending & s->mdi_enable));
}

/* The next time the slow counter comes to the compare value. */
static void cmp_schedule(NGageCtsi *s)
{
    uint64_t n = cal_ticks() >> 9;
    uint64_t target = (n & ~UINT64_C(0xFFFF)) | s->compare;

    if (target <= n) {
        target += 0x10000;
    }
    timer_mod(s->cmp_timer, target * NGAGE_NOS_TICK_NS);
}

static void cmp_fire(void *opaque)
{
    NGageCtsi *s = opaque;

    s->nos_pending = true;
    ctsi_update(s);
    cmp_schedule(s);
}

uint16_t ngage_ctsi_nos_status(void)
{
    NGageCtsi *s = the_ctsi;

    if (!s) {
        return 0;
    }
    return s->soft_pending << 12 | s->mdi_pending << 9 | s->nos_pending << 7;
}

void ngage_ctsi_nos_ack(uint16_t val)
{
    NGageCtsi *s = the_ctsi;

    if (!s) {
        return;
    }
    s->soft_pending &= ~(val >> 12) & 3;
    s->mdi_pending &= ~(val >> 9) & 3;
    if (val & 0x80) {
        s->nos_pending = false;
    }
    ctsi_update(s);
}

void ngage_ctsi_mdi_events(unsigned bits)
{
    NGageCtsi *s = the_ctsi;

    if (s && (bits & 3)) {
        s->mdi_pending |= bits & 3;
        ctsi_update(s);
    }
}

static uint64_t en_read(void *opaque, hwaddr off, unsigned size)
{
    NGageCtsi *s = opaque;
    uint32_t w = (s->st010 & ~0x36800000u) | (uint32_t)s->soft_enable << 28 |
                 (uint32_t)s->mdi_enable << 25 | (uint32_t)s->nos_enable << 23;
    uint64_t v = ngage_take(w, off, size);

    ngage_trace_log("ctsi", false, EN_BASE + off, size, v);
    return v;
}

static void en_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageCtsi *s = opaque;
    unsigned be;
    uint32_t w = ngage_lanes(off, size, val, &be), m = ngage_be_mask(be);
    unsigned soft_set = (be & 8) ? (w >> 28) & 3 : 0, soft_off = (be & 2) ? (w >> 12) & 3 : 0;
    unsigned mdi_set = (be & 8) ? (w >> 25) & 3 : 0, mdi_off = (be & 2) ? (w >> 9) & 3 : 0;

    ngage_trace_log("ctsi", true, EN_BASE + off, size, val);
    s->st010 = (s->st010 & ~m) | (w & m);
    s->nos_enable = (s->nos_enable || ((be & 4) && (w & (1u << 23)))) &&
                    !((be & 1) && (w & 0x80));
    s->soft_enable = (s->soft_enable | soft_set) & ~soft_off;
    s->soft_pending = (s->soft_pending | soft_set) & ~soft_off;
    s->mdi_enable = (s->mdi_enable | mdi_set) & ~mdi_off;
    ctsi_update(s);
}

static uint64_t cal_read(void *opaque, hwaddr off, unsigned size)
{
    NGageCtsi *s = opaque;
    uint32_t w;
    uint64_t v;

    switch (off >> 2) {
    case 0: w = (s->st110 & 0xFFFF) | (uint32_t)cal_counter(s) << 16; break;
    case 1: w = (uint32_t)nos_counter() << 16 | cal_reload(s); break;
    default: w = (s->st118 & 0xFFFF0000u) | s->compare; break;
    }
    v = ngage_take(w, off, size);
    ngage_trace_log("ctsi", false, CAL_BASE + off, size, v);
    return v;
}

static void cal_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageCtsi *s = opaque;
    unsigned be;
    uint32_t w = ngage_lanes(off, size, val, &be), m = ngage_be_mask(be);

    ngage_trace_log("ctsi", true, CAL_BASE + off, size, val);
    switch (off >> 2) {
    case 0:
        s->st110 = (s->st110 & ~(m & 0xFFFF)) | (w & m & 0xFFFF);   /* the counter takes no writes */
        break;
    case 1:
        if (be & 3) {
            s->window = (s->window & ~m) | (w & m);
            s->cal_k0 = cal_ticks();
        }
        break;
    default:
        s->st118 = (s->st118 & ~m) | (w & m);
        if (be & 3) {
            s->compare = (s->compare & ~m) | (w & m);
            s->compare_valid = true;
            if (nos_counter() == s->compare) {
                s->nos_pending = true;
                ctsi_update(s);
            }
            cmp_schedule(s);
        }
        break;
    }
}

static const MemoryRegionOps en_ops = {
    .read = en_read, .write = en_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static const MemoryRegionOps cal_ops = {
    .read = cal_read, .write = cal_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

void ngage_ctsi_create(MemoryRegion *sysmem)
{
    NGageCtsi *s = g_new0(NGageCtsi, 1);

    the_ctsi = s;
    s->cmp_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, cmp_fire, s);
    memory_region_init_io(&s->en_mr, NULL, &en_ops, s, "ngage.ctsi-010", 4);
    memory_region_add_subregion(sysmem, EN_BASE, &s->en_mr);
    memory_region_init_io(&s->cal_mr, NULL, &cal_ops, s, "ngage.ctsi-110", 12);
    memory_region_add_subregion(sysmem, CAL_BASE, &s->cal_mr);
}
