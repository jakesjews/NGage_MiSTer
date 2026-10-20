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

/* Physical addresses as the Phoenix flash files place the two NOR chips. */
#define NGAGE_FLASH0_BASE   0x00000000u
#define NGAGE_FLASH0_SIZE   (16u << 20)     /* Samsung K8S2815ETA, 8M x 16 */
#define NGAGE_FLASH1_BASE   0x02000000u
#define NGAGE_FLASH1_SIZE   (8u << 20)      /* Samsung K8S6415ETA, 4M x 16 */

#define NGAGE_SDRAM_BASE    0x0A000000u
#define NGAGE_SDRAM_SIZE    (16u << 20)     /* Samsung K4M28163, 8M x 16 */

#define NGAGE_IRAM_BASE     0x0C000000u
#define NGAGE_IRAM_SIZE     (256u << 10)    /* TODO: real size not known yet */

typedef struct NGageFlash NGageFlash;

NGageFlash *ngage_flash_create(MemoryRegion *sysmem, const char *name,
                               hwaddr base, uint32_t size, const char *path);

uint8_t *ngage_flash_data(NGageFlash *f, uint32_t *size);
void ngage_flash_changed(NGageFlash *f, uint32_t off, uint32_t len);

/* Model shortcuts applied to the flash images at load (ngage_patch.c). */
void ngage_apply_rom_patches(const char *path, NGageFlash *cs0, NGageFlash *cs1);

uint32_t ngage_guest_pc(void);

/* Register blocks modelled as storage with first-access logging (ngage_upp.c). */
void ngage_upp_block(MemoryRegion *sysmem, const char *name, hwaddr base, uint32_t size);
void ngage_upp_set_log(FILE *fp);
void ngage_upp_load_quirks(const char *path);

/* Interrupt controller and timers (ngage_intc.c). */
void ngage_intc_create(MemoryRegion *sysmem, qemu_irq cpu_irq, qemu_irq cpu_fiq);
/* Drive interrupt source 0..95 (numbering in ngage_intc.c). */
void ngage_intc_set_source(int src, int level);

/* Interrupt source numbers (ngage_intc.c). */
#define NGAGE_IRQ_TIMER(n)      (n)
#define NGAGE_IRQ_LCDBUFFER     15
#define NGAGE_IRQ_MMC_DATAIDLE  21
#define NGAGE_IRQ_MMC_DATARDY   22
#define NGAGE_IRQ_MMC_CMDIDLE   23
#define NGAGE_IRQ_MMC_CMDRDY    24
#define NGAGE_IRQ_CTSI_IRQ      25
#define NGAGE_IRQ_CTSI_FIQ      26
#define NGAGE_IRQ_GPIO_LOW(n)   (29 + 2 * (n))
#define NGAGE_IRQ_GPIO_HIGH(n)  (30 + 2 * (n))

/* STI trace output window: kernel debug text (ngage_sti.c). */
void ngage_sti_create(MemoryRegion *sysmem, FILE *log);

/* CBUS master and UEMK model (ngage_cbus.c). */
void ngage_cbus_create(MemoryRegion *sysmem, const char *regs_path, FILE *log);

#endif
