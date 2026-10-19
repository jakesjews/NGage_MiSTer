/*
 * Nokia N-Gage QD (RH-29) machine: Nokia UPP_WD2 ASIC (ARM9 MCU + DSP),
 * two burst NOR flashes, SDRAM. Reference model for the MiSTer core.
 *
 * The UPP_WD2 register map is undocumented. This machine grows as the
 * firmware is reverse engineered: every access to an address no model
 * claims is logged by the probe region with the guest PC that made it.
 *
 * Copyright (c) 2026 the NGage_MiSTer authors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "hw/core/boards.h"
#include "hw/arm/boot.h"
#include "hw/arm/machines-qom.h"
#include "system/address-spaces.h"
#include "system/reset.h"
#include "accel/tcg/cpu-loop.h"
#include "exec/target_page.h"
#include "target/arm/cpu.h"
#include "hw/arm/ngage.h"

#define TYPE_NGAGE_MACHINE MACHINE_TYPE_NAME("ngage-qd")
OBJECT_DECLARE_SIMPLE_TYPE(NGageMachineState, NGAGE_MACHINE)

struct NGageMachineState {
    MachineState parent;
    char *flash0_path;
    char *flash1_path;
    char *probe_log;
    char *upp_log;
    char *quirks;
    NGageFlash *flash[2];
    MemoryRegion probe;
    MemoryRegion sdram;
    MemoryRegion iram;
    FILE *probe_fp;
    uint64_t probe_count;
    ARMCPU *cpu;
};

/* Guest PC of the instruction performing the current memory access. */
uint32_t ngage_guest_pc(void)
{
    uint64_t data[8] = { 0 };

    if (current_cpu && current_cpu->mem_io_pc &&
        cpu_unwind_state_data(current_cpu, current_cpu->mem_io_pc, data)) {
        /*
         * ARM translates page-relative (CF_PCREL): the saved value is the
         * offset in the page; the page comes from the PC at block entry.
         */
        uint64_t mask = (uint64_t)(int64_t)qemu_target_page_mask();
        if ((data[0] & mask) == 0) {
            return (ARM_CPU(current_cpu)->env.regs[15] & mask) | data[0];
        }
        return data[0];
    }
    if (current_cpu) {
        return ARM_CPU(current_cpu)->env.regs[15];
    }
    return 0;
}

/* ---------------------------------------------------------------- probe */

#define PROBE_LIMIT 200000

static void probe_log(NGageMachineState *s, const char *dir, hwaddr addr,
                      unsigned size, uint64_t val)
{
    if (s->probe_count++ >= PROBE_LIMIT) {
        return;
    }
    if (s->probe_fp) {
        fprintf(s->probe_fp, "%s pc=%08x addr=%08" HWADDR_PRIx " size=%u val=%08" PRIx64 "\n",
                dir, ngage_guest_pc(), addr, size, val);
    }
}

static uint64_t probe_read(void *opaque, hwaddr addr, unsigned size)
{
    NGageMachineState *s = opaque;

    probe_log(s, "R", addr, size, 0);
    return 0;
}

static void probe_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    NGageMachineState *s = opaque;

    probe_log(s, "W", addr, size, val);
}

