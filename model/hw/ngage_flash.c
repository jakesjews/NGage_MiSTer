/*
 * Samsung K8S2815ETA / K8S6415ETA style NOR flash with the AMD command set,
 * as fitted to the N-Gage QD. Array reads go straight to host memory
 * (ROM device in "romd" mode); writes are decoded as commands. Programs and
 * erases complete at once, so status polling sees the final data.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "hw/arm/ngage.h"

/* JAF reads "Flash ID is 0x22F800EC" on RH-29: manufacturer 0xEC, device 0x22F8. */
#define FLASH_MANUFACTURER  0x00EC
#define FLASH_DEVICE_CS0    0x22F8
#define FLASH_DEVICE_CS1    0x22FA      /* boot code at 0xA40 accepts 0x22F2 or 0x22FA for CS1 */

#define SECTOR_SIZE         (64u << 10)  /* TODO: confirm sector map from the datasheet */

enum { ST_READ, ST_UNLOCK1, ST_UNLOCK2, ST_CMD80, ST_CMD80_U1, ST_CMD80_U2,
       ST_PROGRAM, ST_AUTOSELECT, ST_CFI };

struct NGageFlash {
    MemoryRegion mr;
    uint8_t *data;
    uint32_t size;
    hwaddr base;
    uint16_t device_id;
    int state;
    int mode;           /* ST_READ, ST_AUTOSELECT or ST_CFI */
    char *path;
};

static void set_mode(NGageFlash *f, int mode)
{
    f->mode = mode;
    memory_region_rom_device_set_romd(&f->mr, mode == ST_READ);
}

static uint16_t cfi_word(NGageFlash *f, uint32_t w)
{
    static const uint16_t q[] = { 'Q', 'R', 'Y', 0x02, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 };

    if (w >= 0x10 && w < 0x10 + ARRAY_SIZE(q)) {
        return q[w - 0x10];
    }
    if (w == 0x27) {
        return ctz32(f->size);  /* device size = 2^n bytes */
    }
    return 0;
}

static uint64_t flash_read(void *opaque, hwaddr addr, unsigned size)
{
    NGageFlash *f = opaque;
    uint32_t w = addr >> 1;
    uint64_t v = 0;

    if (f->mode == ST_AUTOSELECT) {
        switch (w & 0xFF) {
        case 0: v = FLASH_MANUFACTURER; break;
        case 1: v = f->device_id; break;
        case 2: v = 0; break;               /* sector protect: unprotected */
        default: v = 0; break;
        }
    } else if (f->mode == ST_CFI) {
        v = cfi_word(f, w & 0xFF);
    } else {
        memcpy(&v, f->data + addr, size);
        return v;
    }
    if (size == 4) {
        v |= v << 16;
    }
    return v;
}

static void erase(NGageFlash *f, uint32_t off, uint32_t len)
{
    if (off < f->size) {
        memset(f->data + off, 0xFF, MIN(len, f->size - off));
        memory_region_flush_rom_device(&f->mr, off, MIN(len, f->size - off));
    }
}

static void flash_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    NGageFlash *f = opaque;
    uint32_t w = (addr >> 1) & 0x7FF;
    uint16_t d = val;

    if (f->state == ST_PROGRAM) {
        /* Programming can only clear bits. */
        uint8_t *p = f->data + addr;
        for (unsigned i = 0; i < size && addr + i < f->size; i++) {
            p[i] &= val >> (8 * i);
        }
        memory_region_flush_rom_device(&f->mr, addr, size);
        f->state = ST_READ;
        return;
    }
    if (d == 0xF0 || d == 0xFF) {
        f->state = ST_READ;
        set_mode(f, ST_READ);
        return;
    }
    switch (f->state) {
    case ST_READ:
        if (w == 0x555 && (d & 0xFF) == 0xAA) {
            f->state = ST_UNLOCK1;
        } else if (w == 0x55 && (d & 0xFF) == 0x98) {
            set_mode(f, ST_CFI);
        } else {
            qemu_log_mask(LOG_GUEST_ERROR, "%s: stray write %08x=%04x pc=%08x\n",
                          memory_region_name(&f->mr), (unsigned)addr, d, ngage_guest_pc());
        }
        break;
    case ST_UNLOCK1:
        f->state = (w == 0x2AA && (d & 0xFF) == 0x55) ? ST_UNLOCK2 : ST_READ;
        break;
    case ST_UNLOCK2:
        f->state = ST_READ;
        switch (d & 0xFF) {
        case 0x90: set_mode(f, ST_AUTOSELECT); break;
        case 0xA0: f->state = ST_PROGRAM; break;
        case 0x80: f->state = ST_CMD80; break;
        default:
            qemu_log_mask(LOG_UNIMP, "%s: command %02x at %08x pc=%08x\n",
                          memory_region_name(&f->mr), d & 0xFF, (unsigned)addr, ngage_guest_pc());
        }
        break;
    case ST_CMD80:
        f->state = (w == 0x555 && (d & 0xFF) == 0xAA) ? ST_CMD80_U1 : ST_READ;
        break;
    case ST_CMD80_U1:
        f->state = (w == 0x2AA && (d & 0xFF) == 0x55) ? ST_CMD80_U2 : ST_READ;
        break;
    case ST_CMD80_U2:
        if ((d & 0xFF) == 0x30) {
            erase(f, addr & ~(SECTOR_SIZE - 1), SECTOR_SIZE);
        } else if ((d & 0xFF) == 0x10) {
            erase(f, 0, f->size);
        }
        f->state = ST_READ;
        break;
    default:
        f->state = ST_READ;
    }
}

static const MemoryRegionOps flash_ops = {
    .read = flash_read,
    .write = flash_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

NGageFlash *ngage_flash_create(MemoryRegion *sysmem, const char *name,
                               hwaddr base, uint32_t size, const char *path)
{
    NGageFlash *f = g_new0(NGageFlash, 1);

    f->size = size;
    f->base = base;
    f->device_id = base ? FLASH_DEVICE_CS1 : FLASH_DEVICE_CS0;
    memory_region_init_rom_device(&f->mr, NULL, &flash_ops, f, name, size, &error_fatal);
    f->data = memory_region_get_ram_ptr(&f->mr);
    memset(f->data, 0xFF, size);
    if (path) {
        gsize len = 0;
        gchar *buf = NULL;
        GError *err = NULL;

        if (!g_file_get_contents(path, &buf, &len, &err)) {
            error_report("%s: %s", name, err->message);
            exit(1);
        }
        memcpy(f->data, buf, MIN(len, size));
        g_free(buf);
        f->path = g_strdup(path);
    }
    memory_region_add_subregion(sysmem, base, &f->mr);
    f->mode = ST_READ;
    return f;
}
