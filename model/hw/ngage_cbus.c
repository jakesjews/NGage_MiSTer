/*
 * UPP_WD2 CBUS master (3-wire 1 MHz control bus to the UEMK power-management
 * ASIC, the ZOCUS current sensor and the Bluetooth module) and register
 * models of the devices behind it.
 *
 * Register interface (UIF block, 16-bit registers), from RH-29 v4.60
 * bootstrap 0x35AC-0x3678 and cbus.dll 0x5037CF4C (read) / 0x5037D28C (write):
 *
 *   0x0C150420  transfer length: bits 4:0 = number of data bits - 1
 *               (cbus.dll writes width-1 from its register table; bits 7:5
 *               carry an extra field on some writes, 0x5037D330, meaning unknown)
 *   0x0C150422  control: bits 4:0 register, bits 7:5 device, bit 8 = read
 *               (writing it starts the read), bit 9 set on some writes;
 *               read: bit 10 = idle/done (polled before and after every transfer)
 *   0x0C150424  data bits 31:16 (written before +0x426 when width > 16, 0x5037D388;
 *               read after a read when width > 16, 0x5037D074)
 *   0x0C150426  data bits 15:0; writing it starts a write (bootstrap 0x3604)
 *
 * Devices seen (cbus.dll register table at 0x5037E544: {device, type,
 * register, shadow, width} x 69):
 *   1  UEMK (TriX names the same register numbers on the DCT4 UEM)
 *   4  unknown, 25 registers, widths 2..20 bits; probably ZOCUS (LM3820)
 *      because of the 20-bit counters (guess). cbus.dll self-test 0x5037E008:
 *      register 0 must read 0x04xx, register 0x0D must read back what is written.
 *   5  unknown, 8 registers.
 * Register values come from model/cbus-regs.txt; every transaction is logged.
 *
 * UEMK A/D converter (register numbers as TriX's DCT4 UEM): writing register
 * 0x19 with bit 11 set starts a conversion of channel bits 15:12; register
 * 0x1A then reads the 10-bit result. The bootstrap (0x3104) and cbus.dll
 * (0x5037E194) both write 0x68xx (channel 6, start) and read 0x1A & 0x3FF;
 * cbus.dll classifies the value as the battery-size indicator (BSI):
 * 5-49 and 50-93 select two test modes, 380-590 a normal battery, anything
 * else "unknown" (0x5037E240-0x5037E280; ecust then reports start-up reason
 * 9). Channel values come from "adc <channel> <value>" lines in
 * cbus-regs.txt; unset channels read 0.
 *
 * Power key: UEMK register 0x1F bit 1 reads 1 while the power key is held.
 * ekeyb's key-state read (0x5041CC9C) reports it as key bit 28 (scan code
 * 0xA6) and polls it while it is down; the bootstrap (0x3090) takes the
 * normal power-on path when it is set. The keypad model holds the key from
 * reset for one guest second (a user switching the phone on) and takes
 * "power" from the key script.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "hw/arm/ngage.h"

#define CBUS_BASE       0x0C150420
#define CBUS_DONE       (1u << 10)

typedef struct NGageCbus {
    MemoryRegion mr;
    uint16_t len, ctrl, data_hi, data_lo;
    uint32_t regs[8][32];
    uint32_t ro_val[8][32];
    uint8_t is_ro[8][32];
    uint16_t adc[16];
    bool power_key;
    FILE *log;
} NGageCbus;

static NGageCbus *the_cbus;

void ngage_cbus_set_power_key(bool down)
{
    if (the_cbus) {
        the_cbus->power_key = down;
    }
}

static void cbus_log(NGageCbus *s, const char *what, unsigned dev, unsigned reg,
                     unsigned bits, uint32_t val)
{
    if (s->log) {
        fprintf(s->log, "%s dev=%u reg=%02x bits=%2u val=%05x len=%04x ctrl=%04x pc=%08x\n",
                what, dev, reg, bits, val, s->len, s->ctrl, ngage_guest_pc());
    }
}

static unsigned cbus_bits(NGageCbus *s)
{
    return (s->len & 0x1F) + 1;
}

static void cbus_do_read(NGageCbus *s)
{
    unsigned dev = (s->ctrl >> 5) & 7, reg = s->ctrl & 0x1F, bits = cbus_bits(s);
    uint32_t v = s->is_ro[dev][reg] ? s->ro_val[dev][reg] : s->regs[dev][reg];

    if (dev == 1 && reg == 0x1F) {
        v = (v & ~2u) | (s->power_key ? 2u : 0);
    }

    if (bits < 32) {
        v &= (1u << bits) - 1;
    }
    s->data_lo = v;
    s->data_hi = v >> 16;
    cbus_log(s, "R", dev, reg, bits, v);
}

static void cbus_do_write(NGageCbus *s)
{
    unsigned dev = (s->ctrl >> 5) & 7, reg = s->ctrl & 0x1F, bits = cbus_bits(s);
    uint32_t v = s->data_lo | (bits > 16 ? (uint32_t)s->data_hi << 16 : 0);

    if (bits < 32) {
        v &= (1u << bits) - 1;
    }
    cbus_log(s, "W", dev, reg, bits, v);
    s->regs[dev][reg] = v;
    if (dev == 1 && reg == 0x19 && (v & 0x800) && !s->is_ro[1][0x1A]) {
        s->regs[1][0x1A] = s->adc[(v >> 12) & 15];
        if (s->log) {
            fprintf(s->log, "  ADC channel %u -> %u\n", (v >> 12) & 15, s->regs[1][0x1A]);
        }
    }
    if (dev == 1 && reg == 0x12 && v == 0) {
        qemu_log("ngage: UEMK register 0x12 = 0 (bootstrap power-off path) pc=%08x\n",
                 ngage_guest_pc());
    }
}

static uint64_t cbus_read(void *opaque, hwaddr off, unsigned size)
{
    NGageCbus *s = opaque;
    uint16_t r[4] = { s->len, s->ctrl | CBUS_DONE, s->data_hi, s->data_lo };
    uint64_t v = r[(off >> 1) & 3];

    if (size == 4) {
        v |= (uint64_t)r[((off >> 1) + 1) & 3] << 16;
    }
    return v;
}

static void cbus_write16(NGageCbus *s, hwaddr off, uint16_t val)
{
    switch (off & 6) {
    case 0:
        s->len = val;
        break;
    case 2:
        s->ctrl = val & 0x3FF;
        if (val & 0x100) {
            cbus_do_read(s);
        }
        break;
    case 4:
        s->data_hi = val;
        break;
    case 6:
        s->data_lo = val;
        cbus_do_write(s);
        break;
    }
}

static void cbus_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageCbus *s = opaque;

    cbus_write16(s, off, val);
    if (size == 4) {
        cbus_write16(s, off + 2, val >> 16);
    }
}

static const MemoryRegionOps cbus_ops = {
    .read = cbus_read, .write = cbus_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 2, .max_access_size = 4 },
    .impl = { .min_access_size = 2, .max_access_size = 4 },
};

/*
 * model/cbus-regs.txt: "<device> <register> <value> [ro]" or
 * "adc <channel> <value>" per line, '#' comments.
 */
