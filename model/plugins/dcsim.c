// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dcsim: a QEMU TCG plugin for the reference model. Every data access
 * outside device memory goes through a set of simulated data caches, so a
 * run tells how the core's cache (32 KB, two ways, 16-byte lines), the
 * phone's (8 KB) and other sizes, line lengths and a next-line prefetch
 * would do on the same accesses (model/tools/dcstat.py prints the report).
 *
 *   NGAGE_DCSIM=FILE,t0=SEC,t1=SEC model/run.sh ...
 *
 * The caches are virtually indexed and tagged with LRU replacement; a load
 * miss fills a line, a store miss does not (the core posts it), a store hit
 * makes the line dirty and a dirty victim counts as a write-back. The
 * kernel's invalidations are applied: the whole cache for c7,c6,0, c7,c7,0
 * and each c7,c14,2 (its clean-and-invalidate loop goes through every
 * index), one line for c7,c6,1 and c7,c14,1. Prefetch variants fetch the
 * next line (never across a 4 KB page): on every miss; "tagged", also on
 * the first use of a prefetched line; only on a miss whose previous line is
 * in the cache; and "stream", the last two together.
 *
 * Counters cover guest seconds t0 to t1 (instructions / 62.5 million with
 * the model's default -icount shift=4); the caches run from the start. FILE
 * is text, written at t1 and at exit:
 *   window N0 N1 N           the instruction counts
 *   uncached LOADS STORES    accesses to device memory
 *   cache|name|loads|stores|load misses|store misses|write-backs|
 *         prefetches|prefetched lines used|evicted unused|invalidations
 *   seq UP DOWN BOTH         first cache's load misses with the line
 *                            before, the line after, or both in the cache
 *   region MB LOADS STORES MISSES   per 1 MB of virtual address (hex)
 *   pc ADDRESS MISSES        first cache's load misses by instruction
 * With these callbacks the model ran at about a third of real time.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glib.h>
#include <qemu-plugin.h>
QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

typedef struct { uint32_t tag, gen, stamp; uint8_t dirty, pf; } Ent;
typedef struct {
    const char *name;
    uint32_t bytes, ways, shift;
    int pf;                 /* 0 none, 1 next line on a miss, 2 tagged (miss or first use of a prefetched line),
                               3 on a miss whose previous line is present, 4 = 3 + tagged */
    int noflush;
    uint32_t sets, gen, clock;
    Ent *e;
    uint64_t loads, stores, lmiss, smiss, wb, pfi, pfu, pfx, flushes;
} Cache;

static Cache caches[] = {
    { "32K 2-way 16B (core)",        32768, 2, 4, 0, 0 },
    { "8K 2-way 16B (phone)",         8192, 2, 4, 0, 0 },
    { "16K 2-way 16B",               16384, 2, 4, 0, 0 },
    { "32K 4-way 16B",               32768, 4, 4, 0, 0 },
    { "32K 8-way 16B",               32768, 8, 4, 0, 0 },
    { "64K 2-way 16B",               65536, 2, 4, 0, 0 },
    { "128K 2-way 16B",             131072, 2, 4, 0, 0 },
    { "4M 8-way 16B (no capacity)", 4194304, 8, 4, 0, 0 },
    { "32K 2-way 32B",               32768, 2, 5, 0, 0 },
    { "32K 2-way 64B",               32768, 2, 6, 0, 0 },
    { "32K 2-way 16B never flushed", 32768, 2, 4, 0, 1 },
    { "32K 2-way 16B +next on miss", 32768, 2, 4, 1, 0 },
    { "32K 2-way 16B +tagged next",  32768, 2, 4, 2, 0 },
    { "32K 2-way 16B +next if seq",  32768, 2, 4, 3, 0 },
    { "32K 2-way 16B +stream",       32768, 2, 4, 4, 0 },
    { "8K 2-way 16B +stream",         8192, 2, 4, 4, 0 },
};
#define NC (sizeof caches / sizeof caches[0])

static FILE *fp;
static const char *outname = "dcsim.txt";
static struct qemu_plugin_scoreboard *score;
static qemu_plugin_u64 insns;
static struct qemu_plugin_register *cpsr_reg, *gpr[16];
static GByteArray *buf;
static uint64_t n0, n1 = UINT64_MAX;
static bool counting, done;
static uint8_t *pagekind;               /* per 4 KB virtual page: 0 unknown, 1 memory, 2 device */
static uint64_t unc_loads, unc_stores, seq_up, seq_dn, seq_both;
static uint64_t region_miss[4096], region_load[4096], region_store[4096];
static GHashTable *pc_miss;

static inline Ent *find(Cache *c, uint32_t line)
{
    Ent *s = &c->e[(line & (c->sets - 1)) * c->ways];
    for (uint32_t w = 0; w < c->ways; w++) {
        if (s[w].gen == c->gen && s[w].tag == line) return &s[w];
    }
    return NULL;
}

static void install(Cache *c, uint32_t line, int pf)
{
    Ent *s = &c->e[(line & (c->sets - 1)) * c->ways], *v = NULL;
    for (uint32_t w = 0; w < c->ways; w++) {
        if (s[w].gen != c->gen) { v = &s[w]; break; }
        if (!v || s[w].stamp < v->stamp) v = &s[w];
    }
    if (v->gen == c->gen && counting) {
        if (v->dirty) c->wb++;
        if (v->pf) c->pfx++;
    }
    v->tag = line; v->gen = c->gen; v->stamp = ++c->clock; v->dirty = 0; v->pf = pf;
}

static void prefetch(Cache *c, uint32_t line)
{
    if (((line << c->shift) & 0xFFF) == 0 || find(c, line)) return;     /* not across a page */
    install(c, line, 1);
    if (counting) c->pfi++;
}

static inline void touch(Cache *c, uint32_t va, bool store, uint32_t pc, bool first)
{
    uint32_t line = va >> c->shift;
    Ent *e = find(c, line);
    if (counting) { if (store) c->stores++; else c->loads++; }
    if (e) {
        e->stamp = ++c->clock;
        if (store) e->dirty = 1;
        if (e->pf) {
            e->pf = 0;
            if (counting) c->pfu++;
            if (c->pf == 2 || c->pf == 4) prefetch(c, line + 1);
        }
        return;
    }
    if (store) { if (counting) c->smiss++; return; }
    bool up = find(c, line - 1) != NULL;
    if (counting) {
        c->lmiss++;
        if (first) {
            bool dn = find(c, line + 1) != NULL;
            if (up && dn) seq_both++; else if (up) seq_up++; else if (dn) seq_dn++;
            region_miss[va >> 20]++;
            gpointer k = GUINT_TO_POINTER(pc);
            g_hash_table_insert(pc_miss, k, GUINT_TO_POINTER(GPOINTER_TO_UINT(g_hash_table_lookup(pc_miss, k)) + 1));
        }
    }
    install(c, line, 0);
    if (c->pf == 1 || c->pf == 2 || ((c->pf == 3 || c->pf == 4) && up)) prefetch(c, line + 1);
}

static gint by_count(gconstpointer a, gconstpointer b, gpointer t)
{
    guint x = GPOINTER_TO_UINT(g_hash_table_lookup(t, a)), y = GPOINTER_TO_UINT(g_hash_table_lookup(t, b));
    return x < y ? 1 : x > y ? -1 : 0;
}

static void report(uint64_t n)
{
    if (done) return;
    done = true;
    fp = fopen(outname, "w");
    if (!fp) return;
    fprintf(fp, "window %" PRIu64 " %" PRIu64 " %" PRIu64 "\n", n0, n < n1 ? n : n1, n);
    fprintf(fp, "uncached %" PRIu64 " %" PRIu64 "\n", unc_loads, unc_stores);
    for (size_t i = 0; i < NC; i++) {
        Cache *c = &caches[i];
        fprintf(fp, "cache|%s|%" PRIu64 "|%" PRIu64 "|%" PRIu64 "|%" PRIu64 "|%" PRIu64 "|%" PRIu64 "|%" PRIu64 "|%" PRIu64 "|%" PRIu64 "\n",
                c->name, c->loads, c->stores, c->lmiss, c->smiss, c->wb, c->pfi, c->pfu, c->pfx, c->flushes);
    }
    fprintf(fp, "seq %" PRIu64 " %" PRIu64 " %" PRIu64 "\n", seq_up, seq_dn, seq_both);
    for (int r = 0; r < 4096; r++) {
        if (region_load[r] || region_store[r] || region_miss[r]) {
            fprintf(fp, "region %03x %" PRIu64 " %" PRIu64 " %" PRIu64 "\n", r, region_load[r], region_store[r], region_miss[r]);
        }
    }
    GList *keys = g_list_sort_with_data(g_hash_table_get_keys(pc_miss), by_count, pc_miss);
    int k = 0;
    for (GList *l = keys; l; l = l->next) {
        fprintf(fp, "pc %08x %u\n", GPOINTER_TO_UINT(l->data), GPOINTER_TO_UINT(g_hash_table_lookup(pc_miss, l->data)));
        if (++k >= 4000) break;
    }
    g_list_free(keys);
    fclose(fp);
}

static void mem(unsigned int vcpu, qemu_plugin_meminfo_t info, uint64_t vaddr, void *udata)
{
    uint32_t va = (uint32_t)vaddr, pc = (uint32_t)(uintptr_t)udata;
    bool store = qemu_plugin_mem_is_store(info);
    uint64_t n = qemu_plugin_u64_get(insns, vcpu);
    counting = n >= n0 && n < n1;
    if (n >= n1) { report(n); return; }
    uint8_t *pk = &pagekind[va >> 12];
    if (!*pk) {
        struct qemu_plugin_hwaddr *hw = qemu_plugin_get_hwaddr(info, vaddr);
        *pk = hw && qemu_plugin_hwaddr_is_io(hw) ? 2 : 1;
    }
    if (*pk == 2) {
        if (counting) { if (store) unc_stores++; else unc_loads++; }
        return;
    }
    if (counting) { if (store) region_store[va >> 20]++; else region_load[va >> 20]++; }
    for (size_t i = 0; i < NC; i++) touch(&caches[i], va, store, pc, i == 0);
}

static bool read_reg(struct qemu_plugin_register *reg, uint32_t *out)
{
    if (!reg) return false;
    g_byte_array_set_size(buf, 0);
    if (!qemu_plugin_read_register(reg, buf) || buf->len < 4) return false;
    memcpy(out, buf->data, 4);
    return true;
}

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

static void cp15(unsigned int vcpu, void *udata)
{
    uint32_t word = (uint32_t)(uintptr_t)udata, cpsr = 0, val = 0, op = word & 0x0FFF0FFF;
    if ((word >> 28) != 14 && read_reg(cpsr_reg, &cpsr) && !condition(word >> 28, cpsr)) return;
    bool whole = op == 0x0E070F16 || op == 0x0E070F17 || op == 0x0E070F5E;
    bool line = op == 0x0E070F36 || op == 0x0E070F3E;
    if (!whole && !line) return;
    if (line) read_reg(gpr[(word >> 12) & 15], &val);
    for (size_t i = 0; i < NC; i++) {
        Cache *c = &caches[i];
        if (c->noflush) continue;
        if (whole) {
            c->gen++;
            if (counting) c->flushes++;
        } else {
            Ent *e = find(c, val >> c->shift);
            if (e) e->gen = c->gen - 1;
        }
    }
}

static void tb_trans(struct qemu_plugin_tb *tb, void *udata)
{
    size_t n = qemu_plugin_tb_n_insns(tb);
    for (size_t i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint32_t word = 0;
        if (qemu_plugin_insn_size(insn) == 4 && qemu_plugin_insn_data(insn, &word, 4) == 4 &&
            (word & 0x0F100F10) == 0x0E000F10 && ((word >> 16) & 15) == 7) {
            qemu_plugin_register_vcpu_insn_exec_cb(insn, cp15, QEMU_PLUGIN_CB_R_REGS, (void *)(uintptr_t)word);
        }
        qemu_plugin_register_vcpu_mem_cb(insn, mem, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_MEM_RW,
                                         (void *)(uintptr_t)qemu_plugin_insn_vaddr(insn));
    }
    qemu_plugin_register_vcpu_tb_exec_inline_per_vcpu(tb, QEMU_PLUGIN_INLINE_ADD_U64, insns, n);
}

static void vcpu_init(unsigned int vcpu, void *udata)
{
    static const char *const names[16] = { "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9",
                                             "r10", "r11", "r12", "sp", "lr", "pc" };
    g_autoptr(GArray) regs = qemu_plugin_get_registers();
    for (guint i = 0; i < regs->len; i++) {
        qemu_plugin_reg_descriptor *d = &g_array_index(regs, qemu_plugin_reg_descriptor, i);
        if (!strcmp(d->name, "cpsr")) cpsr_reg = d->handle;
        for (int k = 0; k < 16; k++) if (!strcmp(d->name, names[k])) gpr[k] = d->handle;
    }
}

static void at_exit(void *udata) { report(qemu_plugin_u64_sum(insns)); }

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (g_str_has_prefix(argv[i], "out=")) outname = g_strdup(argv[i] + 4);
        else if (g_str_has_prefix(argv[i], "t0=")) n0 = (uint64_t)(atof(argv[i] + 3) * 62.5e6);
        else if (g_str_has_prefix(argv[i], "t1=")) n1 = (uint64_t)(atof(argv[i] + 3) * 62.5e6);
    }
    for (size_t i = 0; i < NC; i++) {
        Cache *c = &caches[i];
        c->sets = c->bytes / c->ways >> c->shift;
        c->gen = 1;
        c->e = g_new0(Ent, c->sets * c->ways);
    }
    pagekind = g_malloc0(1 << 20);
    pc_miss = g_hash_table_new(g_direct_hash, g_direct_equal);
    buf = g_byte_array_new();
    score = qemu_plugin_scoreboard_new(sizeof(uint64_t));
    insns = qemu_plugin_scoreboard_u64(score);
    qemu_plugin_register_vcpu_init_cb(id, vcpu_init, NULL);
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans, NULL);
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
