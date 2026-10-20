/*
 * UPP_WD2 LCD bus interface (0x0C121200) and the QD's 176x208 display
 * module, as far as the RH-29 v4.60 bootstrap (0x6600-0x6F40) and lcd.ldd
 * (0x50401D34-0x50406968) drive them.
 *
 * Interface registers:
 *   +0x00 control. Read: the last value written with bit 30 set (the drivers
 *         write 0x49200000 and poll bit 30, lcd.ldd 0x504068A0). Write: the
 *         phase for the following +0x08 accesses; bits 15:0 = bytes - 1.
 *         Bits 19:18 select how a 32-bit FIFO word becomes bus bytes:
 *           2 (0x09280000)  one command byte, word bits 7:0 (A0 = 0)
 *           1 (0x09240000, 0x83140000, 0x89240000)  three bytes from two
 *             12-bit units u0 = w[11:0], u1 = w[27:16]. With bit 31 clear
 *             the bytes are V = u0 | u1 << 12 least significant byte first:
 *             the bootstrap packs CASET/PASET parameters this way (0x694C:
 *             p0 in bits 7:0, p1 split over 11:8 and 19:16, p2 in 27:20).
 *             With bit 31 set (pixel streams after RAMWR, 0x50402188) the
 *             model sends u0[11:4], u0[3:0]u1[11:8], u1[7:0]: two 0x0RGB
 *             pixels in the DCS 12-bit order. Bit 31's meaning is inferred.
 *           3 (0x092C0000 LUT, 0x082C0000 16-bit pixels)  four bytes per word,
 *             least significant first (the RGBSET table at 0x50406980 is
 *             stored in that order).
 *         0x0784xxxx = read phase: each +0x08 read returns one byte, the
 *         first a dummy (bootstrap RDDID 0x6C44, RDDST 0x6BC8).
 *   +0x04 auxiliary: bit 2 reads 1 = FIFO can take a word (polled before
 *         data writes, bootstrap 0x6858, lcd.ldd 0x50401F14); writes 2 then
 *         1 reset the FIFO (0x6834).
 *   +0x08 FIFO data (write) / read data.
 *
 * Panel: MIPI-DCS-style command set (research/peripherals/DISPLAY.md).
 * RDDID returns ID1 = 0x29, which makes both drivers take the "module 0x10"
 * path (bootstrap 0x62D8: 0x29 -> 0x10, 0x83 -> 4); which module a QD has is
 * not known. The panel is assumed mounted rotated by 180 degrees: module 0x10
 * sets MADCTL 0xD4 (MY, MX) and sends coordinates as they are, module 4
 * mirrors coordinates itself; both then appear upright.
 *
 * Partial and idle mode (the screen saver, lcd.ldd 0x50406278): PTLAR 0x30
 * (start row, end row, 16 bits each), PTLON 0x12 and IDMON 0x39, then a full
 * frame with the date bar in those rows; every minute again with the bar
 * moved (rows 4-26, 128-150, 164-186 seen). NORON 0x13 and IDMOFF 0x38 end
 * it. The model shows rows outside the partial area black (the rows are the
 * driver's PASET rows: the bar it draws falls in them) and, in idle mode,
 * each colour component as its top bit (eight colours).
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "qemu/error-report.h"
#include "qemu/notify.h"
#include "ui/console.h"
#include "system/system.h"
#include <zlib.h>
#include "hw/arm/ngage.h"

#define LCD_BASE    0x0C121200
#define LCD_W       176
#define LCD_H       208

typedef struct NGageLcd {
    MemoryRegion mr;
    QemuConsole *con;
    int scale;
    /* interface */
    uint32_t ctrl, aux, last_data;
    uint32_t phase_left;            /* bytes left in the current data phase */
    /* panel */
    uint8_t cmd;
    int nparam;
    uint8_t param[64];
    uint16_t xs, xe, ys, ye, x, y;
    uint8_t madctl, colmod;
    bool sleep, display_on, idle, te_on, partial;
    uint16_t ptl_sr, ptl_er;
    uint8_t lut[48];
    bool lut_valid;
    uint8_t pix[3];
    int npix;
    uint8_t rd[8];
    int rd_len, rd_pos;
    uint32_t id;
    uint32_t gram[LCD_H][LCD_W];    /* physical panel memory, 0x00RRGGBB */
    bool dirty;
    /* output */
    FILE *log;
    char *shot_dir;
    int shot_period;                /* guest seconds, 0 = on exit only */
    int shot_seq;
    QEMUTimer *shot_timer;
    Notifier exit_notifier;
    uint64_t cmds, pixels;
} NGageLcd;

