/* nan16-gen.c - TCC code generator for the NaN16 target.
 *
 * ABI (nan16-abi.h):
 *   r0=0, r13=1, r14=SP, r15=link, r12=frame pointer (reserved here).
 *   Frames grow up.  At entry SP points just past the pushed arguments.
 *   Prologue saves the link at [SP], sets FP = SP + FRAME, SP = FP.
 *   Locals are at FP+loc (loc negative); parameters at
 *   FP-FRAME-(n-i), i.e. the caller's pushed argument slots.
 *   FRAME words are reserved per call; 255 words of locals are allowed.
 */
#ifdef TARGET_DEFS_ONLY

#define NB_REGS 10              /* r1..r9 values; r10 scratch; r11 carry; r12 FP */
#define RC_INT   0x01
#define RC_FLOAT 0x02
#define RC_R(n)  (1 << (2 + (n)))
#define RC_IRET  RC_R(1)
#define RC_IRE2  RC_R(2)
#define RC_FRET  RC_R(1)
#define RC_FRE2  RC_R(2)
#define REG_IRET 1
#define REG_IRE2 2
#define REG_FRET 1
#define REG_FRE2 2
#define PTR_SIZE 4
#define LDOUBLE_SIZE 8
#define LDOUBLE_ALIGN 8
#define MAX_ALIGN 8

#else /* !TARGET_DEFS_ONLY */
#define USING_GLOBALS
#include "tcc.h"
#include "nan16-abi.h"
#include <assert.h>

#define NAN_FRAME 256
static int nan_nparams;
static int nan_paramwords;

void nan16_add_reloc(int pos, Sym *sym, int addend);
void nan16_add_addr_reloc(int lo, int hi, Sym *sym, int addend);

ST_DATA const char * const target_machine_defs =
    "__nan16\0"
    "__SIZEOF_POINTER__ 4\0"
    "__SIZEOF_LONG__ 4\0"
    "__SIZEOF_LONG_LONG__ 8\0"
    "__CHAR_BIT__ 8\0"
    ;

ST_DATA const int reg_classes[NB_REGS] = {
    0,
    RC_INT | RC_FLOAT | RC_R(1), RC_INT | RC_FLOAT | RC_R(2),
    RC_INT | RC_FLOAT | RC_R(3), RC_INT | RC_FLOAT | RC_R(4),
    RC_INT | RC_FLOAT | RC_R(5), RC_INT | RC_FLOAT | RC_R(6),
    RC_INT | RC_FLOAT | RC_R(7), RC_INT | RC_FLOAT | RC_R(8),
    RC_INT | RC_FLOAT | RC_R(9),
};

/* ---------------------------------------------------------------- emission */
ST_FUNC void g(int c)
{
    int ind1;
    if (nocode_wanted) return;
    ind1 = ind + 1;
    if (ind1 > cur_text_section->data_allocated)
        section_realloc(cur_text_section, ind1);
    cur_text_section->data[ind] = c;
    ind = ind1;
}

static void nan_word(uint32_t payload, int pred)
{
    uint64_t w = nan16_mkword(payload, pred & 15);
    int i;
    if (nocode_wanted) return;
    for (i = 0; i < 8; i++) g((int)(w >> (8 * i)));
}

static void nan_op(int op, int d, int a, int imm)
{
    nan_word(((uint32_t)op << 24) | ((uint32_t)(d & 15) << 20)
             | ((uint32_t)(a & 15) << 16) | (imm & 0xFFFF), 15);
}

static void nan_pred_op(int op, int d, int a, int imm, int pred)
{
    nan_word(((uint32_t)op << 24) | ((uint32_t)(d & 15) << 20)
             | ((uint32_t)(a & 15) << 16) | (imm & 0xFFFF), pred);
}

static void nan_patch16(int pos, uint16_t v);

/* After ADD/SUB, materialise the carry/borrow flag into r11.  n is the
   NaN predicate mask for the carry state (k=1 and, for ADD, k=3). */
static void nan_cap_carry(int pred)
{
    int pos;
    nan_op(0x01, 11, 0, 1);            /* MOVI r11,1 */
    nan_pred_op(0x0A, 0, 0, 0, pred);  /* JMP[pred] over the zero */
    pos = ind - 6;
    nan_op(0x01, 11, 0, 0);            /* MOVI r11,0 */
    nan_patch16(pos, (uint16_t)(ind / 8));
}

