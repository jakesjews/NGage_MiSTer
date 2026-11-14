/*
 * UPP_WD2 interrupt controller, OS-timer interrupt unit and timers 0-5.
 * Everything is inferred from RH-29 v4.60 code; evidence is given per item
 * and collected in docs/UPP_WD2.md.
 *
 * Interrupt controller, 0x0C120100-0x0C12027F. Two planes with three banks
 * of 32 sources each (96 source numbers; NOS names 93 sources):
 *   IRQ plane  bank k at 0x0C120100 + 0x40*k
 *   FIQ plane  bank k at 0x0C1201C0 + 0x40*k
 *   per bank:
 *     +0x08  write 1s: enable those sources on this plane
 *            (ekern 0x5031E874 IRQ, 0x5031E998 FIQ: single-bit writes, never
 *            read-modify-write, so set semantics; boot 0x31D4 writes 1)
 *     +0x0C  write 1s: disable (ekern 0x5031E8CC / 0x5031E9F0; boot ISR 0x3074)
 *     +0x10  read: raw pending bits (ekern 0x5031E7B0 / 0x5031E930 test one bit)
 *     +0x14  read: number of the highest-priority pending enabled source in
 *            the bank, 1-based, 0 = none. IRQ dispatcher 0x5031C87C calls ISR
 *            n + 0x5C + 32*bank; FIQ dispatcher 0x5031C99C calls ISR
 *            n - 1 + 32*bank. Priority order is unknown; the model returns
 *            the lowest bit (guess).
 * Source numbering (bit b of bank k = source 32k+b) follows the kernel's
 * interrupt-name table (ekern 0x5031D674, names after the first ten) and the
 * reverse of NOS's source tables: Timer0-5 = 0-5, DMA0-7 = 6-13,
 * FlashCopyRdy 14, LCDBuffer 15, Ir4M 16-20, MMCDataIdle 21, MMCDataRdy 22,
 * MMCCmdIdle 23, MMCCmdRdy 24, CTSI_IRQ 25, CTSI_FIQ 26, APIIOAbort 27,
 * APIMissAlign 28, GPIOnLow/High = 29+2n/30+2n. Checked against: boot timer 0
 * uses bit 0; kernel timer 4 (0x0C120A80) uses bit 4 (0x5031C968); the
 * kernel enables bit 25 at start-up.
 *
 * OS-timer interrupt unit, 0x0C120040-0x0C12007F:
 *   +0x04 (0x0C120044) enable bits 2:0 (kernel writes 2 at 0x5031C7A8)
 *   +0x10 (0x0C120050) status bits 2:0, write 1 to clear; the FIQ dispatcher
 *         reads it first and treats bit 1 as the system tick (0x5031C99C).
 *   The model drives FIQ while status & enable. What sets the status bits
 *   is unknown (the kernel's 1/64 s tick is timer 0 on IRQ source 0, ISR
 *   0x5031C5B0), so nothing sets them yet.
 *
 * Timers, 0x0C120A00 + 0x20*n, n = 0..5 (stride inferred from timer 4 at
 * +0x80 using IRQ bit 4):
 *   +0x04 control: bit 1 = run, reloading from +0x18 on underflow (kernel
 *         tick timer 0, 0x5031C6E4; boot timer 0, 0x31AC; timer 4); bit 0
 *         alone = run once and stop at zero (guess: the high-resolution
 *         timer 1 is started with 1 and re-armed by writing +0x10 for each
 *         expiry, 0x5031CA78/0x5031CB1C). The kernel rewrites it until it
 *         reads back (0x5031EA58).
 *   +0x08 interrupt acknowledge: any write clears the timer's interrupt
 *         latch, which underflow sets; reads return the last value written.
 *         This is the one reading that fits all users: the tick ISR writes 0
 *         (0x5031C5C0), the high-resolution timer-1 ISR writes 1 without
 *         disabling its source (0x5031CACC), the boot and timer-4 ISRs write
 *         1 (0x3064, 0x5031C86C), starts write 0, and the boot then polls
 *         the value it wrote for nonzero (0x3208).
 *   +0x10 counter: write loads it, read returns the live down-count
 *   +0x18 reload value, loaded on underflow
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "qemu/log.h"
#include "hw/core/irq.h"
#include "hw/arm/ngage.h"

/*
 * 104/3 MHz: the kernel converts microseconds with x34666/1000 (0x5031CB74)
 * and its tick reload 0x843E2 (0x5031C6F0) then gives the EKA1 1/64 s tick.
 */
