/* nan16.c - host conformance harness for the NaN16/NaNVM1 core (S6).
   NOT the VM: spec/NANVM_SPEC.md is normative; no semantics land here first.
   Semantics ref: OPS.md (verified against kan16.xa r28d). */
#include "nan16_int.h"
#include <math.h>
#if defined(__linux__) && defined(MADV_DONTNEED)
#include <sys/mman.h>
#define NAN_MMAP_MEM 1
#endif

static inline int is_nan32(uint32_t x) { return (x & 0x7F800000u) == 0x7F800000u && (x & 0x007FFFFFu); }
static inline float f32(uint32_t x) { float f; memcpy(&f, &x, 4); return f; }
static inline uint32_t u32(float f) { uint32_t x; memcpy(&x, &f, 4); return x; }

static uint32_t fp_bin(int op, uint32_t A, uint32_t B) {
  if (is_nan32(A)) return A | 0x00400000u;
  if (is_nan32(B)) return B | 0x00400000u;
  volatile float a = f32(A), b = f32(B), r;
  switch (op) { case 0x30: r = a + b; break; case 0x31: r = a - b; break;
                case 0x32: r = a * b; break; default: r = a / b; break; }
  uint32_t x = u32(r);
  return is_nan32(x) ? 0xFFC00000u : x;
}
static uint32_t fp_div(uint32_t A, uint32_t B) {
  if ((B & 0x7FFFFFFFu) == 0) {
    if ((A & 0x7FFFFFFFu) == 0 || is_nan32(A)) return 0x7FC00000u;
    return ((A ^ B) & 0x80000000u) | 0x7F800000u;
  }
  return fp_bin(0x33, A, B);
}
static uint32_t fp_sqrt(uint32_t A) {
  if (is_nan32(A) || ((A & 0x80000000u) && (A & 0x7FFFFFFFu))) return 0x7FC00000u;
  volatile float a = f32(A), r = sqrtf(a);
  return u32(r);
}
static uint32_t fp_cvtfi(uint32_t A) {
  if (is_nan32(A)) return 0;
  float f = f32(A);
  if (f >= 2147483648.0f) return 0x7FFFFFFFu;
  if (f <= -2147483648.0f) return 0x80000000u;
  return (uint32_t)(int32_t)f;
}
static uint32_t fp_unary(uint32_t A, int op) {
  if (is_nan32(A)) return A | 0x00400000u;
  volatile float a = f32(A), r;
  if (op == 0x46) r = expf(a);
  else if (op == 0x47) r = tanhf(a);
  else {
    if ((A & 0x7FFFFFFFu) == 0) return 0xFF800000u;  /* log(+-0) = -inf */
    if (A & 0x80000000u) return 0x7FC00000u;         /* log(negative) */
    r = logf(a);
  }
  uint32_t x = u32(r);
  return is_nan32(x) ? 0x7FC00000u : x;
}

static void *nan_mem_alloc(size_t bytes, uint8_t *is_mmap) {
  *is_mmap = 0;
#ifdef NAN_MMAP_MEM
  /* Demand-mapped zero pages: a 128 MiB payload VM must not commit its full
     256 MiB word array just because it exists. */
  void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p != MAP_FAILED) { *is_mmap = 1; return p; }
#endif
  return calloc(1, bytes);
}
static void nan_mem_free(nan_vm *v) {
  if (!v->mem) return;
#ifdef NAN_MMAP_MEM
  if (v->mem_mmap) { munmap(v->mem, (size_t)v->mem_words * 8u); return; }
#endif
  free(v->mem);
}
static void nan_mem_clear(nan_vm *v) {
  size_t bytes = (size_t)v->mem_words * 8u;
#ifdef NAN_MMAP_MEM
  if (v->mem_mmap) { madvise(v->mem, bytes, MADV_DONTNEED); return; }
#endif
  memset(v->mem, 0, bytes);
}
/* nan_create_words() takes a power-of-two word count (rounded up if needed).
   Words are 8 bytes; guest C programs see four payload bytes per word. */
nan_vm *nan_create_words(uint32_t words) {
  if (words < NAN_MIN_WORDS) words = NAN_MIN_WORDS;
  if (words & (words - 1u)) {
    uint32_t p = NAN_MIN_WORDS;
    while (p < words) { if (p > 0x8000000u) return NULL; p <<= 1; }
    words = p;
  }
  if (words > 0x10000000u) return NULL;
  nan_vm *v = (nan_vm *)calloc(1, sizeof *v);
  if (!v) return NULL;
  v->mem_words = words;
  v->mem_mask = words - 1u;
  v->mem = (uint64_t *)nan_mem_alloc((size_t)words * 8u, &v->mem_mmap);
  v->vram = (uint8_t *)calloc(NAN_VRAM, 1);
  v->ser = (char *)calloc(NAN_SER_CAP, 1);
  if (!v->mem || !v->vram || !v->ser) { nan_destroy(v); return NULL; }
  nan_reset(v);
  return v;
}
nan_vm *nan_create(void) { return nan_create_words(NAN_WORDS); }
void nan_destroy(nan_vm *v) {
  if (!v) return;
  nan_mem_free(v);
  free(v->vram); free(v->ser); free(v);
}
uint32_t nan_mem_words(const nan_vm *v) { return v ? v->mem_words : 0; }
void nan_reset(nan_vm *v) {
  nan_mem_clear(v);
  memset(v->vram, 0, NAN_VRAM);
  memset(v->r, 0, sizeof v->r);
  memset(v->vreg, 0, sizeof v->vreg);
  v->pc = 0; v->k = 0; v->halted = 0; v->steps = 0; v->ms = 0;
  for (int i = 0; i < 2000; i++) v->cells[i] = 0x0720;
  v->vmode = 0; v->fbw = 0; v->fbh = 0; v->fbtot = 64000;
  v->trap[0] = 0; v->ser_h = v->ser_t = 0;
  v->tick_last = 0xFFFFFFFFu; v->tick_same = 0;
  v->kentry = v->kframe = v->kstack = v->kregions = v->ktcb = NAN_KABI_UNSET;
  v->ktimer = v->ktimer_left = 0;
  v->kin = v->ktimer_pending = v->ktrap_pending = 0;
  v->dirty++; v->frame++;
  nan_dev_reset(v);
}