static void nan_movi32(int r, uint32_t v)
{
    nan_op(0x01, r, 0, v & 0xFFFF);
    nan_op(0x02, r, 0, (v >> 16) & 0xFFFF);
}

/* --------------------------------------------------------- jump fixup list */
typedef struct { int next; int pos; } NanJump;
static NanJump nan_jumps[4096];
static int nan_njumps;

static int nan_jump_new(int pos, int next)
{
    if (nan_njumps >= (int)(sizeof nan_jumps / sizeof nan_jumps[0]))
        tcc_error("nan16: too many jumps");
    nan_jumps[nan_njumps].next = next;
    nan_jumps[nan_njumps].pos = pos;
    return nan_njumps++ + 1;
}

static void nan_patch16(int pos, uint16_t v)
{
    if (pos < 0) return;
    cur_text_section->data[pos] = v & 0xFF;
    cur_text_section->data[pos + 1] = v >> 8;
}

ST_FUNC void gsym_addr(int t, int a)
{
    int target = (a / 8) & 0xFFFF;
    while (t) {
        NanJump *j = &nan_jumps[t - 1];
        nan_patch16(j->pos, target);
        t = j->next;
    }
}

ST_FUNC int gjmp_append(int n, int t)
{
    int h;
    if (!n) return t;
    if (!t) return n;
    h = n;
    while (nan_jumps[h - 1].next) h = nan_jumps[h - 1].next;
    nan_jumps[h - 1].next = t;
    return n;
}

ST_FUNC int gjmp(int t)
{
    int pos;
    nan_op(0x0A, 0, 0, 0);
    pos = ind - 6;             /* imm16 is bytes 2..3 of the 8-byte word */
    return nan_jump_new(pos, t);
}

ST_FUNC void gjmp_addr(int a)
{
    int pos;
    nan_op(0x0A, 0, 0, (a / 8) & 0xFFFF);
    pos = ind - 6;
    nan_jump_new(pos, 0);
}

/* Shift every recorded absolute jump by the entry-prelude word count. */
void nan16_shift_jumps(Section *text, int pre)
{
    int i;
    for (i = 0; i < nan_njumps; i++) {
        int pos = nan_jumps[i].pos;
        uint16_t t = (uint16_t)(text->data[pos] | (text->data[pos + 1] << 8));
        t = (uint16_t)(t + pre);
        text->data[pos] = t & 0xFF;
        text->data[pos + 1] = t >> 8;
    }
}

/* comparison state for deferred VT_CMP branches */
static int nan_cmp_a, nan_cmp_b, nan_cmp_signed, nan_cmp_pending;

static int nan_pred_for(int op)
{
    switch (op) {
    case TOK_EQ: return 4;
    case TOK_NE: return 3;
    case TOK_LT: case TOK_ULT: return 2;
    case TOK_GE: case TOK_UGE: return 5;
    case TOK_GT: case TOK_UGT: return 1;
    case TOK_LE: case TOK_ULE: return 6;
    }
    return 4;
}

static void nan_emit_cmp(void)
{
    if (!nan_cmp_pending) return;
    nan_op(nan_cmp_signed ? 0x28 : 0x07, 0, nan_cmp_a, nan_cmp_b);
    nan_cmp_pending = 0;
}

ST_FUNC int gjmp_cond(int op, int t)
{
    int pos;
    nan_emit_cmp();
    nan_pred_op(0x0A, 0, 0, 0, nan_pred_for(op));
    pos = ind - 6;
    return nan_jump_new(pos, t);
}

ST_FUNC void ggoto(void)
{
    nan_op(0x0D, 0, vtop->r & VT_VALMASK, 0);
}

ST_FUNC void gen_fill_nops(int n)
{
    (void)n;
}

ST_FUNC void gen_vla_sp_save(int addr) { (void)addr; }
ST_FUNC void gen_vla_sp_restore(int addr) { (void)addr; }
ST_FUNC void gen_vla_alloc(CType *type, int align)
{
    (void)type; (void)align;
    tcc_error("nan16: variable-length arrays are not implemented");
}

