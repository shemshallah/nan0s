/* test_kernel_abi.c - S1 kernel ABI v0.1 conformance oracle.
 *
 * This gate exercises the frozen format in spec/KERNEL_ABI.md against the
 * portable C core.  The product path is the bare-metal x86_64 S1
 * (src/native64/s1_kabi.c, tools/kabi64_gate.sh); this file is the oracle.
 */
#include "../core/nan16_int.h"
#include <stdio.h>
#include <string.h>

static int fails = 0, checks = 0;
#define CHECK(c) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)
#define EQ(a, b) do { checks++; uint64_t _a = (uint64_t)(a), _b = (uint64_t)(b); \
  if (_a != _b) { fails++; printf("FAIL %s:%d  %s == %s  (got 0x%llX, want 0x%llX)\n", \
    __FILE__, __LINE__, #a, #b, (unsigned long long)_a, (unsigned long long)_b); } } while (0)

static nan_vm *V;
static uint32_t pw, frame_base = 0x2000u;
#define ENTRY  0x1000u
#define FRAME  0x2000u
#define KSTACK 0x3000u
#define RTAB   0x4000u
#define TCB    0x5000u

static void begin_at(uint32_t pc) { nan_reset(V); pw = pc; nan_set_pc(V, pc); }
static void begin(void) { begin_at(0); }
static void emit(int op, int d, int a, uint32_t imm, int n) {
  nan_set_word(V, pw++, nan_mkword(((uint32_t)op << 24) | ((uint32_t)d << 20) |
                                    ((uint32_t)a << 16) | (imm & 0xFFFF), n));
}
static void I(int op, int d, int a, uint32_t imm) { emit(op, d, a, imm, 15); }
static void halt(void) { emit(0xFF, 0, 0, 0, 15); }
static int go(uint32_t budget) { return nan_run(V, budget); }
#define R(i) nan_reg(V, i)
static uint32_t fw(int i) { return (uint32_t)(nan_word(V, frame_base + (uint32_t)i) >> 16); }
static void set_fw(int i, uint32_t x) { nan_set_word(V, frame_base + (uint32_t)i, nan_mkword(x, 10)); }
static uint32_t status(void) { return nan_port_in(V, NAN_KABI_PORT_STATUS, 4); }

static void cfg(uint32_t entry, uint32_t frame, uint32_t timer,
                uint32_t stack, uint32_t regions) {
  frame_base = frame;
  nan_port_out(V, NAN_KABI_PORT_ENTRY, entry, 4);
  nan_port_out(V, NAN_KABI_PORT_FRAME, frame, 4);
  nan_port_out(V, NAN_KABI_PORT_TIMER, timer, 4);
  nan_port_out(V, NAN_KABI_PORT_KSTACK, stack, 4);
  nan_port_out(V, NAN_KABI_PORT_REGIONS, regions, 4);
  nan_port_out(V, NAN_KABI_PORT_TCB, TCB, 4);
}
static void region_entry(uint32_t slot, uint32_t base, uint32_t nwords,
                         uint32_t kind, uint32_t prot) {
  nan_set_word(V, RTAB + slot * NAN_REGION_WORDS + 0, nan_mkword(base, 10));
  nan_set_word(V, RTAB + slot * NAN_REGION_WORDS + 1, nan_mkword(nwords, 10));
  nan_set_word(V, RTAB + slot * NAN_REGION_WORDS + 2, nan_mkword(kind, 10));
  nan_set_word(V, RTAB + slot * NAN_REGION_WORDS + 3, nan_mkword(prot, 10));
}
static void region_one(uint32_t base, uint32_t nwords, uint32_t kind, uint32_t prot) {
  region_entry(0, base, nwords, kind, prot);
  region_entry(1, 0, 0, 0, 0);                 /* terminator */
}

/* SVC 0 (yield) and SVC 1 (exit) reach the kernel with the frozen frame. */
static void t_svc_yield_exit(void) {
  begin();
  cfg(ENTRY, FRAME, 0, KSTACK, NAN_KABI_UNSET);
  I(0x01, 1, 0, 0x111); I(0x01, 2, 0, 0x222);
  I(0x01, 3, 0, 0x333); I(0x01, 4, 0, 0x444);
  I(0x01, 14, 0, 0xABC);                        /* guest SP */
  I(0x07, 0, 0, 0);                             /* CMP r0,r0 -> k=2 */
  I(0x01, 6, 0, 0x666);
  I(0x4E, 0, 0, NAN_SYS_YIELD);                 /* SVC 0 */
  uint32_t resume = pw;
  I(0x01, 7, 0, 0x777);
  halt();
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));   /* kernel: HALT */
  EQ(go(1000), NAN_HALTED);
  EQ(nan_pc(V), ENTRY + 1);
  EQ(fw(NAN_TF_R1), 0x111); EQ(fw(NAN_TF_R2), 0x222);
  EQ(fw(NAN_TF_R3), 0x333); EQ(fw(NAN_TF_R4), 0x444);
  EQ(fw(NAN_TF_PC), resume);
  EQ(fw(NAN_TF_K), 2);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_SVC);
  EQ(fw(NAN_TF_IMM), NAN_SYS_YIELD);
  EQ(fw(NAN_TF_RET), 0);
  EQ(fw(NAN_TF_SP), 0xABC);
  EQ(fw(NAN_TF_R14), 0xABC);
  EQ(R(14), KSTACK);                            /* kernel stack */
  EQ(status(), NAN_KABI_STATUS_TRAP);

  /* SVCRET restores the frame; frame[21] is the SVC return in r1. */
  nan_set_word(V, ENTRY + 1, nan_mkword(0x4F000000u, 15));
  set_fw(NAN_TF_RET, 0x55);
  nan_set_pc(V, ENTRY + 1);
  EQ(go(1000), NAN_HALTED);
  EQ(R(1), 0x55); EQ(R(2), 0x222); EQ(R(7), 0x777);
  EQ(R(14), 0xABC); EQ(nan_flags(V), 2);
  EQ(status(), 0);
  CHECK(!*nan_trap_text(V));

  /* SVC 1 (exit) carries its number in frame[20]. */
  begin();
  cfg(ENTRY, FRAME, 0, KSTACK, NAN_KABI_UNSET);
  I(0x01, 1, 0, 7);
  I(0x4E, 0, 0, NAN_SYS_EXIT);
  halt();
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_SVC);
  EQ(fw(NAN_TF_IMM), NAN_SYS_EXIT);
  EQ(fw(NAN_TF_R1), 7);
}

