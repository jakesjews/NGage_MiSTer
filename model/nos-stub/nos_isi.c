/*
 * NOS stand-in, part 3: an offline modem at the ISI message level.
 *
 * The real NOS (the cellular side) is encrypted in flash; its key is in the
 * UPP_WD2 silicon. Symbian talks to it through nosdriver.ldd, which hands
 * every channel call to an object built by the hidden NOS DLL (see
 * nos_dll.S): vtable +0x0C cancel(mask), +0x10 request(fn, status, a1, a2),
 * +0x14 control(fn, a1, a2). User code reaches the channel through
 * phonet.dll (RPhoNet): control 4 sends one ISI message (phonet.dll
 * 0x50366F04: byte 2 = 0, byte 7 = the client's object), request 0 receives
 * one (0x50366F54: a1 = TDes8 for the message). Messages are PhoNet frames:
 *   [0] media  [1] receiver device  [2] sender device  [3] resource
 *   [4..5] length of what follows, little-endian (phonet.dll 0x5036700E)
 *   [6] receiver object  [7] sender object  [8] transaction id
 *   [9] message id  [10..] payload
 *
 * This file answers requests as a phone with no SIM card, no network and
 * a modem in its normal state. Every reply is a guess about NOS, written
 * from how the Symbian client parses it; docs/NOS_STANDIN.md lists them
 * with their evidence. All calls arrive in the client thread's context
 * (EKA1 logical channels), so the client's buffers are mapped and replies
 * are written directly; a reply waits in the channel's queue until the
 * client has a receive request outstanding.
 *
 * Freestanding ARMv4T (ARM state: the kernel calls the vtable with
 * "mov lr, pc; ldr pc, ..."). State lives in NOS BSS, which nosstarter.ext
 * zeroes before calling the NOS entry.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

/* ekern exports, through its export directory (ordinal n at 0x50342068 + 4n - 4). */
#define EKERN(ord)          (*(volatile u32 *)(0x50342068u + 4u * ((ord) - 1)))
/* DLogicalChannel::Complete(channel, request number, reason): ord 64,
 * 0x5032F0C4 (thread at channel+20, status slots at channel+24). */
#define K_COMPLETE(c, n, r) ((void (*)(void *, int, int))EKERN(64))((c), (n), (r))
/* Kern::Printf(const TDesC16 &fmt, ...): ord 286 (rtc.dll 0x5034ADA0). */
#define K_PRINTF            ((void (*)(const void *, ...))EKERN(286))

#define KERR_NONE           0
#define KERR_CANCEL         (-3)

#define NSLOTS              32
#define QBYTES              1024

struct slot {
    void *obj;                  /* NOS object (nosdriver channel + 0x38) */
    void *chan;                 /* nosdriver channel (DLogicalChannel) */
    int unit;
    int rx_pending;
    u32 *rx_des;                /* client's TDes8 for request 0 */
    int qlen;                   /* queued replies, length-prefixed */
    u8 q[QBYTES];
};

static struct slot slots[NSLOTS];

/* ---------------------------------------------------------------- utils */

static u32 irq_off(void)
{
    u32 old, tmp;
    __asm__ volatile("mrs %0, cpsr\n\torr %1, %0, #0xC0\n\tmsr cpsr_c, %1"
                     : "=r"(old), "=r"(tmp) : : "memory");
    return old;
}

static void irq_restore(u32 old)
{
    __asm__ volatile("msr cpsr_c, %0" : : "r"(old) : "memory");
}

static void copy(u8 *d, const u8 *s, int n)
{
    while (n-- > 0) {
        *d++ = *s++;
    }
}

static void fill(u8 *d, int v, int n)
{
    while (n-- > 0) {
        *d++ = (u8)v;
    }
}

/* EPOC descriptors: word 0 = type << 28 | length. Types: 0 TBufC (data at
 * +4), 1 TPtrC (pointer at +4), 2 TPtr (max at +4, pointer at +8), 3 TBuf
 * (max at +4, data at +8), 4 TBufCPtr (max at +4, pointer at +8 to a TBufC). */
static u8 *des_data(u32 *d, int *len, int *max)
{
    u32 t = d[0] >> 28;

    *len = (int)(d[0] & 0x0FFFFFFF);
    *max = t >= 2 ? (int)d[1] : *len;
    switch (t) {
    case 0: return (u8 *)&d[1];
    case 1: return (u8 *)d[1];
    case 2: return (u8 *)d[2];
    case 3: return (u8 *)&d[2];
    case 4: return (u8 *)d[2] + 4;
    default: return 0;
    }
}

static void des_set_len(u32 *d, int len)
{
    d[0] = (d[0] & 0xF0000000u) | (u32)len;
    if ((d[0] >> 28) == 4) {            /* the TBufC it points at keeps its own length */
        u32 *b = (u32 *)d[2];
        b[0] = (b[0] & 0xF0000000u) | (u32)len;
    }
}

/* ---------------------------------------------------------------- logging */

static u16 logbuf[160];

