/*
 * ISI replies of the offline-modem stand-in (included by nos_isi.c): a
 * phone with no SIM card and no network. docs/NOS_STANDIN.md lists every
 * reply with the client code that parses it.
 */

/* Resources (PhoNet resource ids as the clients use them). */
#define RES_SIM         0x09
#define RES_1C          0x1C        /* subscribed by DOS and the TSY with message 0x10 */
#define RES_MTC         0x15        /* modem state (oFono mtc.h PN_MTC) */
#define RES_SELFTEST    0x35        /* DOS self test (RDosSelfTest, Nokia.dsy object 0x4D) */
#define RES_59          0x59        /* last step of the DOS self test */

/* SIM_IND (PN_SIM 0xEF, oFono sim.h) as Nokia.dsy reads it (0x50FFB21C):
 * [10] service, [11] status, [12] SIM state 1..8 -> DosSrv ord31(state - 1). */
#define SIM_IND             0xEF
#define SIM_STATE_NO_CARD   0x05

/* Start a reply in r[]: devices and objects swapped, same resource and
 * transaction, message id `id`. Returns the header length (10). */
static int isi_reply_hdr(u8 *r, const u8 *m, u8 id)
{
    r[0] = m[0];
    r[1] = m[2];
    r[2] = m[1];
    r[3] = m[3];
    r[6] = m[7];
    r[7] = m[6];
    r[8] = m[8];
    r[9] = id;
    return 10;
}

/* An indication from object `from` of resource `res` to the client. */
static int isi_ind_hdr(u8 *r, const struct slot *s, u8 res, u8 from, u8 id)
{
    r[0] = 0;
    r[1] = 0;
    r[2] = 0;
    r[3] = res;
    r[6] = (u8)s->obj_id;
    r[7] = from;
    r[8] = 0;
    r[9] = id;
    return 10;
}

static void isi_send(struct slot *s, u8 *r, int n)
{
    r[4] = (u8)(n - 6);
    r[5] = (u8)((n - 6) >> 8);
    queue(s, r, n);
}

static void isi_request(struct slot *s, const u8 *m, int len)
{
    u8 r[64];
    int n;

    (void)len;
    switch (m[3] << 8 | m[9]) {
    case RES_1C << 8 | 0x10:
        /* Nokia.dsy 0x50FFAD98 reads the reply 0x11 at [10]: 0 -> DosSrv
         * ord22(0); 1 -> 2; 0x10/0x11/0x20/0x21 -> 1. */
        n = isi_reply_hdr(r, m, 0x11);
        r[n++] = 0x00;
        isi_send(s, r, n);
        /* The SIM state follows as an indication: no card. */
        n = isi_ind_hdr(r, s, RES_SIM, m[6], SIM_IND);
        r[n++] = 0x00;                  /* service: card status */
        r[n++] = 0x06;                  /* SIM_SERV_SIM_DISCONNECTED (oFono sim.h) */
        r[n++] = SIM_STATE_NO_CARD;
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    case RES_SELFTEST << 8 | 0x02:
        /* Nokia.dsy 0x50FFBB04 reads the reply 0x03 at [10]: 12 -> DOS
         * event 1 = 2 (DosSrv ord24 via 0x50FFBA2C), which Startup.app
         * shows as "Device start-up failed" (tried); 0/10/11 -> DOS goes on
         * with the next self-test message (0x50FFBDC4); other values ->
         * 0x50FFBD98. */
        n = isi_reply_hdr(r, m, 0x03);
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    case RES_SELFTEST << 8 | 0x00:
        /* Nokia.dsy 0x50FFBBBC reads the reply 0x01 at [10]: 0 -> the
         * next step, 0x59/0x01 (0x50FFBD6C); 1/2 -> asks again; 12 -> DOS
         * event 1 = 2 and MTC_STATE_REQ(SELFTEST_FAIL) (0x50FFBD40). */
        n = isi_reply_hdr(r, m, 0x01);
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    case RES_59 << 8 | 0x01:
        /* Nokia.dsy 0x50FFBC74 reads the reply 0x02 at [10]: 0 -> DOS
         * event 1 = 3, the self test passed (0x50FFBCBC); otherwise it
         * asks again (0x50FFBD6C). */
        n = isi_reply_hdr(r, m, 0x02);
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    default:
        break;
    }
}