/* Control ports are host-configured before the ABI goes live; INL stays
 * available to the guest.  Guest writes to a live control port fault. */
static void t_control_ports(void) {
  begin();
  nan_port_out(V, NAN_KABI_PORT_ENTRY, ENTRY, 4);
  nan_port_out(V, NAN_KABI_PORT_FRAME, FRAME, 4);
  nan_port_out(V, NAN_KABI_PORT_TIMER, 16, 4);
  nan_port_out(V, NAN_KABI_PORT_KSTACK, KSTACK, 4);
  nan_port_out(V, NAN_KABI_PORT_REGIONS, NAN_KABI_UNSET, 4);
  nan_port_out(V, NAN_KABI_PORT_TCB, TCB, 4);
  I(0x01, 1, 0, NAN_KABI_PORT_STATUS); I(0x4D, 3, 1, 0);
  halt();
  EQ(go(100), NAN_HALTED);
  EQ(V->kentry, ENTRY); EQ(V->kframe, FRAME); EQ(V->ktimer, 16);
  EQ(V->kstack, KSTACK);
  EQ(V->kregions, NAN_KABI_UNSET); EQ(V->ktcb, TCB);
  EQ(R(3), 0);
}

static void t_control_locked(void) {
  begin();
  cfg(ENTRY, FRAME, 0, KSTACK, NAN_KABI_UNSET);
  I(0x01, 1, 0, NAN_KABI_PORT_ENTRY);
  I(0x01, 2, 0, 0x7777);
  I(0x43, 2, 1, 0);                             /* guest OUTL to ENTRY */
  halt();
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), NAN_KABI_PORT_ENTRY);
  EQ(V->kentry, ENTRY);                         /* unchanged */
}

