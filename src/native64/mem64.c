/* mem64.c - native maximum-width page-table builder for the NaN substrate.
 *
 * Target: 52-bit physical (4 PiB), 57-bit virtual (128 PiB), 5-level paging
 * when LA57 is present, 4-level fallback otherwise.  The direct map uses
 * 1 GiB pages; 2 MiB and 4 KiB leaves exist for memory objects and MMIO.
 *
 * This is the only layer that writes hardware PTEs.  The NaN side owns
 * policy and shadow objects; guest words are payload+class-head pairs, not
 * raw 64-bit PTEs, so they must not be used as hardware tables.
 *
 * Gate: tools/mem64_gate.sh (QEMU, 128 MiB RAM, no host hugepages).
 */
#include <stdint.h>
#include <stddef.h>

#define MEM64_POOL_BASE   0x100000ULL
#define MEM64_POOL_SIZE   (64ULL * 1024 * 1024)
#define MEM64_DIRECT_BASE 0xFF00000000000000ULL

#define PTE_P   1ULL
#define PTE_RW  2ULL
#define PTE_US  4ULL
#define PTE_PS  0x80ULL
#define PTE_NX  (1ULL << 63)
#define PTE_ADDR 0x000FFFFFFFFFF000ULL

#define MEM64_AUTO 0
#define MEM64_1G   1
#define MEM64_2M   2
#define MEM64_4K   3

struct mem64 {
  uint64_t root_phys;
  uint64_t high_min;
  uint64_t pool_base;
  uint64_t pool_size;
  uint64_t pool_used;
  uint64_t tables;
  uint64_t mapped;
  uint64_t pages_1g;
  uint64_t pages_2m;
  uint64_t pages_4k;
  uint32_t levels;
  uint32_t phys_bits;
  uint32_t virt_bits;
};

