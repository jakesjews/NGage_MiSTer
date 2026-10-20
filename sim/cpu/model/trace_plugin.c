/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * QEMU TCG plugin for comparing the reference model with the RTL boot
 * bench: an instruction trace of a window of the run, with the registers
 * before each instruction, the interrupts and exceptions taken, and the
 * device accesses (physical 0x08000000-0x0DFFFFFF without SDRAM and
 * on-chip RAM).
 *
 *   -plugin libtrace_plugin.so,start=N,count=M,out=FILE[,regs=0][,insns=0][,stop=1][,flashw=1]
 *
 * Lines: "I n pc r0 .. r14 cpsr" (instruction n, about to execute; without
 * regs only "I n pc"; insns=0 leaves them out), "X n kind from to"
 * (interrupt or exception), "M n R|W size pa value pc" (device access;
 * flashw=1 adds the writes below 0x08000000, i.e. flash commands). n
 * counts executed instructions from reset, as -icount does. stop=1 raises
 * SIGINT after the window (run_model.sh's timeout ends the run anyway).
 *
 * Caveats: QEMU shares a translation block between the virtual aliases of a
 * page, so the PC reported is the one the block was first translated at
 * (the kernel runs ROM code both at 0x5000xxxx and through its alias at 0);
 * register values read in the callback were seen to lag behind in such
 * code, so sim/cpu/boot/cmp_window.py --pc-only compares PCs alone.
 */
#include <glib.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

static uint64_t start, count = 1000000, n;
static int with_regs = 1, with_insns = 1, stop, flash_writes;
static FILE *out;
static struct qemu_plugin_register *reg[17];
static GByteArray *buf;

static uint32_t rd(int i)
{
    uint32_t v = 0;

    if (!reg[i]) {
        return 0;
    }
    g_byte_array_set_size(buf, 0);
    if (qemu_plugin_read_register(reg[i], buf) && buf->len >= 4) {
        memcpy(&v, buf->data, 4);
    }
    return v;
}

static bool in_window(void)
{
    return n >= start && n < start + count;
}

static void insn_exec(unsigned int vcpu, void *udata)
{
    n++;
    if (!in_window()) {
        if (stop == 1 && n >= start + count) {
            stop = 2;
            fprintf(out, "E %" PRIu64 "\n", n);
            fflush(out);
            raise(SIGINT);
        }
        return;
    }
    if (!with_insns) {
        return;
    }
    fprintf(out, "I %" PRIu64 " %08" PRIx32, n, (uint32_t)(uintptr_t)udata);
    if (with_regs) {
        for (int i = 0; i < 15; i++) {
            fprintf(out, " %08" PRIx32, rd(i));
        }
        fprintf(out, " %08" PRIx32, rd(16));
    }
    fputc('\n', out);
}

static void mem_cb(unsigned int vcpu, qemu_plugin_meminfo_t info, uint64_t va, void *udata)
{
    struct qemu_plugin_hwaddr *hw;
    uint64_t pa;

    if (!in_window()) {
        return;
    }
    hw = qemu_plugin_get_hwaddr(info, va);
    if (!hw) {
        return;
    }
    pa = qemu_plugin_hwaddr_phys_addr(hw);
    if (pa < 0x08000000 && flash_writes && qemu_plugin_mem_is_store(info)) {
        /* a flash command: logged below */
    } else if (pa < 0x08000000 || pa >= 0x0E000000 ||     /* devices only: */
        (pa >= 0x0A000000 && pa < 0x0B000000) ||          /* not SDRAM */
        (pa >= 0x0C000000 && pa < 0x0C040000)) {          /* not on-chip RAM */
        return;
    }
    {
        qemu_plugin_mem_value v = qemu_plugin_mem_get_value(info);
        uint64_t val = v.type == QEMU_PLUGIN_MEM_VALUE_U8 ? v.data.u8 :
                       v.type == QEMU_PLUGIN_MEM_VALUE_U16 ? v.data.u16 :
                       v.type == QEMU_PLUGIN_MEM_VALUE_U32 ? v.data.u32 : v.data.u64;
        fprintf(out, "M %" PRIu64 " %c %u %08" PRIx64 " %08" PRIx64 " %08" PRIx32 "\n", n,
                qemu_plugin_mem_is_store(info) ? 'W' : 'R',
                1u << qemu_plugin_mem_size_shift(info), pa, val, (uint32_t)(uintptr_t)udata);
    }
}

static void tb_trans(struct qemu_plugin_tb *tb, void *udata)
{
    size_t ni = qemu_plugin_tb_n_insns(tb);

    for (size_t i = 0; i < ni; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        void *pc = (void *)(uintptr_t)qemu_plugin_insn_vaddr(insn);
        qemu_plugin_register_vcpu_insn_exec_cb(insn, insn_exec,
                                               with_regs ? QEMU_PLUGIN_CB_R_REGS : QEMU_PLUGIN_CB_NO_REGS, pc);
        qemu_plugin_register_vcpu_mem_cb(insn, mem_cb, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_MEM_RW, pc);
    }
}

static void discon(unsigned int vcpu, enum qemu_plugin_discon_type type, uint64_t from,
                   uint64_t to, void *udata)
{
    if (in_window()) {
        fprintf(out, "X %" PRIu64 " %s %08" PRIx64 " %08" PRIx64 "\n", n,
                type == QEMU_PLUGIN_DISCON_INTERRUPT ? "int" :
                type == QEMU_PLUGIN_DISCON_EXCEPTION ? "exc" : "host", from, to);
    }
}

static void vcpu_init(unsigned int vcpu, void *udata)
{
    static const char *names[17] = { "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8",
                                     "r9", "r10", "r11", "r12", "sp", "lr", "pc", "cpsr" };
    GArray *regs = qemu_plugin_get_registers();

    for (guint i = 0; i < regs->len; i++) {
        qemu_plugin_reg_descriptor *d = &g_array_index(regs, qemu_plugin_reg_descriptor, i);
        for (int j = 0; j < 17; j++) {
            if (!strcmp(d->name, names[j])) {
                reg[j] = d->handle;
            }
        }
    }
    g_array_free(regs, TRUE);
}

static void at_exit(void *p)
{
    fprintf(out, "E %" PRIu64 "\n", n);
    fclose(out);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info,
                                           int argc, char **argv)
{
    const char *path = "trace.txt";

    for (int i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "start=", 6)) {
            start = strtoull(argv[i] + 6, NULL, 0);
        } else if (!strncmp(argv[i], "count=", 6)) {
            count = strtoull(argv[i] + 6, NULL, 0);
        } else if (!strncmp(argv[i], "out=", 4)) {
            path = argv[i] + 4;
        } else if (!strncmp(argv[i], "regs=", 5)) {
            with_regs = atoi(argv[i] + 5);
        } else if (!strncmp(argv[i], "insns=", 6)) {
            with_insns = atoi(argv[i] + 6);
        } else if (!strncmp(argv[i], "stop=", 5)) {
            stop = atoi(argv[i] + 5);
        } else if (!strncmp(argv[i], "flashw=", 7)) {
            flash_writes = atoi(argv[i] + 7);
        }
    }
    out = fopen(path, "w");
    if (!out) {
        return -1;
    }
    buf = g_byte_array_new();
    qemu_plugin_register_vcpu_init_cb(id, vcpu_init, NULL);
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans, NULL);
    if (!with_insns) {
        with_regs = 0;
    }
    qemu_plugin_register_vcpu_discon_cb(id, QEMU_PLUGIN_DISCON_ALL, discon, NULL);
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
