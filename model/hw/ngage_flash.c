/*
 * Samsung K8S2815ETA / K8S6415ETA style NOR flash with the AMD command set,
 * as fitted to the N-Gage QD. Array reads go straight to host memory
 * (ROM device in "romd" mode); writes are decoded as commands. Programs
 * complete at once, apart from the first-format handshake described below.
 *
 * Sector erase is timed, with erase suspend/resume, because medint.pdd (the
 * C: drive driver) depends on it: after 0x30 it polls the sector until
 * DQ7 = 0 and DQ3 = 1 (0x5037FEAC), checks completion by reading 0xFFFF
 * twice (0x5037FF34: DQ7 = 1 means suspended, DQ5 = time-out, anything else
 * busy), suspends with 0xB0 and waits for DQ7 = 1 (0x5037FEE4), and resumes
 * with 0x30 (0x5037FDEC). While an erase is in progress only the erasing
 * sector reads status (an I/O overlay over that sector); the rest of the chip
 * reads array data, as in a multi-bank part whose other banks are readable
 * (the bank layout is not known). Status: erasing DQ7 = 0, DQ6 and DQ2
 * toggle, DQ3 = 1; suspended DQ7 = 1, DQ2 toggles. With log-time=on each
 * erase start and end goes to the QEMU log with the guest time.
 *
 * First format: while CS1's upper 4 MB is still erased, sector erases in
 * C: skip the array write and timer. Erase and program still expose one busy
 * status read in their bank, then array data: medint.pdd must observe DQ7=0
 * and DQ3=1 before it checks erase completion. This read-driven handshake
 * cannot expire before the first poll. The first program of non-FF C: data
 * ends eligibility for this shortcut until a new image is loaded; its own
 * busy read is retained. Erases never re-arm it. Outside this shortcut,
 * programs retain this model's existing synchronous completion.
 *
 * Sector map: 64 KB sectors with the top 64 KB in eight 8 KB sectors (top
 * boot), from medint.pdd's sector-size rule at 0x5037FC28 (8 KB at and above
 * region size - 64 KB, with its 4 MB region ending at the top of CS1).
 *
 * Scrambled area: part of CS0 (the cellular software, NOS) is stored
 * scrambled and the ASIC decodes it on array reads (ngage_scramble.h). The
 * area is the one the image names at 0x174 / 0x178 (0xA000-0x2ACFFF in RH-29
 * 4.10 and 4.60) [assumed: nothing in the firmware reads those words; the
 * ASIC's boot ROM is taken to]. Array reads go straight to host memory, so
 * the host copy holds that area decoded, from the image load on; everything
 * that looks at the chip's data (the patches, the integrity digests) sees
 * what the CPU reads. A program or an erase there leaves what the core's
 * flash leaves (rtl/mem/ddram_flash.sv): the stored word becomes the word
 * read before, ANDed with the data (FFFF for an erase), and reads back
 * decoded. [A chip would AND the data into the stored word; nothing in the
 * firmware programs this area.]
 *
 * Persistence: with a save file the chip starts from that file when it
 * exists (instead of the image) and writes its whole contents back to it on
 * exit after any program or erase. CS1 0x400000-0x7FFFFF is the C: drive
 * (medint.pdd maps it at 0x59200000/0x59600000), so this keeps user data
 * across runs as on the phone.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "qemu/notify.h"
#include "qemu/timer.h"
#include "qapi/error.h"
#include "system/system.h"
#include "hw/arm/ngage.h"
#include "hw/arm/ngage_scramble.h"

/* JAF reads "Flash ID is 0x22F800EC" on RH-29: manufacturer 0xEC, device 0x22F8. */
#define FLASH_MANUFACTURER  0x00EC
#define FLASH_DEVICE_CS0    0x22F8
#define FLASH_DEVICE_CS1    0x22FA      /* boot code at 0xA40 accepts 0x22F2 or 0x22FA for CS1 */

