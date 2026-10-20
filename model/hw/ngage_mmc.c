/*
 * UPP_WD2 MMC host (0x0C120600) and an MMC card, as far as epbus.dll's
 * "WD2MMC" layer uses them (RH-29 v4.60). Evidence per register:
 *
 *   +0x604  control. Writing bit 0 = 1 starts a command; bits 5:2 select the
 *           transfer: 0 none, 1 (0x04) R1, 2 (0x08) R3 (with bit 6, no CRC
 *           check, CMD1), 3 (0x0C) R2, 4 (0x10) R1b?, 5-10 (0x14-0x28) data
 *           phases (0x503F53DC jump table, 0x503F5688-0x503F57A8). Bit 0
 *           reads 1 until the controller has taken the command; the driver
 *           polls it up to 120 times (0x503F5490). Writes without bit 0:
 *           0x40 at power-up then a timer wait (0x503F5D28), 0 at power-down
 *           (0x503F4CC8), 2 after power-down if +0x618 bits 3:2 were set
 *           (0x503F4D78).
 *   +0x608  data length for the following transfer (0 for plain commands)
 *   +0x60C, +0x610  0x1DC130 at power-up (0x503F5E18, 0x503F5DDC): time-outs?
 *   +0x614  0x280 at power-up (0x503F5DA4): clock divider?
 *   +0x618  status, decoded at 0x503F5E4C:
 *             bit 3 command busy (clear = event "command idle")
 *             bit 2 data busy (clear = event "data idle")
 *             bit 8 response word available (event "command ready")
 *             command errors: bit 6 response time-out, bit 1 response CRC,
 *             bit 9 other; data errors: bit 0 data CRC, bit 5 busy time-out,
 *             bit 7 data time-out, bit 10 other
 *   +0x61C  command index (0x503F52A4)
 *   +0x620  write: argument (0x503F5350); read: response. 48-bit responses
 *           give bits 39:8 in one read; R2 gives four words, most
 *           significant first, the driver waiting for bit 8 before each
 *           (0x503F54F4, 0x503F555C).
 *   +0x624  data FIFO, 8 bits wide for the DMA (ekern table 0x503401D0 gives
 *           the DMA address 0x10120624 for device type 5 = MMC); also read
 *           once before +0x618 when powering down (0x503F4D30).
 * Data phases (control bits 5:2, epbus 0x503F5688-0x503F57A8): 8 (0x20) =
 * command with R1 and a block read (CMD17 is issued with 0x21), 9 (0x24) =
 * read the next block, 10 (0x28) = CMD12 after reading; 5 (0x14), 6
 * (0x18), 7 (0x1C) = the same for writing. +0x608 holds the block length for the phase. The driver
 * starts the DMA after the command (0x503F57D0, 0x503F585C).
 * Interrupts (bound by name in epbus 0x503F6180-0x503F62E8): MMCCmdIdle,
 * MMCDataIdle, MMCCmdRdy (sources 23, 21, 24) are modelled as levels that
 * follow the status bits; the driver disables each in its ISR. Data moves by
 * DMA channel 5 (kernel DMA object, epbus 0x503F62E8); not modelled yet.
 *
 * The card follows the MMC 3.x protocol for the commands listed in
 * mmc_command(). It is read-only when the CSD says so (retail game cards).
 * CID and CSD come from <image>.cid and <image>.csd (16 bytes, binary or 32
 * hex digits, card order: byte 0 = bits 127:120 with byte 15 = CRC7<<1|1);
 * without them the model makes a generic card the size of the image.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "hw/arm/ngage.h"

#define MMC_BASE        0x0C120600

#define ST_DATA_CRC     (1u << 0)
#define ST_RESP_CRC     (1u << 1)
#define ST_DATA_BUSY    (1u << 2)
#define ST_CMD_BUSY     (1u << 3)
#define ST_RESP_TIMEOUT (1u << 6)
#define ST_RESP         (1u << 8)

enum { CARD_IDLE, CARD_READY, CARD_IDENT, CARD_STBY, CARD_TRAN, CARD_DATA };

typedef struct NGageMmc {
    MemoryRegion mr;
    uint32_t regs[16];
    uint32_t status;
    uint32_t resp[4];
    int resp_words, resp_pos;
    uint8_t blk[4096];
    uint32_t blk_len, blk_pos;
    uint64_t data_addr;
    bool writing;
    FILE *log;
    /* card */
    bool present;
    uint8_t *data;
    uint64_t size;
    uint8_t cid[16], csd[16];
    uint32_t ocr;
    uint16_t rca;
    int state;
    uint32_t blocklen;
    bool read_only;
} NGageMmc;

