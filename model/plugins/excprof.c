// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * excprof: a QEMU TCG plugin for the reference model. It logs every
 * exception and interrupt the guest CPU takes and every write to a CP15
 * register, each with the number of instructions executed so far, so that
 * a run can be read back as kernel calls, process switches and cache and
 * TLB flushes per second (model/tools/excstat.py).
 *
 *   NGAGE_EXCLOG=FILE model/run.sh ...     (-plugin excprof,out=FILE)
 *   NGAGE_EXCLOG=FILE,footprint=on         also the footprint records below
 *
 * FILE holds 24-byte little-endian records
 *   { u64 instructions; u32 pc; u32 to; u32 word; u32 value; }
 * An exception: to is the vector the CPU went to and value the CPSR after
 * the entry. pc is what QEMU reports as the source: the instruction itself
 * for an abort or an undefined instruction, the next instruction for an
 * interrupt and for a SWI (its return address). word is the SWI instruction
 * for a SWI (found before pc: an ARM "svc" word, or 0x0000DFnn for a Thumb
 * one), else the 32 bits at pc.
 * A CP15 write (MCR p15) that is executed (its condition is checked here:
 * QEMU calls a plugin for a conditional instruction whether or not it runs):
 * to = 0xFFFFFFFE, word the instruction, value the register written, pc the
 * instruction's address.
 * With footprint=on, each whole D-TLB invalidation (c8,c6,0: the kernel's
 * process switch) is followed by a record with to = 0xFFFFFFFD: what ran
 * since the one before, as pc = distinct 16-byte code lines executed, word
 * = distinct 4 KB code pages, value = distinct 4 KB data pages read or
 * written. TLBs of any size have to walk at least those pages again after
 * the kernel's invalidation. (This slows the model several times.)
 * The last record has to = 0xFFFFFFFF and the final instruction count.
 *
 * With the model's default -icount shift=4 an instruction is 16 ns of guest
 * time, and the firmware never halts the CPU (the NOS stand-in's idle is a
 * loop), so guest seconds = instructions / 62.5 million.
 */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <glib.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

typedef struct {
    uint64_t n;
    uint32_t pc, to, word, value;
} Event;

static FILE *fp;
static struct qemu_plugin_scoreboard *score;
static qemu_plugin_u64 insns;
static struct qemu_plugin_register *cpsr_reg;
static struct qemu_plugin_register *gpr[16];
static GByteArray *buf;

/* footprint=on: generation stamps by code line, code page and data page */
static bool footprint;
static uint16_t *line_gen, *cpage_gen, *dpage_gen;
static uint16_t gen = 1;
static uint32_t lines, cpages, dpages;

typedef struct {
    uint32_t first, last;       /* the block's first and last 16-byte line */
} Block;

static void footprint_flush(uint64_t n)
{
    Event e = { .n = n, .pc = lines, .to = 0xFFFFFFFDu, .word = cpages, .value = dpages };
    fwrite(&e, sizeof(e), 1, fp);
    lines = cpages = dpages = 0;
    if (++gen == 0) {
        memset(line_gen, 0, sizeof(uint16_t) << 28);
        memset(cpage_gen, 0, sizeof(uint16_t) << 20);
        memset(dpage_gen, 0, sizeof(uint16_t) << 20);
        gen = 1;
    }
}

static void block_exec(unsigned int vcpu, void *udata)
{
    const Block *b = udata;
    for (uint32_t l = b->first; l <= b->last; l++) {
        if (line_gen[l] != gen) {
            line_gen[l] = gen;
            lines++;
            if (cpage_gen[l >> 8] != gen) {
                cpage_gen[l >> 8] = gen;
                cpages++;
            }
        }
    }
}

static void mem_access(unsigned int vcpu, qemu_plugin_meminfo_t info, uint64_t vaddr, void *udata)
{
    uint32_t page = (uint32_t)vaddr >> 12;
    if (dpage_gen[page] != gen) {
        dpage_gen[page] = gen;
        dpages++;
    }
}

static bool read_reg(struct qemu_plugin_register *reg, uint32_t *out)
{
    if (!reg) {
        return false;
    }
    g_byte_array_set_size(buf, 0);
    if (!qemu_plugin_read_register(reg, buf) || buf->len < 4) {
        return false;
    }
    memcpy(out, buf->data, 4);
    return true;
}

static bool read_mem(uint64_t addr, uint32_t *out)
{
    g_byte_array_set_size(buf, 0);
    if (!qemu_plugin_read_memory_vaddr(addr, buf, 4) || buf->len < 4) {
        return false;
    }
    memcpy(out, buf->data, 4);
    return true;
}

/* The ARM condition field against the CPSR's flags. */
static bool condition(uint32_t cond, uint32_t cpsr)
{
    bool n = cpsr >> 31, z = (cpsr >> 30) & 1, c = (cpsr >> 29) & 1, v = (cpsr >> 28) & 1, r;
    switch (cond >> 1) {
    case 0: r = z; break;
    case 1: r = c; break;
    case 2: r = n; break;
    case 3: r = v; break;
    case 4: r = c && !z; break;
    case 5: r = n == v; break;
    case 6: r = !z && n == v; break;
    default: return true;
    }
    return r != (cond & 1);
}

