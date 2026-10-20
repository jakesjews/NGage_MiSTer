/*
 * UPP_WD2 UIF general-purpose ports D and E (0x0C150400-0x0C15041F) wired
 * to the N-Gage QD's 6x5 key matrix, as ekeyb.dll (RH-29 v4.60) uses them.
 *
 * Port D = columns COL0-4 (bits 4:0), port E = rows ROW0-5 (bits 5:0); the
 * driver's line masks put columns in bits 4:0 and rows in bits 13:8
 * (0x3F1F, line configuration at ekeyb 0x5041C6F8). Per port:
 *   D      E
 *   +0x00  +0x0C  data: output latch; reads give the pin levels. The
 *                 driver changes it with read-modify-write (op 0 clear,
 *                 op 1 set; ekeyb 0x5041C7D8/0x5041C7EC).
 *   +0x02  +0x0E  direction, 1 = output. Writes set the bits in the low
 *                 byte and clear the bits in the high byte (ops 2/3).
 *   +0x04  +0x10  interrupt enable, same set/clear write format (ops 4/5).
 *   +0x08  +0x14  unknown, same write format (ops 6/7); stored.
 *   +0x0A  +0x16  pull-up enable, same write format (ops 8/9).
 *   +0x18         written 0 at keypad init (0x5041CCFC); stored.
 * Reads of the set/clear registers return the current bit state (guess).
 *
 * Idle state set by ekeyb 0x5041CCE0: columns are outputs driving 0, rows
 * are pulled-up inputs. A scan (0x5041C490) turns all lines into inputs,
 * then drives one column at a time and reads the rows active-low
 * (0x5041CBA8 reads +0x00 and +0x0C, inverts, keeps 0x1F and 0x3F).
 * Pin model: an output pin shows its latch; an input pin reads 0 when a
 * pressed key connects it to a line that is driven 0, otherwise 1 (pull-up
 * or floating high).
 *
 * Interrupt: ekeyb binds "IrqCTSI_IRQ" (source 25, shared with cbus.dll)
 * and "IrqGPIO23Low" (0x5041C560). Its CTSI handler (0x5041B9E0) reads
 * CTSI +0x100 (0x0C150100) and acts only if bit 2 is set; it then masks
 * the row interrupts and writes 0xC to +0x100 (0x5041CD6C). The model
 * latches bit 2 when an interrupt-enabled port E (row) input falls to 0
 * and bit 3 for port D (guess), clears bits written as 1, and drives
 * source 25 while any is set. The bootstrap writes 0x8000 there (0x2EE4);
 * other bits are stored.
 *
 * Host keys come from QEMU's keyboard (see key_map) and from an optional
 * key script: lines "<guest seconds> down|up <key name>". The power key is
 * not in the matrix: it is UEMK register 0x1F bit 1 (ngage_cbus.c), held
 * from reset for three guest seconds.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "qemu/error-report.h"
#include "ui/input.h"
#include "hw/arm/ngage.h"

#define UIF_BASE    0x0C150400
#define NROWS       6
#define NCOLS       5

/* The QD matrix from ekeyb's table 3 (research/peripherals/INPUT.md). */
typedef struct NGageKey { const char *name; int row, col; } NGageKey;
static const NGageKey keys[] = {
    { "up", 0, 0 }, { "left", 0, 1 }, { "rsk", 0, 2 }, { "clear", 0, 3 }, { "menu", 0, 4 },
    { "down", 1, 0 }, { "right", 1, 1 }, { "end", 1, 2 }, { "edit", 1, 3 }, { "ok", 1, 4 },
    { "lsk", 2, 0 }, { "1", 2, 2 }, { "6", 2, 3 }, { "8", 2, 4 },
    { "call", 3, 0 }, { "5", 3, 2 }, { "7", 3, 3 }, { "hash", 3, 4 },
    { "9", 4, 2 }, { "0", 4, 3 }, { "3", 4, 4 },
    { "star", 5, 2 }, { "2", 5, 3 }, { "4", 5, 4 },
    { "power", -1, -1 },                /* UEMK register 0x1F bit 1, not in the matrix */
};