/* -------------------------------------------------------------- load/store */
static int nan_size(CType *t)
{
    int align, sz = type_size(t, &align);
    if ((t->t & VT_BTYPE) == VT_PTR || (t->t & VT_BTYPE) == VT_FUNC)
        sz = PTR_SIZE;
    return sz;
}

static void nan_load_indirect(int r, int size, int sign)
{
    if (size == 1) {
        nan_op(0x2A, r, r, 0);          /* LDB r,[r] */
        if (sign) {
            nan_op(0x05, r, r, 24);
            nan_op(0x27, r, r, 24);
        }
    } else {
        nan_op(0x06, r, r, 2);          /* SHR r,2 */
        nan_op(0x08, r, r, 0);          /* LD r,[r] */
    }
}

static void nan_store_indirect(int r, int size, int addr_reg)
{
    int t = 10;
    if (size == 1) {
        nan_op(0x2B, r, addr_reg, 0);   /* STB */
    } else {
        nan_op(0x06, t, addr_reg, 2);   /* SHR t,addr,2 */
        nan_op(0x09, r, t, 0);          /* ST */
    }
}

/* Emit the byte address of a local/param into r.
   locals: ci<0, byte address = SP*4 + ci
   params: ci>=0, byte address = FP*4 + ci */
static void nan_local_addr(int r, int ci)
{
    /* Locals live below SP but their address must not move when arguments
       are pushed, so address them from FP.  Local ci<0 maps to
       FP + (n+2+FRAME) + ci/4 words; parameters ci>=0 map to FP + ci/4. */
    int off = ci < 0 ? (nan_paramwords + 2 + NAN_FRAME) * 4 + ci : ci;
    nan_op(0x05, r, 12, 2);             /* SHL r,FP,2 */
    nan_op(0x29, r, r, off);
}

ST_FUNC void load(int r, SValue *sv)
{
    int v = sv->r & VT_VALMASK;
    int size, sign;
    if (v == VT_CONST) {
        if (sv->r & VT_SYM) {
            int p0 = ind, p1, lo, hi;
            nan_op(0x01, r, 0, 0);
            lo = p0 + 2;
            p1 = ind;
            nan_op(0x02, r, 0, 0);
            hi = p1 + 2;
            nan16_add_addr_reloc(lo, hi, sv->sym, (int)sv->c.i);
            if (sv->r & VT_LVAL) {
                size = nan_size(&sv->type);
                sign = !(sv->type.t & VT_UNSIGNED) && size == 1;
                nan_load_indirect(r, size, sign);
            }
        } else {
            nan_movi32(r, (uint32_t)sv->c.i);
        }
    } else if (v == VT_LOCAL) {
        int ci = (int)sv->c.i;
        nan_local_addr(r, ci);
        if (sv->r & VT_LVAL) {
            size = nan_size(&sv->type);
            sign = !(sv->type.t & VT_UNSIGNED) && size == 1;
            nan_load_indirect(r, size, sign);
        }
    } else if (v == VT_LLOCAL) {
        int ci = (int)sv->c.i;
        nan_local_addr(r, ci);
        nan_op(0x06, r, r, 2);
        nan_op(0x08, r, r, 0);          /* load the pointer */
        if (sv->r & VT_LVAL) {
            size = nan_size(&sv->type);
            sign = !(sv->type.t & VT_UNSIGNED) && size == 1;
            nan_load_indirect(r, size, sign);
        }
    } else if (sv->r & VT_LVAL) {
        size = nan_size(&sv->type);
        sign = !(sv->type.t & VT_UNSIGNED) && size == 1;
        if (r != v)
            nan_op(0x03, r, v, 0);
        nan_load_indirect(r, size, sign);
    } else {
        nan_op(0x03, r, v, 0);
    }
}

ST_FUNC void store(int r, SValue *sv)
{
    int v = sv->r & VT_VALMASK;
    int size = nan_size(&sv->type);
    if (v == VT_LOCAL) {
        int ci = (int)sv->c.i;
        int t = 10;
        nan_local_addr(t, ci);
        nan_store_indirect(r, size, t);
    } else if (v == VT_LLOCAL) {
        int ci = (int)sv->c.i;
        int t = 10;
        nan_local_addr(t, ci);
        nan_op(0x06, t, t, 2);
        nan_op(0x08, t, t, 0);
        nan_store_indirect(r, size, t);
    } else if (sv->r & VT_LVAL) {
        nan_store_indirect(r, size, v);
    } else {
        tcc_error("nan16: unsupported store");
    }
}

