/*
 * HLE audio device at 0x0C1F0000: an EMULATOR INVENTION, not UPP_WD2
 * hardware. On the phone, PCM goes from SoundDevice.mda to NOS over ISI
 * (resource 0xE8, docs/NOS_STANDIN.md) and NOS has the DSP play it from a
 * shared SDRAM chunk; both are encrypted. The NOS stand-in answers those
 * messages and drives this device, which the FPGA core implements as a
 * small block reading PCM from SDRAM. Nothing in the firmware touches the
 * 0x0C1Fxxxx page (no constant in the ROM, no access in any run), and
 * Symbian maps it at virtual 0x581F0000 with the rest of 0x0C1xxxxx.
 * Registers (32-bit, docs/UPP_WD2.md "HLE audio device"):
 *
 *   +0x00  ID      read 0x41554431 ("AUD1")
 *   +0x04  CTRL    bit 0 RUN (0 resets position and both buffers),
 *                  bit 1 IRQ enable
 *   +0x08  FORMAT  bit 0 stereo (L, R frames); samples are signed 16-bit
 *                  little-endian
 *   +0x0C  RATE    frames per second (4000-48000)
 *   +0x10  ADDR0   physical address of buffer 0     +0x14  ADDR1
 *   +0x18  LEN0    frames in buffer 0; writing a nonzero value marks the
 *                  buffer full                       +0x1C  LEN1
 *   +0x20  STATUS  bit 0/1 DONE0/1: that buffer was played to its end
 *                  (write 1 to clear); bit 4/5 FULL0/1; bit 8 running;
 *                  bit 9 buffer being played; bit 10 starved (both empty)
 *   +0x24  POS     frames played from the current buffer
 *   +0x28  VOLUME  gain 0-0x100 (0x100 = unity), reset 0x100
 *   +0x2C  PLAYED  frames played since RUN, silence included
 *
 * While RUN is set the device plays the current buffer at RATE. At its
 * end the buffer becomes empty, DONE is set and play moves to the other
 * buffer. When the current buffer is empty play takes the other one if it
 * is full, else outputs silence until one is filled. The interrupt (source
 * 5, IrqTimer5, which nothing in Symbian binds and no timer drives in the
 * model) is DONE0|DONE1 while IRQ enable is set.
 *
 * Time follows QEMU_CLOCK_VIRTUAL (guest time), so what the guest sees is
 * the same however fast the host runs. The model writes what it plays to
 * a WAV file at the first session's rate and format, and resamples to
 * 48 kHz stereo (linear interpolation, as the FPGA does for AUDIO_L/R)
 * for the host audio backend when one is given (-audiodev ...,id=x
 * -M ngage-qd,audiodev=x). Host playback is in real time only when guest
 * time is (NGAGE_ICOUNT=none or sleep=on): otherwise its buffer overflows
 * and the excess is dropped.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "qemu/audio.h"
#include "system/address-spaces.h"
#include "system/system.h"
#include "hw/arm/ngage.h"

#define AUD_BASE        0x0C1F0000
#define AUD_ID          0x41554431u
#define AUD_IRQ         5
#define AUD_TICK_NS     (5 * 1000 * 1000)       /* 5 ms of guest time */
#define OUT_RATE        48000
#define RING_FRAMES     (OUT_RATE / 2)          /* 0.5 s of host output */
#define MAX_CHUNK       4096

enum {
    R_ID = 0x00, R_CTRL = 0x04, R_FORMAT = 0x08, R_RATE = 0x0C,
    R_ADDR0 = 0x10, R_ADDR1 = 0x14, R_LEN0 = 0x18, R_LEN1 = 0x1C,
    R_STATUS = 0x20, R_POS = 0x24, R_VOLUME = 0x28, R_PLAYED = 0x2C,
};

#define CTRL_RUN        1u
#define CTRL_IRQEN      2u
#define ST_DONE(n)      (1u << (n))
#define ST_FULL(n)      (1u << (4 + (n)))
#define ST_RUNNING      (1u << 8)
#define ST_CUR          (1u << 9)
#define ST_STARVED      (1u << 10)