#define SECTOR_SIZE         (64u << 10)
#define BOOT_SECTOR_SIZE    (8u << 10)
/* Shorter than a real sector erase (typically 0.7 s) to keep runs short. */
#define ERASE_NS            (20 * 1000 * 1000)

enum { ST_READ, ST_UNLOCK1, ST_UNLOCK2, ST_CMD80, ST_CMD80_U1, ST_CMD80_U2,
       ST_PROGRAM, ST_AUTOSELECT, ST_CFI };
enum { FAST_NONE, FAST_ERASE, FAST_PROGRAM };

struct NGageFlash {
    MemoryRegion mr;
    uint8_t *data;
    uint32_t size;
    hwaddr base;
    uint16_t device_id;
    int state;
    int mode;           /* ST_READ, ST_AUTOSELECT or ST_CFI */
    char *path;
    char *save_path;
    bool dirty;
    bool c_blank;       /* sticky until a new CS1 image is loaded */
    uint32_t scr_first, scr_end;    /* the scrambled area, data[] holds it decoded; 0, 0: none */
    Notifier exit_notifier;
    /* Busy overlay: 0 none, 1 active (erase or fast program), 2 suspended erase. */
    int busy;
    uint32_t busy_off, busy_len;
    uint32_t busy_map_off;
    int fast;
    uint16_t fast_data;
    bool fast_toggle;
    int64_t busy_left;              /* ns of erase left when suspended */
    uint16_t toggle;
    QEMUTimer *timer;
    MemoryRegion busy_mr;
    MemoryRegion *sysmem;
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

static uint32_t sector_len(NGageFlash *f, uint32_t off)
{
    return off >= f->size - SECTOR_SIZE ? BOOT_SECTOR_SIZE : SECTOR_SIZE;
}

/* The words of [off, off + len) in the scrambled area now hold stored
 * contents (after a program or an erase): decode them as a read does. */
static void decode_written(NGageFlash *f, uint32_t off, uint32_t len)
{
    uint32_t a = MAX(off & ~1u, f->scr_first), b = MIN((off + len + 1) & ~1u, f->scr_end);

    if (a < b) {
        ngage_descramble_buf(f->data + a, a, b - a);
    }
}

static void erase(NGageFlash *f, uint32_t off, uint32_t len)
{
    if (off < f->size) {
        len = MIN(len, f->size - off);
        memset(f->data + off, 0xFF, len);
        decode_written(f, off, len);
        memory_region_flush_rom_device(&f->mr, off, len);
        f->dirty = true;
    }
}

static void erase_done(void *opaque)
{
    NGageFlash *f = opaque;

    erase(f, f->busy_off, f->busy_len);
    memory_region_del_subregion(f->sysmem, &f->busy_mr);
    f->busy = 0;
    if (ngage_log_time) {
        qemu_log("%11.6f %s: sector erase done at %08x\n", ngage_guest_seconds(),
                 memory_region_name(&f->mr), f->busy_off);
    }
}

/* Match nor_flash's sixteen banks and one busy read, with no elapsed time
 * requirement. A program's array write has already landed before this starts.
 * Keep this toggle phase separate so the existing timed path is unchanged. */
static void fast_start(NGageFlash *f, int kind, uint32_t off, uint16_t data)
{
    uint32_t bank_len = f->size / 16;

    f->fast = kind;
    f->fast_data = data;
    f->busy = 1;
    f->busy_map_off = off & ~(bank_len - 1);
    memory_region_set_size(&f->busy_mr, bank_len);
    memory_region_add_subregion_overlap(f->sysmem, f->base + f->busy_map_off,
                                       &f->busy_mr, 1);
    if (ngage_log_time) {
        qemu_log("%11.6f %s: fast %s at %08x pc=%08x\n", ngage_guest_seconds(),
                 memory_region_name(&f->mr), kind == FAST_ERASE ? "erase" : "program",
                 off, ngage_guest_pc());
    }
}

static void erase_start(NGageFlash *f, uint32_t off)
{
    if (f->busy || off >= f->size) {
        qemu_log_mask(LOG_GUEST_ERROR, "%s: sector erase at %08x while busy pc=%08x\n",
                      memory_region_name(&f->mr), off, ngage_guest_pc());
        return;
    }
    f->busy_len = sector_len(f, off);
    f->busy_off = off & ~(f->busy_len - 1);
    if (f->c_blank && f->busy_off >= f->size / 2) {
        fast_start(f, FAST_ERASE, off, 0xFFFF);
        return;
    }
    f->busy = 1;
    f->busy_map_off = f->busy_off;
    memory_region_set_size(&f->busy_mr, f->busy_len);
    memory_region_add_subregion_overlap(f->sysmem, f->base + f->busy_off, &f->busy_mr, 1);
    timer_mod(f->timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + ERASE_NS);
    if (ngage_log_time) {
        qemu_log("%11.6f %s: sector erase at %08x pc=%08x\n", ngage_guest_seconds(),
                 memory_region_name(&f->mr), f->busy_off, ngage_guest_pc());
    }
}

/* Erase suspend (0xB0) and resume (0x30) are accepted at any address while busy. */
static bool erase_suspend_resume(NGageFlash *f, uint16_t d)
{
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    if (f->busy == 1 && d == 0xB0) {
        f->busy_left = MAX(timer_expire_time_ns(f->timer) - now, 0);
        timer_del(f->timer);
        f->busy = 2;
        return true;
    }
    if (f->busy == 2 && d == 0x30) {
        timer_mod(f->timer, now + f->busy_left);
        f->busy = 1;
        return true;
    }
    return false;
}

static void flash_write(void *opaque, hwaddr addr, uint64_t val, unsigned size);

static uint64_t busy_read(void *opaque, hwaddr addr, unsigned size)
{
    NGageFlash *f = opaque;
    uint64_t v;

    if (f->fast) {
        uint32_t off = f->busy_map_off + addr;
        bool selected = off >= f->busy_off && off < f->busy_off + f->busy_len;

        v = f->fast_toggle ? 0x40 : 0;
        if (f->fast == FAST_ERASE) {
            v |= 0x08 | (selected ? (f->fast_toggle ? 0x04 : 0) : 0x04);
        } else {
            v |= (~f->fast_data & 0x80) | 0x04;
        }
        f->fast_toggle = !f->fast_toggle;
        f->fast = FAST_NONE;
        f->busy = 0;
        memory_region_del_subregion(f->sysmem, &f->busy_mr);
        /* The physical chip is x16: a word load is two reads, so only its
         * first halfword is busy. Byte polls use the addressed byte lane. */
        if (size == 4) {
            v |= (uint64_t)lduw_le_p(f->data + off + 2) << 16;
        } else if (size == 1 && (off & 1)) {
            v >>= 8;
        }
        return v;
    }
    f->toggle ^= 0x44;      /* DQ6 and DQ2 */
    if (f->busy == 1) {
        v = 0x0008 | f->toggle;
    } else {
        v = 0x0080 | (f->toggle & 0x04);
    }
    if (size == 4) {
        v |= v << 16;
    }
    return v;
}

static void busy_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    NGageFlash *f = opaque;

