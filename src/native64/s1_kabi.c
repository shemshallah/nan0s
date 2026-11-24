/* s1_kabi.c - x86_64 bare-metal S1 first slice for the NaN/0S kernel ABI.
 *
 * Normative format: spec/KERNEL_ABI.md.  This is NOT the full NaN16 core:
 * it implements the fetch/gate/predication path plus the integer, memory,
 * port and trap instructions needed to prove the S1 boundary on the product
 * target.  Guest words live at 0x200000 (512 KiB, 64K words); COM1 is the
 * terminal.  Floating point, vectors, display and ATA remain on the portable
 * oracle until the full x86_64 S1 port.
 *
 * Build: tools/kabi64_gate.sh.  Everything here is freestanding C99; the
 * only assembly is s1_boot.S (long-mode entry).
 */
#include <stdint.h>
#include <stddef.h>

#ifndef S1_GUEST_MEM
#define S1_GUEST_MEM 0x10000u
#endif
#ifndef S1_GUEST_STEPS
#define S1_GUEST_STEPS 20000000u
#endif
#ifndef S1_GUEST_STACK
#define S1_GUEST_STACK (S1_GUEST_MEM - (S1_GUEST_MEM / 8u))
#endif
#ifndef S1_GUEST_ZERO_WORDS
#define S1_GUEST_ZERO_WORDS S1_GUEST_MEM
#endif
#define MEM_BASE   0x200000ul
#define MEM_WORDS  S1_GUEST_MEM
#define MEM_MASK   (MEM_WORDS - 1u)
#define UNSET      0xFFFFFFFFu
#define NAN_HALTED 3

/* Single-threaded S1: ordinary accesses; no DMA/IRQ writer observes these. */
#define MEM ((uint64_t *)(uintptr_t)MEM_BASE)

/* ---- freestanding libc surface the compiler may reference ---- */
void *memset(void *d, int c, size_t n) {
  uint8_t *p = (uint8_t *)d;
  while (n--) *p++ = (uint8_t)c;
  return d;
}
void *memcpy(void *d, const void *s, size_t n) {
  uint8_t *p = (uint8_t *)d; const uint8_t *q = (const uint8_t *)s;
  while (n--) *p++ = *q++;
  return d;
}