static void cp15_write(unsigned int vcpu, void *udata)
{
    uint32_t word = (uint32_t)(uintptr_t)udata, cpsr = 0;
    Event e = { .n = qemu_plugin_u64_get(insns, vcpu), .to = 0xFFFFFFFEu, .word = word };
    if ((word >> 28) != 14 && read_reg(cpsr_reg, &cpsr) && !condition(word >> 28, cpsr)) {
        return;
    }
    read_reg(gpr[(word >> 12) & 15], &e.value);
    read_reg(gpr[15], &e.pc);
    fwrite(&e, sizeof(e), 1, fp);
    if (footprint && (word & 0x0FFF0FFF) == 0x0E080F16) {      /* c8,c6,0 */
        footprint_flush(e.n);
    }
}

static void tb_trans(struct qemu_plugin_tb *tb, void *udata)
{
    size_t n = qemu_plugin_tb_n_insns(tb);
    for (size_t i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint32_t word = 0;
        /* MCR p15 (ARM state only: ARMv5T Thumb has no coprocessor access) */
        if (qemu_plugin_insn_size(insn) == 4 && qemu_plugin_insn_data(insn, &word, 4) == 4 &&
            (word & 0x0F100F10) == 0x0E000F10) {
            qemu_plugin_register_vcpu_insn_exec_cb(insn, cp15_write, QEMU_PLUGIN_CB_R_REGS,
                                                   (void *)(uintptr_t)word);
        }
        if (footprint) {
            qemu_plugin_register_vcpu_mem_cb(insn, mem_access, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_MEM_RW, NULL);
        }
    }
    if (footprint && n) {
        struct qemu_plugin_insn *end = qemu_plugin_tb_get_insn(tb, n - 1);
        Block *b = g_new(Block, 1);         /* lives as long as the translation */
        b->first = (uint32_t)qemu_plugin_tb_vaddr(tb) >> 4;
        b->last = (uint32_t)(qemu_plugin_insn_vaddr(end) + qemu_plugin_insn_size(end) - 1) >> 4;
        qemu_plugin_register_vcpu_tb_exec_cb(tb, block_exec, QEMU_PLUGIN_CB_NO_REGS, b);
    }
    qemu_plugin_register_vcpu_tb_exec_inline_per_vcpu(tb, QEMU_PLUGIN_INLINE_ADD_U64, insns, n);
}

static void discon(unsigned int vcpu, enum qemu_plugin_discon_type type, uint64_t from_pc,
                   uint64_t to_pc, void *udata)
{
    Event e = { .n = qemu_plugin_u64_get(insns, vcpu), .pc = (uint32_t)from_pc, .to = (uint32_t)to_pc };
    read_reg(cpsr_reg, &e.value);
    if ((to_pc & 0x1C) == 0x08) {
        /* a SWI: from_pc is its return address */
        uint32_t w = 0;
        if (!(from_pc & 2) && read_mem(from_pc - 4, &w) && (w >> 24) != 0xDF && (w & 0x0F000000) == 0x0F000000) {
            e.word = w;
        } else if (read_mem((from_pc - 2) & ~3ull, &w)) {
            uint32_t half = (from_pc - 2) & 2 ? w >> 16 : w & 0xFFFF;
            e.word = (half & 0xFF00) == 0xDF00 ? half : 0;
        }
    } else {
        read_mem(from_pc & ~3ull, &e.word);
    }
    fwrite(&e, sizeof(e), 1, fp);
}

static void vcpu_init(unsigned int vcpu, void *udata)
{
    static const char *const names[16] = { "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9",
                                             "r10", "r11", "r12", "sp", "lr", "pc" };
    g_autoptr(GArray) regs = qemu_plugin_get_registers();
    for (guint i = 0; i < regs->len; i++) {
        qemu_plugin_reg_descriptor *d = &g_array_index(regs, qemu_plugin_reg_descriptor, i);
        if (!strcmp(d->name, "cpsr")) {
            cpsr_reg = d->handle;
        }
        for (int k = 0; k < 16; k++) {
            if (!strcmp(d->name, names[k])) {
                gpr[k] = d->handle;
            }
        }
    }
}

static void at_exit(void *udata)
{
    Event e = { .n = qemu_plugin_u64_sum(insns), .to = 0xFFFFFFFFu };
    fwrite(&e, sizeof(e), 1, fp);
    fclose(fp);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv)
{
    const char *out = "excprof.bin";
    for (int i = 0; i < argc; i++) {
        if (g_str_has_prefix(argv[i], "out=")) {
            out = argv[i] + 4;
        } else if (!strcmp(argv[i], "footprint=on")) {
            footprint = true;
        }
    }
    fp = fopen(out, "wb");
    if (!fp) {
        fprintf(stderr, "excprof: cannot open %s\n", out);
        return -1;
    }
    setvbuf(fp, NULL, _IOFBF, 1 << 20);
    buf = g_byte_array_new();
    if (footprint) {
        line_gen = g_malloc0(sizeof(uint16_t) << 28);
        cpage_gen = g_malloc0(sizeof(uint16_t) << 20);
        dpage_gen = g_malloc0(sizeof(uint16_t) << 20);
    }
    score = qemu_plugin_scoreboard_new(sizeof(uint64_t));
    insns = qemu_plugin_scoreboard_u64(score);
    qemu_plugin_register_vcpu_init_cb(id, vcpu_init, NULL);
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans, NULL);
    qemu_plugin_register_vcpu_discon_cb(id, QEMU_PLUGIN_DISCON_ALL, discon, NULL);
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
