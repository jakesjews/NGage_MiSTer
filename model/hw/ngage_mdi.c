/*
 * The MDI link between the UPP_WD2's MCU and its internal DSP, and the DSP's
 * side of it, as the core has them (rtl/upp/upp_mdi.v, upp_mdi_peer.v,
 * upp_dsp_pcm.v; docs/FIRMWARE-PROFILES.md has how they were found by running
 * the unmodified RH-29 4.10 firmware). The DSP's own code is not run: what is
 * here answers the three things NOS asks of it.
 *
 * The link: two rings of 250 halfwords in shared memory and a pointer word
 * for each.
 *   0x0C100000  ring to the DSP (halfword n at +2n)
 *   0x0C1001F4  ring from the DSP
 *   0x0C1003E8  to the DSP: bits 15:0 where NOS writes next, bits 31:16 where
 *               the DSP reads next
 *   0x0C1003EC  from the DSP: bits 15:0 where the DSP writes next, bits 31:16
 *               where NOS reads next
 *   0x0C14B004  control: the link runs while bits 15:0 are 0x0500
 * A frame is big-endian bytes, two to a halfword: four header bytes, a
 * 16-bit length and that many bytes more. The DSP takes what is in the ring
 * to it (CTSI status bit 9, ngage_ctsi.c) and publishes its own frames by
 * moving its write pointer (bit 10).
 *
 * The DSP's side:
 *   - twenty steps of CTSI's slow counter after both pointer words have been
 *     written with the link running, it announces itself: the halfwords
 *     0000 7CD0 0001 0400. NOS's start-up waits for that.
 *   - Version requests (resource 0xF1, message 0xA0) get the reply the core
 *     gives: RF version 3 and DSP software "HDL01", made-up values.
 *   - PCM playback (resource 0xE8): start (0x20, with two buffer addresses in
 *     the handset's shared chunk, 0x0A061000-0x0A06FFFF, their size in frames
 *     and the rate), a buffer filled (0x23, or 0x27 after the DSP asked for
 *     one with 0x26), stop (0x2A). The samples are played by ngage_pcm.c.
 *     Replies: 0x21, 0x24 / 0x28, 0x2B with the position; 0x2B on its own
 *     when a buffer marked as the last has been played. A buffer's sample
 *     count is used as given, also when it is more than a half holds (the
 *     first buffer of Tony Hawk's streams: 8192 samples of silence with
 *     halves of 5600): it is played from the half's address past its end.
 * Anything else is taken from the ring and not answered.
 *
 * The core's blocks work a halfword at a time through the SDRAM; here a
 * frame is taken or published in one step, a microsecond after what caused
 * it.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "hw/arm/ngage.h"

#define RING_BASE       0x0C100000
#define RING_HALVES     250
#define RING_BYTES      (4 * RING_HALVES)       /* both rings */
#define D2M_OFF         (2 * RING_HALVES)
#define CTL_BASE        0x0C14B004
#define ANNOUNCE_TICKS  20
#define WORK_NS         1000

typedef struct DspPcm {
    uint8_t hdr[24];
    unsigned received;
    bool opened, first_buffer, requested, requested_half, final_valid, final_half;
    unsigned free_halves;
    uint16_t final_frames;
    uint8_t media, device, object_id, dsp_device, dsp_object;
    bool reply;                 /* a reply waits to be published */
    uint8_t reply_transaction, reply_opcode;
    uint16_t reply_value;
} DspPcm;

typedef struct NGageMdi {
    MemoryRegion ring_mr, ctl_mr;
    uint8_t mem[RING_BYTES];
    uint32_t control, pointers, receive_ptr;
    bool pointers_seen, receive_seen, announced, announce_due, up;
    QEMUTimer *announce_timer, *work_timer;
    /* the frame being taken from the ring */
    unsigned word_index;
    uint32_t byte_index, frame_bytes;
    uint8_t seen[48];           /* its first bytes, for the log */
    /* the version peer */
    uint8_t rf_hdr[11];
    unsigned rf_received;
    bool rf_active, rf_is_rf;
    DspPcm pcm;
    FILE *log;
} NGageMdi;

static NGageMdi *the_mdi;

static void mdi_log(NGageMdi *s, const char *fmt, ...) G_GNUC_PRINTF(2, 3);
static void mdi_log(NGageMdi *s, const char *fmt, ...)
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