static const MemoryRegionOps probe_ops = {
    .read = probe_read,
    .write = probe_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

/* ---------------------------------------------------------------- board */

static void ngage_init(MachineState *machine)
{
    NGageMachineState *s = NGAGE_MACHINE(machine);
    MemoryRegion *sysmem = get_system_memory();
    Object *cpuobj;

    cpuobj = object_new(machine->cpu_type);
    qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);
    s->cpu = ARM_CPU(cpuobj);

    if (s->probe_log) {
        s->probe_fp = fopen(s->probe_log, "w");
        if (!s->probe_fp) {
            error_report("ngage: cannot open probe log %s", s->probe_log);
            exit(1);
        }
        setvbuf(s->probe_fp, NULL, _IOLBF, 0);
    }

    if (s->upp_log) {
        FILE *fp = fopen(s->upp_log, "w");
        if (!fp) {
            error_report("ngage: cannot open register log %s", s->upp_log);
            exit(1);
        }
        setvbuf(fp, NULL, _IOLBF, 0);
        ngage_upp_set_log(fp);
    }
    if (s->quirks) {
        ngage_upp_load_quirks(s->quirks);
    }
    /* Memory controller (boot writes 0x08000000..0x08000014 first thing). */
    ngage_upp_block(sysmem, "emif", 0x08000000, 0x10000);
    /* UPP peripherals: Symbian maps 0x0C000000 at virtual 0x58000000. */
    ngage_upp_block(sysmem, "upp", 0x0C100000, 0x100000);

    /* Everything nothing else claims: log it. */
    memory_region_init_io(&s->probe, NULL, &probe_ops, s, "ngage.probe",
                          UINT64_C(0x100000000));
    memory_region_add_subregion_overlap(sysmem, 0, &s->probe, -1000);

    /* 128 Mbit mobile SDRAM: the boot code memory-tests 0x0A000000 (0x264..0x29C). */
    memory_region_init_ram(&s->sdram, NULL, "ngage.sdram", NGAGE_SDRAM_SIZE, &error_fatal);
    memory_region_add_subregion(sysmem, NGAGE_SDRAM_BASE, &s->sdram);

    /* On-chip RAM: the boot code copies its flash routines to 0x0C004748 and runs them there. */
    memory_region_init_ram(&s->iram, NULL, "ngage.iram", NGAGE_IRAM_SIZE, &error_fatal);
    memory_region_add_subregion(sysmem, NGAGE_IRAM_BASE, &s->iram);

    if (!s->flash0_path) {
        error_report("ngage: -machine flash0=<cs0 image> is required");
        exit(1);
    }
    s->flash[0] = ngage_flash_create(sysmem, "ngage.flash0", NGAGE_FLASH0_BASE,
                                     NGAGE_FLASH0_SIZE, s->flash0_path);
    s->flash[1] = ngage_flash_create(sysmem, "ngage.flash1", NGAGE_FLASH1_BASE,
                                     NGAGE_FLASH1_SIZE, s->flash1_path);
}

static char *get_flash0(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->flash0_path); }
static void set_flash0(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->flash0_path = g_strdup(v); }
static char *get_flash1(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->flash1_path); }
static void set_flash1(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->flash1_path = g_strdup(v); }
static char *get_upp(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->upp_log); }
static void set_upp(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->upp_log = g_strdup(v); }
static char *get_quirks(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->quirks); }
static void set_quirks(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->quirks = g_strdup(v); }
static char *get_probe(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->probe_log); }
static void set_probe(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->probe_log = g_strdup(v); }

static void ngage_machine_class_init(ObjectClass *oc, const void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);

    mc->desc = "Nokia N-Gage QD (RH-29, UPP_WD2)";
    mc->init = ngage_init;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("ti925t");
    mc->ignore_memory_transaction_failures = true;

    object_class_property_add_str(oc, "flash0", get_flash0, set_flash0);
    object_class_property_set_description(oc, "flash0", "CS0 NOR image (16 MB)");
    object_class_property_add_str(oc, "flash1", get_flash1, set_flash1);
    object_class_property_set_description(oc, "flash1", "CS1 NOR image (8 MB)");
    object_class_property_add_str(oc, "probe-log", get_probe, set_probe);
    object_class_property_add_str(oc, "quirks", get_quirks, set_quirks);
    object_class_property_set_description(oc, "quirks", "register read quirks file");
    object_class_property_add_str(oc, "upp-log", get_upp, set_upp);
    object_class_property_set_description(oc, "upp-log", "file that receives the first access to each register");
    object_class_property_set_description(oc, "probe-log",
                                          "file that receives every unclaimed access");
}

static const TypeInfo ngage_machine_type = {
    .name = TYPE_NGAGE_MACHINE,
    .parent = TYPE_MACHINE,
    .instance_size = sizeof(NGageMachineState),
    .class_init = ngage_machine_class_init,
    .interfaces = arm_machine_interfaces,
};

static void ngage_machine_init(void)
{
    type_register_static(&ngage_machine_type);
}

type_init(ngage_machine_init)
