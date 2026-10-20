/*
 * Model shortcuts: explicit, logged changes to the flash contents the model
 * presents, read from model/rom-patches.txt. The image files on disk are not
 * modified. Each line is one of
 *
 *   cs0|cs1 <offset> <hex bytes>      bytes as stored in flash (little-endian)
 *   cs0file|cs1file <offset> <path>   the contents of a file (e.g. assembled code)
 *   md5 <entry offset in CS0>         recompute the bootstrap integrity-check
 *                                     digest of the table entry {start, end,
 *                                     digest[16]} (bootstrap 0x3238, table 0x8F00)
 *
 * The md5 lines run after all byte patches. The digest covers ROM virtual
 * addresses start..end through the bootstrap's ROM map (its page-table
 * entries at CS0 0x744; sim/cpu/boot/prep.py and tools/mkimage.py use the
 * same map): 0x50000000 + x -> CS0 x for x < 0xF00000, CS1 0-4 MB at
 * 0x50F00000, CS0 0xF00000-0xFEFFFF at 0x51300000.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "crypto/hash.h"
#include "hw/arm/ngage.h"

#define ROM_VA      0x50000000u

static const struct {
    uint32_t va, cs, off, len;      /* VA offset, chip, chip offset, length */
} rom_map[] = {
    { 0x0000000, 0, 0x000000, 0xF00000 },
    { 0x0F00000, 1, 0x000000, 0x400000 },
    { 0x1300000, 0, 0xF00000, 0x0F0000 },
};

static void md5_entry(uint32_t entry, NGageFlash *cs0, NGageFlash *cs1)
{
    uint32_t s0, s1;
    uint8_t *d0 = ngage_flash_data(cs0, &s0);
    uint8_t *d1 = ngage_flash_data(cs1, &s1);
    uint32_t start = ldl_le_p(d0 + entry), end = ldl_le_p(d0 + entry + 4);
    uint32_t len = end - start + 1, off = start - ROM_VA;
    g_autofree uint8_t *buf = g_malloc(len);
    uint8_t *res = NULL;
    size_t rlen = 0;

    for (uint32_t i = 0; i < len; i++) {
        uint32_t x = off + i;
        unsigned k;

        for (k = 0; k < sizeof(rom_map) / sizeof(rom_map[0]); k++) {
            if (x - rom_map[k].va < rom_map[k].len) {
                uint32_t o = rom_map[k].off + x - rom_map[k].va;
                buf[i] = rom_map[k].cs ? (o < s1 ? d1[o] : 0xFF) : (o < s0 ? d0[o] : 0xFF);
                break;
            }
        }
        if (k == sizeof(rom_map) / sizeof(rom_map[0])) {
            error_report("ngage: rom-patch: digest entry 0x%x: 0x%08x is outside the ROM map",
                         entry, ROM_VA + x);
            exit(1);
        }
    }
    if (qcrypto_hash_bytes(QCRYPTO_HASH_ALGO_MD5, buf, len, &res, &rlen, &error_fatal) < 0) {
        exit(1);
    }
    memcpy(d0 + entry + 8, res, 16);
    ngage_flash_changed(cs0, entry + 8, 16);
    info_report("ngage: rom-patch: digest at CS0 0x%x for 0x%08x-0x%08x recomputed",
                entry, start, end);
    g_free(res);
}

void ngage_apply_rom_patches(const char *path, NGageFlash *cs0, NGageFlash *cs1)
{
    FILE *fp = fopen(path, "r");
    char line[1024];
    uint32_t md5s[16];
    int nmd5 = 0;

    if (!fp) {
        error_report("ngage: cannot open rom patch file %s", path);
        exit(1);
    }
    while (fgets(line, sizeof(line), fp)) {
        char kind[8], hex[512] = "";
        unsigned long off;
        char *h = strchr(line, '#');
        if (h) {
            *h = 0;
        }
        int n = sscanf(line, "%7s %li %511s", kind, (long *)&off, hex);
        if (n >= 2 && !strcmp(kind, "md5")) {
            if (nmd5 < 16) {
                md5s[nmd5++] = off;
            }
            continue;
        }
        if (n == 3 && (!strcmp(kind, "cs0file") || !strcmp(kind, "cs1file"))) {
            NGageFlash *f = strcmp(kind, "cs0file") ? cs1 : cs0;
            uint32_t size;
            uint8_t *d = ngage_flash_data(f, &size);
            g_autofree gchar *buf = NULL;
            gsize len = 0;
            GError *err = NULL;
            if (!g_file_get_contents(hex, &buf, &len, &err)) {
                error_report("ngage: rom patch: %s", err->message);
                exit(1);
            }
            if (off + len > size) {
                error_report("ngage: rom patch out of range: %s", line);
                exit(1);
            }
            memcpy(d + off, buf, len);
            ngage_flash_changed(f, off, len);
            info_report("ngage: rom-patch: %s 0x%lx <- %s (%zu bytes)", kind, off, hex, (size_t)len);
            continue;
        }
        if (n != 3 || (strcmp(kind, "cs0") && strcmp(kind, "cs1"))) {
            continue;
        }
        NGageFlash *f = strcmp(kind, "cs0") ? cs1 : cs0;
        uint32_t size;
        uint8_t *d = ngage_flash_data(f, &size);
        size_t nb = strlen(hex) / 2;
        if (off + nb > size) {
            error_report("ngage: rom patch out of range: %s", line);
            exit(1);
        }
        for (size_t i = 0; i < nb; i++) {
            unsigned v;
            sscanf(hex + 2 * i, "%2x", &v);
            d[off + i] = v;
        }
        ngage_flash_changed(f, off, nb);
        info_report("ngage: rom-patch: %s 0x%lx <- %s", kind, off, hex);
    }
    fclose(fp);
    for (int i = 0; i < nmd5; i++) {
        md5_entry(md5s[i], cs0, cs1);
    }
}