static void mdi_log_frame(NGageMdi *s, const char *what, const uint8_t *b, unsigned n, unsigned total)
{
    if (!s->log) {
        return;
    }
    fprintf(s->log, "%11.6f %s", ngage_guest_seconds(), what);
    for (unsigned i = 0; i < n; i++) {
        fprintf(s->log, " %02x", b[i]);
    }
    if (total > n) {
        fprintf(s->log, " .. (%u bytes)", total);
    }
    fputc('\n', s->log);
}

static bool running(NGageMdi *s)
{
    return (s->control & 0xFFFF) == 0x0500;
}

static bool pointers_valid(NGageMdi *s)
{
    return (s->pointers & 0xFFFF) < RING_HALVES && (s->pointers >> 16) < RING_HALVES &&
           (s->receive_ptr & 0xFFFF) < RING_HALVES && (s->receive_ptr >> 16) < RING_HALVES;
}

static unsigned next_index(unsigned i)
{
    return i == RING_HALVES - 1 ? 0 : i + 1;
}

static unsigned output_free(NGageMdi *s)
{
    unsigned p = s->receive_ptr & 0xFF, c = (s->receive_ptr >> 16) & 0xFF;

    return RING_HALVES - 1 - (p >= c ? p - c : p + RING_HALVES - c);
}

/* ---------------------------------------------------------------- the version peer */

static void rf_byte(NGageMdi *s, uint8_t d, bool last)
{
    const uint8_t *h = s->rf_hdr;

    if (s->rf_received < 11) {
        s->rf_hdr[s->rf_received] = d;
    }
    if (!last) {
        if (s->rf_received != 31) {
            s->rf_received++;
        }
        return;
    }
    /* NOS sends media 0x12; 0 is the form the core's benches use */
    if (s->rf_received == 11 && (h[0] == 0x12 || h[0] == 0) && (h[1] & 0xFC) == 0x7C &&
        h[3] == 0xF1 && h[4] == 0 && h[5] == 6 && h[9] == 0xA0 &&
        ((h[8] == 0x20 && h[10] == 2) || (h[8] == 0x40 && h[10] == 1))) {
        s->rf_active = true;
        s->rf_is_rf = h[8] == 0x20;
    }
    s->rf_received = 0;
}

static unsigned rf_reply(NGageMdi *s, uint8_t *out)
{
    static const uint8_t dsp_sw[5] = { 'H', 'D', 'L', '0', '1' };
    const uint8_t *h = s->rf_hdr;
    unsigned n = 0;

    out[n++] = h[0];
    out[n++] = h[2];
    out[n++] = h[1];
    out[n++] = h[3];
    out[n++] = 0;
    out[n++] = s->rf_is_rf ? 6 : 10;
    out[n++] = h[7];
    out[n++] = h[6];
    out[n++] = h[8];
    out[n++] = 0xA1;
    out[n++] = s->rf_is_rf ? 1 : 5;
    if (s->rf_is_rf) {
        out[n++] = 0x03;
    } else {
        memcpy(out + n, dsp_sw, 5);
        n += 5;
    }
    return n;
}

/* ---------------------------------------------------------------- PCM playback */

static void pcm_reply(DspPcm *p, uint8_t transaction, uint8_t opcode, uint16_t value)
{
    p->reply = true;
    p->reply_transaction = transaction;
    p->reply_opcode = opcode;
    p->reply_value = value;
}

