/*
 * Nokia N-Gage QD reference model: shared declarations.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef HW_ARM_NGAGE_H
#define HW_ARM_NGAGE_H

#include "system/memory.h"
#include "hw/core/irq.h"
#include "qemu/audio.h"

/* Physical addresses as the Phoenix flash files place the two NOR chips. */
#define NGAGE_FLASH0_BASE   0x00000000u
#define NGAGE_FLASH0_SIZE   (16u << 20)     /* Samsung K8S2815ETA, 8M x 16 */
#define NGAGE_FLASH1_BASE   0x02000000u
#define NGAGE_FLASH1_SIZE   (8u << 20)      /* Samsung K8S6415ETA, 4M x 16 */

#define NGAGE_SDRAM_BASE    0x0A000000u
#define NGAGE_SDRAM_SIZE    (16u << 20)     /* Samsung K4M28163, 8M x 16 */

/*
 * 0x0C000000-0x0C0FFFFF: the ASIC ROM page, then on-chip RAM (the bootstrap's
 * flash routines at 0x0C004748, NOS's communication RAM and the two DSP
 * uploads at 0x0C030000 and 0x0C06FF00), as the core maps them
 * (rtl/upp/upp_bus.sv). The real layout is not known.
 */
#define NGAGE_IRAM_BASE     0x0C000000u
#define NGAGE_IRAM_SIZE     (1u << 20)
#define NGAGE_ASIC_ROM_SIZE 0x1000u

typedef struct NGageFlash NGageFlash;

NGageFlash *ngage_flash_create(MemoryRegion *sysmem, const char *name,
                               hwaddr base, uint32_t size, const char *path,
                               const char *save_path);

uint8_t *ngage_flash_data(NGageFlash *f, uint32_t *size);
bool ngage_flash_c_blank(NGageFlash *f);
void ngage_flash_changed(NGageFlash *f, uint32_t off, uint32_t len);

/*
 * A file that holds one part of a chip, as the core's save files do (C: is
 * CS1's upper 4 MiB, PMM the top 64 KiB of CS0): loaded over the image at
 * start, written back on exit when a program or an erase changed the part.
 */
void ngage_flash_part(NGageFlash *f, uint32_t off, uint32_t len, const char *path);

/* Today's date into PMM's clock records, as the core does before every start
 * (rtl/mister/pmm_date.sv). Returns the number of records written. */
int ngage_pmm_set_date(NGageFlash *cs0, int year, int month, int day);

uint32_t ngage_guest_pc(void);

/*
 * Guest-time stamps in the logs (machine property log-time=on): kern.log
 * then gets one line per kernel message, cbus.log a time column and the
 * QEMU log (-D) a line per flash sector erase start and end, each starting
 * with the guest virtual clock in seconds.
 */
extern bool ngage_log_time;
double ngage_guest_seconds(void);

/* Register blocks modelled as storage with first-access logging (ngage_upp.c). */
void ngage_upp_block(MemoryRegion *sysmem, const char *name, hwaddr base, uint32_t size);
void ngage_upp_set_log(FILE *fp);
void ngage_upp_load_quirks(const char *path);
/* Log every access in "lo-hi:lo-hi" physical ranges to the register log. */
void ngage_upp_set_trace(const char *spec);
bool ngage_trace_hit(uint32_t pa);
void ngage_trace_log(const char *dev, bool write, uint32_t pa, unsigned size, uint64_t val);

/* Interrupt controller and timers (ngage_intc.c). */
void ngage_intc_create(MemoryRegion *sysmem, qemu_irq cpu_irq, qemu_irq cpu_fiq);
/* Drive interrupt source 0..95 (numbering in ngage_intc.c). */
void ngage_intc_set_source(int src, int level);

/*
 * Source 25, IrqCTSI_IRQ, is shared: who 0 = the key matrix (ngage_keypad.c),
 * who 1 = the Bluetooth module's line (ngage_bt.c), who 2 = the cellular
 * side's events (ngage_ctsi.c).
 */
void ngage_ctsi_set(int who, bool level);

/* Source 1 is timer 1's and the UEMK's RTC alarm (ngage_cbus.c). */
void ngage_intc_set_alarm(bool level);

/* Interrupt source numbers (ngage_intc.c). */
#define NGAGE_IRQ_TIMER(n)      (n)
#define NGAGE_IRQ_DMA(n)        (6 + (n))
#define NGAGE_IRQ_LCDBUFFER     15
#define NGAGE_IRQ_MMC_DATAIDLE  21
#define NGAGE_IRQ_MMC_DATARDY   22
#define NGAGE_IRQ_MMC_CMDIDLE   23
#define NGAGE_IRQ_MMC_CMDRDY    24
#define NGAGE_IRQ_CTSI_IRQ      25
#define NGAGE_IRQ_CTSI_FIQ      26      /* on the FIQ plane only */
#define NGAGE_IRQ_GPIO_LOW(n)   (29 + 2 * (n))
#define NGAGE_IRQ_GPIO_HIGH(n)  (30 + 2 * (n))