/* ---- accessors ---- */
uint64_t nan_steps(const nan_vm *v) { return v->steps; }
const char *nan_trap_text(const nan_vm *v) { return v->trap; }
void nan_set_time_ms(nan_vm *v, uint32_t ms) { v->ms = ms; }
uint32_t nan_reg(const nan_vm *v, int i) { return v->r[i & 15]; }
uint32_t nan_pc(const nan_vm *v) { return v->pc; }
uint64_t nan_word(const nan_vm *v, uint32_t i) { return v->mem[i & v->mem_mask]; }
uint32_t nan_vector_lane(const nan_vm *v, int vreg, int lane) {
  return ((const uint32_t *)(const void *)v->vreg[vreg & 15])[lane & 15];
}
void nan_set_word(nan_vm *v, uint32_t i, uint64_t raw) { v->mem[i & v->mem_mask] = raw; }
/* Host boundary: pack external bytes into NaN16 data words for guest LDB.
   Corpus interpretation and all training decisions remain in the guest. */
int nan_write_bytes(nan_vm *v, uint32_t byte_address, const uint8_t *data, size_t len) {
  if (!v || (!data && len)) return -1;
  const uint64_t cap = (uint64_t)v->mem_words * 4u;
  if ((uint64_t)byte_address > cap || (uint64_t)len > cap - byte_address) return -1;
  for (size_t i = 0; i < len; ++i) {
    uint64_t at = (uint64_t)byte_address + i;
    uint32_t wi = (uint32_t)(at >> 2);
    uint32_t shift = (uint32_t)(at & 3u) * 8u;
    uint32_t payload = (uint32_t)(v->mem[wi] >> 16);
    payload = (payload & ~(0xFFu << shift)) | ((uint32_t)data[i] << shift);
    v->mem[wi] = nan_mkword(payload, 10);
  }
  return 0;
}
int nan_read_bytes(const nan_vm *v, uint32_t byte_address, uint8_t *out, size_t len) {
  if (!v || (!out && len)) return -1;
  const uint64_t cap = (uint64_t)v->mem_words * 4u;
  if ((uint64_t)byte_address > cap || (uint64_t)len > cap - byte_address) return -1;
  for (size_t i = 0; i < len; ++i) {
    uint64_t at = (uint64_t)byte_address + i;
    uint32_t wi = (uint32_t)(at >> 2);
    uint32_t shift = (uint32_t)(at & 3u) * 8u;
    out[i] = (uint8_t)(((uint32_t)(v->mem[wi] >> 16) >> shift) & 0xFFu);
  }
  return 0;
}

/* Raw class-bearing NaN16 guest-memory transport, NOT corpus-byte injection.
   Each 8-byte word is copied unchanged (both NaN faces, payload, endianness).
   This API does not interpret words or decide a head's validity/generation:
   the native nh_open/nh_get/nh_put guest code remains the sole authority.
   Reject entire out-of-range spans before writing any byte; no wraparound. */
static int nan_raw_words_bounds(const nan_vm *v, uint32_t first_word,
                                size_t word_count, const void *buffer) {
  if (!v || (!buffer && word_count)) return -1;
  if ((uint64_t)first_word > v->mem_words || word_count > (size_t)(v->mem_words - first_word)) return -1;
  /* Canonical NaN16 raw words are little-endian, supported by ARM/x86. */
  const uint16_t one = 1;
  if (*(const uint8_t *)&one != 1) return -1;
  return 0;
}
int nan_write_words_raw(nan_vm *v, uint32_t first_word,
                        const uint8_t *raw_words, size_t word_count) {
  if (nan_raw_words_bounds(v, first_word, word_count, raw_words)) return -1;
  if (word_count) memcpy(v->mem + first_word, raw_words, word_count * 8u);
  return 0;
}
int nan_read_words_raw(const nan_vm *v, uint32_t first_word,
                       uint8_t *out, size_t word_count) {
  if (nan_raw_words_bounds(v, first_word, word_count, out)) return -1;
  if (word_count) memcpy(out, v->mem + first_word, word_count * 8u);
  return 0;
}