/* A whole frame for resource 0xE8 has come in: n bytes of it are in hdr. */
static void pcm_frame(NGageMdi *s, unsigned n)
{
    DspPcm *p = &s->pcm;
    const uint8_t *h = p->hdr;
    uint32_t st = ngage_pcm_status();
    unsigned full = (st >> 16) & 3;
    bool playing = st & (1u << 15);
    uint8_t opcode = h[9];
    uint16_t frames = h[12] << 8 | h[13];
    uint32_t bytes = (uint32_t)frames << 1;
    uint32_t a0 = ldl_be_p(h + 14), a1 = ldl_be_p(h + 18);
    uint32_t low0 = a0 & 0x1FFFF, low1 = a1 & 0x1FFFF;
    uint32_t end0 = low0 + bytes, end1 = low1 + bytes;
    bool start_valid = n == 24 && h[10] == 0x82 && h[11] == 2 && h[22] == 0 &&
                       (h[23] == 0x32 || h[23] == 0x46) &&
                       (a0 >> 17) == 0x0503 && (a1 >> 17) == 0x0503 &&
                       low0 >= 0x1000 && low1 >= 0x1000 && !(low0 & 1) && !(low1 & 1) &&
                       frames != 0 && end0 <= 0x10000 && end1 <= 0x10000 &&
                       (end0 <= low1 || end1 <= low0);
    bool owner = p->opened && p->device == h[2] && p->object_id == h[7] &&
                 p->dsp_device == h[1] && p->dsp_object == h[6];
    bool half = opcode == 0x23 ? h[10] & 1 : p->requested_half;
    unsigned half_mask = half ? 2 : 1;
    bool submit_valid = n == 14 && owner && !p->final_valid &&
                        ((opcode == 0x23 && h[10] < 2) || (opcode == 0x27 && p->requested)) &&
                        !(full & half_mask) &&
                        (h[11] == 1 || h[11] == 2);

    if ((opcode == 0x20 && start_valid) || (opcode == 0x2A && n == 10 && !p->opened)) {
        p->media = h[0];
        p->device = h[2];
        p->object_id = h[7];
        p->dsp_device = h[1];
        p->dsp_object = h[6];
    }
    if (opcode == 0x20 && start_valid) {
        mdi_log(s, "PCM start: %u frames a buffer at %08x and %08x, %u Hz", frames, a0, a1,
                h[23] == 0x32 ? 8000 : 16000);
        ngage_pcm_write(0x04, 0);
        p->opened = true;
        p->first_buffer = true;
        p->requested = false;
        p->final_valid = false;
        p->free_halves = 0;
        ngage_pcm_write(0x08, 0);
        ngage_pcm_write(0x0C, h[23] == 0x32 ? 8000 : 16000);
        ngage_pcm_write(0x10, a0);
        ngage_pcm_write(0x14, a1);
        pcm_reply(p, h[8], 0x21, 0);
    } else if (opcode == 0x2A && n == 10 && (owner || !p->opened)) {
        uint16_t pos = owner && playing ? (st & 0x7FFF) << 1 : 0;

        mdi_log(s, "PCM stop at %u", pos);
        ngage_pcm_write(0x04, 0);
        p->opened = false;
        pcm_reply(p, h[8], 0x2B, pos);
    } else if (submit_valid) {
        ngage_pcm_write(0x20, half_mask);       /* an end of this half not yet seen */
        if (p->requested && half == p->requested_half) {
            p->requested = false;
        }
        if (h[11] == 1) {
            p->final_valid = true;
            p->final_half = half;
            p->final_frames = frames;
        }
        p->free_halves = (p->free_halves | (p->first_buffer ? (half ? 1 : 2) : 0)) & ~half_mask;
        p->first_buffer = false;
        ngage_pcm_write(half ? 0x1C : 0x18, frames);
        if (!playing && frames != 0) {
            ngage_pcm_write(0x04, 1);
        }
        pcm_reply(p, h[8], opcode + 1, 0);
    } else {
        mdi_log(s, "PCM frame not answered: opcode %02x, %u bytes", opcode, n);
    }
}

static void pcm_byte(NGageMdi *s, uint8_t d, bool last)
{
    DspPcm *p = &s->pcm;

    if (p->received < 24) {
        p->hdr[p->received] = d;
    }
    if (!last) {
        if (p->received < 24) {
            p->received++;
        }
        return;
    }
    if (p->received >= 9 && p->received < 24 && p->hdr[3] == 0xE8 && (p->hdr[1] >> 2) == 0x1F) {
        pcm_frame(s, p->received + 1);
    }
    p->received = 0;
}

/* Nothing is on its way either way: what the playback itself gives rise to. */
static bool pcm_idle(NGageMdi *s)
{
    DspPcm *p = &s->pcm;
    uint32_t st = ngage_pcm_status();
    unsigned done = (st >> 18) & 3, full = (st >> 16) & 3;
    bool final_done = p->final_valid &&
                      ((done >> p->final_half) & 1 || (p->final_frames == 0 && full == 0));

    if (!p->opened || p->received != 0) {
        return false;
    }
    if (final_done) {
        mdi_log(s, "PCM: the last buffer has been played");
        ngage_pcm_write(0x04, 0);
        p->opened = false;
        pcm_reply(p, 0, 0x2B, p->final_frames << 1);
        return true;
    }
    if (done) {
        ngage_pcm_write(0x20, done);
        p->free_halves |= done & ~full;
        return true;
    }
    if (p->free_halves && !p->requested && !p->final_valid) {
        bool half = !(p->free_halves & 1);

        p->requested = true;
        p->requested_half = half;
        p->free_halves &= (p->free_halves & 1) ? 2 : 1;
        pcm_reply(p, 0, 0x26, half);
        return true;
    }
    return false;
}