static void lcd_log(NGageLcd *s, const char *fmt, ...) G_GNUC_PRINTF(2, 3);
static void lcd_log(NGageLcd *s, const char *fmt, ...)
{
    va_list ap;

    if (!s->log) {
        return;
    }
    va_start(ap, fmt);
    vfprintf(s->log, fmt, ap);
    va_end(ap);
}

/* ------------------------------------------------------------- panel */

static int nparams_for(uint8_t cmd)
{
    switch (cmd) {
    case 0x2A: case 0x2B: case 0x30: return 4;
    case 0x26: case 0x35: case 0x36: case 0x3A: case 0x24: return 1;
    case 0x2D: return 48;
    default: return 0;
    }
}

static void put_pixel(NGageLcd *s, uint32_t rgb)
{
    unsigned c = s->x, r = s->y;

    if (s->madctl & 0x20) {             /* MV: exchange rows and columns */
        unsigned t = c; c = r; r = t;
    }
    if (s->madctl & 0x40) {             /* MX */
        c = LCD_W - 1 - c;
    }
    if (s->madctl & 0x80) {             /* MY */
        r = LCD_H - 1 - r;
    }
    if (c < LCD_W && r < LCD_H) {
        s->gram[r][c] = rgb;
        s->dirty = true;
    }
    s->pixels++;
    if (s->x >= s->xe) {
        s->x = s->xs;
        s->y = s->y >= s->ye ? s->ys : s->y + 1;
    } else {
        s->x++;
    }
}

static uint32_t rgb444(NGageLcd *s, unsigned r, unsigned g, unsigned b)
{
    if (s->lut_valid) {                 /* RGBSET: 16 R (5 bit), 16 G (6 bit), 16 B (5 bit) */
        unsigned r5 = s->lut[r] & 31, g6 = s->lut[16 + g] & 63, b5 = s->lut[32 + b] & 31;
        return ((r5 << 3 | r5 >> 2) << 16) | ((g6 << 2 | g6 >> 4) << 8) | (b5 << 3 | b5 >> 2);
    }
    return (r * 17) << 16 | (g * 17) << 8 | b * 17;
}

static void ram_byte(NGageLcd *s, uint8_t b)
{
    s->pix[s->npix++] = b;
    if (s->colmod == 5) {               /* 16 bpp: RRRRRGGG GGGBBBBB */
        if (s->npix == 2) {
            unsigned v = s->pix[0] << 8 | s->pix[1];
            unsigned r = v >> 11, g = (v >> 5) & 63, bl = v & 31;
            put_pixel(s, ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (bl << 3 | bl >> 2));
            s->npix = 0;
        }
    } else {                            /* 12 bpp: R0G0 B0R1 G1B1 */
        if (s->npix == 3) {
            put_pixel(s, rgb444(s, s->pix[0] >> 4, s->pix[0] & 15, s->pix[1] >> 4));
            put_pixel(s, rgb444(s, s->pix[1] & 15, s->pix[2] >> 4, s->pix[2] & 15));
            s->npix = 0;
        }
    }
}

static void panel_params_done(NGageLcd *s)
{
    uint8_t *p = s->param;

    switch (s->cmd) {
    case 0x2A:
        s->xs = p[0] << 8 | p[1];
        s->xe = p[2] << 8 | p[3];
        break;
    case 0x2B:
        s->ys = p[0] << 8 | p[1];
        s->ye = p[2] << 8 | p[3];
        break;
    case 0x36:
        s->madctl = p[0];
        break;
    case 0x3A:
        s->colmod = p[0];
        break;
    case 0x2D:
        memcpy(s->lut, p, 48);
        s->lut_valid = true;
        break;
    case 0x30:                                  /* PTLAR */
        s->ptl_sr = p[0] << 8 | p[1];
        s->ptl_er = p[2] << 8 | p[3];
        s->dirty = true;
        break;
    }
    lcd_log(s, "  params %02x:", s->cmd);
    for (int i = 0; i < s->nparam && i < 8; i++) {
        lcd_log(s, " %02x", p[i]);
    }
    lcd_log(s, "\n");
}