/* Timer IRQ vectors with cause=1 and resumes where it interrupted. */
static void t_timer(void) {
  begin();
  cfg(ENTRY, FRAME, 4, KSTACK, NAN_KABI_UNSET);
  for (int i = 0; i < 6; i++) I(0x0F, 0, 0, 0);   /* NOP x6 */
  halt();
  /* kernel entry reads the status with INL, then halts for observation */
  nan_set_word(V, ENTRY + 0, nan_mkword(0x01104E06u, 15));  /* MOVI r1,0x4E06 */
  nan_set_word(V, ENTRY + 1, nan_mkword(0x4D510000u, 15));  /* INL r5,[r1] */
  nan_set_word(V, ENTRY + 2, nan_mkword(0xFF000000u, 15));  /* HALT */
  EQ(go(100), NAN_HALTED);
  EQ(nan_pc(V), ENTRY + 3);
  EQ(fw(NAN_TF_PC), 4);                          /* four NOPs retired */
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_IRQ);
  EQ(fw(NAN_TF_IMM), 0);
  EQ(fw(NAN_TF_R1), 0);
  EQ(R(5), NAN_KABI_STATUS_TIMER);
  EQ(status(), NAN_KABI_STATUS_TIMER);
  /* resume through SVCRET: the remaining NOPs and the guest HALT */
  nan_set_word(V, ENTRY + 3, nan_mkword(0x4F000000u, 15));
  nan_set_pc(V, ENTRY + 3);
  EQ(go(100), NAN_HALTED);
  EQ(status(), 0);
  EQ(R(1), 0);                                   /* IRQ does not invent r1 */
  CHECK(!*nan_trap_text(V));
}

static void run_fault_case(uint32_t region_prot, int kind_of_fault) {
  (void)kind_of_fault;
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_one(0x100, 0x20, NAN_REGION_KIND_RAM, region_prot);
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
}

static void t_region_read(void) {
  run_fault_case(NAN_PROT_R | NAN_PROT_W | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x400);                          /* outside the region */
  I(0x08, 2, 1, 0);                              /* LD r2,[r1] */
  halt();
  uint32_t ldpc = pw - 2;
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_PC), ldpc);
  EQ(fw(NAN_TF_IMM), 0x400);
  EQ(status(), NAN_KABI_STATUS_TRAP);
  /* the kernel may skip the faulting instruction and SVCRET */
  nan_set_word(V, ENTRY + 1, nan_mkword(0x4F000000u, 15));
  set_fw(NAN_TF_PC, ldpc + 1);
  nan_set_pc(V, ENTRY + 1);
  EQ(go(100), NAN_HALTED);
  CHECK(!*nan_trap_text(V));
}

static void t_region_write(void) {
  run_fault_case(NAN_PROT_R | NAN_PROT_X, 0);    /* W denied */
  I(0x01, 1, 0, 0x110);
  I(0x01, 2, 0, 0x55);
  I(0x09, 2, 1, 0);                              /* ST r2,[r1] */
  halt();
  uint32_t stpc = pw - 2;
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_PC), stpc);
  EQ(fw(NAN_TF_IMM), 0x110);
}

static void t_region_exec(void) {
  run_fault_case(NAN_PROT_R | NAN_PROT_W, 0);    /* X denied */
  I(0x01, 1, 0, 1);
  halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_PC), 0x100);
  EQ(fw(NAN_TF_IMM), 0x100);
}

static void t_region_bytes(void) {
  /* STB: word inside the region, W denied. */
  run_fault_case(NAN_PROT_R | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x440);                          /* byte addr of word 0x110 */
  I(0x01, 2, 0, 0x41);
  I(0x2B, 2, 1, 0);
  halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x440);
  /* LDB: byte outside the region. */
  run_fault_case(NAN_PROT_R | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x480);
  I(0x2A, 2, 1, 0);
  halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x480);
}

