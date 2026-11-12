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

/* A receive request, decoded in the client's context: the addresses are
 * the client's, written later with DThread raw writes. */
struct rx {
    u32 des;                    /* the TDes8 for the message */
    u32 hdr;                    /* its type bits (word 0 & 0xF0000000) */
    u32 data;                   /* where its bytes go */
    int max;
    u32 tbufc;                  /* type 4: the TBufC it points at, else 0 */
    u32 tbufc_hdr;
    u32 len;                    /* the TPckgBuf<TUint16> (TBuf8<2>), or 0 */
    u32 len_hdr;
};

struct slot {
    void *obj;                  /* NOS object (nosdriver channel + 0x38) */
    void *chan;                 /* nosdriver channel (DLogicalChannel) */
    int unit;
    int obj_id;                 /* PhoNet object of the client (byte 7 of its sends) */
    int rx_pending;
    struct rx rx;
    int qlen;                   /* queued replies, length-prefixed */
    u8 q[QBYTES];
};

static struct slot slots[NSLOTS];

/* Set while a client call (vtable method) runs. EKA1 does not run DFCs in
 * kernel-side thread code as far as we know; if one does, it leaves its
 * work to the call (dfc_missed). */
static volatile int in_call;
static volatile int dfc_missed;

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

/* DThread vtable +0x54 (0x5032DBB8): write len bytes from src to the
 * thread's address dst (address translation by vtable +0x4C, then
 * Mem::Copy); 0 or KErrArgument. GD1DRV uses it to complete from a DFC.
 * The channel's thread is at channel + 20 (DLogicalChannel::Complete). */
static int thread_write(void *chan, u32 dst, const void *src, int len)
{
    u32 *thr = *(u32 **)((u8 *)chan + 20);
    int (*fn)(void *, u32, const void *, int) =
        (int (*)(void *, u32, const void *, int))((u32 *)thr[0])[0x54 / 4];

    return fn(thr, dst, src, len);
}