void nan_set_reg(nan_vm *v, int i, uint32_t x) { v->r[i & 15] = x; }
void nan_set_pc(nan_vm *v, uint32_t pc) { v->pc = pc; v->halted = 0; }
int nan_flags(const nan_vm *v) { return v->k; }
void nan_set_trace(nan_vm *v, nan_trace_fn cb, void *ctx) { v->trace = cb; v->trace_ctx = ctx; }
uint32_t nan_dirty(const nan_vm *v) { return v->dirty; }
uint32_t nan_frame_counter(const nan_vm *v) { return v->frame; }
int nan_display_mode(const nan_vm *v) { return v->vmode; }
void nan_display_size(const nan_vm *v, int *w, int *h) {
  if (v->vmode) { *w = (int)v->fbw; *h = (int)v->fbh; } else { *w = 80; *h = 25; }
}
uint16_t nan_text_cell(const nan_vm *v, int i) { return (i >= 0 && i < 2000) ? v->cells[i] : 0; }

static void trap(nan_vm *v, char kind, uint32_t shown) {
  char b[24]; snprintf(b, sizeof b, "!%c%04X", kind, (unsigned)shown);
  for (const char *p = b; *p; p++) nan_ser_putc(v, (uint8_t)*p);
  snprintf(v->trap, sizeof v->trap, "%s", b);
  v->pc = shown; v->halted = 1;
}

/* ---- VRAM helpers (clamped to 16 MB; x86 is unchecked) ---- */
static void fb_copy(nan_vm *v, uint32_t cnt, uint32_t dst, uint32_t src) {
  uint64_t cap = NAN_VRAM, n4 = cnt >> 2; uint8_t *f = v->vram;
  uint64_t lo = dst < src ? dst : src;
  if (lo >= cap) return;
  if ((uint64_t)dst + cnt <= cap && (uint64_t)src + cnt <= cap &&
      ((uint64_t)dst + cnt <= src || (uint64_t)src + cnt <= dst)) { memcpy(f + dst, f + src, cnt); v->dirty++; return; }
  for (uint64_t i = 0; i < n4; i++) {           /* forward dword loop (rep movsd order) */
    uint64_t d = (uint64_t)dst + i * 4, s = (uint64_t)src + i * 4;
    if (d >= cap && s >= cap) return;
    uint8_t t[4];
    for (int j = 0; j < 4; j++) t[j] = (s + j < cap) ? f[s + j] : 0;
    for (int j = 0; j < 4; j++) if (d + j < cap) f[d + j] = t[j];
  }
  for (uint32_t j = 0; j < (cnt & 3); j++) {       /* trailing bytes */
    uint64_t d = (uint64_t)dst + n4 * 4 + j, s = (uint64_t)src + n4 * 4 + j;
    if (d < cap) f[d] = (s < cap) ? f[s] : 0;
  }
  v->dirty++;
}
static void fb_fill(nan_vm *v, uint32_t cnt, uint32_t start, uint8_t c) {
  uint64_t cap = NAN_VRAM;
  if (start >= cap) return;
  uint64_t n = cnt; if (start + n > cap) n = cap - start;
  memset(v->vram + start, c, (size_t)n); v->dirty++;
}

static void dispset(nan_vm *v, uint32_t x) {
  if (x >= 0xFFFF0000u) { v->rawkb = x & 255; v->rhead = v->rtail = 0; return; }
  if (x >= 0x10000u) {
    v->fbw = x >> 16; v->fbh = x & 0xFFFF; uint64_t t = (uint64_t)v->fbw * v->fbh;
    v->fbtot = (uint32_t)t; v->vmode = 1;
    memset(v->vram, 0, t > NAN_VRAM ? NAN_VRAM : (size_t)(t & ~3ull));
  } else if ((x & 255) == 0x13) {
    v->vmode = 1; v->fbtot = 64000; v->fbw = 320; v->fbh = 200; memset(v->vram, 0, 64000);
  } else {
    v->vmode = 0; v->fbw = 80; v->fbh = 25;
    for (int i = 0; i < 2000; i++) v->cells[i] = 0;
  }
  v->dirty++; v->frame++;
}

/* ---- kernel ABI v0.1 (spec/KERNEL_ABI.md) ----
 * Frame words use the normal NaN16 class +q/+q representation so guest LD
 * reads the 32-bit payload directly.  The kernel ABI is active as soon as
 * the entry port is set; before that, 0x4E/0x4F keep their old reserved-op
 * trap behaviour. */
