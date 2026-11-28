/*
 * PCM playback of the UPP_WD2's internal DSP, as the core has it
 * (rtl/upp/upp_pcm.v). On the phone, SoundDevice.mda sends PCM requests to
 * NOS over ISI (resource 0xE8) and NOS has the DSP play the samples from two
 * halves of a shared SDRAM chunk. The DSP's side of that exchange is in
 * ngage_mdi.c; this file is what it drives, and has no registers the CPU can
 * reach. Its control port (ngage_pcm_write):
 *
 *   0x04  bit 0 RUN; 0 empties both buffers and forgets their DONE
 *   0x08  bit 0 stereo (L, R frames); samples are signed 16-bit little-endian
 *   0x0C  frames per second (4000-48000; the DSP asks for 8000 or 16000)
 *   0x10  physical address of buffer 0             0x14  of buffer 1
 *   0x18  frames in buffer 0; a value other than 0 marks it full
 *                                                  0x1C  buffer 1
 *   0x20  write 1 to bit 0/1: forget DONE of buffer 0/1
 *
 * and its status (ngage_pcm_status): bits 19:18 DONE, 17:16 full, 15
 * running, 14:0 the frame being played in the current buffer.
 *
 * While RUN is set the current buffer is played at the rate. At its end the
 * buffer becomes empty, DONE is set and play moves to the other buffer.
 * When the current buffer is empty play takes the other one if it is full,
 * else there is silence until one is filled.
 *
 * Time follows QEMU_CLOCK_VIRTUAL (guest time), so what the guest sees is
 * the same however fast the host runs. The model writes what it plays to
 * a WAV file at the first session's rate and format, and resamples to
 * 48 kHz stereo (linear interpolation, as the core does for AUDIO_L/R)
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

#define AUD_TICK_NS     (5 * 1000 * 1000)       /* 5 ms of guest time */
#define OUT_RATE        48000
#define RING_FRAMES     (OUT_RATE / 2)          /* 0.5 s of host output */
#define MAX_CHUNK       4096

enum {
    R_CTRL = 0x04, R_FORMAT = 0x08, R_RATE = 0x0C,
    R_ADDR0 = 0x10, R_ADDR1 = 0x14, R_LEN0 = 0x18, R_LEN1 = 0x1C,
    R_DONE = 0x20,
};

#define CTRL_RUN        1u

typedef struct NGageAudio {
    QEMUTimer *tick;
    FILE *log;

    uint32_t ctrl, format, rate, addr[2], len[2];
    bool full[2];
    uint32_t done;              /* bit 0/1: buffer 0/1 was played to its end */
    int cur;
    uint32_t pos, played;
    bool starved;
    bool ended;                 /* a buffer ended since the DSP side was last told */
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
            /* 64-bit products: a sample step near full scale times a phase
             * near 1.0 overflows int (the FPGA computes this in 34 bits) */
            out_push(s, s->out_last[0] + (int)(((int64_t)(l - s->out_last[0]) * a) >> 16),
                     s->out_last[1] + (int)(((int64_t)(r - s->out_last[1]) * a) >> 16));
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
            buf[i] = (int16_t)le16_to_cpu(buf[i]);
        }
        aud_output(s, buf, n, ch);
        s->pos += n;
        s->played += n;
        todo -= n;
        if (s->pos >= s->len[b]) {
            s->full[b] = false;
            s->done |= 1u << b;
            s->cur = b ^ 1;
            s->pos = 0;
            s->ended = true;
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

/* The next look: in 5 ms, or when the buffer being played ends if that is
 * sooner, so that the DSP side hears of the end when it happens. */
static void aud_next_tick(NGageAudio *s)
{
    int64_t at = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + AUD_TICK_NS;
    int b = (!s->full[s->cur] && s->full[s->cur ^ 1]) ? s->cur ^ 1 : s->cur;

    if (s->full[b] && s->rate) {
        uint64_t left = b == s->cur ? s->len[b] - MIN(s->pos, s->len[b]) : s->len[b];
        int64_t end = s->start_ns + muldiv64(s->played - s->due_base + left, NANOSECONDS_PER_SECOND,
                                            s->rate) + 1;
        at = MIN(at, MAX(end, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 1));
    }
    timer_mod(s->tick, at);
}

static void aud_told(NGageAudio *s)
{
    if (s->ended) {
        s->ended = false;
        ngage_mdi_kick();
    }
}

static void aud_tick(void *opaque)
{
    NGageAudio *s = opaque;

    aud_catch_up(s);
    if (s->ctrl & CTRL_RUN) {
        aud_next_tick(s);
    }
    if (s->wav && s->wav_rate && ++s->wav_ticks % 200 == 0) {
        wav_header(s);          /* keep the file readable during a run */
    }
    aud_told(s);
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
        aud_log(s, "run: rate %u, %s, buffers %08x %08x", s->rate,
                (s->format & 1) ? "stereo" : "mono", s->addr[0], s->addr[1]);
        if (s->voice) {
            audio_be_set_active_out(s->be, s->voice, true);
        }
    } else {
        timer_del(s->tick);
        aud_log(s, "stop after %u frames (buffer %d, pos %u)", s->played, s->cur, s->pos);
        if (s->wav && s->wav_rate) {
            wav_header(s);
            fflush(s->wav);
        }
    }
}

/* ---------------------------------------------------------------- the DSP's port */

uint32_t ngage_pcm_status(void)
{
    NGageAudio *s = the_audio;

    if (!s) {
        return 0;
    }
    aud_catch_up(s);
    return s->done << 18 | (uint32_t)s->full[1] << 17 | (uint32_t)s->full[0] << 16 |
           ((s->ctrl & CTRL_RUN) ? 1u << 15 : 0) | (s->pos & 0x7FFF);
}

void ngage_pcm_write(unsigned off, uint32_t v)
{
    NGageAudio *s = the_audio;

    if (!s) {
        return;
    }
    aud_catch_up(s);
    switch (off) {
    case R_CTRL:
        if ((v ^ s->ctrl) & CTRL_RUN) {
            aud_run(s, v & CTRL_RUN);
        }
        s->ctrl = v & CTRL_RUN;
        if (!(v & CTRL_RUN)) {
            s->full[0] = s->full[1] = false;
            s->done = 0;
        }
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
    case R_DONE:
        s->done &= ~(v & 3);
        break;
    }
    if (s->ctrl & CTRL_RUN) {
        aud_next_tick(s);
    }
}

/* The MDI link is down: the state after reset. */
void ngage_pcm_reset(void)
{
    NGageAudio *s = the_audio;

    if (!s) {
        return;
    }
    if (s->ctrl & CTRL_RUN) {
        aud_catch_up(s);
        aud_run(s, false);
    }
    s->ctrl = 0;
    s->format = 0;
    s->rate = 16000;
    s->addr[0] = s->addr[1] = 0;
    s->len[0] = s->len[1] = 0;
    s->full[0] = s->full[1] = false;
    s->done = 0;
    s->cur = 0;
    s->pos = 0;
    s->ended = false;
}

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

void ngage_pcm_create(AudioBackend *be, const char *wav_path, FILE *log)
{
    NGageAudio *s = g_new0(NGageAudio, 1);

    the_audio = s;
    s->log = log;
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
}
