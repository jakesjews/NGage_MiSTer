/*
 * ISI replies of the offline-modem stand-in (included by nos_isi.c).
 * See docs/NOS_STANDIN.md for the table of replies and their evidence.
 */

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

static void isi_send(struct slot *s, u8 *r, int n)
{
    r[4] = (u8)(n - 6);
    r[5] = (u8)((n - 6) >> 8);
    queue(s, r, n);
}

static void isi_request(struct slot *s, const u8 *m, int len)
{
    (void)s;
    (void)m;
    (void)len;
}
