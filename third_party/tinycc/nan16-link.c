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

int nan16_output_file(TCCState *s1, const char *filename)
{
    Section *text = find_section(s1, ".text");
    FILE *f;
    int i;
    if (!text) text = s1->sections[0];

    for (i = 0; i < nan_nrelocs; i++) {
        NanReloc *r = &nan_relocs[i];
        int si = find_elf_sym(s1->symtab, r->name);
        ElfSym *es = si ? &((ElfSym *)s1->symtab->data)[si] : NULL;
        int value = (es ? (int)es->st_value : 0) + r->addend;
        uint16_t word;
        if (!es || value < 0)
            tcc_error("nan16: unresolved symbol '%s'", r->name);
        word = (uint16_t)(value / 8);
        if ((value & 7) || value / 8 > 0xFFFF)
            tcc_error("nan16: relocation out of range");
        text->data[r->pos] = word & 0xFF;
        text->data[r->pos + 1] = word >> 8;
    }

    f = fopen(filename, "wb");
    if (!f) return -1;
    if (text->data_offset && fwrite(text->data, 1, text->data_offset, f)
        != text->data_offset) {
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}
#endif /* TARGET_DEFS_ONLY */
