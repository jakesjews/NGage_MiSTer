/*
 * The reference model's flash patcher (model/hw/ngage_patch.c, compiled as it
 * is) on two flash images, outside QEMU: what the model presents in its flash
 * after loading them. tools/patchcheck.sh compares it with tools/mkimage.py.
 *   patchcheck PATCHES CS0 CS1 OUT0 OUT1
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "crypto/hash.h"
#include "hw/arm/ngage.h"
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#define MD5_BYTES(buf, len, out) CC_MD5(buf, (CC_LONG)(len), out)
#else
#include <openssl/md5.h>                /* link with -lcrypto */
#define MD5_BYTES(buf, len, out) MD5(buf, len, out)
#endif

struct NGageFlash { uint8_t *data; uint32_t size; };
Error *error_fatal;

uint8_t *ngage_flash_data(NGageFlash *f, uint32_t *size) { *size = f->size; return f->data; }
void ngage_flash_changed(NGageFlash *f, uint32_t off, uint32_t len) { (void)f; (void)off; (void)len; }

int qcrypto_hash_bytes(int alg, const void *buf, size_t len, uint8_t **result, size_t *resultlen, Error **errp)
{
    (void)alg; (void)errp;
    *result = g_malloc(16);
    *resultlen = 16;
    MD5_BYTES(buf, len, *result);
    return 0;
}

static void load(NGageFlash *f, const char *path, uint32_t size)
{
    FILE *fp = fopen(path, "rb");
    f->data = calloc(1, size);
    f->size = size;
    if (!fp || fread(f->data, 1, size, fp) != size) { fprintf(stderr, "patchcheck: cannot read %u bytes of %s\n", size, path); exit(1); }
    fclose(fp);
}

static void save(NGageFlash *f, const char *path)
{
    FILE *fp = fopen(path, "wb");
    if (!fp || fwrite(f->data, 1, f->size, fp) != f->size) { fprintf(stderr, "patchcheck: cannot write %s\n", path); exit(1); }
    fclose(fp);
}

int main(int argc, char **argv)
{
    NGageFlash cs0, cs1;
    if (argc != 6) { fprintf(stderr, "usage: patchcheck PATCHES CS0 CS1 OUT0 OUT1\n"); return 2; }
    load(&cs0, argv[2], 16u << 20);
    load(&cs1, argv[3], 8u << 20);
    ngage_apply_rom_patches(argv[1], &cs0, &cs1);
    save(&cs0, argv[4]);
    save(&cs1, argv[5]);
    return 0;
}
