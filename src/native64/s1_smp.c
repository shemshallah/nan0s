/* s1_smp.c - x86_64 S1 multicore prototype: AP bring-up, per-CPU run
 * queues, LAPIC timer/IPI, and a compact NaN16 execution slice.
 *
 * Scope (spec/SMP.md): this is the *mechanics* proof, not the full S1.
 * Each CPU owns an independent NaN register context and executes the same
 * flat cartridge image; guest word memory is shared.  The full S1 in
 * s1_kabi.c remains single-core until its `S1` state is factored per CPU.
 *
 * What this proves on QEMU -smp 2/4:
 *   - ACPI MADT CPU discovery, INIT-SIPI-SIPI AP startup through smp_tramp.S;
 *   - one LAPIC timer per CPU (one-shot probe, vector 0x40) with EOI;
 *   - cross-CPU reschedule IPIs (vector 0x41) and per-CPU round-robin queues;
 *   - a real NaN workload (src/tests/nansmp_test.nas) on every CPU using the
 *     nansmp.nas spinlock and atomic fetch-add over shared word memory.
 *
 * Build: tools/nansmp_gate.sh.  Freestanding C99, no host services.
 */
#include <stdint.h>
#include <stddef.h>

#define NCPU_MAX   8
#define NTASK      2
#define QUANTUM    1024
#define GMEM_BASE  0x200000UL
#define GMEM_WORDS 0x10000u
#define GMEM_MASK  (GMEM_WORDS - 1u)
#define NAN_HALTED 3

#define AP_STACK_BASE 0x300000UL
#define AP_STACK_SIZE 0x10000UL
#define TRAMP_CODE    0x8000UL
#define TRAMP_DATA    0x9000UL
#define LAPIC_FALLBACK 0xFEE00000UL

/* Guest data layout, mirrored by src/tests/nansmp_test.nas. */
#define G_RESULT  0x8000u
#define G_SHARED  0x9000u
#define G_LOCK    0x9001u
#define G_LOCKED  0x9002u
#define G_CPULOCK 0x9010u
#define G_CPUTOT  0x9020u
#define G_QCTX    0xA000u
#define G_QLINK   0xB000u
#define G_STACK   0xE000u

/* S1 control ports: frozen 0x4E00-0x4E07 plus the experimental SMP block. */
#define P_CPU     0x4E08
#define P_STEPS   0x4E09
#define P_IPI     0x4E0A
#define P_CAS     0x4E0B
#define P_FADD    0x4E0C
#define P_FENCE   0x4E0D

#define VEC_TIMER 0x40
#define VEC_IPI   0x41
#define VEC_SPUR  0xFF

#define IA32_APIC_BASE 0x0000001Bu
#define APIC_ENABLE    (1u << 11)
#define APIC_X2APIC    (1u << 10)

/* ---------------------------------------------------------------- libc bits */
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

/* ------------------------------------------------------------------- memory */
static uint64_t *const gmem = (uint64_t *)(uintptr_t)GMEM_BASE;

static const uint16_t HEADS[4] = {0x7FF1, 0xFFF1, 0x7FF8, 0xFFF8};
static uint32_t hcls(uint32_t h) { return ((h >> 2) & 2u) | (h >> 15); }
static int hvalid(uint32_t h) {
  return (h & 0x7FF0u) == 0x7FF0u && ((h & 15u) == 1u || (h & 15u) == 8u);
}
static uint32_t w_near(uint64_t w) { return (uint32_t)(w >> 48); }
static uint32_t w_far(uint64_t w) {
  return (uint32_t)(((w & 0xFFu) << 8) | ((w >> 8) & 0xFFu));
}
static uint64_t mkword(uint32_t payload, int n) {
  uint32_t far = HEADS[n & 3], near = HEADS[(n >> 2) & 3];
  return (uint64_t)(far >> 8) | ((uint64_t)(far & 0xFF) << 8) |
         ((uint64_t)payload << 16) | ((uint64_t)near << 48);
}
static uint32_t gp(uint32_t word) { return (uint32_t)(gmem[word & GMEM_MASK] >> 16); }