static void t_region_blocks(void) {
  /* BCOPY source outside. */
  run_fault_case(NAN_PROT_R | NAN_PROT_W | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x200); I(0x01, 3, 0, 0x110); I(0x01, 2, 0, 4);
  I(0x2D, 3, 1, 2);
  halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x200);
  /* BFILL destination outside. */
  run_fault_case(NAN_PROT_R | NAN_PROT_W | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x99); I(0x01, 3, 0, 0x200); I(0x01, 2, 0, 4);
  I(0x2E, 3, 1, 2);
  halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x200);
  /* Adjacent entries may split a block: this copy is legal. */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_entry(0, 0x100, 0x10, NAN_REGION_KIND_RAM, NAN_PROT_R | NAN_PROT_W | NAN_PROT_X);
  region_entry(1, 0x110, 0x10, NAN_REGION_KIND_RAM, NAN_PROT_R | NAN_PROT_W | NAN_PROT_X);
  region_entry(2, 0, 0, 0, 0);
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
  I(0x01, 1, 0, 0x100); I(0x01, 3, 0, 0x110); I(0x01, 2, 0, 0x20);
  I(0x2D, 3, 1, 2);
  halt();
  EQ(go(100), NAN_HALTED);
  CHECK(!*nan_trap_text(V));
}

/* Config bounds: the ports carry guest WORD indices, so an out-of-range
 * value is a configuration error and halts with !K rather than wrapping. */
static void t_kabi_bounds(void) {
  char t[24];
  /* the last legal 24-word frame is accepted */
  begin();
  cfg(ENTRY, 0x10000u - NAN_TF_WORDS, 0, KSTACK, NAN_KABI_UNSET);
  I(0x4E, 0, 0, NAN_SYS_YIELD); halt();
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_SVC);
  EQ(nan_word(V, 0x10000u - 1u), nan_mkword(0, 10));
  /* a span crossing the end is !K */
  begin();
  cfg(ENTRY, 0x10000u - 12u, 0, KSTACK, NAN_KABI_UNSET);
  I(0x4E, 0, 0, 0); halt();
  EQ(go(100), NAN_HALTED);
  snprintf(t, sizeof t, "%s", nan_trap_text(V));
  CHECK(t[0] == '!' && t[1] == 'K');
  /* a byte address is not a word address: rejected */
  begin();
  cfg(ENTRY, FRAME * 8u, 0, KSTACK, NAN_KABI_UNSET);
  I(0x4E, 0, 0, 0); halt();
  EQ(go(100), NAN_HALTED);
  CHECK(nan_trap_text(V)[1] == 'K');
  /* entry outside guest memory */
  begin();
  cfg(0x10000u, FRAME, 0, KSTACK, NAN_KABI_UNSET);
  I(0x4E, 0, 0, 0); halt();
  EQ(go(100), NAN_HALTED);
  CHECK(nan_trap_text(V)[1] == 'K');
  /* kernel stack outside guest memory */
  begin();
  cfg(ENTRY, FRAME, 0, 0x10000u, NAN_KABI_UNSET);
  I(0x4E, 0, 0, 0); halt();
  EQ(go(100), NAN_HALTED);
  CHECK(nan_trap_text(V)[1] == 'K');
  /* region table cannot even hold its terminator */
  begin();
  cfg(ENTRY, FRAME, 0, KSTACK, 0x10000u - 2u);
  I(0x01, 1, 0, 0); halt();
  EQ(go(100), NAN_HALTED);
  CHECK(nan_trap_text(V)[1] == 'K');
  /* region table with a gap: the first load succeeds, the hole faults */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_entry(0, 0x100, 0x10, NAN_REGION_KIND_RAM, NAN_PROT_R | NAN_PROT_W | NAN_PROT_X);
  region_entry(1, 0x120, 0x10, NAN_REGION_KIND_RAM, NAN_PROT_R | NAN_PROT_W | NAN_PROT_X);
  region_entry(2, 0, 0, 0, 0);
  nan_set_word(V, 0x120, nan_mkword(0x1234, 10));
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
  I(0x01, 1, 0, 0x120); I(0x08, 2, 1, 0);       /* legal */
  I(0x01, 1, 0, 0x110); I(0x08, 3, 1, 0);       /* in the gap */
  halt();
  EQ(go(100), NAN_HALTED);
  EQ(R(2), 0x1234);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x110);
  CHECK(V->kin == 1);
  /* gate failure becomes cause=2 while the kernel ABI is active */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_one(0x100, 0x10, NAN_REGION_KIND_RAM, NAN_PROT_R | NAN_PROT_W | NAN_PROT_X);
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
  nan_set_word(V, 0x100, 0);
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_PC), 0x100);
  EQ(fw(NAN_TF_IMM), 0x100);
  CHECK(!*nan_trap_text(V));
  /* unpredictable op 0x49 also vectors as cause=2 */
  begin_at(0x100);
  cfg(ENTRY, FRAME, 0, KSTACK, RTAB);
  region_one(0x100, 0x10, NAN_REGION_KIND_RAM, NAN_PROT_R | NAN_PROT_W | NAN_PROT_X);
  nan_set_word(V, ENTRY, nan_mkword(0xFF000000u, 15));
  nan_set_word(V, 0x100, nan_mkword(0x49000000u, 15));
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_PC), 0x100);
  EQ(fw(NAN_TF_IMM), 0x100);
  CHECK(!*nan_trap_text(V));
}

