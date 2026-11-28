/*
 * The UPP_WD2's SIM interface and a test card in it, as the core has them
 * (rtl/upp/upp_simif.v, upp_test_sim.v, from the original N-Gage core;
 * docs/FIRMWARE-PROFILES.md, "SIM receive path"). Without a card NOS stops
 * at "Insert SIM card". The register behaviour is what the unmodified
 * firmware was seen to need, not a measured interface, and the card is at
 * the level of bytes: no electrical timing, no baud rate.
 *
 *   0x0C150800  status, 16 bits, write 1 to clear: bit 4 a byte can be read,
 *               bit 3 the bytes written have gone out. Any bit set raises
 *               IrqCTSI_FIQ (source 26)
 *   0x0C150804  configuration; storage, but a read of its upper half takes
 *               bits off it while that half holds 0x79 or 0x7E
 *   0x0C150808  control; storage. The first write of 1 to its lower half
 *               starts reception: bit 4 of the status is set and the card's
 *               answer to reset can be read
 *   0x0C15080C  data: a write sends a byte to the card, a read takes the
 *               next byte from it (first the answer to reset, 3B 00)
 *   0x0C1500B8  a read of the lower half gives 4 while the status is not 0
 *
 * The card is a GSM T=0 card with made-up identities: the directories 3F00
 * and 7F20 and twelve files with fixed contents, enough for the boot's
 * reads. Commands: SELECT (A4), GET RESPONSE (C0), STATUS (F2), READ BINARY
 * (B0), TERMINAL PROFILE (10). Nothing can be written, there is no
 * authentication and no network.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "hw/arm/ngage.h"

#define SIM_BASE        0x0C150800
#define B8_BASE         0x0C1500B8
#define FIFO            64

enum { RESP_PAIR, RESP_PROC, RESP_EF_HEADER, RESP_DF_HEADER, RESP_EF_DATA };

typedef struct NGageSim {
    MemoryRegion mr, b8_mr;
    FILE *log;
    /* the interface */
    uint16_t status;
    uint32_t reg800, reg804, reg808, reg80c, regb8;
    uint32_t position;
    int phase;
    bool injected;
    /* the card */
    uint8_t fifo[FIFO];
    unsigned head, used;
    uint8_t header[4];
    unsigned header_count, select_left, terminal_left;
    uint8_t file_id_high;
    uint16_t selected, directory;
} NGageSim;

static void sim_log(NGageSim *s, const char *fmt, ...) G_GNUC_PRINTF(2, 3);
static void sim_log(NGageSim *s, const char *fmt, ...)
{
    va_list ap;

    if (!s->log) {
        return;
    }
    fprintf(s->log, "%11.6f ", ngage_guest_seconds());
    va_start(ap, fmt);
    vfprintf(s->log, fmt, ap);
    va_end(ap);
    fputc('\n', s->log);
}

static void sim_update(NGageSim *s)
{
    ngage_intc_set_source(NGAGE_IRQ_CTSI_FIQ, s->status != 0);
}

/* ---------------------------------------------------------------- the card */

static bool supported_ef(uint16_t f)
{
    switch (f) {
    case 0x6FB7: case 0x6F05: case 0x6FAE: case 0x6F38: case 0x6F7E: case 0x6FAD:
    case 0x6F07: case 0x6F78: case 0x2FE2: case 0x6F74: case 0x6F20: case 0x6F7B:
        return true;
    }
    return false;
}

static unsigned ef_length(uint16_t f)
{
    switch (f) {
    case 0x6FB7: return 3;
    case 0x6F38: case 0x6F74: return 16;
    case 0x6F7E: return 11;
    case 0x6FAD: return 4;
    case 0x6F07: case 0x6F20: return 9;
    case 0x6F7B: return 12;
    case 0x6F78: return 2;
    case 0x2FE2: return 10;
    }
    return 1;
}

static uint8_t ef_byte(uint16_t file, unsigned i)
{
    static const uint8_t iccid[10] = { 0x98, 0x10, 0x10, 0x32, 0x54, 0x76, 0x98, 0x10, 0x32, 0xF8 };
    static const uint8_t imsi[9] = { 0x08, 0x09, 0x10, 0x10, 0x10, 0x32, 0x54, 0x76, 0x98 };

    switch (file) {
    case 0x6F20: return i == 8 ? 0x07 : 0;      /* Kc: no key (sequence 7) */
    case 0x6F7B: return 0xFF;                   /* forbidden networks: none */
    case 0x2FE2: return i < 10 ? iccid[i] : 0;
    case 0x6F78: return i == 1 ? 1 : 0;         /* access control class */
    case 0x6F07: return i < 9 ? imsi[i] : 0;
    case 0x6FAD: return i == 3 ? 2 : 0;         /* administrative data */
    case 0x6F7E: return i < 10 ? 0xFF : 0x01;   /* location information */
    case 0x6FAE: return 3;                      /* phase */
    case 0x6F05: return 1;                      /* language preference */
    case 0x6FB7: return i == 0 ? 0x11 : i == 1 ? 0xF2 : 0xFF;  /* emergency call codes */
    }
    return 0;                                   /* 6F74 BCCH, 6F38 service table: zeros */
}