/* ---- COM1 ---- */
static inline void outb(uint16_t port, uint8_t v) {
  __asm__ volatile("outb %0,%1" : : "a"(v), "Nd"(port));
}
#ifdef S1_GUEST
static inline void outl(uint16_t port, uint32_t v) {
  __asm__ volatile("outl %0,%1" : : "a"(v), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
  uint8_t v; __asm__ volatile("inb %1,%0" : "=a"(v) : "Nd"(port)); return v;
}
static inline uint16_t inw(uint16_t port) {
  uint16_t v; __asm__ volatile("inw %1,%0" : "=a"(v) : "Nd"(port)); return v;
}
#endif
static void serial_init(void) {
  outb(0x3F9, 0x00); outb(0x3FB, 0x80); outb(0x3F8, 0x01);
  outb(0x3F9, 0x00); outb(0x3FB, 0x03); outb(0x3FA, 0xC7); outb(0x3FC, 0x0B);
}
static void serial_putc(char c) {
  uint8_t lsr;
  do { __asm__ volatile("inb %1,%0" : "=a"(lsr) : "Nd"((uint16_t)0x3FD)); } while (!(lsr & 0x20));
  outb(0x3F8, (uint8_t)c);
}
static void serial_puts(const char *s) { while (*s) serial_putc(*s++); }
static void put_hex32(uint32_t x) {
  static const char hx[] = "0123456789ABCDEF";
  serial_puts("0x");
  for (int i = 28; i >= 0; i -= 4) serial_putc(hx[(x >> i) & 15]);
}
#ifndef S1_GUEST
static void put_dec(uint32_t x) {
  char b[12]; int n = 0;
  if (!x) { serial_putc('0'); return; }
  while (x) { b[n++] = (char)('0' + x % 10u); x /= 10u; }
  while (n) serial_putc(b[--n]);
}
#endif
#ifdef S1_GUEST
/* QEMU debug console (port 0xE9): machine status without polluting COM1,
 * so the guest transcript can be compared byte-for-byte with the C oracle. */
static void dbg_putc(char c) { outb(0xE9, (uint8_t)c); }
static void dbg_puts(const char *s) { while (*s) dbg_putc(*s++); }
static void dbg_dec(uint32_t x) {
  char b[12]; int n = 0;
  if (!x) { dbg_putc('0'); return; }
  while (x) { b[n++] = (char)('0' + x % 10u); x /= 10u; }
  while (n) dbg_putc(b[--n]);
}
static void dbg_hex32(uint32_t x) {
  static const char hx[] = "0123456789ABCDEF";
  dbg_puts("0x");
  for (int i = 28; i >= 0; i -= 4) dbg_putc(hx[(x >> i) & 15]);
}
#endif

/* ---- NaN16 word helpers ---- */
static const uint16_t HEADS[4] = {0x7FF1, 0xFFF1, 0x7FF8, 0xFFF8};
static uint32_t hcls(uint32_t h) { return ((h >> 2) & 2u) | (h >> 15); }
static int hvalid(uint32_t h) { return (h & 0x7FF0u) == 0x7FF0u && ((h & 15u) == 1u || (h & 15u) == 8u); }
static uint32_t w_near(uint64_t w) { return (uint32_t)(w >> 48); }
static uint32_t w_far(uint64_t w) { return (uint32_t)(((w & 0xFFu) << 8) | ((w >> 8) & 0xFFu)); }
static uint64_t mkword(uint32_t payload, int n) {
  uint32_t far = HEADS[n & 3], near = HEADS[(n >> 2) & 3];
  return (uint64_t)(far >> 8) | ((uint64_t)(far & 0xFF) << 8) |
         ((uint64_t)payload << 16) | ((uint64_t)near << 48);
}
static uint32_t word_payload(uint32_t i) { return (uint32_t)(MEM[i & MEM_MASK] >> 16); }

/* ---- scalar FP (nan16.c/OPS.md semantics, SSE2 + freestanding helpers) ---- */
static inline int is_nan32(uint32_t x) {
  return (x & 0x7F800000u) == 0x7F800000u && (x & 0x007FFFFFu);
}
static inline float f32bits(uint32_t x) { float f; memcpy(&f, &x, 4); return f; }
static inline uint32_t u32bits(float f) { uint32_t x; memcpy(&x, &f, 4); return x; }
static float fp_inf(void) { return f32bits(0x7F800000u); }
static float fp_sqrtf(float a) {
  float r;
  __asm__ volatile("sqrtss %1,%0" : "=x"(r) : "x"(a));
  return r;
}
static float fp_expf(float x) {
  if (x != x) return x;
  if (x > 88.0f) return fp_inf();
  if (x < -103.0f) return 0.0f;
  int n = (int)(x * 1.4426950408889634f + (x < 0 ? -0.5f : 0.5f));
  if (n < -126) return 0.0f;
  float r = x - (float)n * 0.6931471805599453f;
  float term = 1.0f, sum = 1.0f;
  for (int i = 1; i <= 8; i++) { term *= r / (float)i; sum += term; }
  uint32_t scale_bits = (uint32_t)(n + 127) << 23;
  return sum * f32bits(scale_bits);
}
static float fp_logf(float x) {
  if (x != x) return x;
  if (x == 0.0f) return f32bits(0xFF800000u);
  if (x < 0.0f) return f32bits(0x7FC00000u);
  if (x == fp_inf()) return x;
  uint32_t b = u32bits(x);
  int e = (int)((b >> 23) & 0xFFu) - 127;
  float m = f32bits((b & 0x007FFFFFu) | 0x3F800000u);
  if (e == -127) { m = f32bits(b & 0x007FFFFFu); }
  float z = (m - 1.0f) / (m + 1.0f), z2 = z * z, p = z, sum = 0.0f;
  for (int k = 1; k <= 31; k += 2) { sum += p / (float)k; p *= z2; }
  return 2.0f * sum + (float)e * 0.6931471805599453f;
}
static float fp_tanhf(float x) {
  if (x != x) return x;
  if (x > 12.0f) return 1.0f;
  if (x < -12.0f) return -1.0f;
  float e = fp_expf(2.0f * x);
  return (e - 1.0f) / (e + 1.0f);
}
static uint32_t fp_bin(int op, uint32_t A, uint32_t B) {
  if (is_nan32(A)) return A | 0x00400000u;
  if (is_nan32(B)) return B | 0x00400000u;
  volatile float a = f32bits(A), b = f32bits(B), r;
  switch (op) {
  case 0x30: r = a + b; break;
  case 0x31: r = a - b; break;
  case 0x32: r = a * b; break;
  default: r = a / b; break;
  }
  uint32_t x = u32bits(r);
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
  return u32bits(fp_sqrtf(f32bits(A)));
}
static uint32_t fp_cvtfi(uint32_t A) {
  if (is_nan32(A)) return 0;
  float f = f32bits(A);
  if (f >= 2147483648.0f) return 0x7FFFFFFFu;
  if (f <= -2147483648.0f) return 0x80000000u;
  return (uint32_t)(int32_t)f;
}
static uint32_t fp_unary(uint32_t A, int op) {
  if (is_nan32(A)) return A | 0x00400000u;
  float a = f32bits(A), r;
  if (op == 0x46) r = fp_expf(a);
  else if (op == 0x47) r = fp_tanhf(a);
  else r = fp_logf(a);
  uint32_t x = u32bits(r);
  return is_nan32(x) ? 0x7FC00000u : x;
}

/* ---- S1 state ---- */
typedef struct {
  uint32_t r[16], pc, k, halted;
  uint64_t steps;
  uint32_t kentry, kframe, ktimer, ktimer_left, kstack, kregions, ktcb;
  uint32_t kin, ktimer_pending, ktrap_pending;
} S1;
static S1 s;

enum { CAUSE_SVC = 0, CAUSE_IRQ = 1, CAUSE_FAULT = 2 };
enum { PROT_R = 1, PROT_W = 2, PROT_X = 4 };
enum { TF_PC = 16, TF_K = 17, TF_ADDRH = 18, TF_CAUSE = 19,
       TF_IMM = 20, TF_RET = 21, TF_SP = 22, TF_WORDS = 24 };

static void s1_reset(void) {
  for (uint32_t i = 0; i < S1_GUEST_ZERO_WORDS; i++) MEM[i] = 0;
  for (int i = 0; i < 16; i++) s.r[i] = 0;
  s.pc = 0; s.k = 0; s.halted = 0; s.steps = 0;
  s.kentry = s.kframe = s.kstack = s.kregions = s.ktcb = UNSET;
  s.ktimer = s.ktimer_left = 0;
  s.kin = s.ktimer_pending = s.ktrap_pending = 0;
}
static int frame_ok(void) {
  return s.kframe != UNSET && s.kframe <= MEM_WORDS - TF_WORDS;
}
static uint32_t frame_w(uint32_t i) { return (uint32_t)(MEM[s.kframe + i] >> 16); }
static int kabi_vector(uint32_t cause, uint32_t resume_pc, uint32_t imm) {
  if (s.kentry == UNSET || s.kentry >= MEM_WORDS || !frame_ok()) return 0;
  if (s.kstack != UNSET && s.kstack >= MEM_WORDS) return 0;
  uint32_t f = s.kframe;
  for (int i = 0; i < 16; i++) MEM[f + (uint32_t)i] = mkword(s.r[i], 10);
  MEM[f + TF_PC] = mkword(resume_pc, 10);
  MEM[f + TF_K] = mkword(s.k & 3u, 10);
  MEM[f + TF_ADDRH] = mkword(0, 10);
  MEM[f + TF_CAUSE] = mkword(cause & 3u, 10);
  MEM[f + TF_IMM] = mkword(imm, 10);
  MEM[f + TF_RET] = mkword(0, 10);
  MEM[f + TF_SP] = mkword(s.r[14], 10);
  MEM[f + TF_WORDS - 1] = mkword(0, 10);
  if (s.kstack != UNSET) s.r[14] = s.kstack;
  s.kin = 1;
  s.ktimer_pending = (cause == CAUSE_IRQ) ? 1u : 0u;
  s.ktrap_pending = (cause != CAUSE_IRQ) ? 1u : 0u;
  s.pc = s.kentry;
  return 1;
}
static int kabi_restore(void) {
  if (!frame_ok()) return 0;
  for (int i = 0; i < 16; i++) s.r[i] = frame_w((uint32_t)i);
  s.k = (int)(frame_w(TF_K) & 3u);
  s.pc = frame_w(TF_PC);
  if ((frame_w(TF_CAUSE) & 3u) == CAUSE_SVC) s.r[1] = frame_w(TF_RET);
  s.halted = 0;
  s.kin = 0;
  s.ktimer_pending = s.ktrap_pending = 0;
  return 1;
}
/* Region table: 4 words {base, nwords, kind, prot}; nwords=0 terminates. */
static int region_range(uint32_t first, uint32_t nwords, uint32_t prot) {
  if (s.kregions == UNSET || s.kin) return 1;
  if (!nwords) return 1;
  uint64_t end = (uint64_t)first + nwords;
  if (end > MEM_WORDS) return 0;
  uint64_t covered = first;
  while (covered < end) {
    int found = 0;
    for (uint32_t e = s.kregions; (uint64_t)e + 4u <= MEM_WORDS; e += 4u) {
      uint32_t base = word_payload(e), nw = word_payload(e + 1);
      uint32_t p = word_payload(e + 3);
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
static int byte_range(uint32_t addr, uint32_t nbytes, uint32_t prot) {
  if (s.kregions == UNSET || s.kin) return 1;
  if (!nbytes) return 1;
  uint64_t end = (uint64_t)addr + nbytes;
  if (end > (uint64_t)MEM_WORDS * 4u) return 0;
  uint32_t first = addr >> 2;
  uint32_t last = (uint32_t)((end - 1) >> 2);
  return region_range(first, last - first + 1u, prot);
}
static char last_trap;
static int quiet_trap;                    /* set only by expected-error tests */
static void trapk(uint32_t pc) {
  last_trap = 'K';
  if (!quiet_trap) { serial_puts("!K"); put_hex32(pc); serial_putc('\n'); }
  s.halted = 1;
}
static void badop(uint32_t pc) {
  last_trap = 'O';
  if (!quiet_trap) { serial_puts("!O"); put_hex32(pc); serial_putc('\n'); }
  s.halted = 1;
}
static void badgate(uint32_t pc) {
  last_trap = 'G';
  if (!quiet_trap) { serial_puts("!G"); put_hex32(pc); serial_putc('\n'); }
  s.halted = 1;
}

/* Control ports: word addresses.  The interpreter is the machine, so these
 * are emulated here, not real x86 port I/O (COM1 excepted). */
static void port_out(uint16_t port, uint32_t v) {
  switch (port) {
  case 0x4E00: s.kentry = v; break;
  case 0x4E01: s.kframe = v; break;
  case 0x4E02: s.ktimer = v; s.ktimer_left = v; break;
  case 0x4E03: s.kstack = v; break;
  case 0x4E04: s.kregions = v; break;
  case 0x4E05: s.ktcb = v; break;
  case 0x3F8: serial_putc((char)v); break;
  default: break;
  }
}
static uint32_t port_in(uint16_t port) {
  switch (port) {
  case 0x4E06: return (s.ktimer_pending ? 1u : 0u) | (s.ktrap_pending ? 2u : 0u);
  case 0x4E00: return s.kentry;
  case 0x4E01: return s.kframe;
  case 0x4E02: return s.ktimer;
  case 0x4E03: return s.kstack;
  case 0x4E04: return s.kregions;
  case 0x4E05: return s.ktcb;
  default: return 0xFFFFFFFFu;
  }
}

#ifdef S1_GUEST
/* Guest time/steps control block (guest BYTE addresses):
   0x03EFF010 ms, +4 steps low, +8 steps high.  The C core publishes the same
   block, so tcc libc time/nanosleep work unchanged. */
static void guest_write_u32(uint32_t byte_addr, uint32_t v) {
  uint32_t wi = byte_addr >> 2;
  if (wi >= MEM_WORDS) return;          /* e.g. --mem 64: no time block */
  MEM[wi] = mkword(v, 10);
}
static void guest_write_byte(uint32_t byte_addr, uint8_t v) {
  uint32_t wi = byte_addr >> 2;
  if (wi >= MEM_WORDS) return;
  uint32_t sh = (byte_addr & 3u) * 8u;
  uint32_t pl = (uint32_t)(MEM[wi] >> 16);
  pl = (pl & ~(0xFFu << sh)) | ((uint32_t)v << sh);
  MEM[wi] = mkword(pl, 10);
}
static void guest_write_bytes(uint32_t byte_addr, const uint8_t *src, uint32_t len) {
  for (uint32_t i = 0; i < len; i++) guest_write_byte(byte_addr + i, src[i]);
}
static void guest_publish_time(void) {
  uint32_t ms = (uint32_t)(s.steps / 1000u);
  guest_write_u32(0x03EFF010u, ms);
  guest_write_u32(0x03EFF014u, (uint32_t)s.steps);
  guest_write_u32(0x03EFF018u, (uint32_t)(s.steps >> 32));
}
#endif

#define SETK(z, l) (s.k = 2u * (uint32_t)(z) + (uint32_t)(l))
/* `goto restart`, not `continue`: continue would only leave do{}while(0)
 * and fall through into the faulting access. */
#define S1_VECTOR(cause, retpc, faddr) do { \
  if (!kabi_vector((cause), (retpc), (faddr))) { trapk(retpc); return NAN_HALTED; } \
  pc = s.pc; goto restart; \
} while (0)
#define S1_GUEST_FAULT(retpc, faddr) do { \
  if (s.kentry != UNSET && !s.kin) S1_VECTOR(CAUSE_FAULT, (retpc), (faddr)); \
} while (0)

static uint32_t s1_run(uint64_t budget) {
  uint32_t pc = s.pc;
  uint64_t done = 0;
  while (done < budget) {
    done++; s.steps++;
#ifdef S1_GUEST
    if ((s.steps & 1023u) == 0) guest_publish_time();
#endif
    uint32_t at = pc;
    if (s.kregions != UNSET && !s.kin &&
        (uint64_t)s.kregions + 4u > MEM_WORDS) {
      trapk(at); s.pc = at; s.halted = 1; return NAN_HALTED;
    }
    if (s.kregions != UNSET && !s.kin &&
        !region_range(at, 1, PROT_X)) S1_VECTOR(CAUSE_FAULT, at, at);
    uint64_t w = MEM[at & MEM_MASK];
    uint32_t nh = w_near(w), fh = w_far(w);
    if (!hvalid(nh) || !hvalid(fh)) {
      S1_GUEST_FAULT(at, at);
      badgate(pc + 1); s.pc = pc; return NAN_HALTED;
    }
    pc++;
    uint32_t p = (uint32_t)(w >> 16), op = p >> 24;
    uint32_t n = (hcls(nh) << 2) | hcls(fh);
    if (op == 0xFF) { s.halted = 1; s.pc = pc; return NAN_HALTED; }
    if (op > 0x5F) {
      S1_GUEST_FAULT(at, at);
      badop(pc); s.pc = pc; return NAN_HALTED;
    }
    if (op != 0 && !((n >> s.k) & 1u)) goto tick;
    uint32_t d = (p >> 20) & 15u, a = (p >> 16) & 15u, imm = p & 0xFFFFu;
    uint32_t A = s.r[a], B = s.r[imm & 15u];
    switch (op) {
    case 0x00: { uint32_t res = 0;
      if (n & 1) res |= ~(A | B); if (n & 2) res |= ~A & B;
      if (n & 4) res |= A & ~B; if (n & 8) res |= A & B;
      s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x01: s.r[d] = imm; break;
    case 0x02: s.r[d] = (s.r[d] & 0xFFFFu) | (imm << 16); break;
    case 0x03: { uint64_t sum = (uint64_t)A + B; s.r[d] = (uint32_t)sum;
      SETK((uint32_t)sum == 0, sum >> 32); break; }
    case 0x04: { uint32_t res = A - B; s.r[d] = res; SETK(res == 0, A < B); break; }
    case 0x05: { uint32_t res = A << (p & 31u); s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x06: { uint32_t res = A >> (p & 31u); s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x27: { uint32_t res = (uint32_t)((int32_t)A >> (p & 31u)); s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x07: SETK(A == B, A < B); break;
    case 0x28: SETK(A == B, (int32_t)A < (int32_t)B); break;
    case 0x08: { uint32_t ad = A + imm;
      if (s.kregions != UNSET && !s.kin &&
          !region_range(ad, 1, PROT_R)) S1_VECTOR(CAUSE_FAULT, at, ad);
      s.r[d] = (uint32_t)(MEM[ad & MEM_MASK] >> 16); break; }
    case 0x09: { uint32_t ad = A + imm;
      if (s.kregions != UNSET && !s.kin &&
          !region_range(ad, 1, PROT_W)) S1_VECTOR(CAUSE_FAULT, at, ad);
      MEM[ad & MEM_MASK] = mkword(s.r[d], 10); break; }
    case 0x0A: pc = imm; break;
    case 0x0B: s.r[15] = pc; pc = imm; break;
    case 0x0C: pc = s.r[15]; break;
    case 0x0D: pc = A; break;
    case 0x0F: case 0x1B: case 0x2F: break;
    case 0x14: { uint32_t ad = A + imm;
      if (s.kregions != UNSET && !s.kin &&
          !region_range(ad, 1, PROT_R | PROT_W)) S1_VECTOR(CAUSE_FAULT, at, ad);
      uint64_t q = MEM[ad & MEM_MASK];
      MEM[ad & MEM_MASK] = __builtin_bswap64(q); break; }
    case 0x15: serial_putc((char)(s.r[d] & 0xFFu)); break;
    case 0x16: if (s.kregions != UNSET && !s.kin &&
                   !region_range(A, 1, PROT_W)) S1_VECTOR(CAUSE_FAULT, at, A);
      MEM[A & MEM_MASK] = mkword(s.r[d], (int)(B & 15u)); break;
    case 0x17: { uint32_t ad = A + imm;
      if (s.kregions != UNSET && !s.kin &&
          !region_range(ad, 1, PROT_R)) S1_VECTOR(CAUSE_FAULT, at, ad);
      uint64_t q = MEM[ad & MEM_MASK];
      s.r[d] = (hvalid(w_near(q)) && hvalid(w_far(q)))
             ? ((hcls(w_near(q)) << 2) | hcls(w_far(q))) : 0xFFFFFFFFu; break; }
    case 0x20: { uint32_t res = A * B; s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x21: { uint32_t res = (uint32_t)(((int64_t)(int32_t)A * (int32_t)B) >> 32);
      s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x22: { uint32_t res = (uint32_t)(((uint64_t)A * B) >> 32);
      s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x23: case 0x24: case 0x25: case 0x26: {
      uint32_t res;
      if (B == 0) { res = (op == 0x23 || op == 0x25) ? 0 : A; s.r[d] = res; s.k = 3; break; }
      if (op == 0x23) res = (B == 0xFFFFFFFFu) ? 0u - A : (uint32_t)((int32_t)A / (int32_t)B);
      else if (op == 0x24) res = (B == 0xFFFFFFFFu) ? 0 : (uint32_t)((int32_t)A % (int32_t)B);
      else if (op == 0x25) res = A / B; else res = A % B;
      s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x2C: s.r[15] = pc; pc = A; break;
    case 0x30: case 0x31: case 0x32: s.r[d] = fp_bin((int)op, A, B); s.k = 0; break;
    case 0x33: s.r[d] = fp_div(A, B); s.k = 0; break;
    case 0x34: s.r[d] = fp_sqrt(A); s.k = 0; break;
    case 0x35: if (is_nan32(A) || is_nan32(B)) s.k = 3;
      else SETK(f32bits(A) == f32bits(B), f32bits(A) < f32bits(B)); break;
    case 0x36: { volatile float f = (float)(int32_t)A; s.r[d] = u32bits(f); s.k = 0; break; }
    case 0x37: { uint32_t res = fp_cvtfi(A); s.r[d] = res; SETK(res == 0, 0); break; }
    case 0x46: s.r[d] = fp_unary(A, 0x46); s.k = 0; break;
    case 0x47: s.r[d] = fp_unary(A, 0x47); s.k = 0; break;
    case 0x48: s.r[d] = fp_unary(A, 0x48); s.k = 0; break;
    case 0x29: { uint32_t s2 = (uint32_t)(int32_t)(int16_t)imm;
      uint64_t sum = (uint64_t)A + s2; s.r[d] = (uint32_t)sum;
      SETK((uint32_t)sum == 0, sum >> 32); break; }
    case 0x2A: { uint32_t ad = A + imm;
      if (s.kregions != UNSET && !s.kin &&
          !byte_range(ad, 1, PROT_R)) S1_VECTOR(CAUSE_FAULT, at, ad);
      s.r[d] = ((uint32_t)(MEM[(ad >> 2) & MEM_MASK] >> 16) >> ((ad & 3u) * 8u)) & 0xFFu; break; }
    case 0x2B: { uint32_t ad = A + imm, sh = (ad & 3u) * 8u;
      if (s.kregions != UNSET && !s.kin &&
          !byte_range(ad, 1, PROT_W)) S1_VECTOR(CAUSE_FAULT, at, ad);
      uint32_t pl = (uint32_t)(MEM[(ad >> 2) & MEM_MASK] >> 16);
      pl = (pl & ~(0xFFu << sh)) | ((s.r[d] & 0xFFu) << sh);
      MEM[(ad >> 2) & MEM_MASK] = mkword(pl, 10); break; }
    case 0x2D: { uint32_t src = A, dst = s.r[d], cnt = B;
      if (s.kregions != UNSET && !s.kin && !region_range(src, cnt, PROT_R))
        S1_VECTOR(CAUSE_FAULT, at, src);
      if (s.kregions != UNSET && !s.kin && !region_range(dst, cnt, PROT_W))
        S1_VECTOR(CAUSE_FAULT, at, dst);
      src &= MEM_MASK; dst &= MEM_MASK;
      if (cnt) {
        if (((dst - src) & MEM_MASK) < cnt) {
          uint32_t sp = (src + cnt - 1) & MEM_MASK, dp = (dst + cnt - 1) & MEM_MASK;
          for (uint32_t i = 0; i < cnt; i++) { MEM[dp] = MEM[sp]; sp = (sp - 1) & MEM_MASK; dp = (dp - 1) & MEM_MASK; }
        } else {
          for (uint32_t i = 0; i < cnt; i++) { MEM[dst] = MEM[src]; src = (src + 1) & MEM_MASK; dst = (dst + 1) & MEM_MASK; }
        }
      }
      break; }
    case 0x2E: { uint32_t dst = s.r[d], cnt = B;
      if (s.kregions != UNSET && !s.kin &&
          !region_range(dst, cnt, PROT_W)) S1_VECTOR(CAUSE_FAULT, at, dst);
      uint64_t wd = mkword(A, 10);
      for (uint32_t i = 0; i < cnt; i++) MEM[(dst + i) & MEM_MASK] = wd; break; }
    case 0x38: pc = p & 0xFFFFFFu; break;
    case 0x39: s.r[15] = pc; pc = p & 0xFFFFFFu; break;
    case 0x43: port_out((uint16_t)(A & 0xFFFFu), s.r[d]); break;
    case 0x4D: s.r[d] = port_in((uint16_t)(A & 0xFFFFu)); break;
    case 0x4E: {
      if (s.kentry == UNSET || s.kin) { badop(pc); s.pc = pc; return NAN_HALTED; }
      if (!kabi_vector(CAUSE_SVC, pc, imm)) { trapk(pc); s.pc = pc; return NAN_HALTED; }
      pc = s.pc; break; }
    case 0x4F: {
      if (!s.kin) { badop(pc); s.pc = pc; return NAN_HALTED; }
      if (!kabi_restore()) { trapk(pc); s.pc = pc; return NAN_HALTED; }
      pc = s.pc; break; }
    default: S1_GUEST_FAULT(at, at);
      badop(pc); s.pc = pc; return NAN_HALTED;
    }
  tick:
    if (s.ktimer && !s.kin) {
      if (s.ktimer_left == 0) s.ktimer_left = s.ktimer;
      if (--s.ktimer_left == 0) {
        s.ktimer_left = s.ktimer;
        if (!kabi_vector(CAUSE_IRQ, pc, 0)) { trapk(pc); s.pc = pc; return NAN_HALTED; }
        pc = s.pc;
      }
    }
  restart: ;
  }
  s.pc = pc;
  return 0;
}

#ifndef S1_GUEST
/* ---- KABI self-tests (oracle/mechanics build) ---- */
static uint32_t checks, fails, pw;
#define ENTRY  0x1000u
#define FRAME  0x2000u
#define KSTACK 0x3000u
#define RTAB   0x4000u
#define TCB    0x5000u

static void emit(uint32_t op, uint32_t d, uint32_t a, uint32_t imm, uint32_t n) {
  MEM[pw++] = mkword((op << 24) | (d << 20) | (a << 16) | (imm & 0xFFFFu), (int)n);
}
static void ins(uint32_t op, uint32_t d, uint32_t a, uint32_t imm) { emit(op, d, a, imm, 15); }
static void halt_emit(void) { emit(0xFF, 0, 0, 0, 15); }
static void begin_at(uint32_t pc) { s1_reset(); last_trap = 0; pw = pc; s.pc = pc; }
static void kernel_halt(void) { uint32_t save = pw; pw = ENTRY; halt_emit(); pw = save; }
static void cfg(uint32_t entry, uint32_t frame, uint32_t timer, uint32_t stack, uint32_t regions) {
  port_out(0x4E00, entry); port_out(0x4E01, frame); port_out(0x4E02, timer);
  port_out(0x4E03, stack); port_out(0x4E04, regions); port_out(0x4E05, TCB);
}
static void region_entry(uint32_t slot, uint32_t base, uint32_t nwords, uint32_t kind, uint32_t prot) {
  MEM[RTAB + slot * 4 + 0] = mkword(base, 10); MEM[RTAB + slot * 4 + 1] = mkword(nwords, 10);
  MEM[RTAB + slot * 4 + 2] = mkword(kind, 10); MEM[RTAB + slot * 4 + 3] = mkword(prot, 10);
}
static void region_one(uint32_t base, uint32_t nwords, uint32_t kind, uint32_t prot) {
  region_entry(0, base, nwords, kind, prot); region_entry(1, 0, 0, 0, 0);
}
static void check(int cond, const char *what) {
  checks++;
  if (!cond) { fails++; serial_puts("FAIL "); serial_puts(what); serial_putc('\n'); }
}
static void eq(uint32_t got, uint32_t want, const char *what) {
  checks++;
  if (got != want) {
    fails++; serial_puts("FAIL "); serial_puts(what);
    serial_puts(" got="); put_hex32(got); serial_puts(" want="); put_hex32(want); serial_putc('\n');
  }
}
static void set_pc(uint32_t pc) { s.pc = pc; s.halted = 0; }
static uint32_t run_expected_k(void) {
  quiet_trap = 1;
  uint32_t rc = s1_run(100);
  quiet_trap = 0;
  return rc;
}

static void t_svc(void) {
  begin_at(0);
  cfg(ENTRY, FRAME, 0, KSTACK, UNSET);
  ins(0x01, 1, 0, 0x111); ins(0x01, 2, 0, 0x222);
  ins(0x01, 3, 0, 0x333); ins(0x01, 4, 0, 0x444);
  ins(0x01, 14, 0, 0xABC);
  ins(0x07, 0, 0, 0);                       /* k=2 */
  ins(0x01, 6, 0, 0x666);
  ins(0x4E, 0, 0, 0);                       /* SVC yield */
  uint32_t resume = pw;
  ins(0x01, 7, 0, 0x777); halt_emit();
  kernel_halt();
  eq(s1_run(1000), NAN_HALTED, "svc halted");
  eq(s.pc, ENTRY + 1, "svc entry pc");
  eq(frame_w(1), 0x111, "frame r1"); eq(frame_w(2), 0x222, "frame r2");
  eq(frame_w(3), 0x333, "frame r3"); eq(frame_w(4), 0x444, "frame r4");
  eq(frame_w(TF_PC), resume, "frame resume pc");
  eq(frame_w(TF_K), 2, "frame k");
  eq(frame_w(TF_CAUSE), CAUSE_SVC, "frame cause svc");
  eq(frame_w(TF_IMM), 0, "frame syscall yield");
  eq(frame_w(TF_RET), 0, "frame ret initial");
  eq(frame_w(TF_SP), 0xABC, "frame saved sp");
  eq(s.r[14], KSTACK, "kernel stack loaded");
  eq(port_in(0x4E06), 2, "trap status");
  MEM[ENTRY + 1] = mkword(0x4F000000u, 15);  /* SVCRET */
  MEM[FRAME + TF_RET] = mkword(0x55, 10);
  set_pc(ENTRY + 1);
  eq(s1_run(1000), NAN_HALTED, "svcret guest halt");
  eq(s.r[1], 0x55, "svc return r1");
  eq(s.r[7], 0x777, "resume after svc");
  eq(s.r[14], 0xABC, "restored sp");
  eq(s.k, 2, "restored k");
  eq(port_in(0x4E06), 0, "status cleared");
  /* SVC 1 (exit) number in frame[20] */
  begin_at(0); cfg(ENTRY, FRAME, 0, KSTACK, UNSET);
  ins(0x01, 1, 0, 7); ins(0x4E, 0, 0, 1); halt_emit(); kernel_halt();
  eq(s1_run(100), NAN_HALTED, "svc exit halted");
  eq(frame_w(TF_CAUSE), CAUSE_SVC, "exit cause");
  eq(frame_w(TF_IMM), 1, "exit number");
  eq(frame_w(1), 7, "exit arg");
}

static void t_ports(void) {
  begin_at(0);
  ins(0x01, 1, 0, 0x4E00); ins(0x01, 2, 0, ENTRY); ins(0x43, 2, 1, 0);
  ins(0x01, 1, 0, 0x4E01); ins(0x01, 2, 0, FRAME); ins(0x43, 2, 1, 0);
  ins(0x01, 1, 0, 0x4E02); ins(0x01, 2, 0, 16); ins(0x43, 2, 1, 0);
  ins(0x01, 1, 0, 0x4E03); ins(0x01, 2, 0, KSTACK); ins(0x43, 2, 1, 0);
  ins(0x01, 1, 0, 0x4E05); ins(0x01, 2, 0, TCB); ins(0x43, 2, 1, 0);
  ins(0x01, 1, 0, 0x4E04); ins(0x01, 2, 0, 0xFFFF); ins(0x02, 2, 0, 0xFFFF);
  ins(0x43, 2, 1, 0);                        /* REGIONS = 0xFFFFFFFF */
  ins(0x01, 1, 0, 0x4E06); ins(0x4D, 3, 1, 0);
  halt_emit();
  eq(s1_run(100), NAN_HALTED, "ports halted");
  eq(s.kentry, ENTRY, "port entry"); eq(s.kframe, FRAME, "port frame");
  eq(s.ktimer, 16, "port timer"); eq(s.kstack, KSTACK, "port kstack");
  eq(s.kregions, UNSET, "port regions unset"); eq(s.ktcb, TCB, "port tcb");
  eq(s.r[3], 0, "INL status idle");
}

static void t_timer(void) {
  begin_at(0);
  for (int i = 0; i < 6; i++) ins(0x0F, 0, 0, 0);
  halt_emit();
  pw = ENTRY;
  ins(0x01, 1, 0, 0x4E06); ins(0x4D, 5, 1, 0); halt_emit();
  cfg(ENTRY, FRAME, 4, KSTACK, UNSET);
  eq(s1_run(100), NAN_HALTED, "timer kernel halt");
  eq(s.pc, ENTRY + 3, "timer kernel pc");
  eq(frame_w(TF_PC), 4, "timer resume pc");
  eq(frame_w(TF_CAUSE), CAUSE_IRQ, "timer cause");
  eq(frame_w(TF_IMM), 0, "timer imm");
  eq(frame_w(1), 0, "timer frame r1");
  eq(s.r[5], 1, "INL timer pending");
  eq(port_in(0x4E06), 1, "status timer");
  MEM[ENTRY + 3] = mkword(0x4F000000u, 15);
  set_pc(ENTRY + 3);
  eq(s1_run(100), NAN_HALTED, "timer resumed halt");
  eq(port_in(0x4E06), 0, "timer status cleared");
  eq(s.r[1], 0, "timer does not invent r1");
}

static void fault_setup(uint32_t prot) {
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_one(0x100, 0x20, 0, prot);
  kernel_halt();
}

static void t_regions(void) {
  /* read fault */
  fault_setup(PROT_R | PROT_W | PROT_X);
  ins(0x01, 1, 0, 0x400); ins(0x08, 2, 1, 0); halt_emit();
  uint32_t ldpc = pw - 2;
  eq(s1_run(100), NAN_HALTED, "read fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "read cause");
  eq(frame_w(TF_PC), ldpc, "read fault pc");
  eq(frame_w(TF_IMM), 0x400, "read fault addr");
  eq(port_in(0x4E06), 2, "read fault status");
  MEM[ENTRY + 1] = mkword(0x4F000000u, 15);
  MEM[FRAME + TF_PC] = mkword(ldpc + 1, 10);
  set_pc(ENTRY + 1);
  eq(s1_run(100), NAN_HALTED, "read fault skipped");

  /* write fault */
  fault_setup(PROT_R | PROT_X);
  ins(0x01, 1, 0, 0x110); ins(0x01, 2, 0, 0x55); ins(0x09, 2, 1, 0); halt_emit();
  uint32_t stpc = pw - 2;
  eq(s1_run(100), NAN_HALTED, "write fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "write cause");
  eq(frame_w(TF_PC), stpc, "write fault pc");
  eq(frame_w(TF_IMM), 0x110, "write fault addr");

  /* execute fault */
  fault_setup(PROT_R | PROT_W);
  ins(0x01, 1, 0, 1); halt_emit();
  eq(s1_run(100), NAN_HALTED, "exec fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "exec cause");
  eq(frame_w(TF_PC), 0x100, "exec fault pc");
  eq(frame_w(TF_IMM), 0x100, "exec fault addr");

  /* byte faults */
  fault_setup(PROT_R | PROT_X);
  ins(0x01, 1, 0, 0x440); ins(0x01, 2, 0, 0x41); ins(0x2B, 2, 1, 0); halt_emit();
  eq(s1_run(100), NAN_HALTED, "stb fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "stb cause");
  eq(frame_w(TF_IMM), 0x440, "stb fault addr");
  fault_setup(PROT_R | PROT_X);
  ins(0x01, 1, 0, 0x480); ins(0x2A, 2, 1, 0); halt_emit();
  eq(s1_run(100), NAN_HALTED, "ldb fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "ldb cause");
  eq(frame_w(TF_IMM), 0x480, "ldb fault addr");

  /* block faults */
  fault_setup(PROT_R | PROT_W | PROT_X);
  ins(0x01, 1, 0, 0x200); ins(0x01, 3, 0, 0x110); ins(0x01, 2, 0, 4);
  ins(0x2D, 3, 1, 2); halt_emit();
  eq(s1_run(100), NAN_HALTED, "bcopy fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "bcopy cause");
  eq(frame_w(TF_IMM), 0x200, "bcopy fault addr");
  fault_setup(PROT_R | PROT_W | PROT_X);
  ins(0x01, 1, 0, 0x99); ins(0x01, 3, 0, 0x200); ins(0x01, 2, 0, 4);
  ins(0x2E, 3, 1, 2); halt_emit();
  eq(s1_run(100), NAN_HALTED, "bfill fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "bfill cause");
  eq(frame_w(TF_IMM), 0x200, "bfill fault addr");

  /* BSWAPM is read+write */
  fault_setup(PROT_R | PROT_X);
  ins(0x01, 1, 0, 0x110); ins(0x14, 2, 1, 0); halt_emit();
  eq(s1_run(100), NAN_HALTED, "bswapm fault halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "bswapm cause");
  eq(frame_w(TF_IMM), 0x110, "bswapm fault addr");

  /* adjacent entries split a legal block: src 0x128..0x137 crosses the
     0x130 boundary, dst 0x130..0x13f stays in the second entry.  The code
     at 0x100 is outside the copied range. */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_entry(0, 0x100, 0x10, 0, PROT_R | PROT_W | PROT_X);
  region_entry(1, 0x120, 0x10, 0, PROT_R | PROT_W | PROT_X);
  region_entry(2, 0x130, 0x10, 0, PROT_R | PROT_W | PROT_X);
  region_entry(3, 0, 0, 0, 0);
  kernel_halt();
  ins(0x01, 1, 0, 0x128); ins(0x01, 3, 0, 0x130); ins(0x01, 2, 0, 0x10);
  ins(0x2D, 3, 1, 2); halt_emit();
  eq(s1_run(100), NAN_HALTED, "split block halted");
  check(s.kin == 0, "split block no trap");
}

static void t_bounds(void) {
  /* last legal 24-word frame */
  begin_at(0);
  cfg(ENTRY, MEM_WORDS - TF_WORDS, 0, KSTACK, UNSET);
  ins(0x4E, 0, 0, 0); halt_emit(); kernel_halt();
  eq(s1_run(100), NAN_HALTED, "last frame halted");
  eq(frame_w(TF_CAUSE), CAUSE_SVC, "last frame cause");
  eq((uint32_t)(MEM[MEM_WORDS - 1u] >> 16), 0, "last frame word");
  /* frame span crossing the end */
  begin_at(0);
  cfg(ENTRY, MEM_WORDS - 12, 0, KSTACK, UNSET);
  ins(0x4E, 0, 0, 0); halt_emit();
  eq(run_expected_k(), NAN_HALTED, "short frame halted");
  eq(last_trap, 'K', "short frame is config error");
  /* a byte address is not a word address */
  begin_at(0);
  cfg(ENTRY, MEM_WORDS, 0, KSTACK, UNSET);
  ins(0x4E, 0, 0, 0); halt_emit();
  eq(run_expected_k(), NAN_HALTED, "byte frame halted");
  eq(last_trap, 'K', "byte frame rejected");
  /* entry outside guest memory */
  begin_at(0);
  cfg(MEM_WORDS, FRAME, 0, KSTACK, UNSET);
  ins(0x4E, 0, 0, 0); halt_emit();
  eq(run_expected_k(), NAN_HALTED, "bad entry halted");
  eq(last_trap, 'K', "bad entry rejected");
  /* kernel stack outside guest memory */
  begin_at(0);
  cfg(ENTRY, FRAME, 0, MEM_WORDS, UNSET);
  ins(0x4E, 0, 0, 0); halt_emit();
  eq(run_expected_k(), NAN_HALTED, "bad kstack halted");
  eq(last_trap, 'K', "bad kstack rejected");
  /* region table cannot hold one entry */
  begin_at(0);
  cfg(ENTRY, FRAME, 0, KSTACK, MEM_WORDS - 2);
  ins(0x01, 1, 0, 0); halt_emit();
  eq(run_expected_k(), NAN_HALTED, "bad regions halted");
  eq(last_trap, 'K', "bad regions rejected");
  /* gap between regions: legal read, then a hole fault */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_entry(0, 0x100, 0x10, 0, PROT_R | PROT_W | PROT_X);
  region_entry(1, 0x120, 0x10, 0, PROT_R | PROT_W | PROT_X);
  region_entry(2, 0, 0, 0, 0);
  MEM[0x120] = mkword(0x1234, 10);
  kernel_halt();
  ins(0x01, 1, 0, 0x120); ins(0x08, 2, 1, 0);
  ins(0x01, 1, 0, 0x110); ins(0x08, 3, 1, 0);
  halt_emit();
  eq(s1_run(100), NAN_HALTED, "gap halt");
  eq(s.r[2], 0x1234, "gap legal read");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "gap cause");
  eq(frame_w(TF_IMM), 0x110, "gap fault addr");
  check(s.kin == 1, "kernel entered outside X region");
  /* gate failure vectors as cause=2 in guest mode */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_entry(0, 0x100, 0x10, 0, PROT_R | PROT_W | PROT_X);
  region_entry(1, 0, 0, 0, 0);
  kernel_halt();
  MEM[0x100] = 0;
  eq(s1_run(100), NAN_HALTED, "gate vector halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "gate vector cause");
  eq(frame_w(TF_PC), 0x100, "gate vector pc");
  eq(frame_w(TF_IMM), 0x100, "gate vector addr");
  eq(last_trap, 0, "gate vector not legacy !G");
  /* unpredictable op 0x49 vectors as cause=2 */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_entry(0, 0x100, 0x10, 0, PROT_R | PROT_W | PROT_X);
  region_entry(1, 0, 0, 0, 0);
  kernel_halt();
  MEM[0x100] = mkword(0x49000000u, 15);
  eq(s1_run(100), NAN_HALTED, "badop vector halt");
  eq(frame_w(TF_CAUSE), CAUSE_FAULT, "badop vector cause");
  eq(frame_w(TF_PC), 0x100, "badop vector pc");
  eq(frame_w(TF_IMM), 0x100, "badop vector addr");
  eq(last_trap, 0, "badop vector not legacy !O");
}

void s1_main(void) {
  serial_init();
  serial_puts("NAN0S S1 KABI x86_64\n");
  t_svc();
  t_ports();
  t_timer();
  t_regions();
  t_bounds();
  if (fails) {
    serial_puts("S1 KABI x86_64 FAIL ");
    put_dec(fails); serial_puts(" failures / "); put_dec(checks); serial_puts(" checks\n");
  } else {
    serial_puts("S1 KABI x86_64 PASS ");
    put_dec(checks); serial_puts(" checks, 0 failures\n");
  }
  for (;;) __asm__ volatile("hlt");
}

#else /* S1_GUEST: run a flat cartridge placed at guest word 0. */
extern const uint32_t s1_guest_bytes;
extern const uint32_t s1_guest_disk;
extern const uint32_t s1_guest_script_len;
extern const uint8_t s1_guest_script[];
extern const uint32_t s1_peek_count;
extern const uint32_t s1_peek_specs[];

static void serial_hex8(uint32_t x) {
  static const char hx[] = "0123456789ABCDEF";
  for (int i = 28; i >= 0; i -= 4) serial_putc(hx[(x >> i) & 15]);
}
static void serial_dec(uint32_t x) {
  char b[12]; int n = 0;
  if (!x) { serial_putc('0'); return; }
  while (x) { b[n++] = (char)('0' + x % 10u); x /= 10u; }
  while (n) serial_putc(b[--n]);
}
static uint32_t guest_read_word(uint32_t word_addr) {
  return (uint32_t)(MEM[word_addr & MEM_MASK] >> 16);
}
static uint32_t guest_read_u32(uint32_t byte_addr) {
  uint32_t wi = byte_addr >> 2;
  return wi < MEM_WORDS ? (uint32_t)(MEM[wi & MEM_MASK] >> 16) : 0;
}
static uint8_t guest_read_byte(uint32_t byte_addr) {
  uint32_t wi = (byte_addr >> 2) & MEM_MASK;
  return (uint8_t)(((uint32_t)(MEM[wi] >> 16) >> ((byte_addr & 3u) * 8u)) & 0xFFu);
}
static void guest_emit_bytes(uint32_t ptr, uint32_t len) {
  uint64_t cap = (uint64_t)MEM_WORDS * 4u;
  if (ptr >= cap) return;
  if ((uint64_t)ptr + len > cap) len = (uint32_t)(cap - ptr);
  for (uint32_t i = 0; i < len; i++) serial_putc((char)guest_read_byte(ptr + i));
}
static void guest_dump_console(uint32_t ctl, const char *tag) {
  uint32_t ptr = guest_read_u32(ctl), len = guest_read_u32(ctl + 4u);
  uint64_t cap = (uint64_t)MEM_WORDS * 4u;
  if (!ptr || ptr >= cap) len = 0;
  else if ((uint64_t)ptr + len > cap) len = (uint32_t)(cap - ptr);
  serial_puts("@@NAN16 "); serial_puts(tag); serial_putc(' ');
  serial_dec(len); serial_putc('\n');
  if (len) guest_emit_bytes(ptr, len);
  serial_putc('\n');
}
static void guest_dump_peeks(void) {
  uint32_t n = s1_peek_count;
  for (uint32_t i = 0; i < n; i++) {
    uint32_t addr = s1_peek_specs[i * 2u], cnt = s1_peek_specs[i * 2u + 1u];
    for (uint32_t j = 0; j < cnt; j++) {
      serial_puts("@@NAN16 PEEK "); serial_hex8(guest_read_word(addr + j));
      serial_putc('\n');
    }
  }
}
static void guest_frame(uint32_t rc) {
  uint32_t end = (rc == NAN_HALTED && !last_trap) ? 3u : (last_trap ? 4u : 2u);
  guest_dump_console(0x03EFF000u, "SOUT");
  guest_dump_console(0x03EFF008u, "SERR");
  guest_dump_peeks();
  serial_puts("@@NAN16 END "); serial_dec(end); serial_putc('\n');
}

static int ata_read_sector(uint32_t lba, uint8_t *dst) {
  outb(0x1F6, (uint8_t)(0xE0u | ((lba >> 24) & 0x0Fu)));
  outb(0x1F1, 0);
  outb(0x1F2, 1);
  outb(0x1F3, (uint8_t)(lba & 0xFFu));
  outb(0x1F4, (uint8_t)((lba >> 8) & 0xFFu));
  outb(0x1F5, (uint8_t)((lba >> 16) & 0xFFu));
  outb(0x1F7, 0x20);                    /* READ SECTORS, PIO */
  for (uint32_t spin = 0; spin < 2000000u; spin++) {
    uint8_t st = inb(0x1F7);
    if (st & 0x80u) continue;           /* BSY */
    if (st & 0x01u) return -1;          /* ERR */
    if (st & 0x08u) break;              /* DRQ */
    if (spin == 1999999u) return -1;
  }
  for (int i = 0; i < 256; i++) ((uint16_t *)dst)[i] = inw(0x1F0);
  return 0;
}
static uint32_t guest_load_image(void) {
  uint32_t bytes = s1_guest_bytes;
  uint32_t words = bytes / 8u;
  if (!bytes || (bytes % 8u) || words > MEM_WORDS) return 0;
  if (s1_guest_disk) {
    uint32_t sectors = (bytes + 511u) / 512u;
    for (uint32_t i = 0; i < sectors; i++)
      if (ata_read_sector(i, (uint8_t *)MEM + (size_t)i * 512u)) return 0;
    return words;
  }
  if (bytes > 0xC0000u) return 0;
  /* Small path: the boot fixture staged guest bytes at physical 0x40000
     (0x40000..0xFFFFF, 768 KiB max).  Copy them into guest word memory. */
  const uint8_t *src = (const uint8_t *)0x40000u;
  for (uint32_t i = 0; i < words; i++) {
    uint64_t w = 0;
    for (int b = 0; b < 8; b++)
      w |= (uint64_t)src[i * 8u + (uint32_t)b] << (8 * b);
    MEM[i] = w;
  }
  return words;
}

void s1_main(void) {
  serial_init();
  s1_reset();
  uint32_t words = guest_load_image();
  if (!words) {
    dbg_puts("S1GUEST LOAD FAIL\n");
    for (;;) __asm__ volatile("hlt");
  }
  /* Loader contract: flat image at word 0; r0=0, r13=1, r14=stack top,
     PC=0, k=0.  The image owns words 0..words-1; the stack grows up from
     S1_GUEST_STACK (default mem_words - mem_words/8). */
  s.r[0] = 0;
  s.r[13] = 1;
  s.r[14] = S1_GUEST_STACK;
  s.pc = 0;
  s.k = 0;
  /* Optional testfixture script path: u32 length at guest byte 0x03EFF020,
     bytes at 0x03EFF024 (distinct from stdout/stderr at 0x03EFF000). */
  guest_write_u32(0x03EFF020u, s1_guest_script_len);
  if (s1_guest_script_len)
    guest_write_bytes(0x03EFF024u, s1_guest_script, s1_guest_script_len);
  guest_publish_time();
  dbg_puts("S1GUEST LOAD "); dbg_dec(words); dbg_puts(" WORDS\n");
  uint32_t rc = s1_run(S1_GUEST_STEPS);
  dbg_puts("S1GUEST HALT rc="); dbg_dec(rc);
  dbg_puts(" r1="); dbg_hex32(s.r[1]);
  dbg_puts(" pc="); dbg_hex32(s.pc);
  dbg_puts(" steps="); dbg_dec((uint32_t)s.steps); dbg_putc('\n');
  guest_frame(rc);
  outl(0xF4, 0);              /* QEMU isa-debug-exit, when attached */
  for (;;) __asm__ volatile("hlt");
}
#endif