/* STI trace output window: kernel debug text (ngage_sti.c). */
void ngage_sti_create(MemoryRegion *sysmem, FILE *log);

/* LCD bus interface and display module (ngage_lcd.c). shot_period < 0 = no screenshots. */
void ngage_lcd_create(MemoryRegion *sysmem, FILE *log, const char *shot_dir,
                      int shot_period, int scale, uint32_t id);

/* UIF ports D/E and the key matrix (ngage_keypad.c). */
void ngage_keypad_create(MemoryRegion *sysmem, const char *script, FILE *log);

/* DMA controller (ngage_dma.c). */
void ngage_dma_create(MemoryRegion *sysmem, FILE *log);

/* MMC host and card (ngage_mmc.c). image may be NULL (empty slot). */
void ngage_mmc_create(MemoryRegion *sysmem, const char *image, FILE *log);

/* CTSI's cellular side: calibration and deadline counters, software and MDI
 * interrupts (ngage_ctsi.c). The slow counter steps every NGAGE_NOS_TICK_NS. */
#define NGAGE_NOS_TICK_NS       15625000        /* 1/64 s */
#define NGAGE_CTSI_NOS_EVENTS   0x3680u         /* its bits of the status at 0x0C150100 */
void ngage_ctsi_create(MemoryRegion *sysmem);
uint16_t ngage_ctsi_nos_status(void);
void ngage_ctsi_nos_ack(uint16_t val);
/* bit 0: the DSP took words from the ring to it, bit 1: it published words */
void ngage_ctsi_mdi_events(unsigned bits);

/* The MDI link to the internal DSP and the DSP's side of it (ngage_mdi.c). */
void ngage_mdi_create(MemoryRegion *sysmem, FILE *log);
void ngage_mdi_kick(void);

/* The DSP's PCM playback (ngage_pcm.c): no registers of its own, the DSP's
 * side of the MDI link drives it. be and wav_path may be NULL. */
void ngage_pcm_create(AudioBackend *be, const char *wav_path, FILE *log);
void ngage_pcm_reset(void);
void ngage_pcm_write(unsigned off, uint32_t val);
/* bits 19:18 buffer played to its end, 17:16 buffer full, 15 running, 14:0 position */
uint32_t ngage_pcm_status(void);

/* SIM interface and the test card in it (ngage_sim.c). */
void ngage_sim_create(MemoryRegion *sysmem, FILE *log);

/* GENIO pins with the UEMK's loop-back routes (ngage_genio.c). */
void ngage_genio_create(MemoryRegion *sysmem);

/* CBUS master and UEMK model (ngage_cbus.c). */
void ngage_cbus_create(MemoryRegion *sysmem, const char *regs_path, FILE *log);
void ngage_cbus_set_cs1(NGageFlash *flash);
void ngage_cbus_set_power_key(bool down);
/* The UEMK's test routes: the ear and transmit paths and the SIM lines. */
enum { NGAGE_ROUTE_EAR, NGAGE_ROUTE_SIM, NGAGE_ROUTE_TX };
bool ngage_cbus_route(int which);

/* Bluetooth module, CBUS device 5, and its CTSI interrupt bit (ngage_bt.c). */
void ngage_bt_create(MemoryRegion *sysmem, FILE *log);
uint32_t ngage_bt_read(unsigned reg);
void ngage_bt_write(unsigned reg, uint32_t val);

/*
 * A register access as the core's register bus has it: the data in its byte
 * lanes of the 32-bit word and the bytes taken (bit n = byte n).
 */
static inline uint32_t ngage_lanes(hwaddr off, unsigned size, uint64_t val, unsigned *be)
{
    *be = ((1u << size) - 1) << (off & 3);
    return (uint32_t)val << ((off & 3) * 8);
}

static inline uint32_t ngage_be_mask(unsigned be)
{
    return (be & 1 ? 0x000000FFu : 0) | (be & 2 ? 0x0000FF00u : 0) |
           (be & 4 ? 0x00FF0000u : 0) | (be & 8 ? 0xFF000000u : 0);
}

/* The bytes an access of this size at off reads from a word. */
static inline uint64_t ngage_take(uint32_t word, hwaddr off, unsigned size)
{
    word >>= (off & 3) * 8;
    return size < 4 ? word & ((1u << (size * 8)) - 1) : word;
}

#endif
