/* nan16-link.c - TCC flat-cartridge linker for NaN16. */
#ifdef TARGET_DEFS_ONLY

#define EM_TCC_TARGET 0
#define R_DATA_32    1
#define R_DATA_PTR   2
#define R_JMP_SLOT   3
#define R_GLOB_DAT   4
#define R_COPY       5
#define R_RELATIVE   6
#define R_NUM        7
#define R_NAN16_WORD 8
#define ELF_START_ADDR 0
#define ELF_PAGE_SIZE  0x1000
#define PCRELATIVE_DLLPLT 0
#define RELOCATE_DLLPLT 0

#else /* !TARGET_DEFS_ONLY */
#define USING_GLOBALS
#include "tcc.h"

/* 16-bit word-index relocations recorded by the code generator. */
typedef struct { int pos; char name[64]; int addend; } NanReloc;
static NanReloc nan_relocs[8192];
static int nan_nrelocs;

typedef struct { int lo, hi; char name[64]; int addend; } NanAddrReloc;
static NanAddrReloc nan_addr_relocs[8192];
static int nan_naddr_relocs;

void nan16_add_reloc(int pos, Sym *sym, int addend)
{
    if (nan_nrelocs >= (int)(sizeof nan_relocs / sizeof nan_relocs[0]))
        tcc_error("nan16: too many relocations");
    nan_relocs[nan_nrelocs].pos = pos;
    nan_relocs[nan_nrelocs].addend = addend;
    if (!sym || strlen(get_tok_str(sym->v, NULL)) >= sizeof nan_relocs[0].name)
        tcc_error("nan16: invalid call symbol");
    strcpy(nan_relocs[nan_nrelocs].name, get_tok_str(sym->v, NULL));
    nan_nrelocs++;
}

void nan16_add_addr_reloc(int lo, int hi, Sym *sym, int addend)
{
    if (nan_naddr_relocs >= (int)(sizeof nan_addr_relocs / sizeof nan_addr_relocs[0]))
        tcc_error("nan16: too many address relocations");
    nan_addr_relocs[nan_naddr_relocs].lo = lo;
    nan_addr_relocs[nan_naddr_relocs].hi = hi;
    nan_addr_relocs[nan_naddr_relocs].addend = addend;
    if (!sym || strlen(get_tok_str(sym->v, NULL)) >= sizeof nan_addr_relocs[0].name)
        tcc_error("nan16: invalid address symbol");
    strcpy(nan_addr_relocs[nan_naddr_relocs].name, get_tok_str(sym->v, NULL));
    nan_naddr_relocs++;
}

ST_FUNC int code_reloc(int reloc_type) { (void)reloc_type; return -1; }
ST_FUNC int gotplt_entry_type(int reloc_type)
{
    (void)reloc_type;
    return NO_GOTPLT_ENTRY;
}
ST_FUNC unsigned create_plt_entry(TCCState *s1, unsigned got_offset,
                                  struct sym_attr *attr)
{
    (void)s1; (void)got_offset; (void)attr;
    return 0;
}
ST_FUNC void relocate_plt(TCCState *s1) { (void)s1; }

ST_FUNC void relocate(TCCState *s1, ElfW_Rel *rel, int type,
                      unsigned char *ptr, addr_t addr, addr_t val)
{
    (void)s1; (void)rel; (void)addr;
    switch (type) {
    case R_DATA_32:
    case R_DATA_PTR:
        write32le(ptr, (uint32_t)val);
        break;
    case R_NAN16_WORD:
        write16le(ptr, (uint16_t)(val / 8));
        break;
    default:
        tcc_error("nan16: unsupported relocation %d", type);
    }
}

static int nan16_sym_index(TCCState *s1, const char *name)
{
    Section *st = s1->symtab;
    int n, i, fallback = 0;
    if (!st || !st->link) return 0;
    n = st->data_offset / sizeof(ElfSym);
    for (i = 1; i < n; i++) {
        ElfSym *e = &((ElfSym *)st->data)[i];
        if (e->st_name < st->link->data_offset
            && !strcmp((char *)st->link->data + e->st_name, name)) {
            if (e->st_shndx) return i;
            if (!fallback) fallback = i;
        }
    }
    return fallback;
}

static void nan16_write_word(FILE *f, uint64_t w)
{
    unsigned char b[8];
    int i;
    for (i = 0; i < 8; i++) b[i] = (unsigned char)(w >> (8 * i));
    fwrite(b, 1, 8, f);
}

static int nan16_words(Section *sec, int divisor)
{
    return sec ? (sec->data_offset + divisor - 1) / divisor : 0;
}

static void nan16_write_data(FILE *f, Section *sec)
{
    int off;
    if (!sec) return;
    for (off = 0; off < (int)sec->data_offset; off += 4) {
        uint32_t p = 0;
        int k;
        for (k = 0; k < 4 && off + k < (int)sec->data_offset; k++)
            p |= (uint32_t)sec->data[off + k] << (8 * k);
        nan16_write_word(f, nan16_mkword(p, 10));
    }
}

static int nan16_flat_addr(Section *sec, int st_value, int text_words,
                           Section **ds, int *dbase, int nd, int addend)
{
    int i;
    for (i = 0; i < nd; i++)
        if (ds[i] == sec)
            return dbase[i] * 4 + st_value + addend;
    return -1;
}