static inline void outb(uint16_t port, uint8_t v) {
  __asm__ volatile("outb %0,%1" : : "a"(v), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
  uint8_t v;
  __asm__ volatile("inb %1,%0" : "=a"(v) : "Nd"(port));
  return v;
}

static void serial_init(void) {
  outb(0x3F9, 0x00); outb(0x3FB, 0x80); outb(0x3F8, 0x01);
  outb(0x3F9, 0x00); outb(0x3FB, 0x03); outb(0x3FA, 0xC7); outb(0x3FC, 0x0B);
}
static void serial_putc(char c) {
  while (!(inb(0x3FD) & 0x20)) { }
  outb(0x3F8, (uint8_t)c);
}
static void serial_puts(const char *s) {
  while (*s) serial_putc(*s++);
}
static void put_hex64(uint64_t v) {
  static const char hx[] = "0123456789abcdef";
  serial_puts("0x");
  for (int i = 60; i >= 0; i -= 4) serial_putc(hx[(v >> i) & 15]);
}
static void put_dec32(uint32_t v) {
  char b[10];
  unsigned n = 0;
  if (!v) { serial_putc('0'); return; }
  while (v) { b[n++] = (char)('0' + (v % 10u)); v /= 10u; }
  while (n) serial_putc(b[--n]);
}

static void cpuid(uint32_t leaf, uint32_t sub, uint32_t *a, uint32_t *b,
                  uint32_t *c, uint32_t *d) {
  __asm__ volatile("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d)
                            : "a"(leaf), "c"(sub));
}

static void flush_tlb(struct mem64 *m) {
  __asm__ volatile("mov %0,%%cr3" : : "r"(m->root_phys) : "memory");
}

static int canonical(const struct mem64 *m, uint64_t va) {
  if (m->virt_bits == 57) {
    int64_t s = (int64_t)va >> 56;
    return s == 0 || s == -1;
  }
  int64_t s = (int64_t)va >> 47;
  return s == 0 || s == -1;
}

static uint64_t *table_at(uint64_t phys) {
  return (uint64_t *)(uintptr_t)phys;
}

static unsigned pidx(uint64_t va, int level) {
  return (unsigned)((va >> (12 + 9 * (level - 1))) & 0x1FFu);
}

static uint64_t pool_alloc(struct mem64 *m) {
  if (m->pool_used + 4096ULL > m->pool_size) return 0;
  uint64_t p = m->pool_base + m->pool_used;
  m->pool_used += 4096ULL;
  volatile uint64_t *q = (volatile uint64_t *)(uintptr_t)p;
  for (unsigned i = 0; i < 512; i++) q[i] = 0;
  m->tables++;
  return p;
}

static int choose_page(uint64_t va, uint64_t pa, uint64_t size, int mode) {
  if (mode == MEM64_1G || mode == MEM64_AUTO) {
    if (size >= (1ULL << 30) && !(va & ((1ULL << 30) - 1)) &&
        !(pa & ((1ULL << 30) - 1))) return 30;
    if (mode == MEM64_1G) return -1;
  }
  if (mode == MEM64_2M || mode == MEM64_AUTO) {
    if (size >= (1ULL << 21) && !(va & ((1ULL << 21) - 1)) &&
        !(pa & ((1ULL << 21) - 1))) return 21;
    if (mode == MEM64_2M) return -1;
  }
  if ((mode == MEM64_4K || mode == MEM64_AUTO) && size >= 4096ULL &&
      !(va & 0xFFFULL) && !(pa & 0xFFFULL)) return 12;
  return -1;
}

static int map_one(struct mem64 *m, uint64_t va, uint64_t pa, int shift,
                   uint64_t flags) {
  int leaf = (shift == 30) ? 3 : (shift == 21) ? 2 : 1;
  uint64_t *tbl = table_at(m->root_phys);

  for (int lvl = (int)m->levels; lvl > leaf; lvl--) {
    unsigned i = pidx(va, lvl);
    uint64_t e = tbl[i];
    if (e & PTE_P) {
      if (e & PTE_PS) return -1;          /* larger page already covers this */
    } else {
      uint64_t nt = pool_alloc(m);
      if (!nt) return -1;
      e = nt | PTE_P | PTE_RW | PTE_US;
      tbl[i] = e;
    }
    tbl = table_at(e & PTE_ADDR);
  }

  unsigned i = pidx(va, leaf);
  if (tbl[i] & PTE_P) return -1;
  uint64_t e = (pa & PTE_ADDR) | (flags & (PTE_RW | PTE_US | PTE_NX)) | PTE_P;
  if (shift != 12) e |= PTE_PS;
  tbl[i] = e;
  return 0;
}

/* mem64_map: map [va, va+size) to [pa, pa+size).  Returns 0 or -1. */
static int mem64_map(struct mem64 *m, uint64_t va, uint64_t pa, uint64_t size,
                     uint64_t flags, int mode) {
  if (!size) return -1;
  if (pa + size < pa) return -1;
  if (pa + size > (1ULL << m->phys_bits)) return -1;

  uint64_t end = va + size;
  /* The 4-level direct map ends exactly at 2^64; that one wrap is valid. */
  if (end < va && end != 0) return -1;
  if (!canonical(m, va)) return -1;
  if (!canonical(m, va + size - 1)) return -1;
  if ((va >= m->high_min) != ((va + size - 1) >= m->high_min)) return -1;

  while (size) {
    int shift = choose_page(va, pa, size, mode);
    if (shift < 0) return -1;
    uint64_t chunk = 1ULL << shift;
    if (chunk > size) chunk = size;
    if (map_one(m, va, pa, shift, flags)) return -1;
    va += chunk;
    pa += chunk;
    size -= chunk;
    m->mapped += chunk;
    if (shift == 30) m->pages_1g++;
    else if (shift == 21) m->pages_2m++;
    else m->pages_4k++;
  }
  return 0;
}

/* mem64_walk: return physical byte and page size for va, or -1. */
static int mem64_walk(struct mem64 *m, uint64_t va, uint64_t *pa,
                      uint64_t *page_size) {
  if (!canonical(m, va)) return -1;
  uint64_t *tbl = table_at(m->root_phys);
  for (int lvl = (int)m->levels; lvl >= 1; lvl--) {
    uint64_t e = tbl[pidx(va, lvl)];
    if (!(e & PTE_P)) return -1;
    if (lvl > 1 && (e & PTE_PS)) {
      uint64_t shift = (uint64_t)(12 + 9 * (lvl - 1));
      uint64_t mask = (1ULL << shift) - 1;
      *pa = (e & PTE_ADDR & ~mask) | (va & mask);
      *page_size = 1ULL << shift;
      return 0;
    }
    if (lvl == 1) {
      *pa = (e & PTE_ADDR) | (va & 0xFFFULL);
      *page_size = 4096ULL;
      return 0;
    }
    tbl = table_at(e & PTE_ADDR);
  }
  return -1;
}

static void fail(uint32_t code) {
  serial_puts("MEM64 FAIL ");
  put_dec32(code);
  serial_putc('\n');
  outb(0xF4, 1);
  for (;;) __asm__ volatile("hlt");
}

static int check_walk(struct mem64 *m, uint64_t va, uint64_t want_pa,
                      uint64_t want_ps) {
  uint64_t pa = 0, ps = 0;
  if (mem64_walk(m, va, &pa, &ps)) return -1;
  if (pa != want_pa || ps != want_ps) return -1;
  return 0;
}

void mem64_main(uint64_t root, uint32_t levels) {
  serial_init();
  serial_puts("NAN0S MEM64 x86_64\n");

  if (levels != 4 && levels != 5) fail(1);
  if (levels == 5) {
    uint32_t a, b, c, d;
    cpuid(7, 0, &a, &b, &c, &d);
    if (!(c & 0x10000u)) fail(2);
  }

  struct mem64 m;
  m.root_phys = root;
  m.levels = levels;
  m.virt_bits = (levels == 5) ? 57 : 48;
  m.high_min = (levels == 5) ? 0xFF00000000000000ULL
                             : 0xFFFF800000000000ULL;
  m.pool_base = MEM64_POOL_BASE;
  m.pool_size = MEM64_POOL_SIZE;
  m.pool_used = 0;
  m.tables = 0;
  m.mapped = 0;
  m.pages_1g = m.pages_2m = m.pages_4k = 0;

  uint32_t a, b, c, d;
  cpuid(0x80000000u, 0, &a, &b, &c, &d);
  uint32_t phys = 36;
  if (a >= 0x80000008u) {
    cpuid(0x80000008u, 0, &a, &b, &c, &d);
    phys = a & 0xFFu;
    if (phys < 32) phys = 36;
    if (phys > 52) phys = 52;
  }
  m.phys_bits = phys;

  serial_puts("MEM64 LEVELS=");
  put_dec32(m.levels);
  serial_puts(" PHYS=");
  put_dec32(m.phys_bits);
  serial_puts(" VIRT=");
  put_dec32(m.virt_bits);
  serial_putc('\n');

  /* 2 MiB and 4 KiB leaves for object/MMIO mappings. */
  uint64_t va2 = 0x0000500000000000ULL;
  uint64_t pa2 = 0x0000000010000000ULL;      /* 256 MiB */
  if (mem64_map(&m, va2, pa2, 2ULL << 20, PTE_RW | PTE_NX, MEM64_2M))
    fail(10);
  if (check_walk(&m, va2 + 0x123000ULL, pa2 + 0x123000ULL, 2ULL << 20))
    fail(11);

  uint64_t va4 = 0x0000501000000000ULL;
  uint64_t pa4 = 0x0000000020000000ULL;      /* 512 MiB */
  if (mem64_map(&m, va4, pa4, 4096, PTE_RW | PTE_NX, MEM64_4K))
    fail(12);
  if (check_walk(&m, va4 + 0x800ULL, pa4 + 0x800ULL, 4096))
    fail(13);

  /* A 1 TiB object mapping with 1 GiB pages. */
  uint64_t va1 = 0x0000400000000000ULL;      /* 64 TiB */
  uint64_t pa1 = 0x0000010000000000ULL;      /* 1 TiB */
  uint64_t sz1 = 1ULL << 40;
  if (mem64_map(&m, va1, pa1, sz1, PTE_RW | PTE_NX, MEM64_AUTO))
    fail(20);
  if (check_walk(&m, va1, pa1, 1ULL << 30)) fail(21);
  if (check_walk(&m, va1 + sz1 / 2, pa1 + sz1 / 2, 1ULL << 30)) fail(22);
  if (check_walk(&m, va1 + sz1 - (1ULL << 30),
                 pa1 + sz1 - (1ULL << 30), 1ULL << 30)) fail(23);

  /* Full architectural direct map. */
  uint64_t maxphys = 1ULL << m.phys_bits;
  uint64_t dm = MEM64_DIRECT_BASE;
  if (mem64_map(&m, dm, 0, maxphys, PTE_RW | PTE_NX, MEM64_AUTO))
    fail(30);
  if (check_walk(&m, dm, 0, 1ULL << 30)) fail(31);
  if (check_walk(&m, dm + (1ULL << 40), 1ULL << 40, 1ULL << 30)) fail(32);
  if (check_walk(&m, dm + (1ULL << 50), 1ULL << 50, 1ULL << 30)) fail(33);
  if (check_walk(&m, dm + maxphys - (1ULL << 30),
                 maxphys - (1ULL << 30), 1ULL << 30)) fail(34);

  /* Prove the active high-half translation by reading the same code bytes. */
  flush_tlb(&m);
  volatile uint32_t *id = (volatile uint32_t *)(uintptr_t)0x10000;
  volatile uint32_t *hi = (volatile uint32_t *)(uintptr_t)(dm + 0x10000);
  if (*id != *hi) fail(40);

  /* Reject the first physical byte past MAXPHYADDR. */
  if (mem64_map(&m, 0x0000600000000000ULL, maxphys, 1ULL << 30,
                PTE_RW | PTE_NX, MEM64_AUTO) == 0) fail(50);

  /* Reject a non-canonical virtual address. */
  uint64_t bad = (m.virt_bits == 57) ? 0x0100000000000000ULL
                                    : 0x0000800000000000ULL;
  if (mem64_map(&m, bad, 0, 4096, PTE_RW | PTE_NX, MEM64_AUTO) == 0)
    fail(51);

  serial_puts("MEM64 TABLES=");
  put_dec32((uint32_t)m.tables);
  serial_puts(" MAP=");
  put_hex64(m.mapped);
  serial_puts(" 1G=");
  put_dec32((uint32_t)m.pages_1g);
  serial_puts(" 2M=");
  put_dec32((uint32_t)m.pages_2m);
  serial_puts(" 4K=");
  put_dec32((uint32_t)m.pages_4k);
  serial_putc('\n');
  serial_puts("MEM64 PASS\n");
  outb(0xF4, 0);
  for (;;) __asm__ volatile("hlt");
}
