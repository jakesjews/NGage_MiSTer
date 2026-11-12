/*
 * PCM playback for the NOS stand-in (included by nos_isi.c).
 *
 * SoundDevice.mda ("Galaxy" DevSound) streams PCM to NOS with ISI
 * resource 0xE8 from PhoNet object 0x48 (receiver 0x505AF8F8); the DSP
 * plays it from two halves of the shared chunk audio.ldd maps at physical
 * 0x0A061000. docs/NOS_STANDIN.md has the messages and their evidence.
 * NOS and the DSP are encrypted, so the stand-in plays the halves with
 * the HLE audio device at 0x0C1F0000, an emulator invention (model
 * hw/ngage_audio.c, docs/UPP_WD2.md):
 *   0x20 start  -> program the device and run it; reply 0x21
 *   0x23 filled -> give that half to the device; on the first one also
 *                  report the other half free (0x26), so that both are
 *                  full while the first plays
 *   device DONE -> 0x26 [00, half]: that half is free (SoundDevice fills
 *                  it next, 0x505ABBDC)
 *   0x2A stop   -> stop the device; reply 0x2B with the bytes played of
 *                  the current half
 * DONE arrives as an interrupt (IrqTimer5, source 5): the ISR acknowledges
 * the device and queues a DFC, which sends 0x26 to SoundDevice's channel
 * with the asynchronous delivery in nos_isi.c.
 */

/* HLE audio device registers, virtual 0x58000000 + (0x0C1F0000 - 0x0C000000). */
#define HAUD            ((volatile u32 *)0x581F0000u)
#define HAUD_ID         (0x00 / 4)
#define HAUD_CTRL       (0x04 / 4)
#define HAUD_FORMAT     (0x08 / 4)
#define HAUD_RATE       (0x0C / 4)
#define HAUD_ADDR0      (0x10 / 4)
#define HAUD_LEN0       (0x18 / 4)
#define HAUD_STATUS     (0x20 / 4)
#define HAUD_POS        (0x24 / 4)
#define HAUD_VOLUME     (0x28 / 4)
#define HAUD_RUN        1u
#define HAUD_IRQEN      2u

/* ekern exports. Interrupt objects (epbus 0x503F6180 binds the MMC ones
 * the same way): ord 492 constructor (0x5032BCD8: +0 id = 255, +16 base
 * vtable), ord 29 Bind(const TDesC8 &name) (0x5032BD24 -> 0x50328854: id
 * from the name table, links the object into the table at 0x800066E0),
 * ord 112 Enable (0x5032BCF0). The IRQ dispatcher (0x5031C87C ->
 * 0x503287E0) calls vtable(+16)[2](obj) when +4 (enabled) is set. ord 7
 * = TDfc::Add (0x5033F304): queue {+0 next, +4 prev, +8 fn, +12 arg} at
 * 0x80006BB8 unless +0 is set; 0x5032203C unlinks it, clears +0 and calls
 * fn(arg) in mode 0x1B with interrupts on. */
#define K_INT_CTOR(o)       ((void (*)(void *))EKERN(492))(o)
#define K_INT_BIND(o, n)    ((int (*)(void *, const void *))EKERN(29))((o), (n))
#define K_INT_ENABLE(o)     ((void (*)(void *))EKERN(112))(o)
#define K_DFC_ADD(d)        ((void (*)(void *))EKERN(7))(d)

static struct {
    struct slot *client;        /* SoundDevice's channel */
    u8 hdr[10];                 /* its 0x20 request, for the 0x26 headers */
    int running;
    int started;                /* first half given to the device */
    int bound;
    u32 irq[6];                 /* kernel interrupt object */
    u32 dfc[4];                 /* TDfc */
    volatile u32 events;        /* DONE bits taken by the ISR */
} au;

static void au_free(int half)
{
    u8 r[12];

    r[0] = au.hdr[0];
    r[1] = au.hdr[2];
    r[2] = au.hdr[1];
    r[3] = RES_AUDIO;
    r[6] = au.hdr[7];
    r[7] = au.hdr[6];
    r[8] = 0;
    r[9] = 0x26;
    r[10] = 0x00;
    r[11] = (u8)half;
    isi_send(au.client, r, sizeof(r));
}

/* DFC work: one 0x26 per half the device finished. */
static void au_work(void)
{
    u32 old = irq_off();
    u32 ev = au.events;

    au.events = 0;
    irq_restore(old);
    if (!au.running || !au.client || !au.client->chan) {
        return;
    }
    for (int b = 0; b < 2; b++) {
        if (ev & (1u << b)) {
            au_free(b);
        }
    }
    deliver(au.client);
}

static void au_dfc(void *arg)
{
    (void)arg;
    if (in_call) {
        dfc_missed = 1;         /* the call in progress runs au_work at its end */
        return;
    }
    au_work();
}

/* IRQ mode, interrupts off: take and acknowledge DONE, defer the rest. */
static void au_isr(void *obj)
{
    u32 st = HAUD[HAUD_STATUS] & 3;

    (void)obj;
    HAUD[HAUD_STATUS] = st;
    if (st) {
        au.events |= st;
        K_DFC_ADD(au.dfc);
    }
}

static void *const au_isr_vtable[4] = { 0, 0, (void *)au_isr, 0 };