/* -------------------------------------------------------------------- COM1 */
static inline void outb(uint16_t port, uint8_t v) {
  __asm__ volatile("outb %0,%1" : : "a"(v), "Nd"(port));
}
static inline void outl(uint16_t port, uint32_t v) {
  __asm__ volatile("outl %0,%1" : : "a"(v), "Nd"(port));
}
static void serial_init(void) {
  outb(0x3F9, 0x00); outb(0x3FB, 0x80); outb(0x3F8, 0x01);
  outb(0x3F9, 0x00); outb(0x3FB, 0x03); outb(0x3FA, 0xC7); outb(0x3FC, 0x0B);
}
static void pic_mask_all(void) {
  /* The BIOS leaves the 8259s unmasked.  Their legacy IRQ0 vector (0x08)
     would land on the double-fault gate once IF=1; this kernel uses the
     LAPIC timer and LAPIC IPIs only. */
  outb(0x21, 0xFF);
  outb(0xA1, 0xFF);
}
static void serial_putc(char c) {
  uint8_t lsr;
  do { __asm__ volatile("inb %1,%0" : "=a"(lsr) : "Nd"((uint16_t)0x3FD)); }
  while (!(lsr & 0x20));
  outb(0x3F8, (uint8_t)c);
}
static void serial_puts(const char *s) { while (*s) serial_putc(*s++); }
static void put_dec(uint32_t x) {
  char b[12]; int n = 0;
  if (!x) { serial_putc('0'); return; }
  while (x) { b[n++] = (char)('0' + x % 10u); x /= 10u; }
  while (n) serial_putc(b[--n]);
}
static void put_hex32(uint32_t x) {
  static const char hx[] = "0123456789ABCDEF";
  serial_puts("0x");
  for (int i = 28; i >= 0; i -= 4) serial_putc(hx[(x >> i) & 15]);
}

static volatile uint32_t g_serial_lock;
static void serial_lock(void) {
  while (__atomic_exchange_n(&g_serial_lock, 1u, __ATOMIC_ACQUIRE))
    __asm__ volatile("pause");
}
static void serial_unlock(void) {
  __atomic_store_n(&g_serial_lock, 0u, __ATOMIC_RELEASE);
}

/* Line builder: BSP output is serialized so the gate transcript is exact. */
static char g_line[160];
static uint32_t g_ln;
static void line_begin(void) { g_ln = 0; }
static void line_ch(char c) { if (g_ln < sizeof g_line - 1) g_line[g_ln++] = c; }
static void line_s(const char *s) { while (*s) line_ch(*s++); }
static void line_d(uint32_t x) {
  char b[12]; int n = 0;
  if (!x) { line_ch('0'); return; }
  while (x) { b[n++] = (char)('0' + x % 10u); x /= 10u; }
  while (n) line_ch(b[--n]);
}
static void line_h(uint32_t x) {
  static const char hx[] = "0123456789ABCDEF";
  line_s("0x");
  int started = 0;
  for (int i = 28; i >= 0; i -= 4) {
    uint32_t d = (x >> i) & 15u;
    if (d || started || i == 0) { line_ch(hx[d]); started = 1; }
  }
}
static void line_end(void) {
  line_ch('\n');
  serial_lock();
  for (uint32_t i = 0; i < g_ln; i++) serial_putc(g_line[i]);
  serial_unlock();
}

static void panic(const char *what) {
  serial_lock();
  serial_puts("SMP PANIC ");
  serial_puts(what);
  serial_putc('\n');
  serial_unlock();
  for (;;) __asm__ volatile("cli; hlt");
}

