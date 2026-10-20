/*
 * UPP_WD2 DMA controller, channels at 0x0C120300 + 0x40*n (n = 0..7;
 * the kernel allocates 0..6), from ekern's DMA layer (RH-29 v4.60,
 * 0x5031B2C0-0x5031B868; kernel DMA objects 0x5032AAB0-0x5032AEC0):
 *
 *   +0x04  written 1 before programming, 0 when stopping (0x5031B2E8)
 *   +0x08  0 = stop; 1 = start (memory to memory, 0x5031B43C), 2 = start
 *          paced by the peripheral (0x5031B5D8). Reads nonzero while busy
 *          (polled at 0x5031B2D4 after a stop).
 *   +0x0C, +0x10  read after a stop (0x5031B2F4); meaning unknown; read 0
 *   +0x14  source address        +0x20  destination address
 *   +0x18  source mode           +0x24  destination mode
 *          0 = fixed (peripheral FIFO), 2 = incrementing in on-chip RAM,
 *          4 = incrementing in SDRAM (chosen by address at 0x5031B344)
 *   +0x1C  source width          +0x28  destination width
 *          8, 0x10, 0x20 (= 8, 16, 32 bits; the MMC FIFO uses 8 and the
 *          LCD FIFO 0x20, tables at 0x5034025C/0x503402A4)
 *   +0x2C  transfer count - 1, in source-width units (0x5031B5CC)
 * Peripheral addresses seen by the DMA are 0x1xxxxxxx for register
 * 0x0Cxxxxxx: 0x10121208 = LCD FIFO, 0x10120624 = MMC data FIFO,
 * 0x10150554 and 0x10150500 = accessory interface (tables at
 * 0x503401F4/0x503401D0). Request lines are chosen per channel by 4-bit
 * fields in 0x0C120064/68 (MMC = 2, LCD = 7; 0x5031EDF8); the model
 * ignores pacing.
 *
 * The model performs the whole transfer when it is started and then
 * raises source 6+n (IrqDmaChannel0-7) until the channel is stopped. The
 * kernel's DMA ISR (0x50326B08) does not read status; it stops the channel
 * and moves on (status code 3 = done, 0x5031B860).
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "system/address-spaces.h"
#include "system/dma.h"
#include "hw/arm/ngage.h"

#define DMA_BASE    0x0C120300
#define NCHAN       8

typedef struct NGageDma {
    MemoryRegion mr;
    uint32_t regs[NCHAN][16];
    FILE *log;
} NGageDma;

static hwaddr dma_phys(uint32_t a)
{
    return (a & 0xF0000000u) == 0x10000000u ? (a & 0x0FFFFFFFu) + 0x0C000000u : a;
}

static unsigned width_bytes(uint32_t code)
{
    return code >= 0x20 ? 4 : code >= 0x10 ? 2 : 1;
}

static void dma_run(NGageDma *s, int ch)
{
    uint32_t *r = s->regs[ch];
    uint32_t src = r[0x14 >> 2], dst = r[0x20 >> 2];
    unsigned sw = width_bytes(r[0x1C >> 2]), dw = width_bytes(r[0x28 >> 2]);
    bool sinc = r[0x18 >> 2] != 0, dinc = r[0x24 >> 2] != 0;
    uint32_t units = r[0x2C >> 2] + 1;
    size_t total = (size_t)units * sw;
    g_autofree uint8_t *buf = g_malloc(total);
    hwaddr sa = dma_phys(src), da = dma_phys(dst);

    for (uint32_t i = 0; i < units; i++) {
        address_space_read(&address_space_memory, sa, MEMTXATTRS_UNSPECIFIED, buf + i * sw, sw);
        if (sinc) {
            sa += sw;
        }
    }
    for (size_t o = 0; o < total; o += dw) {
        address_space_write(&address_space_memory, da, MEMTXATTRS_UNSPECIFIED, buf + o,
                            MIN(dw, total - o));
        if (dinc) {
            da += dw;
        }
    }
    if (s->log) {
        fprintf(s->log, "DMA%d %08x(%s,%u) -> %08x(%s,%u) %zu bytes pc=%08x\n", ch,
                src, sinc ? "inc" : "fix", sw, dst, dinc ? "inc" : "fix", dw, total,
                ngage_guest_pc());
    }
    r[0x08 >> 2] = 0;
    ngage_intc_set_source(NGAGE_IRQ_DMA(ch), 1);
}

static uint64_t dma_read(void *opaque, hwaddr off, unsigned size)
{
    NGageDma *s = opaque;
    int ch = off >> 6;
    hwaddr o = off & 0x3F;
    uint32_t v = (o == 0x0C || o == 0x10) ? 0 : s->regs[ch][o >> 2];

    ngage_trace_log("dma", false, DMA_BASE + off, size, v);
    return v;
}

static void dma_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    NGageDma *s = opaque;
    int ch = off >> 6;
    hwaddr o = off & 0x3F;

    ngage_trace_log("dma", true, DMA_BASE + off, size, val);
    s->regs[ch][o >> 2] = val;
    if (o == 0x08) {
        if (val == 1 || val == 2) {
            dma_run(s, ch);
        } else if (val == 0) {
            ngage_intc_set_source(NGAGE_IRQ_DMA(ch), 0);
        }
    } else if (o == 0x04 && val == 0) {
        ngage_intc_set_source(NGAGE_IRQ_DMA(ch), 0);
    }
}

static const MemoryRegionOps dma_ops = {
    .read = dma_read, .write = dma_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

void ngage_dma_create(MemoryRegion *sysmem, FILE *log)
{
    NGageDma *s = g_new0(NGageDma, 1);

    s->log = log;
    memory_region_init_io(&s->mr, NULL, &dma_ops, s, "ngage.dma", 0x40 * NCHAN);
    memory_region_add_subregion(sysmem, DMA_BASE, &s->mr);
}