static void cbus_load(NGageCbus *s, const char *path)
{
    FILE *fp = fopen(path, "r");
    char line[256];

    if (!fp) {
        error_report("ngage: cannot open %s", path);
        exit(1);
    }
    while (fgets(line, sizeof(line), fp)) {
        long d, r, v;
        char kind[8] = "";
        char *h = strchr(line, '#');
        if (h) {
            *h = 0;
        }
        if (sscanf(line, " adc %li %li", &r, &v) == 2) {
            s->adc[r & 15] = v;
            continue;
        }
        int n = sscanf(line, "%li %li %li %7s", &d, &r, &v, kind);
        if (n >= 3) {
            s->regs[d & 7][r & 31] = v;
            if (n == 4 && !strcmp(kind, "ro")) {
                s->ro_val[d & 7][r & 31] = v;
                s->is_ro[d & 7][r & 31] = 1;
            }
        }
    }
    fclose(fp);
}

void ngage_cbus_create(MemoryRegion *sysmem, const char *regs_path, FILE *log)
{
    NGageCbus *s = g_new0(NGageCbus, 1);

    the_cbus = s;
    s->power_key = true;                /* held at power-on, see ngage_keypad.c */
    s->log = log;
    if (regs_path) {
        cbus_load(s, regs_path);
    }
    memory_region_init_io(&s->mr, NULL, &cbus_ops, s, "ngage.cbus", 0x8);
    memory_region_add_subregion(sysmem, CBUS_BASE, &s->mr);
}