static void panel_command(NGageLcd *s, uint8_t cmd)
{
    s->cmd = cmd;
    s->nparam = 0;
    s->npix = 0;
    s->cmds++;
    lcd_log(s, "cmd %02x pc=%08x t=%" PRId64 "\n", cmd, ngage_guest_pc(),
            qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL));
    switch (cmd) {
    case 0x01:                                  /* SWRESET */
        s->madctl = 0; s->colmod = 6; s->sleep = true; s->display_on = false;
        s->partial = false; s->idle = false;
        s->ptl_sr = 0; s->ptl_er = LCD_H - 1;
        break;
    case 0x12: s->partial = true; s->dirty = true; break;      /* PTLON */
    case 0x13: s->partial = false; s->dirty = true; break;     /* NORON */
    case 0x10: s->sleep = true; break;
    case 0x11: s->sleep = false; break;
    case 0x28: s->display_on = false; s->dirty = true; break;
    case 0x29: s->display_on = true; s->dirty = true; break;
    case 0x38: s->idle = false; s->dirty = true; break;
    case 0x39: s->idle = true; s->dirty = true; break;
    case 0x34: s->te_on = false; break;
    case 0x35: s->te_on = true; break;
    case 0x2C:                                  /* RAMWR */
        s->x = s->xs;
        s->y = s->ys;
        break;
    case 0x04:                                  /* RDDID: dummy, ID1, ID2, ID3 */
        s->rd[0] = 0;
        s->rd[1] = s->id >> 16; s->rd[2] = s->id >> 8; s->rd[3] = s->id;
        s->rd_len = 4; s->rd_pos = 0;
        break;
    case 0x09: {                                /* RDDST: dummy + 4 status bytes */
        uint8_t st1 = 0x80 | (s->madctl & 0xF4);            /* booster on, address order */
        uint8_t st2 = ((s->colmod & 7) << 4) | (s->idle ? 8 : 0) | (s->sleep ? 0 : 2) | 1;
        uint8_t st3 = (s->display_on ? 4 : 0) | (s->te_on ? 2 : 0);
        s->rd[0] = 0; s->rd[1] = st1; s->rd[2] = st2; s->rd[3] = st3; s->rd[4] = 0;
        s->rd_len = 5; s->rd_pos = 0;
        break;
    }
    }
}

static void panel_data(NGageLcd *s, uint8_t b)
{
    int need = nparams_for(s->cmd);

    if (s->cmd == 0x2C || (s->cmd == 0x3C)) {   /* RAMWR, RAMWRC */
        ram_byte(s, b);
    } else if (s->nparam < need) {
        s->param[s->nparam++] = b;
        if (s->nparam == need) {
            panel_params_done(s);
        }
    } else {
        lcd_log(s, "  extra data %02x after cmd %02x\n", b, s->cmd);
    }
}

static uint8_t panel_read(NGageLcd *s)
{
    return s->rd_pos < s->rd_len ? s->rd[s->rd_pos++] : 0;
}

/* --------------------------------------------------------- interface */

static int phase_packing(uint32_t ctrl)
{
    return (ctrl >> 18) & 3;
}

static bool phase_is_read(uint32_t ctrl)
{
    return (ctrl & 0x0F000000) == 0x07000000;
}

static void phase_bytes(NGageLcd *s, const uint8_t *b, int n)
{
    for (int i = 0; i < n && s->phase_left; i++, s->phase_left--) {
        panel_data(s, b[i]);
    }
}