#define TIMER_HZ    34666667u
#define NTIMERS     6
#define NBANKS      3

typedef struct NGageTimer {
    struct NGageIntc *intc;
    int n;
    QEMUTimer *qt;
    uint32_t regs[8];
    bool running;
    uint32_t start_count;
    int64_t start_ns;
} NGageTimer;

typedef struct NGageIntc {
    MemoryRegion intc_mr, ostu_mr, timer_mr;
    qemu_irq irq, fiq;
    uint32_t pending[NBANKS];
    uint32_t enable[2][NBANKS];       /* [0] IRQ plane, [1] FIQ plane */
    uint32_t other[2][NBANKS][16];    /* registers without known behaviour */
    uint32_t ostu[16];
    NGageTimer timer[NTIMERS];
} NGageIntc;

static NGageIntc *the_intc;

static void intc_update(NGageIntc *s)
{
    bool irq = false, fiq = false;

    for (int k = 0; k < NBANKS; k++) {
        irq |= (s->pending[k] & s->enable[0][k]) != 0;
        fiq |= (s->pending[k] & s->enable[1][k]) != 0;
    }
    fiq |= (s->ostu[0x10 >> 2] & s->ostu[0x04 >> 2] & 7) != 0;
    qemu_set_irq(s->irq, irq);
    qemu_set_irq(s->fiq, fiq);
}

void ngage_ctsi_set(int who, bool level)
{
    static bool lines[2];

    lines[who & 1] = level;
    ngage_intc_set_source(NGAGE_IRQ_CTSI_IRQ, lines[0] || lines[1]);
}

void ngage_intc_set_source(int src, int level)
{
    NGageIntc *s = the_intc;
    uint32_t bit = 1u << (src & 31);

    if (!s || src < 0 || src >= 32 * NBANKS) {
        return;
    }
    if (level) {
        s->pending[src >> 5] |= bit;
    } else {
        s->pending[src >> 5] &= ~bit;
    }
    intc_update(s);
}

static uint64_t intc_read_(NGageIntc *s, hwaddr off);

static uint64_t intc_read(void *opaque, hwaddr off, unsigned size)
{
    uint64_t v = intc_read_(opaque, off);

    ngage_trace_log("intc", false, 0x0C120100 + off, size, v);
    return v;
}

static uint64_t intc_read_(NGageIntc *s, hwaddr off)
{
    int plane = off >= 0xC0;
    hwaddr o = off - (plane ? 0xC0 : 0);
    int k = o >> 6;
    uint32_t v;

    switch (o & 0x3F) {
    case 0x08:
        v = s->enable[plane][k];
        break;
    case 0x10:
        v = s->pending[k];
        break;
    case 0x14: {
        uint32_t act = s->pending[k] & s->enable[plane][k];
        v = act ? ctz32(act) + 1 : 0;
        break;
    }
    default:
        v = s->other[plane][k][(o & 0x3F) >> 2];
    }
    return v;
}

static void intc_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageIntc *s = opaque;
    ngage_trace_log("intc", true, 0x0C120100 + off, size, val);
    int plane = off >= 0xC0;
    hwaddr o = off - (plane ? 0xC0 : 0);
    int k = o >> 6;

    switch (o & 0x3F) {
    case 0x08:
        s->enable[plane][k] |= val;
        break;
    case 0x0C:
        s->enable[plane][k] &= ~(uint32_t)val;
        break;
    default:
        qemu_log_mask(LOG_UNIMP, "ngage intc: write %08x = %08x pc=%08x\n",
                      0x0C120100 + (unsigned)off, (unsigned)val, ngage_guest_pc());
        s->other[plane][k][(o & 0x3F) >> 2] = val;
    }
    intc_update(s);
}

static uint64_t ostu_read(void *opaque, hwaddr off, unsigned size)
{
    NGageIntc *s = opaque;
    uint32_t v = s->ostu[(off >> 2) & 15];

    ngage_trace_log("ostimer", false, 0x0C120040 + off, size, v);
    return v;
}

