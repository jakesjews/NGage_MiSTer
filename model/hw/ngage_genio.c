/*
 * The UPP_WD2's GENIO pins, 0x0C150200-0x0C15020F, as far as NOS's start-up
 * self-tests use them, as the core has them (rtl/upp/upp_gpio.v, from the
 * original N-Gage core; docs/FIRMWARE-PROFILES.md, the self-test table).
 * Four words; in each the upper half is the pins' state and the lower half
 * clears bits of a neighbour's:
 *
 *   +0x0  bits 31:16 the outputs: 1s written there stay set, 1s written to
 *         bits 15:0 of +0x4 clear them. Bits 15:0 are storage
 *   +0x4  the same; its bits 31:16 are cleared through bits 15:0 of +0x8,
 *         its bits 15:0 through bits 31:16 of +0x0
 *   +0x8  storage, cleared in its bits 15:0 through bits 31:16 of +0x4
 *   +0xC  storage
 *
 * The self-tests drive one pin and read another through a path in the UEMK
 * that they switch on over CBUS (ngage_cbus.c):
 *   GENIO1 (+0x8 bit 17) reads GENIO0 (+0x0 bit 16) while the ear path is on,
 *   GENIO3 (+0x8 bit 19) reads GENIO2 (+0x0 bit 18) while the transmit path is,
 *   GENIO17 (+0xC bit 1) reads 1 while the SIM path is on and GENIO16 and
 *   GENIO18 (+0x4 bits 16 and 18) are both set.
 * Those three bits take no writes. The pins' timing is not modelled.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "hw/arm/ngage.h"

#define GENIO_BASE      0x0C150200
#define GENIO1          0x00020000u
#define GENIO3          0x00080000u
#define GENIO17         0x00000002u

typedef struct NGageGenio {
    MemoryRegion mr;
    uint32_t r[4];
} NGageGenio;

static uint64_t genio_read(void *opaque, hwaddr off, unsigned size)
{
    NGageGenio *s = opaque;
    uint32_t w = s->r[off >> 2];
    uint64_t v;

    switch (off >> 2) {
    case 2:
        w |= (ngage_cbus_route(NGAGE_ROUTE_EAR) && (s->r[0] & (1u << 16))) ? GENIO1 : 0;
        w |= (ngage_cbus_route(NGAGE_ROUTE_TX) && (s->r[0] & (1u << 18))) ? GENIO3 : 0;
        break;
    case 3:
        w |= (ngage_cbus_route(NGAGE_ROUTE_SIM) && (s->r[1] & (1u << 18)) &&
              (s->r[1] & (1u << 16))) ? GENIO17 : 0;
        break;
    }
    v = ngage_take(w, off, size);
    ngage_trace_log("genio", false, GENIO_BASE + off, size, v);
    return v;
}

static void genio_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageGenio *s = opaque;
    unsigned be;
    uint32_t w = ngage_lanes(off, size, val, &be), m = ngage_be_mask(be);
    uint32_t *r = s->r;

    ngage_trace_log("genio", true, GENIO_BASE + off, size, val);
    switch (off >> 2) {
    case 0:
        r[0] = (r[0] & ~m) | (w & m) | (r[0] & m & 0xFFFF0000u);
        r[1] &= ~((w & m) >> 16);
        break;
    case 1:
        r[1] = (r[1] & ~m) | (w & m) | (r[1] & m & 0xFFFF0000u);
        r[0] &= ~((w & m & 0xFFFF) << 16);
        r[2] &= ~((w & m) >> 16);
        break;
    case 2:
        r[2] = (r[2] & ~m) | (w & m & ~(GENIO1 | GENIO3));
        r[1] &= ~((w & m & 0xFFFF) << 16);
        break;
    case 3:
        r[3] = (r[3] & ~m) | (w & m & ~GENIO17);
        break;
    }
}

static const MemoryRegionOps genio_ops = {
    .read = genio_read, .write = genio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

void ngage_genio_create(MemoryRegion *sysmem)
{
    NGageGenio *s = g_new0(NGageGenio, 1);

    memory_region_init_io(&s->mr, NULL, &genio_ops, s, "ngage.genio", 0x10);
    memory_region_add_subregion(sysmem, GENIO_BASE, &s->mr);
}