/* The power key is held this long from reset, as when switching the phone on. */
#define POWER_ON_HOLD_NS    (3LL * 1000 * 1000 * 1000)

typedef struct NGageKeypad {
    MemoryRegion mr;
    /* [0] = port D (columns), [1] = port E (rows) */
    uint16_t data[2], dir[2], ien[2], misc[2], pull[2];
    uint16_t reg18;
    MemoryRegion ctsi_mr;
    uint16_t ctsi100, last_c, last_r;
    bool pressed[NROWS][NCOLS];
    FILE *log;
    /* key script */
    struct { int64_t ns; bool down; int key; } *script;
    int nscript, next;
    QEMUTimer *timer;
    QEMUTimer *power_timer;
} NGageKeypad;

static int key_index(const char *name)
{
    for (int i = 0; i < (int)ARRAY_SIZE(keys); i++) {
        if (!g_ascii_strcasecmp(keys[i].name, name)) {
            return i;
        }
    }
    return -1;
}

/* Pin level of every line: bits 4:0 columns, bits 13:8 rows. */
static void pins(NGageKeypad *s, uint16_t *cols, uint16_t *rows)
{
    uint16_t c = 0x1F, r = 0x3F;

    for (int i = 0; i < NCOLS; i++) {
        if (s->dir[0] & (1 << i)) {
            c = (c & ~(1 << i)) | (s->data[0] & (1 << i));
        }
    }
    for (int i = 0; i < NROWS; i++) {
        if (s->dir[1] & (1 << i)) {
            r = (r & ~(1 << i)) | (s->data[1] & (1 << i));
        }
    }
    /* Pressed keys pull an input low when the other side is driven low. */
    for (int ro = 0; ro < NROWS; ro++) {
        for (int co = 0; co < NCOLS; co++) {
            if (!s->pressed[ro][co]) {
                continue;
            }
            bool col_low_driven = (s->dir[0] & (1 << co)) && !(s->data[0] & (1 << co));
            bool row_low_driven = (s->dir[1] & (1 << ro)) && !(s->data[1] & (1 << ro));
            if (col_low_driven && !(s->dir[1] & (1 << ro))) {
                r &= ~(1 << ro);
            }
            if (row_low_driven && !(s->dir[0] & (1 << co))) {
                c &= ~(1 << co);
            }
        }
    }
    *cols = c;
    *rows = r;
}

static void kp_update(NGageKeypad *s)
{
    uint16_t c, r, fell_r, fell_c;

    pins(s, &c, &r);
    fell_r = s->last_r & ~r & s->ien[1] & ~s->dir[1] & 0x3F;
    fell_c = s->last_c & ~c & s->ien[0] & ~s->dir[0] & 0x1F;
    if (fell_r) {
        s->ctsi100 |= 1u << 2;
    }
    if ((fell_r || fell_c) && s->log) {
        fprintf(s->log, "keypad interrupt: rows %02x cols %02x fell %02x/%02x\n", r, c, fell_r, fell_c);
    }
    if (fell_c) {
        s->ctsi100 |= 1u << 3;
    }
    s->last_r = r;
    s->last_c = c;
    ngage_intc_set_source(NGAGE_IRQ_CTSI_IRQ, (s->ctsi100 & 0xC) != 0);
}

static uint64_t ctsi_read(void *opaque, hwaddr off, unsigned size)
{
    NGageKeypad *s = opaque;

    ngage_trace_log("ctsi", false, 0x0C150100 + off, size, s->ctsi100);
    return s->ctsi100;
}

static void ctsi_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageKeypad *s = opaque;

    ngage_trace_log("ctsi", true, 0x0C150100 + off, size, val);
    s->ctsi100 &= ~(val & 0xC);
    s->ctsi100 = (s->ctsi100 & 0xC) | (val & ~0xC);
    kp_update(s);
}

static const MemoryRegionOps ctsi_ops = {
    .read = ctsi_read, .write = ctsi_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 2, .max_access_size = 2 },
};

static void setclr(uint16_t *reg, uint16_t val)
{
    *reg = (*reg | (val & 0xFF)) & ~(val >> 8);
}