static uint32_t kabi_fw(const uint64_t *f, int i) { return (uint32_t)(f[i] >> 16); }
static int kabi_frame_ok(const nan_vm *v) {
  return v->kframe != NAN_KABI_UNSET &&
         (uint64_t)v->kframe + NAN_TF_WORDS <= v->mem_words;
}
static int kabi_vector(nan_vm *v, uint32_t cause, uint32_t resume_pc, uint32_t imm) {
  if (v->kentry == NAN_KABI_UNSET || v->kentry >= v->mem_words ||
      !kabi_frame_ok(v)) return -1;
  if (v->kstack != NAN_KABI_UNSET && v->kstack >= v->mem_words) return -1;
  uint64_t *f = v->mem + v->kframe;
  for (int i = 0; i < 16; i++) f[i] = nan_mkword(v->r[i], 10);
  f[NAN_TF_PC] = nan_mkword(resume_pc, 10);
  f[NAN_TF_K] = nan_mkword((uint32_t)(v->k & 3), 10);
  f[NAN_TF_ADDRH] = nan_mkword(0, 10);          /* ADDRH is not in the S1 C core */
  f[NAN_TF_CAUSE] = nan_mkword(cause & 3u, 10);
  f[NAN_TF_IMM] = nan_mkword(imm, 10);
  f[NAN_TF_RET] = nan_mkword(0, 10);
  f[NAN_TF_SP] = nan_mkword(v->r[14], 10);
  f[NAN_TF_RESERVED] = nan_mkword(0, 10);
  if (v->kstack != NAN_KABI_UNSET) v->r[14] = v->kstack;
  v->kin = 1;
  v->ktimer_pending = (cause == NAN_CAUSE_IRQ) ? 1u : 0u;
  v->ktrap_pending = (cause != NAN_CAUSE_IRQ) ? 1u : 0u;
  v->pc = v->kentry;
  return 0;
}
static int kabi_restore(nan_vm *v) {
  if (!kabi_frame_ok(v)) return -1;
  const uint64_t *f = v->mem + v->kframe;
  for (int i = 0; i < 16; i++) v->r[i] = kabi_fw(f, i);
  v->k = (int)(kabi_fw(f, NAN_TF_K) & 3u);
  v->pc = kabi_fw(f, NAN_TF_PC);
  /* An SVC return value is carried in frame[21]; IRQ/fault resumes keep
      the guest r1 saved in frame[1]. */
  if ((kabi_fw(f, NAN_TF_CAUSE) & 3u) == NAN_CAUSE_SVC)
    v->r[1] = kabi_fw(f, NAN_TF_RET);
  v->halted = 0;
  v->kin = 0;
  v->ktimer_pending = v->ktrap_pending = 0;
  return 0;
}
/* Region table: {base word, nwords, kind, prot}; nwords==0 terminates.
 * Every word of [first, first+nwords) must be covered by an entry whose
 * prot contains all requested bits.  Adjacent entries may split a block. */
static int kabi_region_range(const nan_vm *v, uint32_t first, uint32_t nwords,
                             uint32_t prot) {
  if (v->kregions == NAN_KABI_UNSET || v->kin) return 1;
  if (!nwords) return 1;
  uint64_t end = (uint64_t)first + nwords;
  if (end > v->mem_words) return 0;
  uint64_t covered = first;
  while (covered < end) {
    int found = 0;
    for (uint32_t e = v->kregions;
         (uint64_t)e + NAN_REGION_WORDS <= v->mem_words;
         e += NAN_REGION_WORDS) {
      const uint64_t *q = v->mem + e;
      uint32_t base = kabi_fw(q, 0), nw = kabi_fw(q, 1), p = kabi_fw(q, 3);
      if (nw == 0) break;
      uint64_t rend = (uint64_t)base + nw;
      if (covered >= base && covered < rend) {
        if ((p & prot) != prot) return 0;
        covered = end < rend ? end : rend;
        found = 1;
        break;
      }
    }
    if (!found) return 0;
  }
  return 1;
}
/* Kernel control ports are configured by the boot path before the entry
 * port is set.  Once the ABI is live, only kernel-mode code may write them;
 * a guest write is a region-style fault. */
static int kabi_port_locked(const nan_vm *v, uint32_t port) {
  return v->kentry != NAN_KABI_UNSET && !v->kin &&
         port >= NAN_KABI_PORT_ENTRY && port <= NAN_KABI_PORT_STATUS;
}
static int kabi_byte_range(const nan_vm *v, uint32_t byte_addr, uint32_t nbytes,
                           uint32_t prot) {
  if (v->kregions == NAN_KABI_UNSET || v->kin) return 1;
  if (!nbytes) return 1;
  uint64_t end = (uint64_t)byte_addr + nbytes;
  if (end > (uint64_t)v->mem_words * 4u) return 0;
  uint32_t first = byte_addr >> 2;
  uint32_t last = (uint32_t)((end - 1) >> 2);
  return kabi_region_range(v, first, last - first + 1u, prot);
}

/* The goto (not continue) is deliberate: a continue inside do{}while(0)
 * would only leave the macro's own loop and fall through into the faulting
 * access.  `restart` is after the timer tick, so the aborted instruction
 * neither commits nor consumes an instruction slot. */
#define KABI_FAULT(retpc, faddr) do { \
  if (v->kentry == NAN_KABI_UNSET || v->kin || \
      kabi_vector(v, NAN_CAUSE_FAULT, (retpc), (faddr))) { \
    trap(v, 'K', (retpc)); pc = v->pc; LEAVE(NAN_HALTED); \
  } \
  pc = v->pc; goto restart; \
} while (0)
#define KABI_GUEST_FAULT(retpc, faddr) do { \
  if (v->kentry != NAN_KABI_UNSET && !v->kin) KABI_FAULT((retpc), (faddr)); \
} while (0)

