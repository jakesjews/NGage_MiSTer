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

uint32_t ngage_guest_pc(void);

/* Register blocks modelled as storage with first-access logging (ngage_upp.c). */
void ngage_upp_block(MemoryRegion *sysmem, const char *name, hwaddr base, uint32_t size);
void ngage_upp_set_log(FILE *fp);
void ngage_upp_load_quirks(const char *path);

/* Interrupt controller and timers (ngage_intc.c). */
void ngage_intc_create(MemoryRegion *sysmem, qemu_irq cpu_irq);

/* CBUS master and UEMK model (ngage_cbus.c). */
void ngage_cbus_create(MemoryRegion *sysmem, const char *uemk_regs, FILE *log);

#endif