static void mmc_irq_update(NGageMmc *s)
{
    ngage_intc_set_source(NGAGE_IRQ_MMC_CMDIDLE, !(s->status & ST_CMD_BUSY));
    ngage_intc_set_source(NGAGE_IRQ_MMC_DATAIDLE, !(s->status & ST_DATA_BUSY));
    ngage_intc_set_source(NGAGE_IRQ_MMC_CMDRDY, (s->status & ST_RESP) != 0);
    ngage_intc_set_source(NGAGE_IRQ_MMC_DATARDY, (s->status & ST_DATA_BUSY) != 0);
}

static uint32_t card_status(NGageMmc *s)
{
    /* R1: CURRENT_STATE in bits 12:9, READY_FOR_DATA bit 8 */
    return ((uint32_t)s->state << 9) | (1u << 8);
}

static void resp48(NGageMmc *s, uint32_t v)
{
    s->resp[0] = v;
    s->resp_words = 1;
    s->resp_pos = 0;
}

static void resp136(NGageMmc *s, const uint8_t *r)
{
    for (int i = 0; i < 4; i++) {
        s->resp[i] = ldl_be_p(r + 4 * i);
    }
    s->resp_words = 4;
    s->resp_pos = 0;
}

/* Returns false when the card does not answer (no card, illegal command). */
static bool mmc_command(NGageMmc *s, unsigned cmd, uint32_t arg)
{
    if (!s->present) {
        return cmd == 0;
    }
    switch (cmd) {
    case 0:                                     /* GO_IDLE_STATE */
        s->state = CARD_IDLE;
        s->rca = 0;
        return true;
    case 1:                                     /* SEND_OP_COND, R3 */
        if (s->state != CARD_IDLE && s->state != CARD_READY) {
            return false;
        }
        s->state = CARD_READY;
        resp48(s, s->ocr | 0x80000000u);        /* power-up done */
        return true;
    case 2:                                     /* ALL_SEND_CID, R2 */
        if (s->state != CARD_READY) {
            return false;
        }
        s->state = CARD_IDENT;
        resp136(s, s->cid);
        return true;
    case 3:                                     /* SET_RELATIVE_ADDR, R1 */
        if (s->state != CARD_IDENT) {
            return false;
        }
        s->rca = arg >> 16;
        s->state = CARD_STBY;
        resp48(s, card_status(s));
        return true;
    case 7:                                     /* SELECT/DESELECT_CARD, R1b */
        if ((arg >> 16) == s->rca && s->rca) {
            resp48(s, card_status(s));
            s->state = CARD_TRAN;
        } else {
            if (s->state == CARD_TRAN) {
                s->state = CARD_STBY;
            }
            return false;                       /* deselected cards do not answer */
        }
        return true;
    case 9:                                     /* SEND_CSD, R2 */
    case 10:                                    /* SEND_CID, R2 */
        if ((arg >> 16) != s->rca || s->state != CARD_STBY) {
            return false;
        }
        resp136(s, cmd == 9 ? s->csd : s->cid);
        return true;
    case 12:                                    /* STOP_TRANSMISSION */
        if (s->state == CARD_DATA) {
            s->state = CARD_TRAN;
        }
        resp48(s, card_status(s));
        return true;
    case 13:                                    /* SEND_STATUS */
        if ((arg >> 16) != s->rca) {
            return false;
        }
        resp48(s, card_status(s));
        return true;
    case 17:                                    /* READ_SINGLE_BLOCK */
    case 18:                                    /* READ_MULTIPLE_BLOCK */
    case 24:                                    /* WRITE_BLOCK */
    case 25:                                    /* WRITE_MULTIPLE_BLOCK */
        if (s->state != CARD_TRAN) {
            return false;
        }
        resp48(s, card_status(s) | (cmd >= 24 && s->read_only ? (1u << 26) : 0));
        /* single-block transfers are over before the next command */
        s->state = (cmd == 18 || cmd == 25) ? CARD_DATA : CARD_TRAN;
        return true;
    case 16:                                    /* SET_BLOCKLEN */
        s->blocklen = arg;
        resp48(s, card_status(s));
        return true;
    default:
        qemu_log_mask(LOG_UNIMP, "ngage mmc: CMD%u arg=%08x not modelled\n", cmd, arg);
        return false;
    }
}

static void mmc_load_block(NGageMmc *s)
{
    uint32_t len = s->regs[0x08 >> 2] ? s->regs[0x08 >> 2] : s->blocklen;

    len = MIN(len, sizeof(s->blk));
    memset(s->blk, 0xFF, len);
    if (s->data_addr < s->size) {
        memcpy(s->blk, s->data + s->data_addr, MIN(len, s->size - s->data_addr));
    }
    s->blk_len = len;
    s->blk_pos = 0;
    s->writing = false;
    s->status |= ST_DATA_BUSY;
}

