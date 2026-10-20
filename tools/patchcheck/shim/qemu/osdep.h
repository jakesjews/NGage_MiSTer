/*
 * Stand-ins for the parts of QEMU and GLib that model/hw/ngage_patch.c uses,
 * so that tools/patchcheck can build the model's own patcher outside QEMU.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef PATCHCHECK_OSDEP_H
#define PATCHCHECK_OSDEP_H
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef char gchar;
typedef size_t gsize;
typedef struct GError { const char *message; } GError;

static inline void *g_malloc(size_t n) { void *p = malloc(n ? n : 1); if (!p) abort(); return p; }
static inline void g_free(void *p) { free(p); }
static inline void patchcheck_autofree(void *pp) { free(*(void **)pp); }
#define g_autofree __attribute__((cleanup(patchcheck_autofree)))

static inline bool g_file_get_contents(const char *path, gchar **buf, gsize *len, GError **err)
{
    static GError e = { "cannot read file" };
    FILE *f = fopen(path, "rb");
    if (!f) { *err = &e; return false; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    *buf = g_malloc((size_t)n + 1);
    *len = fread(*buf, 1, (size_t)n, f);
    fclose(f);
    return true;
}

static inline uint32_t ldl_le_p(const void *p)
{
    const uint8_t *b = p;
    return b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24;
}
#endif