static uint64_t kp_read(void *opaque, hwaddr off, unsigned size)
{
    NGageKeypad *s = opaque;
    uint16_t c, r, v;

    pins(s, &c, &r);
    switch (off & ~1) {
    case 0x00: v = c; break;
    case 0x02: v = s->dir[0]; break;
    case 0x04: v = s->ien[0]; break;
    case 0x08: v = s->misc[0]; break;
    case 0x0A: v = s->pull[0]; break;
    case 0x0C: v = r; break;
    case 0x0E: v = s->dir[1]; break;
    case 0x10: v = s->ien[1]; break;
    case 0x14: v = s->misc[1]; break;
    case 0x16: v = s->pull[1]; break;
    case 0x18: v = s->reg18; break;
    default: v = 0;
    }
    ngage_trace_log("keypad", false, UIF_BASE + off, size, v);
    return v;
}

static void kp_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageKeypad *s = opaque;

    ngage_trace_log("keypad", true, UIF_BASE + off, size, val);
    switch (off & ~1) {
    case 0x00: s->data[0] = val & 0x1F; break;
    case 0x02: setclr(&s->dir[0], val); break;
    case 0x04: setclr(&s->ien[0], val); break;
    case 0x08: setclr(&s->misc[0], val); break;
    case 0x0A: setclr(&s->pull[0], val); break;
    case 0x0C: s->data[1] = val & 0x3F; break;
    case 0x0E: setclr(&s->dir[1], val); break;
    case 0x10: setclr(&s->ien[1], val); break;
    case 0x14: setclr(&s->misc[1], val); break;
    case 0x16: setclr(&s->pull[1], val); break;
    case 0x18: s->reg18 = val; break;
    }
    kp_update(s);
}

static const MemoryRegionOps kp_ops = {
    .read = kp_read, .write = kp_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 2, .max_access_size = 2 },
};

static void set_key(NGageKeypad *s, int k, bool down)
{
    if (k < 0) {
        return;
    }
    if (keys[k].row < 0) {
        ngage_cbus_set_power_key(down);
        if (s->log) {
            fprintf(s->log, "key %s %s\n", keys[k].name, down ? "down" : "up");
        }
        return;
    }
    s->pressed[keys[k].row][keys[k].col] = down;
    if (s->log) {
        fprintf(s->log, "key %s %s (dir %02x/%02x data %02x/%02x ien %02x)\n", keys[k].name,
                down ? "down" : "up", s->dir[0], s->dir[1], s->data[0], s->data[1], s->ien[1]);
    }
    kp_update(s);
}

/* Host keyboard: arrows, Return = OK, F1/F2 = soft keys, F3 = Menu,
 * F4 = Call, F5/Escape = End, F6 = Power, Backspace = Clear, Shift = Edit, digits and
 * keypad digits, '*' (keypad *), '#' (keypad /). */
static int key_map(int qcode)
{
    switch (qcode) {
    case Q_KEY_CODE_UP: return key_index("up");
    case Q_KEY_CODE_DOWN: return key_index("down");
    case Q_KEY_CODE_LEFT: return key_index("left");
    case Q_KEY_CODE_RIGHT: return key_index("right");
    case Q_KEY_CODE_RET: case Q_KEY_CODE_KP_ENTER: return key_index("ok");
    case Q_KEY_CODE_F1: return key_index("lsk");
    case Q_KEY_CODE_F2: return key_index("rsk");
    case Q_KEY_CODE_F3: return key_index("menu");
    case Q_KEY_CODE_F4: return key_index("call");
    case Q_KEY_CODE_F5: case Q_KEY_CODE_ESC: return key_index("end");
    case Q_KEY_CODE_F6: return key_index("power");
    case Q_KEY_CODE_BACKSPACE: return key_index("clear");
    case Q_KEY_CODE_SHIFT: return key_index("edit");
    case Q_KEY_CODE_KP_MULTIPLY: return key_index("star");
    case Q_KEY_CODE_KP_DIVIDE: return key_index("hash");
    case Q_KEY_CODE_0: case Q_KEY_CODE_KP_0: return key_index("0");
    case Q_KEY_CODE_1: case Q_KEY_CODE_KP_1: return key_index("1");
    case Q_KEY_CODE_2: case Q_KEY_CODE_KP_2: return key_index("2");
    case Q_KEY_CODE_3: case Q_KEY_CODE_KP_3: return key_index("3");
    case Q_KEY_CODE_4: case Q_KEY_CODE_KP_4: return key_index("4");
    case Q_KEY_CODE_5: case Q_KEY_CODE_KP_5: return key_index("5");
    case Q_KEY_CODE_6: case Q_KEY_CODE_KP_6: return key_index("6");
    case Q_KEY_CODE_7: case Q_KEY_CODE_KP_7: return key_index("7");
    case Q_KEY_CODE_8: case Q_KEY_CODE_KP_8: return key_index("8");
    case Q_KEY_CODE_9: case Q_KEY_CODE_KP_9: return key_index("9");
    default: return -1;
    }
}