static void lcd_data_write(NGageLcd *s, uint32_t w)
{
    uint8_t b[4];

    s->last_data = w;
    switch (phase_packing(s->ctrl)) {
    case 2:
        panel_command(s, w & 0xFF);
        break;
    case 1: {
        uint32_t u0 = w & 0xFFF, u1 = (w >> 16) & 0xFFF;
        if (s->ctrl & 0x80000000u) {
            b[0] = u0 >> 4; b[1] = (u0 & 15) << 4 | u1 >> 8; b[2] = u1;
        } else {
            uint32_t v = u0 | u1 << 12;
            b[0] = v; b[1] = v >> 8; b[2] = v >> 16;
        }
        phase_bytes(s, b, 3);
        break;
    }
    case 3:
        b[0] = w; b[1] = w >> 8; b[2] = w >> 16; b[3] = w >> 24;
        phase_bytes(s, b, 4);
        break;
    default:
        lcd_log(s, "  data %08x in idle phase (ctrl %08x)\n", w, s->ctrl);
    }
}

static uint64_t lcd_read(void *opaque, hwaddr off, unsigned size)
{
    NGageLcd *s = opaque;
    uint32_t v;

    switch (off) {
    case 0x00:
        v = s->ctrl | (1u << 30);
        break;
    case 0x04:
        v = (s->aux & ~4u) | 4u;
        break;
    case 0x08:
        v = phase_is_read(s->ctrl) ? panel_read(s) : s->last_data;
        break;
    default:
        v = 0;
    }
    ngage_trace_log("lcd", false, LCD_BASE + off, size, v);
    return v;
}

static void lcd_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageLcd *s = opaque;

    ngage_trace_log("lcd", true, LCD_BASE + off, size, val);
    switch (off) {
    case 0x00:
        s->ctrl = val;
        s->phase_left = (val & 0xFFFF) + 1;
        if ((val & 0xFFFF0000) != 0x49200000 && (val & 0xFFFF0000) != 0x09200000) {
            lcd_log(s, " ctrl %08x\n", (unsigned)val);
        }
        break;
    case 0x04:
        s->aux = val;
        break;
    case 0x08:
        lcd_data_write(s, val);
        break;
    }
}