/* --------------------------------------------------------------- LAPIC/IDT */
static uint32_t g_lapic = LAPIC_FALLBACK;
static inline uint32_t lapic_read(uint32_t off) {
  return *(volatile uint32_t *)(uintptr_t)(g_lapic + off);
}
static inline void lapic_write(uint32_t off, uint32_t v) {
  *(volatile uint32_t *)(uintptr_t)(g_lapic + off) = v;
}
static inline uint64_t rdmsr(uint32_t msr) {
  uint32_t lo, hi;
  __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
  return ((uint64_t)hi << 32) | lo;
}
static inline void wrmsr(uint32_t msr, uint64_t v) {
  __asm__ volatile("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}
static uint32_t cpuid_apic_id(void) {
  uint32_t a, b, c, d;
  __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(1), "c"(0));
  (void)a; (void)c; (void)d;
  return b >> 24;
}
static void lapic_map(void) {
  /* s1_boot.S: PML4 @0x30000, PDPT @0x31000, PD0 @0x32000 (1 GiB), spare
     @0x33000.  Map the 2 MiB page containing 0xFEE00000 through PDPT[3]. */
  volatile uint64_t *pdpt = (volatile uint64_t *)(uintptr_t)0x31000;
  volatile uint64_t *pd3 = (volatile uint64_t *)(uintptr_t)0x33000;
  pdpt[3] = 0x33003u;
  pd3[503] = 0xFEE00000ull | 0x83ull;
  __asm__ volatile("invlpg (%0)" : : "r"(0xFEE00000ull) : "memory");
}
static void lapic_init(void) {
  uint64_t base = rdmsr(IA32_APIC_BASE);
  base &= ~(uint64_t)APIC_X2APIC;
  base |= APIC_ENABLE;
  wrmsr(IA32_APIC_BASE, base);
  uint32_t b = (uint32_t)(base & 0xFFFFF000ull);
  if (b) g_lapic = b;
  lapic_write(0xF0, 0x100u | VEC_SPUR);   /* SVR: enable, spurious vector */
  lapic_write(0x80, 0);                   /* TPR */
  lapic_write(0xB0, 0);                   /* EOI */
}
static void lapic_eoi(void) { lapic_write(0xB0, 0); }
static int lapic_send_ipi(uint32_t apic_id, uint32_t vec) {
  lapic_write(0x310, apic_id << 24);
  lapic_write(0x300, 0x00004000u | (vec & 0xFFu));
  for (uint32_t spin = 0; spin < 1000000u; spin++) {
    if (!(lapic_read(0x300) & (1u << 12))) return 0;
  }
  return -1;
}
static void lapic_send_init(uint32_t apic_id) {
  lapic_write(0x310, apic_id << 24);
  lapic_write(0x300, 0x00004500u);        /* INIT, level assert */
}
static void lapic_send_sipi(uint32_t apic_id, uint32_t vector) {
  lapic_write(0x310, apic_id << 24);
  lapic_write(0x300, 0x00004600u | (vector & 0xFFu));
}
static void delay_loops(uint32_t n) {
  for (volatile uint32_t i = 0; i < n; i++) __asm__ volatile("pause");
}

enum { IDT_INT = 0x8E };
struct idt_entry {
  uint16_t off_lo, sel;
  uint8_t ist, type;
  uint16_t off_mid;
  uint32_t off_hi, zero;
} __attribute__((packed));
static struct idt_entry g_idt[256];
static struct { uint16_t limit; uint64_t base; } __attribute__((packed)) g_idtr;

extern void isr_timer(void);
extern void isr_ipi(void);
extern void isr_spurious(void);
extern void isr_default(void);
extern void isr_pf(void);
extern void isr_df(void);

static void idt_set(int v, void (*fn)(void)) {
  uint64_t a = (uint64_t)(uintptr_t)fn;
  g_idt[v].off_lo = (uint16_t)a;
  g_idt[v].sel = 0x08;
  g_idt[v].ist = 0;
  g_idt[v].type = IDT_INT;
  g_idt[v].off_mid = (uint16_t)(a >> 16);
  g_idt[v].off_hi = (uint32_t)(a >> 32);
  g_idt[v].zero = 0;
}
static void idt_init(void) {
  for (int i = 0; i < 256; i++) idt_set(i, isr_default);
  idt_set(VEC_TIMER, isr_timer);
  idt_set(VEC_IPI, isr_ipi);
  idt_set(VEC_SPUR, isr_spurious);
  idt_set(0x0E, isr_pf);
  idt_set(0x08, isr_df);
  g_idtr.limit = (uint16_t)(sizeof g_idt - 1);
  g_idtr.base = (uint64_t)(uintptr_t)&g_idt[0];
}
static void idt_load(void) { __asm__ volatile("lidt %0" : : "m"(g_idtr)); }

/* ---------------------------------------------------------------- CPU state */
typedef struct {
  uint32_t r[16], pc, k;
} NanState;

typedef struct {
  NanState st;
  uint32_t state;      /* 0 blocked/free, 1 ready, 2 running, 3 done */
  uint32_t id;         /* 0 = task A, 1 = task B */
  uint32_t stack;      /* guest word address */
  uint32_t count;
  uint32_t checksum;
  uint32_t seen;
} Task;

typedef struct __attribute__((aligned(64))) {
  Task task[NTASK];
  volatile uint32_t online;
  volatile uint32_t timer_ok;
  volatile uint32_t timer_ticks;
  volatile uint32_t need_resched;
  volatile uint32_t pending_b;
  volatile uint32_t ipis;
  volatile uint32_t resched;    /* task B was dispatched after the IPI */
  volatile uint32_t finished;
  volatile uint32_t cur;        /* 0..1, or 0xFFFFFFFF */
  volatile uint32_t atomic_result;
  uint32_t index;
  uint32_t apic_id;
  uint64_t steps;
} Cpu;

static Cpu g_cpu[NCPU_MAX];
static uint32_t g_ncpu;
static volatile uint8_t g_apic_cpu[256];

static int apic_to_cpu(uint32_t id) {
  uint8_t c = g_apic_cpu[id & 0xFFu];
  return (c == 0xFFu) ? -1 : (int)c;
}

/* Interrupt handlers (called from s1_smp_isr.S). */
void smp_timer_isr(void) {
  int c = apic_to_cpu(lapic_read(0x20) >> 24);
  if (c >= 0) {
    g_cpu[c].timer_ticks++;
    lapic_write(0x320, 0x00010000u);      /* mask the one-shot probe */
  }
  lapic_eoi();
}
void smp_ipi_isr(void) {
  int c = apic_to_cpu(lapic_read(0x20) >> 24);
  if (c >= 0) {
    g_cpu[c].ipis++;
    g_cpu[c].need_resched = 1;
    g_cpu[c].pending_b = 1;
  }
  lapic_eoi();
}
void smp_default_isr(void) {
  panic("unexpected interrupt");
}
void smp_exception_isr(uint64_t err, uint64_t rip, uint64_t cr2, uint64_t vec) {
  serial_lock();
  serial_puts("SMP EXC vec="); put_dec((uint32_t)vec);
  serial_puts(" rip="); put_hex32((uint32_t)rip);
  serial_puts(" err="); put_hex32((uint32_t)err);
  serial_puts(" cr2="); put_hex32((uint32_t)cr2);
  serial_putc('\n');
  serial_unlock();
  for (;;) __asm__ volatile("cli; hlt");
}

/* --------------------------------------------------------------- NaN slice */
static void setk(NanState *s, int z, int l) {
  s->k = 2u * (uint32_t)(z != 0) + (uint32_t)(l != 0);
}

static uint32_t port_in(int ci, uint16_t port) {
  switch (port) {
  case P_CPU: return (uint32_t)ci;
  case P_STEPS: return (uint32_t)g_cpu[ci].steps;
  case P_CAS: case P_FADD: return g_cpu[ci].atomic_result;
  default: return 0xFFFFFFFFu;
  }
}

static void port_out(int ci, uint16_t port, uint32_t v) {
  switch (port) {
  case P_IPI:
    if (v < NCPU_MAX) lapic_send_ipi(g_cpu[v].apic_id, VEC_IPI);
    break;
  case P_CAS: {
    uint32_t desc = v & GMEM_MASK;
    if (desc + 2u >= GMEM_WORDS) { g_cpu[ci].atomic_result = 0xFFFFFFFFu; break; }
    uint32_t addr = gp(desc);
    uint32_t exp = gp(desc + 1u);
    uint32_t neu = gp(desc + 2u);
    uint32_t a = addr & GMEM_MASK;
    uint64_t expected = mkword(exp, 10);
    uint64_t desired = mkword(neu, 10);
    uint64_t old = expected;
    __atomic_compare_exchange_n(&gmem[a], &old, desired, 0,
                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    g_cpu[ci].atomic_result = (uint32_t)(old >> 16);
    break;
  }
  case P_FADD: {
    uint32_t desc = v & GMEM_MASK;
    if (desc + 1u >= GMEM_WORDS) { g_cpu[ci].atomic_result = 0xFFFFFFFFu; break; }
    uint32_t addr = gp(desc) & GMEM_MASK;
    uint32_t delta = gp(desc + 1u);
    uint64_t old = __atomic_load_n(&gmem[addr], __ATOMIC_SEQ_CST);
    for (;;) {
      uint64_t desired = mkword((uint32_t)(old >> 16) + delta, 10);
      if (__atomic_compare_exchange_n(&gmem[addr], &old, desired, 0,
                                      __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
        g_cpu[ci].atomic_result = (uint32_t)(old >> 16);
        break;
      }
    }
    break;
  }
  case P_FENCE:
    __asm__ volatile("mfence" ::: "memory");
    break;
  default:
    break;
  }
}

/* One NaN16 instruction for task t on CPU ci.  This covers the scalar subset
 * used by nansmp.nas and the SMP test; it is not the full S1 op set. */
static void nan_step(int ci, Task *t) {
  NanState *s = &t->st;
  uint32_t at = s->pc & GMEM_MASK;
  uint64_t w = gmem[at];
  uint32_t nh = w_near(w), fh = w_far(w);
  if (!hvalid(nh) || !hvalid(fh)) { t->state = 3; return; }
  s->pc = at + 1u;
  uint32_t p = (uint32_t)(w >> 16), op = p >> 24;
  uint32_t n = (hcls(nh) << 2) | hcls(fh);
  if (op == 0xFF) { t->state = 3; return; }
  if (op != 0 && !((n >> s->k) & 1u)) return;
  uint32_t d = (p >> 20) & 15u, a = (p >> 16) & 15u, imm = p & 0xFFFFu;
  uint32_t A = s->r[a], B = s->r[imm & 15u];

  switch (op) {
  case 0x00: {
    uint32_t res = 0;
    if (n & 1) res |= ~(A | B);
    if (n & 2) res |= ~A & B;
    if (n & 4) res |= A & ~B;
    if (n & 8) res |= A & B;
    s->r[d] = res; setk(s, res == 0, 0); break;
  }
  case 0x01: s->r[d] = imm; break;
  case 0x02: s->r[d] = (s->r[d] & 0xFFFFu) | (imm << 16); break;
  case 0x03: { uint64_t sum = (uint64_t)A + B;
    s->r[d] = (uint32_t)sum; setk(s, (uint32_t)sum == 0, (int)(sum >> 32)); break; }
  case 0x04: { uint32_t res = A - B; s->r[d] = res; setk(s, res == 0, A < B); break; }
  case 0x05: { uint32_t res = A << (imm & 31u); s->r[d] = res; setk(s, res == 0, 0); break; }
  case 0x06: { uint32_t res = A >> (imm & 31u); s->r[d] = res; setk(s, res == 0, 0); break; }
  case 0x27: { uint32_t res = (uint32_t)((int32_t)A >> (imm & 31u));
    s->r[d] = res; setk(s, res == 0, 0); break; }
  case 0x07: setk(s, A == B, A < B); break;
  case 0x28: setk(s, A == B, (int32_t)A < (int32_t)B); break;
  case 0x08: { uint32_t ad = A + imm;
    s->r[d] = (uint32_t)(gmem[ad & GMEM_MASK] >> 16); break; }
  case 0x09: { uint32_t ad = A + imm;
    gmem[ad & GMEM_MASK] = mkword(s->r[d], 10); break; }
  case 0x0A: s->pc = imm; break;
  case 0x0B: s->r[15] = s->pc; s->pc = imm; break;
  case 0x0C: s->pc = s->r[15]; break;
  case 0x0D: s->pc = A; break;
  case 0x0F: break;
  case 0x15: serial_putc((char)(s->r[d] & 0xFFu)); break;
  case 0x20: { uint32_t res = A * B; s->r[d] = res; setk(s, res == 0, 0); break; }
  case 0x23: case 0x24: case 0x25: case 0x26: {
    uint32_t res;
    if (B == 0) { res = (op == 0x23 || op == 0x25) ? 0 : A; s->r[d] = res; s->k = 3; break; }
    if (op == 0x23) res = (B == 0xFFFFFFFFu) ? 0u - A : (uint32_t)((int32_t)A / (int32_t)B);
    else if (op == 0x24) res = (B == 0xFFFFFFFFu) ? 0 : (uint32_t)((int32_t)A % (int32_t)B);
    else if (op == 0x25) res = A / B; else res = A % B;
    s->r[d] = res; setk(s, res == 0, 0); break;
  }
  case 0x29: { uint32_t s2 = (uint32_t)(int32_t)(int16_t)imm;
    uint64_t sum = (uint64_t)A + s2; s->r[d] = (uint32_t)sum;
    setk(s, (uint32_t)sum == 0, (int)(sum >> 32)); break; }
  case 0x2C: s->r[15] = s->pc; s->pc = A; break;
  case 0x38: s->pc = p & 0xFFFFFFu; break;
  case 0x39: s->r[15] = s->pc; s->pc = p & 0xFFFFFFu; break;
  case 0x43: port_out(ci, (uint16_t)(A & 0xFFFFu), s->r[d]); break;
  case 0x4D: s->r[d] = port_in(ci, (uint16_t)(A & 0xFFFFu)); break;
  default: t->state = 3; break;
  }
}

/* --------------------------------------------------------------- scheduler */
static void schedule(Cpu *c) {
  int cur = (c->cur == 0xFFFFFFFFu) ? -1 : (int)c->cur;
  if (cur >= 0 && c->task[cur].state == 2) c->task[cur].state = 1;
  int start = (cur >= 0) ? cur : (NTASK - 1);
  int next = -1;
  for (int k = 1; k <= NTASK; k++) {
    int j = (start + k) % NTASK;
    if (c->task[j].state == 1) { next = j; break; }
  }
  if (next < 0) {
    if (cur >= 0 && c->task[cur].state == 1) next = cur;
    else { c->cur = 0xFFFFFFFFu; return; }
  }
  if (next == 1 && c->ipis) c->resched = 1;
  c->task[next].state = 2;
  c->cur = (uint32_t)next;
}

static int cpu_all_done(Cpu *c) {
  return c->task[0].state == 3 && c->task[1].state == 3;
}

static void run_cpu(int ci) {
  Cpu *c = &g_cpu[ci];
  for (;;) {
    if (c->pending_b) {
      c->pending_b = 0;
      if (c->task[1].state == 0) c->task[1].state = 1;
      c->need_resched = 1;
    }
    if (c->need_resched) { c->need_resched = 0; schedule(c); }
    if (c->cur == 0xFFFFFFFFu) {
      if (cpu_all_done(c)) { c->finished = 1; break; }
      schedule(c);
      if (c->cur == 0xFFFFFFFFu) {
        __asm__ volatile("sti; hlt; cli" ::: "memory");
        continue;
      }
    }
    Task *t = &c->task[c->cur];
    for (int i = 0; i < QUANTUM; i++) {
      if (t->state != 2) break;
      nan_step(ci, t);
      c->steps++;
      if (t->state == 3) break;
    }
    if (t->state == 3) {
      schedule(c);
      continue;
    }
    /* Round-robin: give another ready task the CPU at the quantum edge. */
    if (c->task[0].state == 1 || c->task[1].state == 1) schedule(c);
  }
}

/* ------------------------------------------------------------- AP startup */
static void ap_main_entry(uint32_t ci);

static int start_ap(int ci) {
  Cpu *c = &g_cpu[ci];
  volatile uint64_t *blk = (volatile uint64_t *)(uintptr_t)TRAMP_DATA;
  {
    uint64_t cr3;
    __asm__ volatile("mov %%cr3,%0" : "=r"(cr3));
    blk[0] = cr3;
  }
  blk[1] = AP_STACK_BASE + (uint64_t)ci * AP_STACK_SIZE + 0xF000ull;
  blk[2] = (uint64_t)(uintptr_t)&ap_main_entry;
  blk[3] = (uint64_t)ci;
  __asm__ volatile("mfence" ::: "memory");

  c->online = 0;
  lapic_send_init(c->apic_id);
  delay_loops(2000000u);
  lapic_send_sipi(c->apic_id, TRAMP_CODE >> 12);
  delay_loops(200000u);
  lapic_send_sipi(c->apic_id, TRAMP_CODE >> 12);
  for (uint32_t spin = 0; spin < 200000000u; spin++) {
    if (c->online) return 0;
    __asm__ volatile("pause");
  }
  return -1;
}

static void timer_probe(int ci) {
  Cpu *c = &g_cpu[ci];
  c->timer_ticks = 0;
  lapic_write(0x3E0, 0x3);                 /* divide by 16 */
  lapic_write(0x320, VEC_TIMER);           /* one-shot */
  lapic_write(0x380, 1000000u);
  for (uint64_t spin = 0; spin < 100000000ull; spin++) {
    if (c->timer_ticks) break;
    __asm__ volatile("pause");
  }
  lapic_write(0x320, 0x00010000u);         /* mask */
  c->timer_ok = c->timer_ticks ? 1u : 0u;
}

/* ------------------------------------------------------------ ACPI MADT */
static int sig4(const void *p, const char *s) {
  const uint8_t *a = (const uint8_t *)p;
  return a[0] == (uint8_t)s[0] && a[1] == (uint8_t)s[1] &&
         a[2] == (uint8_t)s[2] && a[3] == (uint8_t)s[3];
}
static const uint8_t *find_rsdp(void) {
  for (uint32_t p = 0xE0000; p < 0x100000; p += 16)
    if (sig4((const void *)(uintptr_t)p, "RSD PTR ")) return (const uint8_t *)(uintptr_t)p;
  for (uint32_t p = 0x80000; p < 0xA0000; p += 16)
    if (sig4((const void *)(uintptr_t)p, "RSD PTR ")) return (const uint8_t *)(uintptr_t)p;
  return 0;
}
static const uint8_t *find_madt(void) {
  const uint8_t *rsdp = find_rsdp();
  if (!rsdp) return 0;
  uint8_t rev = rsdp[15];
  uint64_t xsdt = 0;
  uint32_t rsdt = 0;
  if (rev >= 2) {
    xsdt = *(const uint64_t *)(const void *)(rsdp + 24);
    if (xsdt && sig4((const void *)(uintptr_t)xsdt, "XSDT")) {
      uint32_t len = *(const uint32_t *)(const void *)(uintptr_t)(xsdt + 4);
      if (len > 0x100000u) return 0;
      for (uint32_t off = 36; off + 8 <= len; off += 8) {
        uint64_t t = *(const uint64_t *)(const void *)(uintptr_t)(xsdt + off);
        if (t && sig4((const void *)(uintptr_t)t, "APIC")) return (const uint8_t *)(uintptr_t)t;
      }
    }
  }
  rsdt = *(const uint32_t *)(const void *)(rsdp + 16);
  if (rsdt && sig4((const void *)(uintptr_t)rsdt, "RSDT")) {
    uint32_t len = *(const uint32_t *)(const void *)(uintptr_t)(rsdt + 4);
    if (len > 0x100000u) return 0;
    for (uint32_t off = 36; off + 4 <= len; off += 4) {
      uint32_t t = *(const uint32_t *)(const void *)(uintptr_t)(rsdt + off);
      if (t && sig4((const void *)(uintptr_t)t, "APIC")) return (const uint8_t *)(uintptr_t)t;
    }
  }
  return 0;
}
static int detect_cpus(uint8_t *ids, int max) {
  const uint8_t *madt = find_madt();
  int n = 0;
  if (madt) {
    uint32_t len = *(const uint32_t *)(const void *)(madt + 4);
    if (len > 0x100000u) len = 0;
    uint32_t off = 44;
    while (off + 2 <= len && n < max) {
      const uint8_t *e = madt + off;
      uint8_t type = e[0], elen = e[1];
      if (elen < 2 || off + elen > len) break;
      if (type == 0 && elen >= 8) {
        uint8_t apic = e[3];
        uint16_t flags = (uint16_t)(e[4] | (e[5] << 8));
        if (flags & 1u) ids[n++] = apic;
      }
      off += elen;
    }
  }
  if (n == 0) { ids[0] = (uint8_t)cpuid_apic_id(); n = 1; }
  /* The BSP must be logical CPU 0. */
  uint8_t bsp = (uint8_t)cpuid_apic_id();
  for (int i = 0; i < n; i++) {
    if (ids[i] == bsp) {
      uint8_t t = ids[0]; ids[0] = ids[i]; ids[i] = t;
      break;
    }
  }
  return n;
}

/* ------------------------------------------------------------ guest image */
extern const unsigned char smp_nan_image[];
extern const unsigned char smp_nan_image_end[];
extern const unsigned char smp_tramp_blob[];
extern const unsigned char smp_tramp_blob_end[];

static void init_guest(void) {
  for (uint32_t i = 0; i < GMEM_WORDS; i++) gmem[i] = 0;
  size_t bytes = (size_t)(smp_nan_image_end - smp_nan_image);
  if (bytes % 8u || bytes / 8u > GMEM_WORDS) panic("bad NaN image");
  memcpy((void *)(uintptr_t)GMEM_BASE, smp_nan_image, bytes);

  gmem[G_SHARED] = mkword(0, 10);
  gmem[G_LOCK] = mkword(0, 10);
  gmem[G_LOCKED] = mkword(0, 10);
  for (uint32_t c = 0; c < NCPU_MAX; c++) {
    for (uint32_t t = 0; t < NTASK; t++) {
      uint32_t base = G_QCTX + c * 32u + t * 16u;
      gmem[base + 0] = mkword(0, 10);
      gmem[base + 1] = mkword(0, 10);
      gmem[base + 2] = mkword(0, 10);
      gmem[base + 3] = mkword(G_QLINK + (c * 2u + t) * 64u, 10);
      for (uint32_t j = 0; j < 64u; j++)
        gmem[G_QLINK + (c * 2u + t) * 64u + j] = 0;
    }
  }
  size_t tsz = (size_t)(smp_tramp_blob_end - smp_tramp_blob);
  if (tsz > 0x1000u) panic("AP trampoline too large");
  memcpy((void *)(uintptr_t)TRAMP_CODE, smp_tramp_blob, tsz);
  for (uint32_t i = 0; i < 0x100u; i++) *(volatile uint8_t *)(uintptr_t)(TRAMP_DATA + i) = 0;
}

static void task_init(Cpu *c, uint32_t ci, uint32_t ti) {
  Task *t = &c->task[ti];
  memset(t, 0, sizeof *t);
  t->st.r[0] = 0;
  t->st.r[13] = 1;
  t->st.r[14] = G_STACK + ci * 0x100u + (ti ? 0x80u : 0u);
  t->st.pc = ti;              /* word 0 = task A, word 1 = task B */
  t->st.k = 0;
  t->state = (ti == 0) ? 1u : 0u;   /* B is released by the reschedule IPI */
  t->id = ti;
  t->stack = t->st.r[14];
}
static void init_cpus(void) {
  for (uint32_t i = 0; i < g_ncpu; i++) {
    Cpu *c = &g_cpu[i];
    memset(c, 0, sizeof *c);
    c->index = i;
    c->cur = 0xFFFFFFFFu;
    task_init(c, i, 0);
    task_init(c, i, 1);
  }
}

/* ------------------------------------------------------------------- entry */
static void ap_main_entry(uint32_t ci) {
  if (ci >= NCPU_MAX) panic("AP index");
  idt_load();
  lapic_init();
  __asm__ volatile("sti" ::: "memory");
  timer_probe((int)ci);
  g_cpu[ci].online = 1;
  run_cpu((int)ci);
  for (;;) __asm__ volatile("cli; hlt");
}

void s1_main(void) {
  serial_init();
  serial_puts("NAN0S SMP x86_64\n");
  pic_mask_all();

  lapic_map();
  lapic_init();
  idt_init();
  idt_load();

  uint8_t ids[NCPU_MAX];
  int n = detect_cpus(ids, NCPU_MAX);
  if (n > NCPU_MAX) n = NCPU_MAX;
  g_ncpu = (uint32_t)n;

  init_guest();
  init_cpus();

  for (int i = 0; i < 256; i++) g_apic_cpu[i] = 0xFFu;
  for (int i = 0; i < n; i++) {
    g_cpu[i].apic_id = ids[i];
    g_apic_cpu[ids[i]] = (uint8_t)i;
  }

  line_begin();
  line_s("SMP BSP apic="); line_d(ids[0]); line_s(" cpus="); line_d((uint32_t)n);
  line_end();

  __asm__ volatile("sti" ::: "memory");
  timer_probe(0);

  for (int i = 1; i < n; i++) {
    if (start_ap(i) != 0) panic("AP did not come online");
    line_begin();
    line_s("SMP AP cpu="); line_d((uint32_t)i);
    line_s(" apic="); line_d(ids[i]);
    line_s(" online timer="); line_d(g_cpu[i].timer_ok);
    line_end();

    for (uint32_t spin = 0; spin < 200000000u && !g_cpu[i].steps; spin++)
      __asm__ volatile("pause");
    lapic_send_ipi(ids[i], VEC_IPI);
    line_begin();
    line_s("SMP IPI cpu=0 -> cpu="); line_d((uint32_t)i);
    line_s(" vec="); line_h(VEC_IPI);
    line_end();
  }

  for (int i = 0; i < n; i++) {
    line_begin();
    line_s("SMP TIMER cpu="); line_d((uint32_t)i);
    line_s(" ticks="); line_d(g_cpu[i].timer_ok);
    line_end();
  }

  lapic_send_ipi(ids[0], VEC_IPI);
  line_begin();
  line_s("SMP IPI cpu=0 -> cpu=0 vec="); line_h(VEC_IPI);
  line_end();

  run_cpu(0);

  for (int i = 1; i < n; i++)
    for (uint32_t spin = 0; spin < 2000000000u && !g_cpu[i].finished; spin++)
      __asm__ volatile("pause");

  for (int i = 0; i < n; i++) {
    Cpu *c = &g_cpu[i];
    for (int t = 0; t < NTASK; t++) {
      uint32_t addr = G_RESULT + (uint32_t)i * 16u + (uint32_t)t * 8u;
      c->task[t].count = gp(addr);
      c->task[t].checksum = gp(addr + 2u);
      c->task[t].seen = gp(addr + 1u);
    }
  }

  for (int i = 0; i < n; i++) {
    Cpu *c = &g_cpu[i];
    for (int t = 0; t < NTASK; t++) {
      line_begin();
      line_s("SMP WORK cpu="); line_d((uint32_t)i);
      line_s(" task="); line_ch(t ? 'B' : 'A');
      line_s(" count="); line_d(c->task[t].count);
      line_end();
    }
    line_begin();
    line_s("SMP RESCHED cpu="); line_d((uint32_t)i);
    line_s(" ipi="); line_d(c->ipis);
    line_s(" resched="); line_d(c->resched);
    line_end();
    line_begin();
    line_s("SMP ATOM cpu="); line_d((uint32_t)i);
    line_s(" total="); line_d(gp(G_CPUTOT + (uint32_t)i) & 0xFFFFu);
    line_s(" q="); line_d(c->task[0].checksum);
    line_ch('/'); line_d(c->task[1].checksum);
    line_end();
  }

  uint32_t shared = gp(G_SHARED);
  uint32_t locked = gp(G_LOCKED);
  uint32_t expect_shared = (uint32_t)n * 6000u;
  uint32_t expect_locked = (uint32_t)n * 100u;
  line_begin();
  line_s("SMP SHARED atomic="); line_d(shared);
  line_s(" locked="); line_d(locked);
  line_end();

  int ok = (shared == expect_shared && locked == expect_locked);
  for (int i = 0; i < n; i++) {
    Cpu *c = &g_cpu[i];
    if (c->task[0].count != 5000u || c->task[1].count != 1000u) ok = 0;
    if (c->task[0].checksum != 12u || c->task[1].checksum != 12u) ok = 0;
    if (c->task[0].seen != (uint32_t)i || c->task[1].seen != (uint32_t)i) ok = 0;
    if ((gp(G_CPUTOT + (uint32_t)i) & 0xFFFFu) != 6000u) ok = 0;
    if (c->timer_ok != 1u) ok = 0;
    if (c->ipis != 1u || c->resched != 1u) ok = 0;
    if (!c->finished) ok = 0;
  }
  if (ok) {
    line_begin();
    line_s("SMP PASS cpus="); line_d((uint32_t)n);
    line_s(" atomic="); line_d(shared);
    line_s(" locked="); line_d(locked);
    line_end();
  } else {
    line_begin();
    line_s("SMP FAIL cpus="); line_d((uint32_t)n);
    line_s(" atomic="); line_d(shared);
    line_s(" locked="); line_d(locked);
    line_end();
  }

  outl(0xF4, 0x10);             /* isa-debug-exit */
  for (;;) __asm__ volatile("cli; hlt");
}
