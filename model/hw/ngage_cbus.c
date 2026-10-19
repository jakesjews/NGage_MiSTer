/*
 * UPP_WD2 CBUS master (3-wire 1 MHz control bus to the UEMK power-management
 * ASIC, the ZOCUS current sensor and the Bluetooth module) and a register
 * model of the UEMK. Protocol from RH-29 v4.60 boot code:
 *
 *   0x0C150420  device address (UEMK = 0x0F)               write 0x35F0/0x3634
 *   0x0C150422  register; bit 8 set = read, starts it     read 0x3640
 *               on read: bit 10 = transfer done            polls 0x360C/0x364C
 *   0x0C150424  data for the 0x35AC transfer form (device 0x10 seen)
 *   0x0C150426  write data (starts a write) / read data    0x3604/0x3668
 *
 * UEMK register semantics are not documented publicly; initial values come
 * from model/uemk-regs.txt and every transaction is logged.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "hw/arm/ngage.h"

#define CBUS_BASE       0x0C150420
#define UEMK_DEVICE     0x0F

typedef struct NGageCbus {
    MemoryRegion mr;
    uint16_t dev, reg, data24, rdata;
    uint16_t uemk[256];
    uint16_t uemk_ro[256];      /* read value for registers marked "ro" */
    uint8_t uemk_is_ro[256];
    FILE *log;
} NGageCbus;

static void cbus_log(NGageCbus *s, const char *what, uint16_t dev, uint16_t reg, uint16_t val)
{
    if (s->log) {
        fprintf(s->log, "%s dev=%02x reg=%02x val=%04x pc=%08x\n", what, dev, reg, val, ngage_guest_pc());
    }
}

static uint16_t cbus_device_read(NGageCbus *s, uint16_t dev, uint16_t reg)
{
    uint16_t v = 0;

    if (dev == UEMK_DEVICE) {
        v = s->uemk_is_ro[reg & 0xFF] ? s->uemk_ro[reg & 0xFF] : s->uemk[reg & 0xFF];
    }
    cbus_log(s, "R", dev, reg, v);
    return v;
}

static void cbus_device_write(NGageCbus *s, uint16_t dev, uint16_t reg, uint16_t val)
{
    cbus_log(s, "W", dev, reg, val);
    if (dev == UEMK_DEVICE) {
        s->uemk[reg & 0xFF] = val;
        if ((reg & 0xFF) == 0x32 && val == 0) {
            qemu_log("ngage: UEMK register 0x32 = 0 (boot power-off path) pc=%08x\n", ngage_guest_pc());
        }
    }
}

static uint64_t cbus_read(void *opaque, hwaddr off, unsigned size)
{
    NGageCbus *s = opaque;
    uint64_t v;

    switch (off) {
    case 0x0: v = s->dev; break;
    case 0x2: v = s->reg | (1u << 10); break;   /* always done */
    case 0x4: v = s->data24; break;
    case 0x6: v = s->rdata; break;
    default:  v = 0;
    }
    if (size == 4 && off == 0) {
        v = s->dev | ((uint32_t)(s->reg | (1u << 10)) << 16);
    } else if (size == 4 && off == 4) {
        v = s->data24 | ((uint32_t)s->rdata << 16);
    }
    return v;
}

static void cbus_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageCbus *s = opaque;

    switch (off) {
    case 0x0:
        s->dev = val;
        break;
    case 0x2:
        s->reg = val & 0x3FF;
        if (val & 0x100) {
            s->rdata = cbus_device_read(s, s->dev, val & 0xFF);
        }
        break;
    case 0x4:
        s->data24 = val;
        cbus_log(s, "W24", s->dev, 0, val);
        break;
    case 0x6:
        cbus_device_write(s, s->dev, s->reg & 0xFF, val);
        break;
    }
}

static const MemoryRegionOps cbus_ops = {
    .read = cbus_read, .write = cbus_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 2, .max_access_size = 4 },
    .impl = { .min_access_size = 2, .max_access_size = 4 },
};

void ngage_cbus_create(MemoryRegion *sysmem, const char *uemk_regs, FILE *log)
{
    NGageCbus *s = g_new0(NGageCbus, 1);

    s->log = log;
    if (uemk_regs) {
        FILE *fp = fopen(uemk_regs, "r");
        char line[256];
        if (!fp) {
            error_report("ngage: cannot open %s", uemk_regs);
            exit(1);
        }
        while (fgets(line, sizeof(line), fp)) {
            long r, v;
            char kind[8] = "";
            char *h = strchr(line, '#');
            if (h) {
                *h = 0;
            }
            int n = sscanf(line, "%li %li %7s", &r, &v, kind);
            if (n >= 2) {
                s->uemk[r & 0xFF] = v;
                if (n == 3 && !strcmp(kind, "ro")) {
                    s->uemk_ro[r & 0xFF] = v;
                    s->uemk_is_ro[r & 0xFF] = 1;
                }
            }
        }
        fclose(fp);
    }
    memory_region_init_io(&s->mr, NULL, &cbus_ops, s, "ngage.cbus", 0x10);
    memory_region_add_subregion(sysmem, CBUS_BASE, &s->mr);
}
