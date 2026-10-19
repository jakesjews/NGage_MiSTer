/*
 * UPP_WD2 register space as far as it is understood. Unknown registers
 * behave as plain storage (reads return the last value written) and the
 * first access to each register is logged with the guest PC, so the log
 * doubles as a list of registers the firmware uses. Registers whose
 * behaviour is known are special-cased in upp_read_hook / upp_write_hook.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "hw/arm/ngage.h"

typedef struct UPPBlock {
    MemoryRegion mr;
    hwaddr base;
    uint32_t size;
    uint32_t *regs;
    uint8_t *seen;      /* bit 0: read logged, bit 1: write logged */
    const char *name;
} UPPBlock;

static FILE *upp_log;

void ngage_upp_set_log(FILE *fp)
{
    upp_log = fp;
}

static void upp_note(UPPBlock *b, hwaddr off, bool write, uint64_t val, unsigned size)
{
    uint32_t i = off >> 2;
    uint8_t bit = write ? 2 : 1;

    if (!upp_log || (b->seen[i] & bit)) {
        return;
    }
    b->seen[i] |= bit;
    fprintf(upp_log, "%s %-9s %08" HWADDR_PRIx " size=%u val=%08" PRIx64 " pc=%08x\n",
            write ? "W" : "R", b->name, b->base + off, size, val, ngage_guest_pc());
}

/*
 * Read quirks loaded from a text file (model/upp-quirks.txt): bits forced
 * on or off when a register is read. One line per register:
 *     <physical address> <or-mask> <and-mask>   # what it is, where it was found
 */
typedef struct Quirk { uint32_t pa, or_mask, and_mask; } Quirk;
static Quirk *quirks;
static int nquirks;

void ngage_upp_load_quirks(const char *path)
{
    FILE *fp = fopen(path, "r");
    char line[512];

    if (!fp) {
        error_report("ngage: cannot open quirks file %s", path);
        exit(1);
    }
    while (fgets(line, sizeof(line), fp)) {
        unsigned long a, o, n;
        char *hash = strchr(line, '#');
        if (hash) {
            *hash = 0;
        }
        if (sscanf(line, "%li %li %li", (long *)&a, (long *)&o, (long *)&n) == 3) {
            quirks = g_renew(Quirk, quirks, nquirks + 1);
            quirks[nquirks++] = (Quirk){ a, o, n };
        }
    }
    fclose(fp);
}

static bool upp_read_hook(UPPBlock *b, hwaddr pa, uint32_t *val)
{
    for (int i = 0; i < nquirks; i++) {
        if (quirks[i].pa == pa) {
            *val = (*val | quirks[i].or_mask) & quirks[i].and_mask;
            return true;
        }
    }
    return false;
}

static void upp_write_hook(UPPBlock *b, hwaddr pa, uint32_t *val)
{
}

static uint64_t upp_read(void *opaque, hwaddr off, unsigned size)
{
    UPPBlock *b = opaque;
    uint32_t v = b->regs[off >> 2];
    unsigned shift = (off & 3) * 8;

    upp_read_hook(b, b->base + (off & ~3), &v);
    v >>= shift;
    if (size < 4) {
        v &= (1u << (size * 8)) - 1;
    }
    upp_note(b, off & ~3, false, v, size);
    return v;
}

static void upp_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    UPPBlock *b = opaque;
    uint32_t *r = &b->regs[off >> 2];
    unsigned shift = (off & 3) * 8;
    uint32_t mask = (size == 4) ? 0xFFFFFFFFu : (((1u << (size * 8)) - 1) << shift);
    uint32_t v = (*r & ~mask) | (((uint32_t)val << shift) & mask);

    upp_note(b, off & ~3, true, val, size);
    upp_write_hook(b, b->base + (off & ~3), &v);
    *r = v;
}

static const MemoryRegionOps upp_ops = {
    .read = upp_read,
    .write = upp_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

void ngage_upp_block(MemoryRegion *sysmem, const char *name, hwaddr base, uint32_t size)
{
    UPPBlock *b = g_new0(UPPBlock, 1);

    b->base = base;
    b->size = size;
    b->name = name;
    b->regs = g_new0(uint32_t, size / 4);
    b->seen = g_new0(uint8_t, size / 4);
    memory_region_init_io(&b->mr, NULL, &upp_ops, b, name, size);
    memory_region_add_subregion_overlap(sysmem, base, &b->mr, -10);
}