typedef struct NGageAudio {
    MemoryRegion mr;
    QEMUTimer *tick;
    FILE *log;

    uint32_t ctrl, format, rate, addr[2], len[2], volume;
    bool full[2];
    uint32_t done;              /* DONE0/1 */
    int cur;
    uint32_t pos, played;
    bool starved;
    int64_t start_ns;           /* guest time of RUN */
    uint64_t due_base;          /* frames played before the last rate change */

    /* WAV dump */
    FILE *wav;
    uint32_t wav_rate;
    int wav_channels;
    uint64_t wav_frames;
    uint32_t wav_phase;         /* 16.16 resampler for other rates */
    unsigned wav_ticks;

    /* host output: 48 kHz stereo ring */
    AudioBackend *be;
    SWVoiceOut *voice;
    int16_t ring[RING_FRAMES][2];
    unsigned rhead, rtail;      /* frames, rhead == rtail: empty */
    uint32_t out_phase;         /* 16.16 position between last and next */
    int16_t out_last[2];
} NGageAudio;

static NGageAudio *the_audio;

static void aud_log(NGageAudio *s, const char *fmt, ...) G_GNUC_PRINTF(2, 3);
static void aud_log(NGageAudio *s, const char *fmt, ...)
{
    va_list ap;

    if (!s->log) {
        return;
    }
    fprintf(s->log, "t=%" PRId64 " ", qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL));
    va_start(ap, fmt);
    vfprintf(s->log, fmt, ap);
    va_end(ap);
    fputc('\n', s->log);
}

static void aud_update_irq(NGageAudio *s)
{
    ngage_intc_set_source(AUD_IRQ, (s->ctrl & CTRL_IRQEN) && s->done);
}

/* ---------------------------------------------------------------- WAV */

static void wav_header(NGageAudio *s)
{
    uint32_t bytes = (uint32_t)MIN(s->wav_frames * 2 * s->wav_channels, UINT32_MAX - 36);
    uint32_t br = s->wav_rate * 2 * s->wav_channels;
    uint8_t h[44];

    memcpy(h, "RIFF", 4);
    stl_le_p(h + 4, 36 + bytes);
    memcpy(h + 8, "WAVEfmt ", 8);
    stl_le_p(h + 16, 16);
    stw_le_p(h + 20, 1);
    stw_le_p(h + 22, s->wav_channels);
    stl_le_p(h + 24, s->wav_rate);
    stl_le_p(h + 28, br);
    stw_le_p(h + 32, 2 * s->wav_channels);
    stw_le_p(h + 34, 16);
    memcpy(h + 36, "data", 4);
    stl_le_p(h + 40, bytes);
    fseek(s->wav, 0, SEEK_SET);
    fwrite(h, 1, sizeof(h), s->wav);
    fseek(s->wav, 0, SEEK_END);
}

static void wav_put(NGageAudio *s, const int16_t *f, unsigned n, int ch)
{
    if (!s->wav) {
        return;
    }
    if (!s->wav_rate) {
        s->wav_rate = s->rate;
        s->wav_channels = ch;
        wav_header(s);
    }
    for (unsigned i = 0; i < n; i++) {
        int16_t l = f[i * ch], r = f[i * ch + ch - 1];
        uint8_t b[4];

        /* nearest-sample conversion when a later session uses another rate */
        s->wav_phase += (uint32_t)(((uint64_t)s->wav_rate << 16) / s->rate);
        while (s->wav_phase >= 0x10000) {
            s->wav_phase -= 0x10000;
            stw_le_p(b, s->wav_channels == 2 ? l : (int16_t)((l + r) / 2));
            stw_le_p(b + 2, r);
            fwrite(b, 2, s->wav_channels, s->wav);
            s->wav_frames++;
        }
    }
}

/* ---------------------------------------------------------------- host */

static void out_push(NGageAudio *s, int16_t l, int16_t r)
{
    unsigned next = (s->rhead + 1) % RING_FRAMES;

    if (next == s->rtail) {
        return;                 /* host is behind guest time: drop */
    }
    s->ring[s->rhead][0] = l;
    s->ring[s->rhead][1] = r;
    s->rhead = next;
}

/* Linear interpolation from RATE to 48 kHz: the FPGA's resampler. */
static void out_put(NGageAudio *s, const int16_t *f, unsigned n, int ch)
{
    uint32_t step = (uint32_t)(((uint64_t)s->rate << 16) / OUT_RATE);

    if (!s->voice) {
        return;
    }
    for (unsigned i = 0; i < n; i++) {
        int16_t l = f[i * ch], r = f[i * ch + ch - 1];

        while (s->out_phase < 0x10000) {
            int32_t a = s->out_phase;
            out_push(s, s->out_last[0] + (((l - s->out_last[0]) * a) >> 16),
                     s->out_last[1] + (((r - s->out_last[1]) * a) >> 16));
            s->out_phase += step;
        }
        s->out_phase -= 0x10000;
        s->out_last[0] = l;
        s->out_last[1] = r;
    }
}

