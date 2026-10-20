/*
 * STI trace output window. The kernel's debug print (ekern 0x5031E4A8 and
 * 0x5031E538, used when trace-mask bit 30 is set; the ROM header has
 * iTraceMask 0xC0008003) first programs the STI block at 0x0C14D000
 * (0x5031E40C: +0 = 2, +2 = 0x300, +4 = 0x205, +8 = 0; DCT4's STI at
 * 0x0600D000 rebased), then stores the text one byte at a time to
 * incrementing addresses from virtual 0x59000000 (physical 0x0DE00000):
 * 0xC0 before the first byte at the window start, 0xE0 at 0x591D0000 when
 * it wraps. The model treats the window as a write sink (reads return 0)
 * and copies the text to a log file.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "hw/arm/ngage.h"

#define STI_WINDOW_BASE 0x0DE00000
#define STI_WINDOW_SIZE 0x00200000

typedef struct NGageSti {
    MemoryRegion mr;
    FILE *log;
    bool bol;
} NGageSti;

static uint64_t sti_read(void *opaque, hwaddr off, unsigned size)
{
    return 0;
}

static void sti_byte(NGageSti *s, uint8_t c)
{
    if (!s->log || c == 0xC0 || c == 0xE0 || c == '\r') {
        return;
    }
    if (c == '\n' || c == '\t' || (c >= 0x20 && c < 0x7F)) {
        fputc(c, s->log);
    } else {
        fprintf(s->log, "<%02x>", c);
    }
}

static void sti_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageSti *s = opaque;

    for (unsigned i = 0; i < size; i++) {
        sti_byte(s, val >> (8 * i));
    }
}

static const MemoryRegionOps sti_ops = {
    .read = sti_read, .write = sti_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

void ngage_sti_create(MemoryRegion *sysmem, FILE *log)
{
    NGageSti *s = g_new0(NGageSti, 1);

    s->log = log;
    memory_region_init_io(&s->mr, NULL, &sti_ops, s, "ngage.sti-window", STI_WINDOW_SIZE);
    memory_region_add_subregion(sysmem, STI_WINDOW_BASE, &s->mr);
}
