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
#include "qemu/timer.h"
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
    char *flash0_save;
    char *flash1_save;
    char *probe_log;
    char *upp_log;
    char *quirks;
    char *cbus_regs;
    char *cbus_log;
    char *bt_log;
    char *rom_patches;
    char *kern_log;
    char *trace;
    char *mmc;
    char *mmc_log;
    char *lcd_log;
    char *shot_dir;
    char *screenshot;
    char *lcd_scale;
    char *lcd_id;
    char *keys;
    char *audio_wav;
    char *audio_log;
    char *log_time;
    char *pc_sample;
    FILE *pc_sample_fp;
    QEMUTimer *pc_sample_timer;
    NGageFlash *flash[2];
    MemoryRegion probe;
    MemoryRegion sdram;
    MemoryRegion iram;
    FILE *probe_fp;
    uint64_t probe_count;
    ARMCPU *cpu;
};

bool ngage_log_time;

/* Guest virtual clock in seconds (follows executed instructions under -icount). */
double ngage_guest_seconds(void)
{
    return qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1e9;
}

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

/* ---------------------------------------------------------------- PC samples */

/*
 * pc-sample=FILE: every millisecond of guest time, the guest time, PC and
 * mode of the CPU (at the block boundary where the timer runs), so busy
 * and idle stretches can be placed on the guest clock next to the logs.
 */
#define PC_SAMPLE_NS 1000000

static void pc_sample_tick(void *opaque)
{
    NGageMachineState *s = opaque;
    CPUARMState *env = &s->cpu->env;

    fprintf(s->pc_sample_fp, "%.6f %08x %02x\n", ngage_guest_seconds(),
            env->regs[15], env->uncached_cpsr & 0x1F);
    timer_mod_ns(s->pc_sample_timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + PC_SAMPLE_NS);
}

/* ---------------------------------------------------------------- board */

static void ngage_init(MachineState *machine)
{
    NGageMachineState *s = NGAGE_MACHINE(machine);
    MemoryRegion *sysmem = get_system_memory();
    Object *cpuobj;

    cpuobj = object_new(machine->cpu_type);
    qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);
    s->cpu = ARM_CPU(cpuobj);
    ngage_log_time = s->log_time && !strcmp(s->log_time, "on");

    if (s->probe_log) {
        s->probe_fp = fopen(s->probe_log, "w");
        if (!s->probe_fp) {
            error_report("ngage: cannot open probe log %s", s->probe_log);
            exit(1);
        }
        setvbuf(s->probe_fp, NULL, _IOLBF, 0);
    }

    if (s->pc_sample) {
        s->pc_sample_fp = fopen(s->pc_sample, "w");
        if (!s->pc_sample_fp) {
            error_report("ngage: cannot open PC sample file %s", s->pc_sample);
            exit(1);
        }
        setvbuf(s->pc_sample_fp, NULL, _IOFBF, 1 << 16);
        s->pc_sample_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, pc_sample_tick, s);
        timer_mod_ns(s->pc_sample_timer, PC_SAMPLE_NS);
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
    if (s->trace) {
        ngage_upp_set_trace(s->trace);
    }
    /* Memory controller (boot writes 0x08000000..0x08000014 first thing). */
    ngage_upp_block(sysmem, "emif", 0x08000000, 0x10000);
    /* UPP peripherals: Symbian maps 0x0C000000 at virtual 0x58000000. */
    ngage_upp_block(sysmem, "upp", 0x0C100000, 0x100000);

    ngage_intc_create(sysmem, qdev_get_gpio_in(DEVICE(s->cpu), ARM_CPU_IRQ),
                      qdev_get_gpio_in(DEVICE(s->cpu), ARM_CPU_FIQ));
    {
        FILE *cl = NULL;
        if (s->cbus_log) {
            cl = fopen(s->cbus_log, "w");
            if (cl) {
                setvbuf(cl, NULL, _IOLBF, 0);
            }
        }
        ngage_cbus_create(sysmem, s->cbus_regs, cl);
    }
    {
        FILE *bl = NULL;
        if (s->bt_log) {
            bl = fopen(s->bt_log, "w");
            if (bl) {
                setvbuf(bl, NULL, _IOLBF, 0);
            }
        }
        ngage_bt_create(sysmem, bl);
    }

    {
        FILE *kl = NULL;
        if (s->kern_log) {
            kl = fopen(s->kern_log, "w");
            if (kl) {
                setvbuf(kl, NULL, _IOLBF, 0);
            }
        }
        ngage_sti_create(sysmem, kl);
    }

    {
        FILE *ml = NULL;
        if (s->mmc_log) {
            ml = fopen(s->mmc_log, "w");
            if (ml) {
                setvbuf(ml, NULL, _IOLBF, 0);
            }
        }
        ngage_mmc_create(sysmem, s->mmc, ml);
        ngage_dma_create(sysmem, ml);
    }
    {
        FILE *ll = NULL;
        if (s->lcd_log) {
            ll = fopen(s->lcd_log, "w");
            if (ll) {
                setvbuf(ll, NULL, _IOFBF, 1 << 16);
            }
        }
        ngage_keypad_create(sysmem, s->keys, ll);
        ngage_lcd_create(sysmem, ll, s->shot_dir,
                         s->screenshot ? atoi(s->screenshot) : -1,
                         s->lcd_scale ? atoi(s->lcd_scale) : 2,
                         s->lcd_id ? strtoul(s->lcd_id, NULL, 0) : 0x290000);
    }

    {
        FILE *al = NULL;
        AudioBackend *be = NULL;
        if (s->audio_log) {
            al = fopen(s->audio_log, "w");
            if (al) {
                setvbuf(al, NULL, _IOLBF, 0);
            }
        }
        if (machine->audiodev) {
            be = audio_be_by_name(machine->audiodev, &error_fatal);
        }
        ngage_audio_create(sysmem, be, s->audio_wav, al);
    }

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
                                     NGAGE_FLASH0_SIZE, s->flash0_path, s->flash0_save);
    s->flash[1] = ngage_flash_create(sysmem, "ngage.flash1", NGAGE_FLASH1_BASE,
                                     NGAGE_FLASH1_SIZE, s->flash1_path, s->flash1_save);
    ngage_cbus_set_cs1(s->flash[1]);
    if (s->rom_patches) {
        ngage_apply_rom_patches(s->rom_patches, s->flash[0], s->flash[1]);
    }
}