static void out_callback(void *opaque, int avail)
{
    NGageAudio *s = opaque;
    int16_t buf[512][2];

    while (avail >= 4) {
        unsigned n = 0;

        while (n < 512 && n * 4 < (unsigned)avail) {
            if (s->rtail != s->rhead) {
                buf[n][0] = s->ring[s->rtail][0];
                buf[n][1] = s->ring[s->rtail][1];
                s->rtail = (s->rtail + 1) % RING_FRAMES;
            } else {
                buf[n][0] = buf[n][1] = 0;
            }
            n++;
        }
        size_t w = audio_be_write(s->be, s->voice, buf, n * 4);
        if (w == 0) {
            break;
        }
        avail -= w;
    }
}

/* ---------------------------------------------------------------- play */

static void aud_output(NGageAudio *s, const int16_t *f, unsigned n, int ch)
{
    wav_put(s, f, n, ch);
    out_put(s, f, n, ch);
}

static void aud_play(NGageAudio *s, uint64_t todo)
{
    int ch = (s->format & 1) ? 2 : 1;
    int16_t buf[MAX_CHUNK * 2];

    while (todo) {
        unsigned n = MIN(todo, MAX_CHUNK);
        int b = s->cur;

        if (!s->full[b] && s->full[b ^ 1]) {
            s->cur = b ^= 1;
            s->pos = 0;
        }
        if (!s->full[b]) {
            if (!s->starved) {
                aud_log(s, "starved after %u frames", s->played);
                s->starved = true;
            }
            memset(buf, 0, n * 2 * ch);
            aud_output(s, buf, n, ch);
            s->played += n;
            todo -= n;
            continue;
        }
        if (s->starved) {
            aud_log(s, "resumed with buffer %d at frame %u", b, s->played);
            s->starved = false;
        }
        n = MIN(n, s->len[b] - s->pos);
        address_space_read(&address_space_memory,
                           s->addr[b] + (hwaddr)s->pos * 2 * ch,
                           MEMTXATTRS_UNSPECIFIED, buf, n * 2 * ch);
        for (unsigned i = 0; i < n * ch; i++) {
            int32_t v = (int16_t)le16_to_cpu(buf[i]);
            buf[i] = (int16_t)((v * (int32_t)s->volume) >> 8);
        }
        aud_output(s, buf, n, ch);
        s->pos += n;
        s->played += n;
        todo -= n;
        if (s->pos >= s->len[b]) {
            s->full[b] = false;
            s->done |= ST_DONE(b);
            s->cur = b ^ 1;
            s->pos = 0;
            aud_update_irq(s);
        }
    }
}

/* Frames due between RUN and now at RATE, minus those played. */
static void aud_catch_up(NGageAudio *s)
{
    if (!(s->ctrl & CTRL_RUN) || !s->rate) {
        return;
    }
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    uint64_t due = s->due_base + muldiv64(now - s->start_ns, s->rate, NANOSECONDS_PER_SECOND);
    uint64_t have = s->played;

    if (due > have) {
        aud_play(s, due - have);
    }
}

static void aud_tick(void *opaque)
{
    NGageAudio *s = opaque;

    aud_catch_up(s);
    if (s->ctrl & CTRL_RUN) {
        timer_mod(s->tick, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + AUD_TICK_NS);
    }
    if (s->wav && s->wav_rate && ++s->wav_ticks % 200 == 0) {
        wav_header(s);          /* keep the file readable during a run */
    }
}

static void aud_run(NGageAudio *s, bool on)
{
    if (on) {
        s->cur = 0;
        s->pos = 0;
        s->played = 0;
        s->due_base = 0;
        s->starved = false;
        s->start_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
        timer_mod(s->tick, s->start_ns + AUD_TICK_NS);
        aud_log(s, "run: rate %u, %s, buffers %08x %08x", s->rate,
                (s->format & 1) ? "stereo" : "mono", s->addr[0], s->addr[1]);
        if (s->voice) {
            audio_be_set_active_out(s->be, s->voice, true);
        }
    } else {
        aud_catch_up(s);
        timer_del(s->tick);
        aud_log(s, "stop after %u frames (buffer %d, pos %u)", s->played, s->cur, s->pos);
        s->full[0] = s->full[1] = false;
        s->done = 0;
        if (s->wav && s->wav_rate) {
            wav_header(s);
            fflush(s->wav);
        }
    }
}