static uint8_t response_byte(NGageSim *s, unsigned i, int kind, unsigned count, uint16_t pair)
{
    uint8_t v = 0;

    switch (kind) {
    case RESP_PAIR:
        return i == 0 ? pair >> 8 : pair & 0xFF;
    case RESP_PROC:
        return pair >> 8;
    case RESP_EF_HEADER:
        switch (i) {
        case 0: return 0xC0;
        case 4: return ef_length(s->selected);
        case 5: return s->selected >> 8;
        case 6: return s->selected & 0xFF;
        case 7: return 4;
        case 9: return 0x0F;
        case 10: case 11: return 0xFF;
        case 12: return 1;
        case 13: return 2;
        case 16: return 0x90;
        }
        return 0;
    case RESP_DF_HEADER:
        switch (i) {
        case 0: v = 0xF2; break;
        case 5: v = s->directory >> 8; break;
        case 6: v = s->directory & 0xFF; break;
        case 7: v = s->directory == 0x3F00 ? 1 : 2; break;
        case 13: v = 9; break;
        case 14: v = 0xB0; break;
        case 17: v = 2; break;
        case 19: case 21: v = 0x83; break;
        case 20: case 22: v = 0x8A; break;
        }
        if (i == count - 2) {
            v = 0x90;
        }
        if (i == count - 1) {
            v = 0;
        }
        return v;
    case RESP_EF_DATA:
        if (i == 0) {
            return 0xB0;
        }
        if (i == count - 2) {
            return 0x90;
        }
        return i != count - 1 ? ef_byte(s->selected, i - 1) : 0;
    }
    return 0;
}

static void queue_response(NGageSim *s, int kind, unsigned count, uint16_t pair)
{
    unsigned n = MIN(count, FIFO - s->used);

    for (unsigned i = 0; i < n; i++) {
        s->fifo[(s->head + s->used + i) % FIFO] = response_byte(s, i, kind, count, pair);
    }
    s->used += n;
}

/* This byte from the phone completes something the card answers. */
static bool card_will_emit(NGageSim *s)
{
    return s->terminal_left == 1 || (s->terminal_left == 0 && s->select_left == 1) ||
           (s->terminal_left == 0 && s->select_left == 0 && s->header_count == 4);
}

static void card_tx(NGageSim *s, uint8_t d)
{
    const uint8_t *h = s->header;

    if (s->terminal_left != 0) {
        if (--s->terminal_left == 0) {
            queue_response(s, RESP_PAIR, 2, 0x9000);
        }
    } else if (s->select_left != 0) {
        uint16_t file = s->file_id_high << 8 | d;

        s->file_id_high = d;
        if (--s->select_left == 0) {
            bool dir = file == 0x3F00 || file == 0x7F20;

            if (dir || (file == 0x2FE2 && s->directory == 0x3F00) ||
                (supported_ef(file) && file != 0x2FE2 && s->directory == 0x7F20)) {
                s->selected = file;
                if (dir) {
                    s->directory = file;
                }
                queue_response(s, RESP_PAIR, 2, dir ? 0x9F16 : 0x9F0F);
            } else {
                queue_response(s, RESP_PAIR, 2, 0x9404);
            }
            sim_log(s, "card: SELECT %04x", file);
        }
    } else if (s->header_count != 4) {
        s->header[s->header_count++] = d;
    } else {
        bool p12 = h[2] == 0 && h[3] == 0;

        s->header_count = 0;
        if (h[0] != 0xA0) {
            queue_response(s, RESP_PAIR, 2, 0x6E00);
        } else if (h[1] == 0x10 && p12 && d != 0) {
            s->terminal_left = d;
            queue_response(s, RESP_PROC, 1, 0x1000);
        } else if (h[1] == 0xA4 && p12 && d == 2) {
            s->file_id_high = 0;
            s->select_left = 2;
            queue_response(s, RESP_PROC, 1, 0xA400);
        } else if (h[1] == 0xC0 && p12 && d == 15 && supported_ef(s->selected)) {
            queue_response(s, RESP_EF_HEADER, 18, 0);
        } else if (h[1] == 0xF2 && p12 && (d == 15 || d == 22)) {
            queue_response(s, RESP_DF_HEADER, d + 3, 0);
        } else if (h[1] == 0xB0 && p12 && d == ef_length(s->selected) && supported_ef(s->selected)) {
            queue_response(s, RESP_EF_DATA, ef_length(s->selected) + 3, 0);
        } else {
            queue_response(s, RESP_PAIR, 2, 0x6D00);
            sim_log(s, "card: command %02x %02x %02x %02x %02x not known", h[0], h[1], h[2], h[3], d);
        }
    }
}

/* ---------------------------------------------------------------- the interface */