static unsigned pcm_reply_bytes(DspPcm *p, uint8_t *out)
{
    out[0] = p->media;
    out[1] = p->device;
    out[2] = p->dsp_device;
    out[3] = 0xE8;
    out[4] = 0;
    out[5] = 8;
    out[6] = p->object_id;
    out[7] = p->dsp_object;
    out[8] = p->reply_transaction;
    out[9] = p->reply_opcode;
    out[10] = p->reply_value >> 8;
    out[11] = p->reply_value;
    out[12] = 0;
    out[13] = 0;
    return 14;
}

/* ---------------------------------------------------------------- the link */

static void link_down(NGageMdi *s)
{
    s->word_index = 0;
    s->byte_index = 0;
    s->frame_bytes = 0;
    s->announced = false;
    s->announce_due = false;
    timer_del(s->announce_timer);
    if (s->up) {
        s->up = false;
        s->rf_received = 0;
        s->rf_active = false;
        memset(&s->pcm, 0, sizeof(s->pcm));
        s->pcm.first_buffer = true;
        ngage_pcm_reset();
        mdi_log(s, "link down");
    }
}

static void publish(NGageMdi *s, const uint8_t *bytes, unsigned n)
{
    unsigned w = s->receive_ptr & 0xFF;

    for (unsigned i = 0; i < n; i += 2) {
        stw_le_p(s->mem + D2M_OFF + 2 * w, bytes[i] << 8 | bytes[i + 1]);
        w = next_index(w);
    }
    s->receive_ptr = (s->receive_ptr & 0xFFFF0000u) | w;
    ngage_ctsi_mdi_events(2);
}

/* One halfword of the ring to the DSP, its bytes to both receivers. */
static void take_word(NGageMdi *s)
{
    unsigned c = (s->pointers >> 16) & 0xFF;
    uint16_t half = lduw_le_p(s->mem + 2 * c);
    bool last;

    if (s->word_index == 2) {
        s->frame_bytes = (uint32_t)half + 6;
    }
    last = s->word_index >= 2 && s->byte_index + 1 == s->frame_bytes;
    if (s->byte_index < sizeof(s->seen)) {
        s->seen[s->byte_index] = half >> 8;
    }
    rf_byte(s, half >> 8, last);
    pcm_byte(s, half >> 8, last);
    s->byte_index++;
    if (!last) {
        last = s->word_index >= 2 && s->byte_index + 1 == s->frame_bytes;
        if (s->byte_index < sizeof(s->seen)) {
            s->seen[s->byte_index] = half & 0xFF;
        }
        rf_byte(s, half & 0xFF, last);
        pcm_byte(s, half & 0xFF, last);
        s->byte_index++;
    }
    if (last) {
        mdi_log_frame(s, "to the DSP:  ", s->seen, MIN(s->byte_index, sizeof(s->seen)), s->byte_index);
    }
    s->pointers = (s->pointers & 0xFFFF) | next_index(c) << 16;
    ngage_ctsi_mdi_events(1);
    if (last) {
        s->word_index = 0;
        s->byte_index = 0;
        s->frame_bytes = 0;
    } else {
        s->word_index++;
    }
}