/* ---------------------------------------------------------------- regs */

static uint64_t aud_read(void *opaque, hwaddr off, unsigned size)
{
    NGageAudio *s = opaque;
    uint32_t v = 0;

    aud_catch_up(s);
    switch (off) {
    case R_ID: v = AUD_ID; break;
    case R_CTRL: v = s->ctrl; break;
    case R_FORMAT: v = s->format; break;
    case R_RATE: v = s->rate; break;
    case R_ADDR0: v = s->addr[0]; break;
    case R_ADDR1: v = s->addr[1]; break;
    case R_LEN0: v = s->len[0]; break;
    case R_LEN1: v = s->len[1]; break;
    case R_STATUS:
        v = s->done | (s->full[0] ? ST_FULL(0) : 0) | (s->full[1] ? ST_FULL(1) : 0) |
            ((s->ctrl & CTRL_RUN) ? ST_RUNNING : 0) | (s->cur ? ST_CUR : 0) |
            (s->starved ? ST_STARVED : 0);
        break;
    case R_POS: v = s->pos; break;
    case R_VOLUME: v = s->volume; break;
    case R_PLAYED: v = s->played; break;
    }
    ngage_trace_log("haudio", false, AUD_BASE + off, size, v);
    return v;
}

static void aud_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageAudio *s = opaque;
    uint32_t v = val;

    ngage_trace_log("haudio", true, AUD_BASE + off, size, v);
    aud_catch_up(s);
    switch (off) {
    case R_CTRL:
        if ((v ^ s->ctrl) & CTRL_RUN) {
            s->ctrl = v;
            aud_run(s, v & CTRL_RUN);
        }
        s->ctrl = v;
        break;
    case R_FORMAT: s->format = v & 1; break;
    case R_RATE:
        v = MAX(4000, MIN(48000, v));
        if (v != s->rate && (s->ctrl & CTRL_RUN)) {
            s->due_base = s->played;
            s->start_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
        }
        s->rate = v;
        break;
    case R_ADDR0: s->addr[0] = v & ~1u; break;
    case R_ADDR1: s->addr[1] = v & ~1u; break;
    case R_LEN0:
    case R_LEN1: {
        int b = (off - R_LEN0) >> 2;
        s->len[b] = v;
        s->full[b] = v != 0;
        break;
    }
    case R_STATUS:
        s->done &= ~(v & (ST_DONE(0) | ST_DONE(1)));
        break;
    case R_VOLUME: s->volume = MIN(v, 0x100u); break;
    }
    aud_update_irq(s);
}

static const MemoryRegionOps aud_ops = {
    .read = aud_read, .write = aud_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static void aud_exit(Notifier *n, void *data)
{
    NGageAudio *s = the_audio;

    if (s && s->wav) {
        aud_catch_up(s);
        if (s->wav_rate) {
            wav_header(s);
        }
        fclose(s->wav);
        s->wav = NULL;
    }
}

static Notifier aud_exit_notifier = { .notify = aud_exit };

void ngage_audio_create(MemoryRegion *sysmem, AudioBackend *be, const char *wav_path,
                        FILE *log)
{
    NGageAudio *s = g_new0(NGageAudio, 1);

    the_audio = s;
    s->log = log;
    s->volume = 0x100;
    s->rate = 16000;
    s->tick = timer_new_ns(QEMU_CLOCK_VIRTUAL, aud_tick, s);
    if (wav_path) {
        s->wav = fopen(wav_path, "w+b");
        if (!s->wav) {
            error_report("ngage: cannot create %s", wav_path);
        }
    }
    if (be) {
        struct audsettings as = { .freq = OUT_RATE, .nchannels = 2,
                                  .fmt = AUDIO_FORMAT_S16, .big_endian = false };
        s->be = be;
        s->voice = audio_be_open_out(be, NULL, "ngage.audio", s, out_callback, &as);
        if (!s->voice) {
            error_report("ngage: audio output not available");
        }
    }
    qemu_add_exit_notifier(&aud_exit_notifier);
    memory_region_init_io(&s->mr, NULL, &aud_ops, s, "ngage.haudio", 0x100);
    memory_region_add_subregion(sysmem, AUD_BASE, &s->mr);
}
