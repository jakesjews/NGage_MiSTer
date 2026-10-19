/*
 * UPP_WD2 interrupt controller and timers, as far as the firmware has shown
 * them. Everything here is inferred from RH-29 v4.60 code and is marked
 * with the evidence; registers the firmware touches that are not modelled
 * here fall through to the storage block in ngage_upp.c.
 *
 *   0x0C120100  interrupt controller
 *     +0x08 enable (boot writes 1 at 0x31D4 to enable source 0)
 *     +0x0C acknowledge (boot IRQ handler writes 1 at 0x3074 for source 0)
 *   0x0C120A00  timer, source 0
 *     +0x04 control (2 = run, 0 = stop; 0x31AC, handler 0x306C)
 *     +0x08 flag the boot IRQ handler sets to 1 (0x3064); main code polls it
 *     +0x10, +0x18 load value (0x016B28C0 at 0x31B4/0x31BC)
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "qemu/log.h"
#include "hw/core/irq.h"
#include "hw/arm/ngage.h"

/* Assumed timer input clock: the 26 MHz system reference. TODO: confirm. */
#define TIMER_HZ    34666667u   /* 104/3 MHz: kernel reload 0x843E2 gives the 1/64 s EKA1 tick */

typedef struct NGageIntc {
    MemoryRegion intc_mr, timer_mr;
    qemu_irq irq;
    uint32_t pending, enable;
    uint32_t intc_regs[64];
    uint32_t timer_regs[64];
    QEMUTimer *timer;
    bool running;
    uint32_t start_count;
    int64_t start_ns;
} NGageIntc;

static void intc_update(NGageIntc *s)
{
    qemu_set_irq(s->irq, (s->pending & s->enable) != 0);
}

static void ngage_timer_expired2(NGageIntc *s);

static void ngage_timer_expired(void *opaque)
{
    ngage_timer_expired2(opaque);
}

static uint64_t intc_read(void *opaque, hwaddr off, unsigned size)
{
    NGageIntc *s = opaque;
    uint32_t v;

    switch (off) {
    case 0x00: v = s->pending; break;
    case 0x08: v = s->enable; break;
    default:   v = s->intc_regs[(off >> 2) & 63];
    }
    qemu_log_mask(LOG_UNIMP, "ngage intc: read +%02x = %08x pc=%08x\n", (unsigned)off, v, ngage_guest_pc());
    return v;
}

static void intc_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageIntc *s = opaque;

    qemu_log_mask(LOG_UNIMP, "ngage intc: write +%02x = %08x pc=%08x\n",
                  (unsigned)off, (unsigned)val, ngage_guest_pc());
    switch (off) {
    case 0x08:
        s->enable = val;
        break;
    case 0x0C:
        s->pending &= ~(uint32_t)val;
        break;
    default:
        s->intc_regs[(off >> 2) & 63] = val;
    }
    intc_update(s);
}

/*
 * Timer: 32-bit down-counter at +0x10 (live), reload value at +0x18,
 * +0x04 bit 1 = run. On underflow it raises source 0 and reloads from
 * +0x18 (0 wraps through 0xFFFFFFFF, i.e. free-running). The kernel
 * starts it with only +0x04 = 2 (ekern 0x5031E6C0) and then reads +0x10,
 * which fits a free-running counter.
 */
static uint32_t timer_count(NGageIntc *s)
{
    if (!s->running) {
        return s->timer_regs[0x10 >> 2];
    }
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    uint64_t ticks = muldiv64(now - s->start_ns, TIMER_HZ, NANOSECONDS_PER_SECOND);
    return s->start_count - (uint32_t)ticks;
}

static void timer_schedule(NGageIntc *s, uint32_t count)
{
    s->start_count = count;
    s->start_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    /* Underflow after count+1 ticks (count 0 fires on the next tick... of 2^32). */
    uint64_t ticks = count ? (uint64_t)count : (UINT64_C(1) << 32);
    timer_mod(s->timer, s->start_ns + muldiv64(ticks, NANOSECONDS_PER_SECOND, TIMER_HZ));
}

static void ngage_timer_expired2(NGageIntc *s)
{
    s->pending |= 1u << 0;
    qemu_log_mask(LOG_UNIMP, "ngage timer0: underflow\n");
    intc_update(s);
    timer_schedule(s, s->timer_regs[0x18 >> 2]);
}

static uint64_t timer_read(void *opaque, hwaddr off, unsigned size)
{
    NGageIntc *s = opaque;
    uint32_t v = (off == 0x10) ? timer_count(s) : s->timer_regs[(off >> 2) & 63];

    qemu_log_mask(LOG_UNIMP, "ngage timer0: read +%02x = %08x pc=%08x\n", (unsigned)off, v, ngage_guest_pc());
    return v;
}

static void timer_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageIntc *s = opaque;

    qemu_log_mask(LOG_UNIMP, "ngage timer0: write +%02x = %08x pc=%08x\n",
                  (unsigned)off, (unsigned)val, ngage_guest_pc());
    switch (off) {
    case 0x04:
        if ((val & 2) && !s->running) {
            s->running = true;
            timer_schedule(s, s->timer_regs[0x10 >> 2]);
        } else if (!(val & 2) && s->running) {
            s->timer_regs[0x10 >> 2] = timer_count(s);
            s->running = false;
            timer_del(s->timer);
        }
        break;
    case 0x10:
        if (s->running) {
            timer_schedule(s, val);
        }
        break;
    }
    s->timer_regs[(off >> 2) & 63] = val;
}

static const MemoryRegionOps intc_ops = {
    .read = intc_read, .write = intc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static const MemoryRegionOps timer_ops = {
    .read = timer_read, .write = timer_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

void ngage_intc_create(MemoryRegion *sysmem, qemu_irq cpu_irq)
{
    NGageIntc *s = g_new0(NGageIntc, 1);

    s->irq = cpu_irq;
    s->timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, ngage_timer_expired, s);
    memory_region_init_io(&s->intc_mr, NULL, &intc_ops, s, "ngage.intc", 0x100);
    memory_region_add_subregion(sysmem, 0x0C120100, &s->intc_mr);
    memory_region_init_io(&s->timer_mr, NULL, &timer_ops, s, "ngage.timer0", 0x100);
    memory_region_add_subregion(sysmem, 0x0C120A00, &s->timer_mr);
}