/* Every memory-touching opcode must use the right region permission.
 * Device/vector-register ops are deliberately exempt: VPOKE/VPEEK (0x10/
 * 0x11), FBCOPY/FBFILL (0x3C/0x3D), DISP* and the port family (0x3E-0x43)
 * touch VRAM/devices, not guest word memory; 0x50-0x5F operate on vector
 * registers except VLOAD/VSTORE (0x52/0x53), which are checked below. */
static void t_region_op_matrix(void) {
  /* 0x14 BSWAPM is read+write */
  run_fault_case(NAN_PROT_R | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x110); I(0x14, 2, 1, 0); halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x110);
  /* 0x16 STW is write */
  run_fault_case(NAN_PROT_R | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x110); I(0x01, 2, 0, 0x55); I(0x16, 2, 1, 0); halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x110);
  /* 0x17 LDN is read */
  run_fault_case(NAN_PROT_R | NAN_PROT_W | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x400); I(0x17, 2, 1, 0); halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x400);
  /* 0x42 OUTSW reads the source block */
  run_fault_case(NAN_PROT_R | NAN_PROT_W | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x3F8); I(0x01, 2, 0, 0x200); I(0x01, 3, 0, 4);
  I(0x42, 3, 1, 2); halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x200);
  /* 0x52 VLOAD is a 64-byte read */
  run_fault_case(NAN_PROT_R | NAN_PROT_W | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x480); I(0x52, 2, 1, 0); halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x480);
  /* 0x53 VSTORE is a 64-byte write */
  run_fault_case(NAN_PROT_R | NAN_PROT_X, 0);
  I(0x01, 1, 0, 0x440); I(0x53, 2, 1, 0); halt();
  EQ(go(100), NAN_HALTED);
  EQ(fw(NAN_TF_CAUSE), NAN_CAUSE_FAULT);
  EQ(fw(NAN_TF_IMM), 0x440);
}

int main(void) {
  V = nan_create_words(0x10000);
  if (!V) { printf("FAIL nan_create_words\n"); return 1; }
  struct { const char *n; void (*f)(void); } t[] = {
    {"svc yield/exit", t_svc_yield_exit},
    {"control ports", t_control_ports},
    {"control locked", t_control_locked},
    {"timer irq", t_timer},
    {"region read fault", t_region_read},
    {"region write fault", t_region_write},
    {"region exec fault", t_region_exec},
    {"region byte faults", t_region_bytes},
    {"region block faults", t_region_blocks},
    {"region op matrix", t_region_op_matrix},
    {"config bounds", t_kabi_bounds},
  };
  for (size_t i = 0; i < sizeof t / sizeof t[0]; i++) {
    int before = fails;
    nan_reset(V);
    t[i].f();
    printf("%-20s %s\n", t[i].n, fails == before ? "ok" : "FAILED");
  }
  printf("%d checks, %d failures\n", checks, fails);
  nan_destroy(V);
  return fails ? 1 : 0;
}
