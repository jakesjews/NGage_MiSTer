/*
 * The Bluetooth module (CBUS device 5) and its interrupt into UPP_WD2.
 *
 * The module itself is model/hw/ngage_bt_chip.h (shared with the core's
 * benches); this file gives it time, a log and the interrupt path.
 *
 * Interrupt path, from cbus.dll and btldd.ldd (RH-29 v4.60 addresses):
 *   0x0C150102  CTSI interrupt status, second group. Bit 4 is the Bluetooth
 *               module's line: cbus.dll's handler on IrqCTSI_IRQ tests it
 *               (0x5037D5D4) and calls the handler btldd registered, which
 *               writes 0x10 here to clear it (0x503F0B68).
 *   0x0C150014  write 1s: disable those bits of the group (btldd 0x503F084C)
 *   0x0C150016  write 1s: enable them (btldd 0x503F0B48)
 * The bit is taken as a latch set by a pulse from the module, cleared by
 * writing 1; it reaches interrupt source 25 and reads as set only while
 * enabled. The second half is a guess, and the safe one: cbus.dll faults
 * ("CBus:" 7) when it finds the bit set with no handler registered, which
 * a module speaking after btldd has closed its channel would otherwise do.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "hw/arm/ngage.h"
#include "hw/arm/ngage_bt_chip.h"

#define BT_IRQ_BIT      0x0010
/* From the reset request to the module's "I have reset": a guess, the
 * driver waits up to 1.5 s (btldd 0x503F1034). */
#define BT_RESET_NS     (10 * 1000 * 1000)
/* The unit of an inquiry's length, 1.28 s (Bluetooth 1.1, HCI Inquiry). */
#define BT_INQ_UNIT_NS  INT64_C(1280000000)

typedef struct NGageBt {
    BtChip chip;
    MemoryRegion en_mr, st_mr;
    uint16_t latch, enable;
    QEMUTimer *reset_timer, *inq_timer;
    FILE *log;
} NGageBt;

static NGageBt *the_bt;

static void bt_log(NGageBt *s, const char *fmt, ...)
{
    va_list ap;

    if (!s->log) {
        return;
    }
    if (ngage_log_time) {
        fprintf(s->log, "%11.6f ", ngage_guest_seconds());
    }
    va_start(ap, fmt);
    vfprintf(s->log, fmt, ap);
    va_end(ap);
    fputc('\n', s->log);
}

static void bt_log_bytes(NGageBt *s, const char *what, const uint8_t *p, unsigned n)
{
    if (!s->log) {
        return;
    }
    if (ngage_log_time) {
        fprintf(s->log, "%11.6f ", ngage_guest_seconds());
    }
    fprintf(s->log, "%s", what);
    for (unsigned i = 0; i < n; i++) {
        fprintf(s->log, " %02x", p[i]);
    }
    fputc('\n', s->log);
}

static void bt_irq_update(NGageBt *s)
{
    ngage_ctsi_set(1, (s->latch & s->enable) != 0);
}

/* Whatever the module did in the last call: log it, pulse the line. */
static void bt_after(NGageBt *s)
{
    BtChip *c = &s->chip;

    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    if (c->tx_done) {
        bt_log_bytes(s, "HCI<", c->tx, c->tx_done);
        c->tx_done = 0;
    }
    if (c->rx_new) {
        uint8_t b[BT_RX_MAX];

        c->rx_new = false;
        for (unsigned i = 0; i < c->rx_len; i++) {
            b[i] = bt_rx_byte(c, i);
        }
        bt_log_bytes(s, "HCI>", b, c->rx_len);
    }
    if (c->inq_stop) {
        c->inq_stop = false;
        timer_del(s->inq_timer);
    }
    if (c->inq_start) {
        timer_mod(s->inq_timer, now + c->inq_start * BT_INQ_UNIT_NS);
        c->inq_start = 0;
    }
    if (c->reset_req) {
        c->reset_req = false;
        bt_log(s, "reset requested");
        timer_mod(s->reset_timer, now + BT_RESET_NS);
    }
    if (c->irq) {
        c->irq = false;
        s->latch |= BT_IRQ_BIT;
        bt_irq_update(s);
    }
}

static void bt_reset_done(void *opaque)
{
    NGageBt *s = opaque;

    bt_chip_reset_done(&s->chip);
    bt_log(s, "reset done");
    bt_after(s);
}

static void bt_inq_done(void *opaque)
{
    NGageBt *s = opaque;

    bt_chip_inquiry_done(&s->chip);
    bt_after(s);
}

uint32_t ngage_bt_read(unsigned reg)
{
    NGageBt *s = the_bt;
    uint32_t v = bt_chip_read(&s->chip, reg);

    bt_after(s);
    return v;
}

void ngage_bt_write(unsigned reg, uint32_t val)
{
    NGageBt *s = the_bt;

    bt_chip_write(&s->chip, reg, val);
    bt_after(s);
}

static uint64_t bt_en_read(void *opaque, hwaddr off, unsigned size)
{
    NGageBt *s = opaque;

    return s->enable;
}

static void bt_en_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageBt *s = opaque;

    ngage_trace_log("ctsi", true, 0x0C150014 + off, size, val);
    if (off & 2) {
        s->enable |= val;
    } else {
        s->enable &= ~val;
    }
    bt_irq_update(s);
}

static uint64_t bt_st_read(void *opaque, hwaddr off, unsigned size)
{
    NGageBt *s = opaque;

    ngage_trace_log("ctsi", false, 0x0C150102, size, s->latch & s->enable);
    return s->latch & s->enable;
}

static void bt_st_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageBt *s = opaque;

    ngage_trace_log("ctsi", true, 0x0C150102, size, val);
    s->latch &= ~val;
    bt_irq_update(s);
}

static const MemoryRegionOps bt_en_ops = {
    .read = bt_en_read, .write = bt_en_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 2, .max_access_size = 2 },
};

static const MemoryRegionOps bt_st_ops = {
    .read = bt_st_read, .write = bt_st_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 2, .max_access_size = 2 },
};

void ngage_bt_create(MemoryRegion *sysmem, FILE *log)
{
    NGageBt *s = g_new0(NGageBt, 1);

    the_bt = s;
    s->log = log;
    bt_chip_init(&s->chip);
    s->reset_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, bt_reset_done, s);
    s->inq_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, bt_inq_done, s);
    memory_region_init_io(&s->en_mr, NULL, &bt_en_ops, s, "ngage.ctsi-014", 4);
    memory_region_add_subregion(sysmem, 0x0C150014, &s->en_mr);
    memory_region_init_io(&s->st_mr, NULL, &bt_st_ops, s, "ngage.ctsi-102", 2);
    memory_region_add_subregion(sysmem, 0x0C150102, &s->st_mr);
}
