/*
 * ISI replies of the offline-modem stand-in (included by nos_isi.c): a
 * phone with no SIM card and no network. docs/NOS_STANDIN.md lists every
 * reply with the client code that parses it.
 */

/* Resources (PhoNet resource ids as the clients use them). */
#define RES_SECURITY    0x08        /* oFono sim.h PN_SECURITY */
#define RES_SIM         0x09
#define RES_1C          0x1C        /* subscribed by DOS and the TSY with message 0x10 */
#define RES_MTC         0x15        /* modem state (oFono mtc.h PN_MTC) */
#define RES_SOUND       0x0B        /* audio settings (gnokii nk6510: 0x0B sound) */
#define RES_SELFTEST    0x35        /* DOS self test (RDosSelfTest, Nokia.dsy object 0x4D) */
#define RES_59          0x59        /* last step of the DOS self test */

/* SIM_IND (PN_SIM 0xEF, oFono sim.h) as Nokia.dsy reads it (0x50FFB21C):
 * [10] service, [11] status, [12] SIM state 1..8 -> DosSrv ord31(state - 1)
 * -> SA 0x100052E9. Startup.app finishes only with SA 0x100052E9 = 7
 * (state 8) and SA 0x100052F0 = 0 (0x50BBBCD6); with state 5 (no card) it
 * stays on a blank view behind the "Insert SIM card" note. So the
 * stand-in reports an inserted, ready SIM without PIN: state 8. */
#define SIM_IND             0xEF
#define SIM_STATE_READY     0x08
#define SIM_ST_INFO         0x0D        /* oFono sim.h service types */
#define SIM_SERV_OK         0x01        /* oFono sim.h causes */
#define SIM_SERV_INIT_OK    0x0B
#define SIM_SERV_IMSI_EQUAL 0x2A

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
        /* The SIM state follows as an indication: SIM_ST_INFO with
         * SIM_SERV_INIT_OK makes DOS read the SIM flags (0x50FFB610:
         * requests 0x2D and 0x2B, service 0x3A); state 8 makes it compare
         * the IMSI (request 0x3B, 0x50FFB27A). */
        n = isi_ind_hdr(r, s, RES_SIM, m[6], SIM_IND);
        r[n++] = SIM_ST_INFO;
        r[n++] = SIM_SERV_INIT_OK;
        r[n++] = SIM_STATE_READY;
        r[n++] = 0x00;
        isi_send(s, r, n);
        /* Security start-up state, message 0x10 from PN_SECURITY. Nokia.dsy
         * 0x50FFB734 reads [10]: 5 -> DosSrv ord27(0) -> SA 0x100052F0 = 0
         * (no code query), which Startup.app needs; with 5 it also reads
         * [13]: 0x12/0x13 -> DosSrv ord9(1/0), skipped with 0. 1/4 with
         * [11] = 1 or 6 -> ord27(1) (code required). phonetsy.tsy
         * 0x5093D9FC reads [10..] as one sub-block; id 5 is not one it acts
         * on (0x5092C568). 5 is SEC_STARTUP_OK in oFono sim.h. */
        n = isi_ind_hdr(r, s, RES_SECURITY, m[6], 0x10);
        r[n++] = 0x05;
        r[n++] = 0x00;
        r[n++] = 0x00;
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    case RES_SIM << 8 | 0x3B:
        /* Nokia.dsy 0x50FFB388 reads the reply 0x3C at [11]: 0x2A
         * (SIM_SERV_IMSI_EQUAL) -> DosSrv ord28(0), 0x2B -> ord28(1); both
         * stop further 0x3B requests. Same SIM as last time. */
        n = isi_reply_hdr(r, m, 0x3C);
        r[n++] = m[10];
        r[n++] = SIM_SERV_IMSI_EQUAL;
        isi_send(s, r, n);
        break;
    case RES_SIM << 8 | 0x2D:
        /* Nokia.dsy 0x50FFB400 reads the reply 0x2E: [10] service (must
         * echo 0x3A), [11] SIM_SERV_OK, [12] value: 0x0A/0x5A -> DosSrv
         * ord6(2), 0xA0/0xA5 -> 3, 0xAA -> 4, others -> 0. We answer 0. */
        n = isi_reply_hdr(r, m, 0x2E);
        r[n++] = m[10];
        r[n++] = SIM_SERV_OK;
        r[n++] = 0x00;
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    case RES_SIM << 8 | 0x2B:
        /* Nokia.dsy 0x50FFB4BC reads the reply 0x2C: [10] service (0x3A),
         * [11] SIM_SERV_OK, [12] bit 0 = flags valid, [13..14] 16-bit
         * flags, big-endian (isimsg ord1582). All clear: DosSrv ord33(0),
         * ord20(0), ord12(0) -> SA 0x100052F0 = 0, which Startup.app
         * needs. */
        n = isi_reply_hdr(r, m, 0x2C);
        r[n++] = m[10];
        r[n++] = SIM_SERV_OK;
        r[n++] = 0x01;
        r[n++] = 0x00;
        r[n++] = 0x00;
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
    case RES_SOUND << 8 | 0x11:
        /* An audio setting query, [10] = setting. phonetsy.tsy 0x5093E1D8
         * reads the reply 0x12: [8] transaction, [10] setting, [11]
         * sub-block count (must be 1), first sub-block at [12] with a
         * 16-bit big-endian value at its bytes 4-5 (isimsg ord1568), then
         * 0x5092E16C completes the waiting ETel request. Setting 6 answers
         * RCtmGsmPhone::GetHandsfreeMode (PhoneServer start-up): 13 ->
         * hands-free on, anything else -> off. We answer 0 for every
         * setting. Sub-block id and length are guesses. */
        n = isi_reply_hdr(r, m, 0x12);
        r[n++] = m[10];
        r[n++] = 0x01;
        r[n++] = m[10];                 /* sub-block id (guess) */
        r[n++] = 0x08;
        r[n++] = 0x00;
        r[n++] = 0x00;
        r[n++] = 0x00;                  /* value, big-endian */
        r[n++] = 0x00;
        r[n++] = 0x00;
        r[n++] = 0x00;
        isi_send(s, r, n);
        break;
    default:
        break;
    }
}