static char *get_flash0(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->flash0_path); }
static void set_flash0(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->flash0_path = g_strdup(v); }
static char *get_flash1(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->flash1_path); }
static void set_flash1(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->flash1_path = g_strdup(v); }
static char *get_save0(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->flash0_save); }
static void set_save0(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->flash0_save = g_strdup(v); }
static char *get_save1(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->flash1_save); }
static void set_save1(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->flash1_save = g_strdup(v); }
static char *get_upp(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->upp_log); }
static void set_upp(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->upp_log = g_strdup(v); }
static char *get_quirks(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->quirks); }
static void set_quirks(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->quirks = g_strdup(v); }
static char *get_cbusregs(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->cbus_regs); }
static void set_cbusregs(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->cbus_regs = g_strdup(v); }
static char *get_cbuslog(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->cbus_log); }
static void set_cbuslog(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->cbus_log = g_strdup(v); }
static char *get_btlog(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->bt_log); }
static void set_btlog(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->bt_log = g_strdup(v); }
static char *get_patches(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->rom_patches); }
static void set_patches(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->rom_patches = g_strdup(v); }
static char *get_kernlog(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->kern_log); }
static void set_kernlog(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->kern_log = g_strdup(v); }
static char *get_trace(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->trace); }
static void set_trace(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->trace = g_strdup(v); }
static char *get_mmc(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->mmc); }
static void set_mmc(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->mmc = g_strdup(v); }
static char *get_mmclog(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->mmc_log); }
static void set_mmclog(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->mmc_log = g_strdup(v); }
static char *get_lcd_log(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->lcd_log); }
static void set_lcd_log(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->lcd_log = g_strdup(v); }
static char *get_shot_dir(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->shot_dir); }
static void set_shot_dir(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->shot_dir = g_strdup(v); }
static char *get_screenshot(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->screenshot); }
static void set_screenshot(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->screenshot = g_strdup(v); }
static char *get_lcd_scale(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->lcd_scale); }
static void set_lcd_scale(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->lcd_scale = g_strdup(v); }
static char *get_lcd_id(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->lcd_id); }
static void set_lcd_id(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->lcd_id = g_strdup(v); }
static char *get_keys(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->keys); }
static void set_keys(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->keys = g_strdup(v); }
static char *get_audio_wav(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->audio_wav); }
static void set_audio_wav(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->audio_wav = g_strdup(v); }
static char *get_audio_log(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->audio_log); }
static void set_audio_log(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->audio_log = g_strdup(v); }
static char *get_log_time(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->log_time); }
static void set_log_time(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->log_time = g_strdup(v); }
static char *get_pc_sample(Object *o, Error **e) { return g_strdup(NGAGE_MACHINE(o)->pc_sample); }
static void set_pc_sample(Object *o, const char *v, Error **e) { NGAGE_MACHINE(o)->pc_sample = g_strdup(v); }
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
    object_class_property_add_str(oc, "flash0-save", get_save0, set_save0);
    object_class_property_set_description(oc, "flash0-save",
                                          "CS0 contents: loaded instead of flash0 if present, written on exit after changes");
    object_class_property_add_str(oc, "flash1-save", get_save1, set_save1);
    object_class_property_set_description(oc, "flash1-save",
                                          "CS1 contents (C: drive at 0x400000): loaded instead of flash1 if present, written on exit after changes");
    object_class_property_add_str(oc, "probe-log", get_probe, set_probe);
    object_class_property_add_str(oc, "cbus-regs", get_cbusregs, set_cbusregs);
    object_class_property_set_description(oc, "cbus-regs", "CBUS device register initial values");
    object_class_property_add_str(oc, "cbus-log", get_cbuslog, set_cbuslog);
    object_class_property_set_description(oc, "cbus-log", "file that receives every CBUS transaction");
    object_class_property_add_str(oc, "bt-log", get_btlog, set_btlog);
    object_class_property_set_description(oc, "bt-log", "file that receives the Bluetooth module's resets and HCI packets");
    object_class_property_add_str(oc, "lcd-log", get_lcd_log, set_lcd_log);
    object_class_property_set_description(oc, "lcd-log", "file that receives LCD commands");
    object_class_property_add_str(oc, "shot-dir", get_shot_dir, set_shot_dir);
    object_class_property_set_description(oc, "shot-dir", "directory for LCD screenshots");
    object_class_property_add_str(oc, "screenshot", get_screenshot, set_screenshot);
    object_class_property_set_description(oc, "screenshot", "LCD screenshot period in guest seconds (0 = on exit only)");
    object_class_property_add_str(oc, "lcd-scale", get_lcd_scale, set_lcd_scale);
    object_class_property_set_description(oc, "lcd-scale", "LCD console magnification (default 2)");
    object_class_property_add_str(oc, "lcd-id", get_lcd_id, set_lcd_id);
    object_class_property_set_description(oc, "lcd-id", "panel RDDID value (default 0x290000: module 0x10)");
    object_class_property_add_str(oc, "keys", get_keys, set_keys);
    object_class_property_set_description(oc, "keys", "key script: lines '<guest seconds> down|up <key>'");
    object_class_property_add_str(oc, "audio-wav", get_audio_wav, set_audio_wav);
    object_class_property_set_description(oc, "audio-wav", "WAV file that receives what the HLE audio device plays");
    object_class_property_add_str(oc, "audio-log", get_audio_log, set_audio_log);
    object_class_property_set_description(oc, "audio-log", "file that receives HLE audio device events");
    machine_add_audiodev_property(mc);
    object_class_property_add_str(oc, "mmc", get_mmc, set_mmc);
    object_class_property_set_description(oc, "mmc", "game card image (raw); CID/CSD from <image>.cid/.csd");
    object_class_property_add_str(oc, "mmc-log", get_mmclog, set_mmclog);
    object_class_property_set_description(oc, "mmc-log", "file that receives every MMC command");
    object_class_property_add_str(oc, "trace", get_trace, set_trace);
    object_class_property_set_description(oc, "trace", "lo-hi[:lo-hi]: log every register access in these physical ranges");
    object_class_property_add_str(oc, "kern-log", get_kernlog, set_kernlog);
    object_class_property_set_description(oc, "kern-log", "file that receives the kernel's STI debug text");
    object_class_property_add_str(oc, "log-time", get_log_time, set_log_time);
    object_class_property_set_description(oc, "log-time",
                                          "on: kern.log one line per message and cbus.log lines, each led by the guest time in seconds");
    object_class_property_add_str(oc, "pc-sample", get_pc_sample, set_pc_sample);
    object_class_property_set_description(oc, "pc-sample",
                                          "file that receives the guest time, PC and mode every guest millisecond");
    object_class_property_add_str(oc, "rom-patches", get_patches, set_patches);
    object_class_property_set_description(oc, "rom-patches", "model shortcuts applied to the flash contents");
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