static const MemoryRegionOps lcd_ops = {
    .read = lcd_read, .write = lcd_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

/* ----------------------------------------------------------- output */

/* What the user sees: the physical memory rotated by 180 degrees. */
static uint32_t view_pixel(NGageLcd *s, int x, int y)
{
    int r = LCD_H - 1 - y;                      /* panel memory row */
    int row = (s->madctl & 0x80) ? LCD_H - 1 - r : r;   /* as the driver addresses it */
    uint32_t p;

    if (!s->display_on || s->sleep) {
        return 0;
    }
    if (s->partial && (row < s->ptl_sr || row > s->ptl_er)) {
        return 0;
    }
    p = s->gram[r][LCD_W - 1 - x];
    if (s->idle) {                              /* eight colours: top bit of each */
        p = (p & 0x800000 ? 0xFF0000 : 0) | (p & 0x8000 ? 0xFF00 : 0) | (p & 0x80 ? 0xFF : 0);
    }
    return p;
}

static void lcd_invalidate(void *opaque)
{
    NGageLcd *s = opaque;

    s->dirty = true;
}

static bool lcd_gfx_update(void *opaque)
{
    NGageLcd *s = opaque;
    DisplaySurface *surface = qemu_console_surface(s->con);
    int k = s->scale;

    if (!s->dirty || !surface || surface_bits_per_pixel(surface) != 32) {
        return true;
    }
    uint8_t *base = surface_data(surface);
    int stride = surface_stride(surface);
    for (int y = 0; y < LCD_H * k; y++) {
        uint32_t *row = (uint32_t *)(base + y * stride);
        for (int x = 0; x < LCD_W * k; x++) {
            row[x] = view_pixel(s, x / k, y / k);
        }
    }
    qemu_console_update(s->con, 0, 0, LCD_W * k, LCD_H * k);
    s->dirty = false;
    return true;
}

static const GraphicHwOps lcd_hw_ops = {
    .invalidate = lcd_invalidate,
    .gfx_update = lcd_gfx_update,
};

static void png_chunk(FILE *fp, const char *type, const uint8_t *d, uint32_t n)
{
    uint8_t hdr[8];
    uint32_t crc;

    stl_be_p(hdr, n);
    memcpy(hdr + 4, type, 4);
    fwrite(hdr, 1, 8, fp);
    if (n) {
        fwrite(d, 1, n, fp);
    }
    crc = crc32(0, hdr + 4, 4);
    crc = crc32(crc, d, n);
    stl_be_p(hdr, crc);
    fwrite(hdr, 1, 4, fp);
}

static void save_shot(NGageLcd *s, const char *base)
{
    g_autofree char *ppm = g_strdup_printf("%s.ppm", base);
    g_autofree char *png = g_strdup_printf("%s.png", base);
    size_t raw_len = (size_t)LCD_H * (1 + LCD_W * 3);
    g_autofree uint8_t *raw = g_malloc(raw_len);
    uLongf zlen = compressBound(raw_len);
    g_autofree uint8_t *z = g_malloc(zlen);
    FILE *fp;

    for (int y = 0; y < LCD_H; y++) {
        uint8_t *r = raw + y * (1 + LCD_W * 3);
        r[0] = 0;
        for (int x = 0; x < LCD_W; x++) {
            uint32_t p = view_pixel(s, x, y);
            r[1 + 3 * x] = p >> 16; r[2 + 3 * x] = p >> 8; r[3 + 3 * x] = p;
        }
    }
    fp = fopen(ppm, "wb");
    if (fp) {
        fprintf(fp, "P6\n%d %d\n255\n", LCD_W, LCD_H);
        for (int y = 0; y < LCD_H; y++) {
            fwrite(raw + y * (1 + LCD_W * 3) + 1, 1, LCD_W * 3, fp);
        }
        fclose(fp);
    }
    if (compress2(z, &zlen, raw, raw_len, 9) == Z_OK && (fp = fopen(png, "wb"))) {
        static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
        uint8_t ihdr[13];
        fwrite(sig, 1, 8, fp);
        stl_be_p(ihdr, LCD_W);
        stl_be_p(ihdr + 4, LCD_H);
        ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
        png_chunk(fp, "IHDR", ihdr, 13);
        png_chunk(fp, "IDAT", z, zlen);
        png_chunk(fp, "IEND", NULL, 0);
        fclose(fp);
    }
}

static void lcd_shot_timer(void *opaque)
{
    NGageLcd *s = opaque;
    g_autofree char *base = g_strdup_printf("%s/lcd-%04d", s->shot_dir, s->shot_seq++);

    save_shot(s, base);
    timer_mod(s->shot_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + s->shot_period * 1000);
}

static void lcd_exit(Notifier *n, void *data)
{
    NGageLcd *s = container_of(n, NGageLcd, exit_notifier);
    g_autofree char *base = g_strdup_printf("%s/lcd-last", s->shot_dir);

    save_shot(s, base);
    if (s->log) {
        fprintf(s->log, "exit: %" PRIu64 " commands, %" PRIu64 " pixels\n", s->cmds, s->pixels);
        fflush(s->log);
    }
}

void ngage_lcd_create(MemoryRegion *sysmem, FILE *log, const char *shot_dir,
                      int shot_period, int scale, uint32_t id)
{
    NGageLcd *s = g_new0(NGageLcd, 1);

    s->log = log;
    s->scale = scale > 0 ? scale : 1;
    s->id = id;
    s->colmod = 6;
    s->sleep = true;
    s->xe = LCD_W - 1;
    s->ye = LCD_H - 1;
    s->ptl_er = LCD_H - 1;
    s->con = qemu_graphic_console_create(NULL, 0, &lcd_hw_ops, s);
    qemu_console_resize(s->con, LCD_W * s->scale, LCD_H * s->scale);
    memory_region_init_io(&s->mr, NULL, &lcd_ops, s, "ngage.lcd", 0x10);
    memory_region_add_subregion(sysmem, LCD_BASE, &s->mr);
    if (shot_dir && shot_period >= 0) {
        s->shot_dir = g_strdup(shot_dir);
        s->shot_period = shot_period;
        s->exit_notifier.notify = lcd_exit;
        qemu_add_exit_notifier(&s->exit_notifier);
        if (shot_period > 0) {
            s->shot_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, lcd_shot_timer, s);
            timer_mod(s->shot_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + shot_period * 1000);
        }
    }
}