int nan16_output_file(TCCState *s1, const char *filename)
{
    Section *text = find_section(s1, ".text");
    Section *ds[4], *bss = find_section(s1, ".bss");
    int dbase[4], nd = 0, i, j;
    int main_sym, has_main = 0, pre, text_words, total_words;
    FILE *f;

    if (!text) text = s1->sections[0];
    ds[nd++] = find_section(s1, ".rodata");
    ds[nd++] = find_section(s1, ".data.ro");
    ds[nd++] = find_section(s1, ".data");
    ds[nd++] = bss;

    main_sym = find_elf_sym(s1->symtab, "main");
    if (main_sym) {
        ElfSym *me = &((ElfSym *)s1->symtab->data)[main_sym];
        if (me->st_shndx) has_main = 1;
    }
    pre = has_main ? 4 : 0;

    text_words = pre + (text->data_offset + 7) / 8;
    total_words = text_words;
    for (i = 0; i < nd; i++) {
        dbase[i] = total_words;
        if (ds[i]) total_words += (ds[i]->data_offset + 3) / 4;
    }

    if (pre) nan16_shift_jumps(text, pre);

    for (i = 0; i < nan_nrelocs; i++) {
        NanReloc *r = &nan_relocs[i];
        int si = nan16_sym_index(s1, r->name);
        ElfSym *es = si ? &((ElfSym *)s1->symtab->data)[si] : NULL;
        int value;
        if (!es) tcc_error("nan16: unresolved symbol '%s'", r->name);
        value = (int)es->st_value + r->addend;
        if (value < 0 || value / 8 > 0xFFFF || (value & 7))
            tcc_error("nan16: call relocation out of range");
        value = value / 8 + pre;
        text->data[r->pos] = value & 0xFF;
        text->data[r->pos + 1] = (value >> 8) & 0xFF;
    }

    for (i = 0; i < nan_naddr_relocs; i++) {
        NanAddrReloc *r = &nan_addr_relocs[i];
        int si = nan16_sym_index(s1, r->name);
        ElfSym *es = si ? &((ElfSym *)s1->symtab->data)[si] : NULL;
        Section *sec;
        int addr;
        if (!es) tcc_error("nan16: unresolved address '%s'", r->name);
        sec = es->st_shndx < s1->nb_sections ? s1->sections[es->st_shndx] : NULL;
        if (sec == text)
            addr = (int)es->st_value / 8 + pre + r->addend / 8;
        else
            addr = nan16_flat_addr(sec, (int)es->st_value, text_words,
                                   ds, dbase, nd, 0) + r->addend;
        if (addr < 0 || addr > 0xFFFFFFFF)
            tcc_error("nan16: address out of range for '%s'", r->name);
        text->data[r->lo] = addr & 0xFF;
        text->data[r->lo + 1] = (addr >> 8) & 0xFF;
        text->data[r->hi] = (addr >> 16) & 0xFF;
        text->data[r->hi + 1] = (addr >> 24) & 0xFF;
    }

    /* Data relocations, e.g. char *s = "hi". */
    for (i = 0; i < s1->nb_sections; i++) {
        Section *rel = s1->sections[i];
        Section *tgt;
        int n;
        if (!rel || rel->sh_type != SHT_RELX || !rel->data) continue;
        tgt = rel->sh_info < s1->nb_sections ? s1->sections[rel->sh_info] : NULL;
        if (!tgt || !tgt->data) continue;
        n = rel->data_offset / sizeof(ElfW_Rel);
        for (j = 0; j < n; j++) {
            ElfW_Rel *rr = (ElfW_Rel *)rel->data + j;
            int si = ELFW(R_SYM)(rr->r_info);
            ElfSym *es = &((ElfSym *)s1->symtab->data)[si];
            Section *sec = es->st_shndx < s1->nb_sections
                         ? s1->sections[es->st_shndx] : NULL;
            uint32_t addend = read32le(tgt->data + rr->r_offset);
            int addr;
            if (sec == text)
                addr = (int)es->st_value / 8 + pre;
            else
                addr = nan16_flat_addr(sec, (int)es->st_value, text_words,
                                       ds, dbase, nd, 0) + addend;
            if (addr < 0) tcc_error("nan16: bad data relocation");
            write32le(tgt->data + rr->r_offset, (uint32_t)addr);
        }
    }

    f = fopen(filename, "wb");
    if (!f) return -1;
    if (has_main) {
        int mword = ((ElfSym *)s1->symtab->data)[main_sym].st_value / 8 + pre;
        nan16_write_word(f, nan16_mkword(0x01E08000u, 15));
        nan16_write_word(f, nan16_mkword(0x0B000000u | (mword & 0xFFFF), 15));
        nan16_write_word(f, nan16_mkword(0x09100100u, 15));
        nan16_write_word(f, nan16_mkword(0xFF000000u, 15));
    }
    if (text->data_offset) fwrite(text->data, 1, text->data_offset, f);
    for (i = 0; i < nd; i++) {
        if (!ds[i]) continue;
        if (ds[i] == bss) {
            int n = (ds[i]->data_offset + 3) / 4, k;
            for (k = 0; k < n; k++) nan16_write_word(f, nan16_mkword(0, 10));
        } else {
            nan16_write_data(f, ds[i]);
        }
    }
    fclose(f);
    return 0;
}
#endif /* TARGET_DEFS_ONLY */