static uint32_t read804(NGageSim *s, unsigned be)
{
    if (be & 0xC) {
        if ((s->reg804 >> 16) == 0x79) {
            return s->reg804 & ~0x003A0000u;
        }
        if ((s->reg804 >> 16) == 0x7E) {
            return s->reg804 & ~0x00390000u;
        }
    }
    return s->reg804;
}

static uint64_t sim_read(void *opaque, hwaddr off, unsigned size)
{
    NGageSim *s = opaque;
    unsigned be;
    uint32_t w = 0;
    bool low;
    uint64_t v;

    ngage_lanes(off, size, 0, &be);
    low = be & 3;
    switch (off & ~3) {
    case 0x0:
        w = low ? s->status : s->reg800;
        break;
    case 0x4:
        w = read804(s, be);
        s->reg804 = w;
        break;
    case 0x8:
        w = s->reg808;
        break;
    case 0xC:
        if (!low) {
            w = s->reg80c;
        } else if (s->phase == 0) {
            w = s->position == 0 ? 0x3B : 0;    /* the answer to reset: 3B 00 */
            s->position++;
        } else if (s->used) {
            w = s->fifo[s->head];
            if (s->used == 1) {
                s->status = 0;                  /* the last byte of the answer */
            } else if (s->position & 1) {
                s->status = 0x10;
            }
            s->position++;
            s->head = (s->head + 1) % FIFO;
            s->used--;
        } else {
            sim_log(s, "read with nothing from the card");
        }
        sim_update(s);
        break;
    }
    v = ngage_take(w, off, size);
    ngage_trace_log("simif", false, SIM_BASE + off, size, v);
    return v;
}

static void sim_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageSim *s = opaque;
    unsigned be;
    uint32_t m, rep;
    bool low;

    /* the CPU repeats a byte or a halfword in every lane; the interface looks
     * at the lower half's lanes whichever bytes are taken */
    rep = size == 1 ? (uint32_t)(val & 0xFF) * 0x01010101u :
          size == 2 ? (uint32_t)(val & 0xFFFF) * 0x00010001u : (uint32_t)val;
    ngage_lanes(off, size, val, &be);
    m = ngage_be_mask(be);
    low = be & 3;
    ngage_trace_log("simif", true, SIM_BASE + off, size, val);
    switch (off & ~3) {
    case 0x0:
        if (!low) {
            s->reg800 = (s->reg800 & ~m) | (rep & m);
            break;
        }
        {
            uint16_t before = s->status;

            s->status &= ~(rep & 0xFFFF);
            if ((before & 8) && (rep & 8) && s->phase == 1) {
                if (s->used) {
                    s->status |= 0x10;
                }
                s->phase = 2;
            }
        }
        break;
    case 0x4:
        s->reg804 = (s->reg804 & ~m) | (rep & m);
        break;
    case 0x8:
        s->reg808 = (s->reg808 & ~m) | (rep & m);
        if (low && (rep & 0xFFFF) == 1 && !s->injected) {
            s->injected = true;
            s->status = 0x10;
            sim_log(s, "reception started");
        }
        break;
    case 0xC:
        s->reg80c = (s->reg80c & ~m) | (rep & m);
        if (low && s->injected) {
            bool none_waiting = s->used == 0, emits = card_will_emit(s);

            card_tx(s, rep & 0xFF);
            if (none_waiting && emits) {
                s->phase = 1;
                s->status = 8;
                s->position = 0;
            }
        }
        break;
    }
    sim_update(s);
}

static uint64_t b8_read(void *opaque, hwaddr off, unsigned size)
{
    NGageSim *s = opaque;
    unsigned be;
    uint64_t v;

    ngage_lanes(off, size, 0, &be);
    v = ngage_take((be & 3) ? (s->status ? 4 : 0) : s->regb8, off, size);
    ngage_trace_log("simif", false, B8_BASE + off, size, v);
    return v;
}

static void b8_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageSim *s = opaque;
    unsigned be;
    uint32_t w = ngage_lanes(off, size, val, &be), m = ngage_be_mask(be);

    ngage_trace_log("simif", true, B8_BASE + off, size, val);
    s->regb8 = (s->regb8 & ~m) | (w & m);
}

static const MemoryRegionOps sim_ops = {
    .read = sim_read, .write = sim_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static const MemoryRegionOps b8_ops = {
    .read = b8_read, .write = b8_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

void ngage_sim_create(MemoryRegion *sysmem, FILE *log)
{
    NGageSim *s = g_new0(NGageSim, 1);

    s->log = log;
    s->selected = s->directory = 0x3F00;
    memory_region_init_io(&s->mr, NULL, &sim_ops, s, "ngage.simif", 0x10);
    memory_region_add_subregion(sysmem, SIM_BASE, &s->mr);
    memory_region_init_io(&s->b8_mr, NULL, &b8_ops, s, "ngage.simif-b8", 4);
    memory_region_add_subregion(sysmem, B8_BASE, &s->b8_mr);
}