static void mmc_flush_block(NGageMmc *s)
{
    if (!s->read_only && s->data_addr < s->size) {
        memcpy(s->data + s->data_addr, s->blk, MIN(s->blk_len, s->size - s->data_addr));
    }
    if (s->log) {
        fprintf(s->log, "  write block @%08" PRIx64 " %u bytes%s\n", s->data_addr, s->blk_len,
                s->read_only ? " (read-only card: dropped)" : "");
    }
    s->data_addr += s->blk_len;
}

static void mmc_start(NGageMmc *s, uint32_t ctrl)
{
    unsigned cmd = s->regs[0x1C >> 2] & 0x3F, type = (ctrl >> 2) & 0xF;
    uint32_t arg = s->regs[0x20 >> 2];
    bool answered;

    s->status = 0;
    s->resp_words = 0;
    if (type == 6 || type == 9) {
        /* next block of a multi-block transfer: no command on the bus */
        if (type == 9) {
            s->data_addr += s->blk_len;
            mmc_load_block(s);
        } else {
            s->blk_pos = 0;
            s->blk_len = MIN(s->regs[0x08 >> 2] ? s->regs[0x08 >> 2] : s->blocklen, sizeof(s->blk));
            s->writing = true;
            s->status |= ST_DATA_BUSY;
        }
        answered = true;
    } else {
        answered = mmc_command(s, cmd, arg);
    }
    if (type != 0 && type != 6 && type != 9) {
        if (answered && s->resp_words) {
            s->status |= ST_RESP;
        } else {
            s->status |= ST_RESP_TIMEOUT;
        }
    }
    if (answered && (type == 5 || type == 8)) {
        s->data_addr = arg;
        if (type == 8) {
            mmc_load_block(s);
        } else {
            s->blk_pos = 0;
            s->blk_len = MIN(s->regs[0x08 >> 2] ? s->regs[0x08 >> 2] : s->blocklen, sizeof(s->blk));
            s->writing = true;
            s->status |= ST_DATA_BUSY;
        }
    }
    if (s->log) {
        fprintf(s->log, "CMD%-2u arg=%08x ctrl=%02x -> status=%03x resp=%08x pc=%08x\n",
                cmd, arg, ctrl, s->status, s->resp[0], ngage_guest_pc());
    }
    mmc_irq_update(s);
}

static uint64_t mmc_read(void *opaque, hwaddr off, unsigned size)
{
    NGageMmc *s = opaque;
    uint32_t v;

    switch (off) {
    case 0x04:
        v = s->regs[1] & ~1u;                   /* command taken at once */
        break;
    case 0x18:
        v = s->status;
        break;
    case 0x24:
        v = 0;
        for (unsigned i = 0; i < size; i++) {
            if (!s->writing && s->blk_pos < s->blk_len) {
                v |= (uint32_t)s->blk[s->blk_pos++] << (8 * i);
            }
        }
        if (!s->writing && s->blk_pos >= s->blk_len && (s->status & ST_DATA_BUSY)) {
            s->status &= ~ST_DATA_BUSY;
            mmc_irq_update(s);
        }
        break;
    case 0x20:
        if (s->resp_pos < s->resp_words) {
            v = s->resp[s->resp_pos++];
            if (s->resp_pos >= s->resp_words) {
                s->status &= ~ST_RESP;
                mmc_irq_update(s);
            }
        } else {
            v = 0;
        }
        break;
    default:
        v = s->regs[(off >> 2) & 15];
    }
    ngage_trace_log("mmc", false, MMC_BASE + off, size, v);
    return v;
}

static void mmc_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageMmc *s = opaque;

    ngage_trace_log("mmc", true, MMC_BASE + off, size, val);
    if (off == 0x24) {
        for (unsigned i = 0; i < size && s->writing && s->blk_pos < s->blk_len; i++) {
            s->blk[s->blk_pos++] = val >> (8 * i);
        }
        if (s->writing && s->blk_pos >= s->blk_len) {
            mmc_flush_block(s);
            s->writing = false;
            s->status &= ~ST_DATA_BUSY;
            mmc_irq_update(s);
        }
        return;
    }
    s->regs[(off >> 2) & 15] = val;
    if (off == 0x04 && (val & 1)) {
        mmc_start(s, val);
    }
}