    flash_write(f, f->busy_map_off + addr, val, size);
}

static const MemoryRegionOps busy_ops = {
    .read = busy_read,
    .write = busy_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static void flash_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    NGageFlash *f = opaque;
    uint32_t w = (addr >> 1) & 0x7FF;
    uint16_t d = val;

    if (f->fast) {
        return;           /* no suspend/resume or new command before the poll */
    }
    if (f->state == ST_PROGRAM) {
        bool fast = f->c_blank && addr >= f->size / 2;
        /* Programming can only clear bits. */
        uint8_t *p = f->data + addr;
        for (unsigned i = 0; i < size && addr + i < f->size; i++) {
            p[i] &= val >> (8 * i);
            if (addr + i >= f->size / 2 && p[i] != 0xFF) {
                f->c_blank = false;
            }
        }
        decode_written(f, addr, size);
        memory_region_flush_rom_device(&f->mr, addr & ~1u,
                                       MIN((addr + size + 1) & ~1u, f->size) - (addr & ~1u));
        f->dirty = true;
        f->state = ST_READ;
        if (fast) {
            fast_start(f, FAST_PROGRAM, addr, d);
        }
        return;
    }
    if (f->state == ST_READ && erase_suspend_resume(f, d & 0xFF)) {
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
        } else if ((d & 0xFF) == 0x60) {
            /*
             * Samsung block lock/unlock: 0x60 then 0x60 at the block, A6
             * selecting unlock (medint.pdd 0x50380020 writes 0x60 at the
             * block twice and at block + 0x84, then 0xF0, and checks the
             * autoselect protect word). Blocks are never locked in the model.
             */
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
            erase_start(f, addr);
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

static void flash_exit(Notifier *n, void *data)
{
    NGageFlash *f = container_of(n, NGageFlash, exit_notifier);
    GError *err = NULL;

    if (!f->dirty) {
        return;
    }
    /* the file holds the chip as it is stored */
    g_autofree uint8_t *stored = g_memdup2(f->data, f->size);
    if (f->scr_end) {
        ngage_scramble_buf(stored + f->scr_first, f->scr_first, f->scr_end - f->scr_first);
    }
    if (!g_file_set_contents(f->save_path, (const char *)stored, f->size, &err)) {
        error_report("%s: cannot save %s: %s", memory_region_name(&f->mr), f->save_path,
                     err->message);
        g_error_free(err);
        return;
    }
    info_report("ngage: %s saved to %s", memory_region_name(&f->mr), f->save_path);
}

NGageFlash *ngage_flash_create(MemoryRegion *sysmem, const char *name,
                               hwaddr base, uint32_t size, const char *path,
                               const char *save_path)
{
    NGageFlash *f = g_new0(NGageFlash, 1);

    if (save_path && *save_path) {
        f->save_path = g_strdup(save_path);
        f->exit_notifier.notify = flash_exit;
        qemu_add_exit_notifier(&f->exit_notifier);
        if (g_file_test(save_path, G_FILE_TEST_EXISTS)) {
            info_report("ngage: %s starts from %s", name, save_path);
            path = save_path;
        }
    }

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
    if (!base && ngage_scr_window(f->data, size, &f->scr_first, &f->scr_end)) {
        ngage_descramble_buf(f->data + f->scr_first, f->scr_first, f->scr_end - f->scr_first);
        info_report("ngage: %s 0x%x-0x%x is scrambled in flash (header 0x%x), decoded on reads",
                    name, f->scr_first, f->scr_end - 1, NGAGE_SCR_HDR_FIRST);
    }
    f->c_blank = f->device_id == FLASH_DEVICE_CS1;
    ngage_flash_changed(f, 0, size);
    memory_region_add_subregion(sysmem, base, &f->mr);
    f->mode = ST_READ;
    f->sysmem = sysmem;
    memory_region_init_io(&f->busy_mr, NULL, &busy_ops, f, "ngage.flash-busy", SECTOR_SIZE);
    f->timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, erase_done, f);
    return f;
}

uint8_t *ngage_flash_data(NGageFlash *f, uint32_t *size)
{
    *size = f->size;
    return f->data;
}

void ngage_flash_changed(NGageFlash *f, uint32_t off, uint32_t len)
{
    memory_region_flush_rom_device(&f->mr, off, len);
    if (f->c_blank && off < f->size) {
        uint32_t end = off + MIN(len, f->size - off);
        for (uint32_t i = MAX(off, f->size / 2); i < end; i++) {
            if (f->data[i] != 0xFF) {
                f->c_blank = false;
                break;
            }
        }
    }
}

bool ngage_flash_c_blank(NGageFlash *f)
{
    return f && f->c_blank;
}