static void rx_decode(struct rx *r, u32 *d, u32 *l)
{
    int len;

    r->des = (u32)d;
    r->hdr = d[0] & 0xF0000000u;
    r->data = (u32)des_data(d, &len, &r->max);
    r->tbufc = 0;
    if ((d[0] >> 28) == 4) {            /* the TBufC it points at keeps its own length */
        r->tbufc = d[2];
        r->tbufc_hdr = *(u32 *)d[2] & 0xF0000000u;
    }
    r->len = 0;
    if (l && (l[0] >> 28) == 3 && l[1] >= 2) {
        r->len = (u32)l;
        r->len_hdr = l[0] & 0xF0000000u;
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

/* Complete the pending receive with the first queued message. Runs in
 * the client's context or in the audio DFC, so it writes through the
 * channel's thread rather than the client's mapping. */
static u8 dlv_buf[QBYTES];

static void deliver(struct slot *s)
{
    struct rx r;
    u32 w;
    int n;
    u32 old = irq_off();

    if (!s->rx_pending || s->qlen == 0 || !s->chan) {
        irq_restore(old);
        return;
    }
    n = s->q[0] | s->q[1] << 8;
    copy(dlv_buf, s->q + 2, n);
    copy(s->q, s->q + n + 2, s->qlen - n - 2);
    s->qlen -= n + 2;
    s->rx_pending = 0;
    r = s->rx;
    irq_restore(old);

    if (r.data) {
        if (n > r.max) {
            n = r.max;
        }
        thread_write(s->chan, r.data, dlv_buf, n);
        w = r.hdr | (u32)n;
        thread_write(s->chan, r.des, &w, 4);
        if (r.tbufc) {
            w = r.tbufc_hdr | (u32)n;
            thread_write(s->chan, r.tbufc, &w, 4);
        }
        if (r.len) {
            u8 l[2] = { (u8)n, (u8)(n >> 8) };
            thread_write(s->chan, r.len + 8, l, 2);   /* TBuf8<2>: data at +8 */
            w = r.len_hdr | 2;
            thread_write(s->chan, r.len, &w, 4);
        }
        log_text("NOS> ", dlv_buf, n);
    }
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
#include "nos_audio.h"

/* Every vtable method runs inside call_begin/call_end. */
static void call_begin(void)
{
    in_call = 1;
}

static void call_end(void)
{
    in_call = 0;
    if (dfc_missed) {
        dfc_missed = 0;
        au_work();
    }
}

/* ---------------------------------------------------------------- object */

static int m_ret0(void *obj)
{
    (void)obj;
    return 0;
}

static int m_delete(void *obj, int flags)
{
    struct slot *s = slot_by_obj(obj);
    u32 old;

    (void)flags;
    call_begin();
    if (s && s == au.client) {
        au_stop();
        au.client = 0;
    }
    old = irq_off();
    if (s) {
        fill((u8 *)s, 0, sizeof(*s));
    }
    irq_restore(old);
    call_end();
    return 0;
}

static int m_cancel(void *obj, u32 mask)
{
    struct slot *s = slot_by_obj(obj);
    int was;
    u32 old;

    call_begin();
    old = irq_off();
    was = s && (mask & 1) && s->rx_pending;
    if (was) {
        s->rx_pending = 0;
    }
    irq_restore(old);
    if (was) {
        K_COMPLETE(s->chan, 0, KERR_CANCEL);
    }
    call_end();
    return 0;
}

/* EKA1 DLogicalChannel::DoRequest(reqNo, a1, a2); the kernel keeps the
 * TRequestStatus (channel + 24 + 4 * reqNo). For request 0 phonet.dll
 * passes a1 = the message TDes8, a2 = a TPckgBuf<TUint16> (TBuf8<2>). */
static int m_request(void *obj, int fn, u32 *a1, u32 *a2)
{
    struct slot *s = slot_by_obj(obj);

    if (!s) {
        return 0;
    }
    call_begin();
    if (fn == 0) {
        u32 old = irq_off();

        rx_decode(&s->rx, a1, a2);
        s->rx_pending = 1;
        irq_restore(old);
        deliver(s);
    } else {
        u8 b[4] = { (u8)fn, (u8)s->unit, 0, 0 };
        log_text("NOS request ", b, 2);   /* other requests stay pending */
    }
    call_end();
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
    call_begin();
    log_text(fn == 4 ? "NOS< " : "NOS<6 ", m, len);
    s->obj_id = m[7];
    isi_request(s, m, len);
    deliver(s);
    call_end();
    return 0;
}

/* vtable at obj+4; nosdriver calls +0x08 (delete), +0x0C, +0x10, +0x14. */
static const void *const vtable[16] = {
    (void *)m_ret0, (void *)m_ret0, (void *)m_delete, (void *)m_cancel,
    (void *)m_request, (void *)m_control, (void *)m_ret0, (void *)m_ret0,
    (void *)m_ret0, (void *)m_ret0, (void *)m_ret0, (void *)m_ret0,
    (void *)m_ret0, (void *)m_ret0, (void *)m_ret0, (void *)m_ret0,
};

/* NOS DLL ordinal 6 (0x514A261C): build the object for a channel. A C++
 * constructor: nosdriver stores what it returns in r0 as the object
 * (0x511691F0). */
u32 *nos_obj_ctor(u32 *obj, int unit)
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
    return obj;
}

/* HLE RTC date register (an emulator invention, model hw/ngage_cbus.c,
 * docs/UPP_WD2.md): the date on which the UEMK day counter read 0, bits
 * 31:16 year, 15:8 month, 7:0 day; 0 if unknown. */
#define HLE_RTC_DATE        (*(volatile u32 *)0x581F0100u)

/* Called by the entry stub (0x514A1CA4, nos_stub.S) before it sends
 * rtc.dll its event 1: out = the TTime of midnight on that date, or 0 if
 * there is none, which rtc.dll treats as an unset clock. NOS kept this
 * base date in its own flash; rtc.dll adds the UEMK time of day and day
 * counter to it (0x5034A678). TTime counts microseconds in EUser's
 * calendar (TDateTime -> TTime, 0x503B8340): days = 365 * year + leap
 * days before the year + days before the month + day - 1, with Julian
 * leap years up to 1600 and Gregorian ones after (0x503BA494, 0x503BA508),
 * so it runs 12 days ahead of a proleptic Gregorian count. TInt64 is low
 * word first (EUser 0x5039E798). */
void nos_rtc_base(u32 *out)
{
    static const unsigned short before[12] = {
        0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334
    };
    u32 v = HLE_RTC_DATE;
    int y = (int)(v >> 16), m = (int)(v >> 8) & 0xFF, d = (int)v & 0xFF;
    int leap, days, k;
    unsigned long long t;

    out[0] = out[1] = 0;
    if (y < 1980 || y > 2999 || m < 1 || m > 12 || d < 1 || d > 31) {
        return;
    }
    leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    k = y - 1601;
    days = 365 * y + k / 4 - k / 100 + k / 400 + 401 + before[m - 1] + (leap && m > 2) + d - 1;
    t = (unsigned long long)(unsigned)days * 86400ULL * 1000000ULL;
    out[0] = (u32)t;
    out[1] = (u32)(t >> 32);
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