static NGageKeypad *the_keypad;

static void kp_event(DeviceState *dev, QemuConsole *src, QemuInputEvent *evt)
{
    int qcode = qemu_input_linux_to_qcode(evt->key.key);

    set_key(the_keypad, key_map(qcode), evt->key.down);
}

static const QemuInputHandler kp_handler = {
    .name = "N-Gage QD keypad",
    .mask = INPUT_EVENT_MASK_KEY,
    .event = kp_event,
};

static void kp_power_release(void *opaque)
{
    set_key(opaque, key_index("power"), false);
}

static void kp_script_tick(void *opaque)
{
    NGageKeypad *s = opaque;
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    while (s->next < s->nscript && s->script[s->next].ns <= now) {
        set_key(s, s->script[s->next].key, s->script[s->next].down);
        s->next++;
    }
    if (s->next < s->nscript) {
        timer_mod(s->timer, s->script[s->next].ns);
    }
}

static void kp_load_script(NGageKeypad *s, const char *path)
{
    FILE *fp = fopen(path, "r");
    char line[256];

    if (!fp) {
        error_report("ngage: cannot open key script %s", path);
        exit(1);
    }
    while (fgets(line, sizeof(line), fp)) {
        double t;
        char how[8], name[32];
        char *h = strstr(line, " #");
        if (line[strspn(line, " \t")] == '#') {
            continue;
        }
        if (h) {
            *h = 0;
        }
        if (sscanf(line, "%lf %7s %31s", &t, how, name) != 3) {
            continue;
        }
        int k = key_index(name);
        if (k < 0) {
            error_report("ngage: key script: unknown key %s", name);
            exit(1);
        }
        s->script = g_renew(typeof(*s->script), s->script, s->nscript + 1);
        s->script[s->nscript].ns = (int64_t)(t * 1e9);
        s->script[s->nscript].down = !strcmp(how, "down");
        s->script[s->nscript].key = k;
        s->nscript++;
    }
    fclose(fp);
    if (s->nscript) {
        s->timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, kp_script_tick, s);
        timer_mod(s->timer, s->script[0].ns);
    }
}

void ngage_keypad_create(MemoryRegion *sysmem, const char *script, FILE *log)
{
    NGageKeypad *s = g_new0(NGageKeypad, 1);

    the_keypad = s;
    s->log = log;
    s->data[0] = 0x1F;
    s->data[1] = 0x3F;
    s->last_c = 0x1F;
    s->last_r = 0x3F;
    memory_region_init_io(&s->ctsi_mr, NULL, &ctsi_ops, s, "ngage.ctsi-100", 2);
    memory_region_add_subregion(sysmem, 0x0C150100, &s->ctsi_mr);
    memory_region_init_io(&s->mr, NULL, &kp_ops, s, "ngage.keypad", 0x20);
    memory_region_add_subregion(sysmem, UIF_BASE, &s->mr);
    (void)qemu_input_handler_register(NULL, &kp_handler);
    s->power_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, kp_power_release, s);
    timer_mod(s->power_timer, POWER_ON_HOLD_NS);
    if (script) {
        kp_load_script(s, script);
    }
}