static void mdi_work(void *opaque)
{
    NGageMdi *s = opaque;
    uint8_t out[16];

    if (!running(s)) {
        link_down(s);
        return;
    }
    if (!s->up) {
        s->up = true;
        mdi_log(s, "link up");
    }
    if (s->pointers_seen && s->receive_seen && !s->announced && !s->announce_due &&
        !timer_pending(s->announce_timer)) {
        int64_t n = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / NGAGE_NOS_TICK_NS;

        timer_mod(s->announce_timer, (n + ANNOUNCE_TICKS) * NGAGE_NOS_TICK_NS);
    }
    if (!pointers_valid(s)) {
        return;
    }
    for (;;) {
        bool tx = s->rf_active || s->pcm.reply;

        if (s->announce_due && !s->announced && output_free(s) >= 4) {
            static const uint8_t ann[8] = { 0x00, 0x00, 0x7C, 0xD0, 0x00, 0x01, 0x04, 0x00 };

            publish(s, ann, sizeof(ann));
            s->announced = true;
            mdi_log_frame(s, "from the DSP:", ann, sizeof(ann), sizeof(ann));
        } else if (tx && output_free(s) >= 8) {
            unsigned n;

            if (s->rf_active) {
                n = rf_reply(s, out);
                s->rf_active = false;
            } else {
                n = pcm_reply_bytes(&s->pcm, out);
                s->pcm.reply = false;
            }
            publish(s, out, n);
            mdi_log_frame(s, "from the DSP:", out, n, n);
        } else if (!tx && (s->pointers & 0xFF) != ((s->pointers >> 16) & 0xFF)) {
            take_word(s);
        } else if (!tx && pcm_idle(s)) {
            continue;
        } else {
            break;
        }
    }
}

void ngage_mdi_kick(void)
{
    NGageMdi *s = the_mdi;

    if (s && !timer_pending(s->work_timer)) {
        timer_mod(s->work_timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + WORK_NS);
    }
}

static void announce_fire(void *opaque)
{
    NGageMdi *s = opaque;

    if (running(s) && !s->announced) {
        s->announce_due = true;
        ngage_mdi_kick();
    }
}

/* ---------------------------------------------------------------- registers */

static uint32_t ring_word(NGageMdi *s, hwaddr off)
{
    if (off == RING_BYTES) {
        return s->pointers;
    }
    if (off == RING_BYTES + 4) {
        return s->receive_ptr;
    }
    return off < RING_BYTES ? ldl_le_p(s->mem + off) : 0;
}

static uint64_t ring_read(void *opaque, hwaddr off, unsigned size)
{
    NGageMdi *s = opaque;
    uint64_t v = ngage_take(ring_word(s, off & ~3), off, size);

    ngage_trace_log("mdi", false, RING_BASE + off, size, v);
    return v;
}

static void ring_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageMdi *s = opaque;
    unsigned be;
    uint32_t w = ngage_lanes(off, size, val, &be), m = ngage_be_mask(be);
    hwaddr word = off & ~3;

    ngage_trace_log("mdi", true, RING_BASE + off, size, val);
    if (word < RING_BYTES) {
        stl_le_p(s->mem + word, (ldl_le_p(s->mem + word) & ~m) | (w & m));
        return;
    }
    if (word == RING_BYTES) {
        s->pointers_seen = true;
        s->pointers = (s->pointers & ~m) | (w & m);
    } else if (word == RING_BYTES + 4) {
        s->receive_seen = true;
        s->receive_ptr = (s->receive_ptr & ~m) | (w & m);
    }
    ngage_mdi_kick();
}

static uint64_t ctl_read(void *opaque, hwaddr off, unsigned size)
{
    NGageMdi *s = opaque;
    uint64_t v = ngage_take(s->control, off, size);

    ngage_trace_log("mdi", false, CTL_BASE + off, size, v);
    return v;
}

static void ctl_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageMdi *s = opaque;
    unsigned be;
    uint32_t w = ngage_lanes(off, size, val, &be), m = ngage_be_mask(be);

    ngage_trace_log("mdi", true, CTL_BASE + off, size, val);
    s->control = (s->control & ~m) | (w & m);
    if (!running(s)) {
        link_down(s);
    }
    ngage_mdi_kick();
}

static const MemoryRegionOps ring_ops = {
    .read = ring_read, .write = ring_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static const MemoryRegionOps ctl_ops = {
    .read = ctl_read, .write = ctl_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

void ngage_mdi_create(MemoryRegion *sysmem, FILE *log)
{
    NGageMdi *s = g_new0(NGageMdi, 1);

    the_mdi = s;
    s->log = log;
    s->pcm.first_buffer = true;
    s->announce_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, announce_fire, s);
    s->work_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, mdi_work, s);
    memory_region_init_io(&s->ring_mr, NULL, &ring_ops, s, "ngage.mdi-rings", RING_BYTES + 8);
    memory_region_add_subregion(sysmem, RING_BASE, &s->ring_mr);
    memory_region_init_io(&s->ctl_mr, NULL, &ctl_ops, s, "ngage.mdi-control", 4);
    memory_region_add_subregion(sysmem, CTL_BASE, &s->ctl_mr);
}