int nan_run(nan_vm *v, uint32_t max_steps) {
  uint32_t *r = v->r; uint64_t *mem = v->mem;
  const uint32_t M = v->mem_mask;
  uint32_t pc = v->pc; uint32_t done = 0;
  int rc = NAN_BUDGET;
#define SETK(z, l) (v->k = 2 * (int)(z) + (int)(l))
#define LEAVE(code) do { rc = (code); goto out; } while (0)
  if (v->halted) return NAN_HALTED;
  while (done < max_steps) {
    done++; v->steps++;
    uint32_t at = pc;
    if (v->kregions != NAN_KABI_UNSET && !v->kin &&
        (uint64_t)v->kregions + NAN_REGION_WORDS > v->mem_words) {
      trap(v, 'K', at); pc = v->pc; LEAVE(NAN_HALTED);
    }
    if (!kabi_region_range(v, at, 1, NAN_PROT_X)) KABI_FAULT(at, at);
    uint64_t w = mem[at & M];
    uint32_t nh = nan_near(w), fh = nan_far(w);
    if (!nan_hvalid(nh) || !nan_hvalid(fh)) {
      KABI_GUEST_FAULT(at, at);
      trap(v, 'G', pc + 1); pc = v->pc; LEAVE(NAN_HALTED);
    }
    pc++;
    uint32_t p = (uint32_t)(w >> 16), op = p >> 24;
    int n = (int)((nan_hcls(nh) << 2) | nan_hcls(fh));
    if (op == 0xFF) { v->halted = 1; LEAVE(NAN_HALTED); }
    if (op > 0x5F) {
      KABI_GUEST_FAULT(at, at);
      trap(v, 'O', pc); pc = v->pc; LEAVE(NAN_HALTED);
    }
    if (op != 0 && !((n >> v->k) & 1)) goto tick;
    if (v->trace) v->trace(v->trace_ctx, at, p, n, v->k);
    uint32_t d = (p >> 20) & 15, a = (p >> 16) & 15, imm = p & 0xFFFF;
    uint32_t A = r[a], B = r[imm & 15];
    switch (op) {
    case 0x00: { uint32_t res = 0;
      if (n & 1) res |= ~(A | B); if (n & 2) res |= ~A & B; if (n & 4) res |= A & ~B; if (n & 8) res |= A & B;
      r[d] = res; SETK(res == 0, 0); break; }
    case 0x01: r[d] = imm; break;
    case 0x02: r[d] = (r[d] & 0xFFFF) | (imm << 16); break;
    case 0x03: { uint64_t s = (uint64_t)A + B; r[d] = (uint32_t)s; SETK((uint32_t)s == 0, s >> 32); break; }
    case 0x04: { uint32_t res = A - B; r[d] = res; SETK(res == 0, A < B); break; }
    case 0x05: { uint32_t res = A << (p & 31); r[d] = res; SETK(res == 0, 0); break; }
    case 0x06: { uint32_t res = A >> (p & 31); r[d] = res; SETK(res == 0, 0); break; }
    case 0x27: { uint32_t res = (uint32_t)((int32_t)A >> (p & 31)); r[d] = res; SETK(res == 0, 0); break; }
    case 0x07: SETK(A == B, A < B); break;
    case 0x28: SETK(A == B, (int32_t)A < (int32_t)B); break;
    case 0x08: { uint32_t ad = A + imm;
      if (!kabi_region_range(v, ad, 1, NAN_PROT_R)) KABI_FAULT(at, ad);
      r[d] = (uint32_t)(mem[ad & M] >> 16); break; }
    case 0x09: { uint32_t ad = A + imm;
      if (!kabi_region_range(v, ad, 1, NAN_PROT_W)) KABI_FAULT(at, ad);
      mem[ad & M] = nan_mkword(r[d], 10); break; }
    case 0x0A: pc = imm; break;
    case 0x0B: r[15] = pc; pc = imm; break;
    case 0x0C: pc = r[15]; break;
    case 0x0D: pc = A; break;
    case 0x2C: r[15] = pc; pc = A; break;
    case 0x0E: case 0x1E: case 0x1F:
      KABI_GUEST_FAULT(at, at);
      trap(v, 'O', pc); pc = v->pc; LEAVE(NAN_HALTED);
    case 0x0F: case 0x1B: case 0x2F: break;
    case 0x10: { uint32_t i = A;
      if (v->vmode == 1) { if (i < v->fbtot && i < NAN_VRAM) { v->vram[i] = (uint8_t)r[d]; v->dirty++; } }
      else if (i < 2000) { v->cells[i] = (uint16_t)r[d]; v->dirty++; } break; }
    case 0x11: { uint32_t i = A;
      if (v->vmode == 1) { if (i < v->fbtot && i < NAN_VRAM) r[d] = v->vram[i]; }
      else if (i < 2000) r[d] = v->cells[i]; break; }
    case 0x12: { int c = nan_ring_pop(v);
      if (c < 0) { pc = at; v->steps--; LEAVE(NAN_WAIT_KEY); }
      r[d] = (uint32_t)c; break; }
    case 0x1A: { int c = nan_ring_pop(v); r[d] = c < 0 ? 0 : (uint32_t)c; break; }
    case 0x13: r[d] = v->ms;
      if (v->ms == v->tick_last) { if (++v->tick_same >= 256) { v->tick_same = 0; LEAVE(NAN_TIME_WAIT); } }
      else { v->tick_last = v->ms; v->tick_same = 0; }
      break;
    case 0x14: { uint32_t ad = A + imm;
      if (!kabi_region_range(v, ad, 1, NAN_PROT_R | NAN_PROT_W)) KABI_FAULT(at, ad);
      uint64_t *q = &mem[ad & M]; *q = __builtin_bswap64(*q); break; }
    case 0x15: nan_ser_putc(v, (uint8_t)r[d]); break;
    case 0x16: if (!kabi_region_range(v, A, 1, NAN_PROT_W)) KABI_FAULT(at, A);
      mem[A & M] = nan_mkword(r[d], (int)(B & 15)); break;
    case 0x1C: { uint32_t ad = 0xF0000u + imm;
      if (!kabi_region_range(v, ad, 1, NAN_PROT_R)) KABI_FAULT(at, ad);
      r[d] = (uint32_t)(mem[ad & M] >> 16); break; }
    case 0x1D: { uint32_t ad = 0xF0000u + imm;
      if (!kabi_region_range(v, ad, 1, NAN_PROT_W)) KABI_FAULT(at, ad);
      mem[ad & M] = nan_mkword(r[d], 10); break; }
    case 0x17: { uint32_t ad = A + imm;
      if (!kabi_region_range(v, ad, 1, NAN_PROT_R)) KABI_FAULT(at, ad);
      uint64_t q = mem[ad & M];
      r[d] = (nan_hvalid(nan_near(q)) && nan_hvalid(nan_far(q))) ? ((nan_hcls(nan_near(q)) << 2) | nan_hcls(nan_far(q))) : 0xFFFFFFFFu; break; }
    case 0x18: r[d] = v->vmode == 1 ? 0x1300C800u : 0x00031950u; break;
    case 0x19: dispset(v, r[d]); break;
    case 0x20: { uint32_t res = A * B; r[d] = res; SETK(res == 0, 0); break; }
    case 0x21: { uint32_t res = (uint32_t)(((int64_t)(int32_t)A * (int32_t)B) >> 32); r[d] = res; SETK(res == 0, 0); break; }
    case 0x22: { uint32_t res = (uint32_t)(((uint64_t)A * B) >> 32); r[d] = res; SETK(res == 0, 0); break; }
    case 0x23: case 0x24: case 0x25: case 0x26: {
      uint32_t res;
      if (B == 0) { res = (op == 0x23 || op == 0x25) ? 0 : A; r[d] = res; v->k = 3; break; }
      if (op == 0x23) res = (B == 0xFFFFFFFFu) ? 0u - A : (uint32_t)((int32_t)A / (int32_t)B);
      else if (op == 0x24) res = (B == 0xFFFFFFFFu) ? 0 : (uint32_t)((int32_t)A % (int32_t)B);
      else if (op == 0x25) res = A / B; else res = A % B;
      r[d] = res; SETK(res == 0, 0); break; }
    case 0x29: { uint32_t s2 = (uint32_t)(int32_t)(int16_t)imm; uint64_t s = (uint64_t)A + s2;
      r[d] = (uint32_t)s; SETK((uint32_t)s == 0, s >> 32); break; }
    case 0x2A: { uint32_t ad = A + imm;
      if (!kabi_byte_range(v, ad, 1, NAN_PROT_R)) KABI_FAULT(at, ad);
      r[d] = ((uint32_t)(mem[(ad >> 2) & M] >> 16) >> ((ad & 3) * 8)) & 0xFF; break; }
    case 0x2B: { uint32_t ad = A + imm, sh = (ad & 3) * 8;
      if (!kabi_byte_range(v, ad, 1, NAN_PROT_W)) KABI_FAULT(at, ad);
      uint64_t *q = &mem[(ad >> 2) & M];
      uint32_t pl = (uint32_t)(*q >> 16); pl = (pl & ~(0xFFu << sh)) | ((r[d] & 0xFF) << sh); *q = nan_mkword(pl, 10); break; }
    case 0x2D: { uint32_t src = A, dst = r[d], cnt = B;
      if (!kabi_region_range(v, src, cnt, NAN_PROT_R)) KABI_FAULT(at, src);
      if (!kabi_region_range(v, dst, cnt, NAN_PROT_W)) KABI_FAULT(at, dst);
      src &= M; dst &= M;
      if (cnt) {
        if (((dst - src) & M) < cnt) { uint32_t s = (src + cnt - 1) & M, t = (dst + cnt - 1) & M;
          for (uint32_t i = 0; i < cnt; i++) { mem[t] = mem[s]; s = (s - 1) & M; t = (t - 1) & M; } }
        else for (uint32_t i = 0; i < cnt; i++) { mem[dst] = mem[src]; src = (src + 1) & M; dst = (dst + 1) & M; } }
      break; }
    case 0x2E: { uint32_t dst = r[d], cnt = B;
      if (!kabi_region_range(v, dst, cnt, NAN_PROT_W)) KABI_FAULT(at, dst);
      uint64_t wd = nan_mkword(A, 10);
      for (uint32_t i = 0; i < cnt; i++) mem[(dst + i) & M] = wd; break; }
    case 0x30: case 0x31: case 0x32: r[d] = fp_bin((int)op, A, B); v->k = 0; break;
    case 0x33: r[d] = fp_div(A, B); v->k = 0; break;
    case 0x34: r[d] = fp_sqrt(A); v->k = 0; break;
    case 0x35: if (is_nan32(A) || is_nan32(B)) v->k = 3; else SETK(f32(A) == f32(B), f32(A) < f32(B)); break;
    case 0x36: { volatile float f = (float)(int32_t)A; r[d] = u32(f); v->k = 0; break; }
    case 0x37: { uint32_t res = fp_cvtfi(A); r[d] = res; SETK(res == 0, 0); break; }
    case 0x46: r[d] = fp_unary(A, 0x46); v->k = 0; break;  /* FEXP */
    case 0x47: r[d] = fp_unary(A, 0x47); v->k = 0; break;  /* FTANH */
    case 0x48: r[d] = fp_unary(A, 0x48); v->k = 0; break;  /* FLOG */
    case 0x38: pc = p & 0xFFFFFF; break;
    case 0x39: r[15] = pc; pc = p & 0xFFFFFF; break;
    case 0x3A: r[d] = (v->fbw << 16) | v->fbh; break;
    case 0x3B: if (v->vmode == 1) { v->frame++; LEAVE(NAN_VSYNC); } break;
    case 0x3C: fb_copy(v, r[d], A, B); break;
    case 0x3D: fb_fill(v, r[d], A, (uint8_t)B); break;
    case 0x3E: { uint32_t po = A & 0xFFFF;
      if (kabi_port_locked(v, po)) KABI_FAULT(at, po);
      nan_port_out(v, po, r[d], 1); break; }
    case 0x3F: r[d] = nan_port_in(v, A & 0xFFFF, 1) & 0xFF; break;
    case 0x40: r[d] = nan_port_in(v, A & 0xFFFF, 2) & 0xFFFF; break;
    case 0x41: { uint32_t po = A & 0xFFFF;
      if (kabi_port_locked(v, po)) KABI_FAULT(at, po);
      nan_port_out(v, po, r[d] & 0xFFFF, 2); break; }
    case 0x42: { uint32_t cnt = r[d], idx = B, po = A & 0xFFFF;
      if (kabi_port_locked(v, po)) KABI_FAULT(at, po);
      if (!kabi_region_range(v, idx, cnt, NAN_PROT_R)) KABI_FAULT(at, idx);
      for (uint32_t i = 0; i < cnt; i++, idx++) nan_port_out(v, A & 0xFFFF, (uint32_t)(mem[idx & M] >> 16) & 0xFFFF, 2); break; }
    case 0x43: { uint32_t po = A & 0xFFFF;
      if (kabi_port_locked(v, po)) KABI_FAULT(at, po);
      nan_port_out(v, po, r[d], 4); break; }
    case 0x44: { uint32_t reg[4] = {0, 0, 0, 0};
      if (A == 0x4E4D00FFu) {              /* machine-memory discovery */
        reg[0] = v->mem_mask;
        reg[1] = v->mem_words;
        reg[2] = 0x4E160001u;              /* "N16" + dynamic-size flag */
        reg[3] = v->mem_words * 4u;        /* guest C payload bytes */
      } else switch (A) {
      case 0: reg[0] = 0x16; reg[1] = 0x314E614Eu /* "NaN1" */; reg[3] = 0x726F4336u /* "6Cor" */; reg[2] = 0x4D565F65u /* "e_VM" */; break;
      case 1: reg[0] = 0x00000F10; reg[3] = 0x00000001; break;
      case 0x80000000u: reg[0] = 0x80000004u; break;
      case 0x80000001u: reg[3] = 1u << 29; break;
      case 0x80000002u: memcpy(reg, "NaN16 portable C", 16); break;
      case 0x80000003u: memcpy(reg, " core (not x86) ", 16); break;
      case 0x80000004u: break; }
      r[d] = reg[B & 3]; break; }
    case 0x45: r[d] = A == 0 ? (uint32_t)v->steps : (uint32_t)(v->steps >> 32); break;
    /* ---- 512-bit abstract vector family (0x50-0x5F) ---- */
    case 0x50: memset(v->vreg[d], 0, 64); break;
    case 0x51: { uint32_t *q = (uint32_t *)(void *)v->vreg[d];
      for (int i = 0; i < 16; i++) q[i] = A; break; }
    case 0x52: if (!kabi_byte_range(v, A, 64, NAN_PROT_R)) KABI_FAULT(at, A);
      nan_read_bytes(v, A, v->vreg[d], 64); break;
    case 0x53: if (!kabi_byte_range(v, A, 64, NAN_PROT_W)) KABI_FAULT(at, A);
      nan_write_bytes(v, A, v->vreg[d], 64); break;
    case 0x54: for (int i = 0; i < 64; i++) v->vreg[d][i] = (uint8_t)(v->vreg[a][i] + v->vreg[imm & 15][i]); break;
    case 0x55: for (int i = 0; i < 64; i++) v->vreg[d][i] = (uint8_t)(v->vreg[a][i] - v->vreg[imm & 15][i]); break;
    case 0x56: { uint32_t *q = (uint32_t *)(void *)v->vreg[d];
      const uint32_t *x = (const uint32_t *)(const void *)v->vreg[a];
      const uint32_t *y = (const uint32_t *)(const void *)v->vreg[imm & 15];
      for (int i = 0; i < 16; i++) q[i] = x[i] + y[i]; break; }
    case 0x57: { uint32_t *q = (uint32_t *)(void *)v->vreg[d];
      const uint32_t *x = (const uint32_t *)(const void *)v->vreg[a];
      const uint32_t *y = (const uint32_t *)(const void *)v->vreg[imm & 15];
      for (int i = 0; i < 16; i++) q[i] = x[i] - y[i]; break; }
    case 0x58: { uint32_t *q = (uint32_t *)(void *)v->vreg[d];
      const uint32_t *x = (const uint32_t *)(const void *)v->vreg[a];
      const uint32_t *y = (const uint32_t *)(const void *)v->vreg[imm & 15];
      for (int i = 0; i < 16; i++) q[i] = x[i] * y[i]; break; }
    case 0x59: { uint32_t *q = (uint32_t *)(void *)v->vreg[d];
      const uint32_t *x = (const uint32_t *)(const void *)v->vreg[a];
      const uint32_t *y = (const uint32_t *)(const void *)v->vreg[imm & 15];
      for (int i = 0; i < 16; i++) {
        int32_t acc = 0;
        for (int k = 0; k < 4; k++) {
          int32_t av = (int32_t)(int8_t)((x[i] >> (8*k)) & 0xFF);
          int32_t bv = (int32_t)(int8_t)((y[i] >> (8*k)) & 0xFF);
          acc += av * bv;
        }
        q[i] = (uint32_t)acc;
      }
      break; }
    case 0x5E: r[d] = ((const uint32_t *)(const void *)v->vreg[a])[imm & 15]; break;
    case 0x5F: ((uint32_t *)(void *)v->vreg[d])[imm & 15] = A; break;
    case 0x4C: { /* VDP4B4: 8 signed Q4 weights x 8 signed i8 activations
                    per 32-bit lane.  Activations come from Vb and V(b+1). */
      const uint32_t *ww = (const uint32_t *)(const void *)v->vreg[a];
      const uint8_t *a0 = v->vreg[imm & 15];
      const uint8_t *a1 = v->vreg[(imm + 1) & 15];
      uint32_t *q = (uint32_t *)(void *)v->vreg[d];
      for (int i = 0; i < 16; i++) {
        uint32_t w = ww[i];
        int32_t acc = 0;
        for (int j = 0; j < 4; j++) {
          int32_t wv = (int32_t)((w >> (4*j)) & 0xF);
          if (wv & 8) wv -= 16;
          acc += wv * (int32_t)(int8_t)a0[i*4+j];
        }
        for (int j = 0; j < 4; j++) {
          int32_t wv = (int32_t)((w >> (4*(j+4))) & 0xF);
          if (wv & 8) wv -= 16;
          acc += wv * (int32_t)(int8_t)a1[i*4+j];
        }
        q[i] = (uint32_t)acc;
      }
      break; }
    case 0x4A: { /* DP4B: four signed i8 lanes, dot product */
      int32_t acc = 0;
      for (int i = 0; i < 4; i++) {
        int32_t av = (int32_t)(int8_t)((A >> (8*i)) & 0xFF);
        int32_t bv = (int32_t)(int8_t)((B >> (8*i)) & 0xFF);
        acc += av * bv;
      }
      r[d] = (uint32_t)acc; SETK(acc == 0, 0); break; }
    /* ---- kernel ABI v0.1 (spec/KERNEL_ABI.md) ---- */
    case 0x4D: r[d] = nan_port_in(v, A & 0xFFFFu, 4); break;      /* INL  */
    case 0x4E: {                                                  /* SVC  */
      if (v->kentry == NAN_KABI_UNSET || v->kin) {
        trap(v, 'O', pc); pc = v->pc; LEAVE(NAN_HALTED);
      }
      if (kabi_vector(v, NAN_CAUSE_SVC, pc, imm)) {
        trap(v, 'K', pc); pc = v->pc; LEAVE(NAN_HALTED);
      }
      pc = v->pc; break; }
    case 0x4F: {                                                  /* SVCRET */
      if (!v->kin) { trap(v, 'O', pc); pc = v->pc; LEAVE(NAN_HALTED); }
      if (kabi_restore(v)) { trap(v, 'K', pc); pc = v->pc; LEAVE(NAN_HALTED); }
      pc = v->pc; break; }
    default: KABI_GUEST_FAULT(at, at);
      trap(v, 'O', pc); pc = v->pc; LEAVE(NAN_HALTED);
    }
  tick:
    /* Timer is sampled at instruction boundaries, never while the kernel
       is running.  It counts every completed instruction. */
    if (v->ktimer && !v->kin) {
      if (v->ktimer_left == 0) v->ktimer_left = v->ktimer;
      if (--v->ktimer_left == 0) {
        v->ktimer_left = v->ktimer;
        if (kabi_vector(v, NAN_CAUSE_IRQ, pc, 0)) {
          trap(v, 'K', pc); pc = v->pc; LEAVE(NAN_HALTED);
        }
        pc = v->pc;
      }
    }
  restart: ;
  }
out:
  v->pc = pc;
  return rc;
}