static const MemoryRegionOps mmc_ops = {
    .read = mmc_read, .write = mmc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static uint8_t crc7(const uint8_t *d, int n)
{
    uint8_t crc = 0;

    for (int i = 0; i < n; i++) {
        uint8_t b = d[i];
        for (int k = 0; k < 8; k++) {
            crc <<= 1;
            if ((b ^ crc) & 0x80) {
                crc ^= 0x09;
            }
            b <<= 1;
        }
    }
    return crc & 0x7F;
}

static bool load_reg(const char *path, uint8_t out[16])
{
    gchar *buf = NULL;
    gsize len = 0;
    int n = 0;

    if (!g_file_get_contents(path, &buf, &len, NULL)) {
        return false;
    }
    if (len == 16) {
        memcpy(out, buf, 16);
        g_free(buf);
        return true;
    }
    for (gsize i = 0; i + 1 < len && n < 16; i++) {
        if (g_ascii_isxdigit(buf[i]) && g_ascii_isxdigit(buf[i + 1])) {
            out[n++] = g_ascii_xdigit_value(buf[i]) * 16 + g_ascii_xdigit_value(buf[i + 1]);
            i++;
        }
    }
    g_free(buf);
    if (n == 15) {
        out[15] = (crc7(out, 15) << 1) | 1;
        n = 16;
    }
    return n == 16;
}

/* Generic CID/CSD for an image without sidecars: MMC 3.1, 512-byte blocks. */
static void default_regs(NGageMmc *s)
{
    static const uint8_t cid[15] = { 0x00, 0x00, 0x00, 'N', 'G', 'M', 'O', 'D', 'L',
                                     0x10, 0x00, 0x00, 0x00, 0x01, 0x76 };
    uint64_t blocks = s->size / 512;
    int mult = 0;
    uint32_t csize;

    while (mult < 7 && (blocks >> (mult + 2)) > 4096) {
        mult++;
    }
    csize = (blocks >> (mult + 2)) - 1;
    memcpy(s->cid, cid, 15);
    s->cid[15] = (crc7(s->cid, 15) << 1) | 1;
    memset(s->csd, 0, 16);
    s->csd[0] = 0x8C;                           /* CSD_STRUCTURE 2, SPEC_VERS 3 */
    s->csd[1] = 0x0E;                           /* TAAC */
    s->csd[2] = 0x01;                           /* NSAC */
    s->csd[3] = 0x2A;                           /* TRAN_SPEED 20 MHz */
    s->csd[4] = 0x1F;                           /* CCC 0x1F5: classes 0,2,4,5,6,7,8 */
    s->csd[5] = 0x59;                           /* CCC low nibble 5, READ_BL_LEN 9 */
    s->csd[6] = 0x80 | ((csize >> 10) & 3);     /* READ_BL_PARTIAL, C_SIZE[11:10] */
    s->csd[7] = csize >> 2;
    s->csd[8] = ((csize & 3) << 6) | 0x36;      /* VDD currents */
    s->csd[9] = 0xD8 | ((mult >> 1) & 3);       /* VDD_W, C_SIZE_MULT[2:1] */
    s->csd[10] = ((mult & 1) << 7) | 0x7F;      /* ERASE_GRP */
    s->csd[11] = 0xFF;
    s->csd[12] = 0x92;                          /* R2W_FACTOR, WRITE_BL_LEN[3:2] = 9 */
    s->csd[13] = 0x40;                          /* WRITE_BL_LEN[1:0] */
    s->csd[14] = 0x00;                          /* not write-protected */
    s->csd[15] = (crc7(s->csd, 15) << 1) | 1;
}

void ngage_mmc_create(MemoryRegion *sysmem, const char *image, FILE *log)
{
    NGageMmc *s = g_new0(NGageMmc, 1);

    s->log = log;
    s->ocr = 0x00FF8000;                        /* 2.7-3.6 V */
    s->blocklen = 512;
    if (image) {
        gchar *buf = NULL;
        gsize len = 0;
        GError *err = NULL;
        g_autofree char *cidp = g_strdup_printf("%s.cid", image);
        g_autofree char *csdp = g_strdup_printf("%s.csd", image);

        if (!g_file_get_contents(image, &buf, &len, &err)) {
            error_report("ngage: mmc image: %s", err->message);
            exit(1);
        }
        s->data = (uint8_t *)buf;
        s->size = len;
        s->present = true;
        default_regs(s);
        if (load_reg(cidp, s->cid)) {
            info_report("ngage: mmc: CID from %s", cidp);
        }
        if (load_reg(csdp, s->csd)) {
            info_report("ngage: mmc: CSD from %s", csdp);
        }
        /* PERM_WRITE_PROTECT (bit 13) or TMP_WRITE_PROTECT (bit 12) */
        s->read_only = (s->csd[14] & 0x30) != 0;
    }
    memory_region_init_io(&s->mr, NULL, &mmc_ops, s, "ngage.mmc", 0x40);
    memory_region_add_subregion(sysmem, MMC_BASE, &s->mr);
    mmc_irq_update(s);
}