/* --------------------------------------------------------------- integer ops */
static void nan_gen_cmp(int op)
{
    gv2(RC_INT, RC_INT);
    nan_cmp_a = vtop[-1].r & VT_VALMASK;
    nan_cmp_b = vtop[0].r & VT_VALMASK;
    nan_cmp_signed = !(op >= TOK_ULT && op <= TOK_GT);
    nan_cmp_pending = 1;
    vtop -= 2;
    vtop++;
    vset_VT_CMP(op);
}

ST_FUNC void gen_opi(int op)
{
    int a, b;

    if (op >= TOK_ULT && op <= TOK_GT) {
        nan_gen_cmp(op);
        return;
    }
    if ((op == TOK_SHL || op == TOK_SHR || op == TOK_SAR)
        && (vtop->r & (VT_VALMASK | VT_LVAL)) == VT_CONST) {
        int sh = vtop->c.i & 31;
        vtop--;
        gv(RC_INT);
        a = vtop->r & VT_VALMASK;
        nan_op(op == TOK_SHL ? 0x05 : op == TOK_SHR ? 0x06 : 0x27, a, a, sh);
        return;
    }

    gv2(RC_INT, RC_INT);
    a = vtop[-1].r & VT_VALMASK;
    b = vtop[0].r & VT_VALMASK;
    switch (op) {
    case '+': nan_op(0x03, a, a, b); break;
    case '-': nan_op(0x04, a, a, b); break;
    case '*': nan_op(0x20, a, a, b); break;
    case '/': nan_op(0x23, a, a, b); break;
    case TOK_UDIV: nan_op(0x25, a, a, b); break;
    case '%': nan_op(0x24, a, a, b); break;
    case TOK_UMOD: nan_op(0x26, a, a, b); break;
    case '&': nan_pred_op(0x00, a, a, b, 8); break;
    case '^': nan_pred_op(0x00, a, a, b, 6); break;
    case '|': nan_pred_op(0x00, a, a, b, 14); break;
    case TOK_ADDC1:
        nan_op(0x03, a, a, b);
        nan_cap_carry(10);             /* k=1 or k=3 */
        break;
    case TOK_SUBC1:
        nan_op(0x04, a, a, b);
        nan_cap_carry(2);              /* borrow is k=1 */
        break;
    case TOK_ADDC2:
        nan_op(0x03, a, a, b);
        nan_op(0x03, a, a, 11);
        break;
    case TOK_SUBC2:
        nan_op(0x04, a, a, b);
        nan_op(0x04, a, a, 11);
        break;
    case TOK_UMULL:
        nan_op(0x20, a, a, b);      /* low 32 */
        nan_op(0x22, 11, a, b);     /* high 32 into r11 */
        vtop--;
        vtop->r = a;
        vtop->r2 = 11;
        return;
    default:
        tcc_error("nan16: unimplemented integer operator %s",
                  get_tok_str(op, NULL));
    }
    vtop--;
    vtop->r = a;
}

/* ----------------------------------------------------------------- float ops */
ST_FUNC void gen_opf(int op)
{
    int a, b;
    if (op >= TOK_ULT && op <= TOK_GT) {
        gv2(RC_FLOAT, RC_FLOAT);
        nan_op(0x35, 0, vtop[-1].r & VT_VALMASK, vtop[0].r & VT_VALMASK);
        nan_cmp_pending = 0;
        vtop -= 2;
        vtop++;
        vset_VT_CMP(op);
        return;
    }
    gv2(RC_FLOAT, RC_FLOAT);
    a = vtop[-1].r & VT_VALMASK;
    b = vtop[0].r & VT_VALMASK;
    switch (op) {
    case '+': nan_op(0x30, a, a, b); break;
    case '-': nan_op(0x31, a, a, b); break;
    case '*': nan_op(0x32, a, a, b); break;
    case '/': nan_op(0x33, a, a, b); break;
    case TOK_NEG: nan_op(0x04, a, 0, a); break;
    default:
        tcc_error("nan16: unimplemented float operator %s",
                  get_tok_str(op, NULL));
    }
    vtop--;
    vtop->r = a;
}