static void ostu_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageIntc *s = opaque;

    ngage_trace_log("ostimer", true, 0x0C120040 + off, size, val);
    if (off == 0x10) {
        s->ostu[4] &= ~(uint32_t)val;
    } else {
        s->ostu[(off >> 2) & 15] = val;
    }
    intc_update(s);
}

/* ---------------------------------------------------------------- timers */

static uint32_t ngtimer_count(NGageTimer *t)
{
    if (!t->running) {
        return t->regs[0x10 >> 2];
    }
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    uint64_t ticks = muldiv64(now - t->start_ns, TIMER_HZ, NANOSECONDS_PER_SECOND);
    return t->start_count - (uint32_t)ticks;
}

static void ngtimer_schedule(NGageTimer *t, uint32_t count)
{
    t->start_count = count;
    t->start_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    uint64_t ticks = count ? (uint64_t)count : (UINT64_C(1) << 32);
    timer_mod(t->qt, t->start_ns + muldiv64(ticks, NANOSECONDS_PER_SECOND, TIMER_HZ));
}

static void ngtimer_expired(void *opaque)
{
    NGageTimer *t = opaque;

    ngage_intc_set_source(t->n, 1);
    if (t->regs[0x04 >> 2] & 2) {
        ngtimer_schedule(t, t->regs[0x18 >> 2]);
    } else {
        t->running = false;
        t->regs[0x10 >> 2] = 0;
    }
}

static uint64_t timer_read(void *opaque, hwaddr off, unsigned size)
{
    NGageIntc *s = opaque;
    NGageTimer *t = &s->timer[(off >> 5) % NTIMERS];
    hwaddr o = off & 0x1F;

    uint32_t v = o == 0x10 ? ngtimer_count(t) : t->regs[o >> 2];

    ngage_trace_log("timer", false, 0x0C120A00 + off, size, v);
    return v;
}

static void timer_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageIntc *s = opaque;
    NGageTimer *t = &s->timer[(off >> 5) % NTIMERS];
    hwaddr o = off & 0x1F;

    ngage_trace_log("timer", true, 0x0C120A00 + off, size, val);
    switch (o) {
    case 0x04:
        if ((val & 3) && !t->running) {
            t->running = true;
            ngtimer_schedule(t, t->regs[0x10 >> 2]);
        } else if (!(val & 3) && t->running) {
            t->regs[0x10 >> 2] = ngtimer_count(t);
            t->running = false;
            timer_del(t->qt);
        }
        break;
    case 0x08:
        ngage_intc_set_source(t->n, 0);
        break;
    case 0x10:
        if (t->running) {
            ngtimer_schedule(t, val);
        } else if (t->regs[0x04 >> 2] & 3) {
            /* a one-shot timer that ran out is re-armed by a new count */
            t->running = true;
            ngtimer_schedule(t, val);
        }
        break;
    }
    t->regs[o >> 2] = val;
}

static const MemoryRegionOps intc_ops = {
    .read = intc_read, .write = intc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static const MemoryRegionOps ostu_ops = {
    .read = ostu_read, .write = ostu_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static const MemoryRegionOps timer_ops = {
    .read = timer_read, .write = timer_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

void ngage_intc_create(MemoryRegion *sysmem, qemu_irq cpu_irq, qemu_irq cpu_fiq)
{
    NGageIntc *s = g_new0(NGageIntc, 1);

    the_intc = s;
    s->irq = cpu_irq;
    s->fiq = cpu_fiq;
    for (int n = 0; n < NTIMERS; n++) {
        s->timer[n].intc = s;
        s->timer[n].n = n;
        s->timer[n].qt = timer_new_ns(QEMU_CLOCK_VIRTUAL, ngtimer_expired, &s->timer[n]);
    }
    memory_region_init_io(&s->ostu_mr, NULL, &ostu_ops, s, "ngage.ostimer-irq", 0x40);
    memory_region_add_subregion(sysmem, 0x0C120040, &s->ostu_mr);
    memory_region_init_io(&s->intc_mr, NULL, &intc_ops, s, "ngage.intc", 0x180);
    memory_region_add_subregion(sysmem, 0x0C120100, &s->intc_mr);
    memory_region_init_io(&s->timer_mr, NULL, &timer_ops, s, "ngage.timers", 0x20 * NTIMERS);
    memory_region_add_subregion(sysmem, 0x0C120A00, &s->timer_mr);
}