static void au_bind(void)
{
    static const char name[] = "IrqTimer5";
    u32 des[2];
    int r;

    if (au.bound) {
        return;
    }
    au.dfc[0] = 0;
    au.dfc[2] = (u32)au_dfc;
    au.dfc[3] = 0;
    K_INT_CTOR(au.irq);
    au.irq[4] = (u32)au_isr_vtable;
    des[0] = (1u << 28) | (sizeof(name) - 1);   /* TPtrC8 */
    des[1] = (u32)name;
    r = K_INT_BIND(au.irq, des);
    {
        u8 b[2] = { (u8)r, (u8)au.irq[0] };
        log_text("NOS audio irq bind ", b, 2);
    }
    if (r == 0) {
        K_INT_ENABLE(au.irq);
        au.bound = 1;
    }
}

static u32 be32(const u8 *p)
{
    return (u32)p[0] << 24 | (u32)p[1] << 16 | (u32)p[2] << 8 | p[3];
}

static void au_stop(void)
{
    HAUD[HAUD_CTRL] = 0;
    HAUD[HAUD_STATUS] = 3;
    au.running = 0;
    au.events = 0;
}

/* Resource 0x0B message 0x14 (isimsg ord691 with an ord649 sub-block):
 * [10] 0, [11] 4 or 5, [12..14] FF, [15] sub-block count, sub-blocks
 * [03 08 param 00 value-hi value-lo FF FF]. SoundDevice sends param 2 with
 * the halfword at its +0x164 (0x505AE286; 0x505ABB34) before every
 * buffer; its constructor sets +0x38 = 9 next to it (0x505AB6B0), read
 * here as the volume range 0..9 (a guess, like the linear gain). Nothing
 * reads a reply. */
static void audio_param(const u8 *m, int len)
{
    int n = len >= 16 ? m[15] : 0;
    int i = 16;

    while (n-- > 0 && i + 8 <= len && m[i + 1] >= 4) {
        if (m[i] == 0x03 && m[i + 2] == 0x02) {
            u32 v = (u32)m[i + 4] << 8 | m[i + 5];
            HAUD[HAUD_VOLUME] = v >= 9 ? 0x100 : v * 0x100 / 9;
        }
        i += m[i + 1];
    }
}

static void audio_request(struct slot *s, const u8 *m, int len)
{
    u8 r[16];
    int n;

    switch (m[9]) {
    case 0x20:
        /* START (isimsg ord951, sent at SoundDevice 0x505AC65A): [10]
         * 0x82, [11] path (2; 3 during a call), [12..13] half length in
         * samples (5600), [14..17] half A, [18..21] half B (A + 11200),
         * [22] 0, [23] rate code: 50 for sources up to 8 kHz in a call,
         * else 70, with SoundDevice upsampling 8 kHz sources x2 itself
         * (0x505AC5B8-0x505AC62C). Read as 50 = 8 kHz, 70 = 16 kHz, mono
         * 16-bit (the upsampler, 0x505AEFEC, filters one channel). The
         * receiver (0x505AFAE0) only checks its state on the reply 0x21. */
        if (len < 24) {
            break;
        }
        au_bind();
        au_stop();
        HAUD[HAUD_FORMAT] = 0;
        HAUD[HAUD_RATE] = m[23] == 50 ? 8000 : 16000;
        HAUD[HAUD_ADDR0] = be32(m + 14);
        HAUD[HAUD_ADDR0 + 1] = be32(m + 18);
        HAUD[HAUD_LEN0] = 0;
        HAUD[HAUD_LEN0 + 1] = 0;
        for (int i = 0; i < 10; i++) {
            au.hdr[i] = m[i];
        }
        au.client = s;
        au.started = 0;
        au.running = 1;
        HAUD[HAUD_CTRL] = HAUD_RUN | HAUD_IRQEN;
        n = isi_reply_hdr(r, m, 0x21);
        r[n++] = 0x00;
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    case 0x23:
        /* FILLED (isimsg ord962, SoundDevice 0x505AE17A after copying a
         * buffer into half [0x1F9]): [10] half, [11] 1 = last buffer
         * (CMMFBuffer flag) or 2, [12..13] samples. No reply: the
         * receiver's 0x24 handler (0x505AFB56) leaves the playing states,
         * and 0x23 is only sent in them. */
        if (!au.running || len < 14) {
            break;
        }
        HAUD[HAUD_LEN0 + (m[10] & 1)] = (u32)m[12] << 8 | m[13];
        if (!au.started) {
            au.started = 1;
            au_free((m[10] & 1) ^ 1);
        }
        break;
    case 0x2A:
        /* STOP (isimsg ord952): sent on the client's stop (0x505ADC94) or
         * when two halves are free with nothing to play (0x505ABC44). The
         * 0x2B handler (0x505AFBC2) adds a 16-bit big-endian byte count
         * at [10] to the position (0x505ABBA8) and tears down. */
        n = isi_reply_hdr(r, m, 0x2B);
        {
            u32 bytes = au.running ? HAUD[HAUD_POS] * 2 : 0;
            r[n++] = (u8)(bytes >> 8);
            r[n++] = (u8)bytes;
        }
        au_stop();
        isi_send(s, r, n);
        break;
    default:
        break;
    }
}