ST_FUNC void gen_cvt_itof(int t) { (void)t; nan_op(0x36, vtop->r & VT_VALMASK, vtop->r & VT_VALMASK, 0); }
ST_FUNC void gen_cvt_ftoi(int t) { (void)t; nan_op(0x37, vtop->r & VT_VALMASK, vtop->r & VT_VALMASK, 0); }
ST_FUNC void gen_cvt_ftof(int t) { (void)t; }

/* --------------------------------------------------------------- functions */
ST_FUNC int gfunc_sret(CType *vt, int variadic, CType *ret,
                       int *align, int *regsize)
{
    (void)vt; (void)variadic; (void)ret; (void)align; (void)regsize;
    return -1;                  /* struct returns use memory */
}

ST_FUNC void gfunc_prolog(Sym *func_sym)
{
    CType *func_type = &func_sym->type;
    Sym *sym = func_type->ref;
    int n = 0, i, byteoff;

    while ((sym = sym->next) != NULL) n++;
    sym = func_type->ref->next;
    nan_nparams = n;

    /* FP = first pushed argument; link at FP+paramwords; saved caller FP
       at FP+paramwords+1; locals above. */
    byteoff = 0;
    for (i = 0; i < n; i++, sym = sym->next) {
        int align, sz;
        gfunc_set_param(sym, byteoff, 0);
        sz = type_size(&sym->type, &align);
        byteoff += sz < 4 ? 4 : sz;
    }
    nan_paramwords = (byteoff + 3) / 4;
    nan_op(0x09, 12, 14, 1);
    nan_op(0x29, 12, 14, -nan_paramwords);
    nan_op(0x09, 15, 12, nan_paramwords);
    nan_op(0x29, 14, 12, nan_paramwords + 2 + NAN_FRAME);
}

ST_FUNC void gfunc_epilog(void)
{
    if (-loc / 4 > NAN_FRAME)
        tcc_error("nan16: frame too large (%d bytes)", -loc);
    nan_op(0x08, 15, 12, nan_paramwords);
    nan_op(0x08, 11, 12, nan_paramwords + 1);
    nan_op(0x29, 14, 12, nan_paramwords);
    nan_op(0x03, 12, 11, 0);
    nan_op(0x0C, 0, 0, 0);
}

ST_FUNC void gfunc_call(int nb_args)
{
    SValue *fn = &vtop[-nb_args];
    int i, pos, words = 0;

    save_regs(nb_args + 1);
    for (i = 0; i < nb_args; i++) {
        SValue *arg = &vtop[-(nb_args - 1 - i)];
        int align;
        int size = type_size(&arg->type, &align);
        if (size == 8) {
            SValue hi = *arg;
            load(1, arg);
            nan_op(0x09, 1, 14, 0);
            nan_op(0x29, 14, 14, 1);
            if ((hi.r & VT_VALMASK) == VT_CONST && !(hi.r & VT_SYM)) {
                hi.c.i = (uint64_t)hi.c.i >> 32;
            } else if (hi.r & VT_LVAL) {
                hi.c.i = (int)hi.c.i + 4;
            } else if (hi.r2 && hi.r2 < VT_CONST) {
                hi.r = hi.r2;
            } else {
                tcc_error("nan16: cannot pass 64-bit value from this location");
            }
            load(2, &hi);
            nan_op(0x09, 2, 14, 0);
            nan_op(0x29, 14, 14, 1);
            words += 2;
        } else if (size <= 4) {
            load(1, arg);
            nan_op(0x09, 1, 14, 0);
            nan_op(0x29, 14, 14, 1);
            words++;
        } else {
            tcc_error("nan16: struct arguments are not implemented");
        }
    }
    if ((fn->r & VT_VALMASK) == VT_CONST && (fn->r & VT_SYM)) {
        nan_op(0x0B, 0, 0, 0);
        pos = ind - 6;
        nan16_add_reloc(pos, fn->sym, fn->c.i);
    } else {
        load(1, fn);
        nan_op(0x2C, 0, 1, 0);
    }
    if (words)
        nan_op(0x29, 14, 14, -words);
    vtop -= nb_args + 1;        /* pop args and the function slot */
}

/* --------------------------------------------------------------- link hooks */
/* nan16-link.c provides the relocation table and the output writer. */
#endif /* TARGET_DEFS_ONLY */