static void log_text(const char *pre, const u8 *m, int n)
{
    static const char hex[] = "0123456789abcdef";
    int k = 0;
    u32 des[2];

    while (*pre && k < 40) {
        logbuf[k++] = (u8)*pre++;
    }
    for (int i = 0; i < n && k < 156; i++) {
        logbuf[k++] = hex[m[i] >> 4];
        logbuf[k++] = hex[m[i] & 15];
        if (i == 9 && k < 156) {
            logbuf[k++] = ' ';          /* header | payload */
        }
    }
    logbuf[k++] = '\n';
    des[0] = (1u << 28) | (u32)k;       /* TPtrC16 */
    des[1] = (u32)logbuf;
    K_PRINTF(des);
}

/* ---------------------------------------------------------------- slots */

static struct slot *slot_by_obj(void *obj)
{
    for (int i = 0; i < NSLOTS; i++) {
        if (slots[i].obj == obj) {
            return &slots[i];
        }
    }
    return 0;
}

static void deliver(struct slot *s)
{
    int len, max;
    u8 *buf;
    int n;

    if (!s->rx_pending || s->qlen == 0 || !s->chan) {
        return;
    }
    n = s->q[0] | s->q[1] << 8;
    buf = des_data(s->rx_des, &len, &max);
    if (buf) {
        if (n > max) {
            n = max;
        }
        copy(buf, s->q + 2, n);
        des_set_len(s->rx_des, n);
        log_text("NOS> ", buf, n);
    }
    n = (s->q[0] | s->q[1] << 8) + 2;
    copy(s->q, s->q + n, s->qlen - n);
    s->qlen -= n;
    s->rx_pending = 0;
    K_COMPLETE(s->chan, 0, KERR_NONE);
}

static void queue(struct slot *s, const u8 *m, int n)
{
    if (s->qlen + n + 2 > QBYTES) {
        log_text("NOS queue full ", m, n);
        return;
    }
    s->q[s->qlen] = (u8)n;
    s->q[s->qlen + 1] = (u8)(n >> 8);
    copy(s->q + s->qlen + 2, m, n);
    s->qlen += n + 2;
}

/* ---------------------------------------------------------------- replies */

#include "nos_isi_replies.h"

/* ---------------------------------------------------------------- object */

static int m_ret0(void *obj)
{
    (void)obj;
    return 0;
}

static int m_delete(void *obj, int flags)
{
    struct slot *s = slot_by_obj(obj);
    u32 old = irq_off();

    (void)flags;
    if (s) {
        fill((u8 *)s, 0, sizeof(*s));
    }
    irq_restore(old);
    return 0;
}

static int m_cancel(void *obj, u32 mask)
{
    struct slot *s = slot_by_obj(obj);

    if (s && (mask & 1) && s->rx_pending) {
        s->rx_pending = 0;
        K_COMPLETE(s->chan, 0, KERR_CANCEL);
    }
    return 0;
}

static int m_request(void *obj, int fn, void *status, u32 *a1, void *a2)
{
    struct slot *s = slot_by_obj(obj);

    (void)status;
    (void)a2;
    if (!s) {
        return 0;
    }
    if (fn == 0) {
        s->rx_des = a1;
        s->rx_pending = 1;
        deliver(s);
    } else {
        u8 b[4] = { (u8)fn, (u8)s->unit, 0, 0 };
        log_text("NOS request ", b, 2);   /* other requests stay pending */
    }
    return 0;
}

static int m_control(void *obj, int fn, u32 *a1, void *a2)
{
    struct slot *s = slot_by_obj(obj);
    int len, max;
    u8 *m;

    (void)a2;
    if (!s || (fn != 4 && fn != 6) || !a1) {
        u8 b[2] = { (u8)fn, s ? (u8)s->unit : 0xFF };
        log_text("NOS control ", b, 2);
        return 0;
    }
    m = des_data(a1, &len, &max);
    if (!m || len < 10) {
        return 0;
    }
    log_text(fn == 4 ? "NOS< " : "NOS<6 ", m, len);
    isi_request(s, m, len);
    deliver(s);
    return 0;
}

/* vtable at obj+4; nosdriver calls +0x08 (delete), +0x0C, +0x10, +0x14. */
static const void *const vtable[16] = {
    (void *)m_ret0, (void *)m_ret0, (void *)m_delete, (void *)m_cancel,
    (void *)m_request, (void *)m_control, (void *)m_ret0, (void *)m_ret0,
    (void *)m_ret0, (void *)m_ret0, (void *)m_ret0, (void *)m_ret0,
    (void *)m_ret0, (void *)m_ret0, (void *)m_ret0, (void *)m_ret0,
};

/* NOS DLL ordinal 6 (0x514A261C): build the object for a channel. */
void nos_obj_ctor(u32 *obj, int unit)
{
    u32 old = irq_off();

    obj[0] = 0;
    obj[1] = (u32)vtable;
    for (int i = 0; i < NSLOTS; i++) {
        if (!slots[i].obj) {
            slots[i].obj = obj;
            slots[i].unit = unit & 0xFF;
            break;
        }
    }
    irq_restore(old);
}

/* NOS DLL ordinal 4 (0x514A1CA0): (channel, unit) right after the object. */
int nos_channel_open(void *chan, int unit)
{
    u32 old = irq_off();

    for (int i = NSLOTS - 1; i >= 0; i--) {
        if (slots[i].obj && !slots[i].chan && slots[i].unit == unit) {
            slots[i].chan = chan;
            break;
        }
    }
    irq_restore(old);
    return 0;
}
