/* nan16.h - NaN/0S NaN16 + NaNVM1 interpreter (portable C99).
 *
 * Behaviour mirrors src/native/kan16.xa (the x86 gold core) op for op:
 * 8-byte double-ended NaN words, both-face gate, predication by flags k=2Z+L,
 * runtime-sized power-of-two guest word space (default 32M words = 128 MiB
 * of guest C payload bytes), text mode 80x25, mode 13h, VBE LFB, VGA DAC,
 * raw/cooked keyboard, PIT channel 2 speaker, PCI config mech #1.
 * No allocation after nan_create() except the display buffers.
 */
#ifndef NAN16_H
#define NAN16_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct nan_vm nan_vm;

/* ---- Kernel ABI v0.1 (normative: spec/KERNEL_ABI.md) ----
 * Ports are word addresses in guest memory, not byte addresses.  All
 * control ports are written with OUTL (0x43) and STATUS is read with INL
 * (0x4D).  NAN_KABI_UNSET is the power-on value ("not configured"). */
enum {
  NAN_KABI_PORT_ENTRY   = 0x4E00, /* kernel entry word address           */
  NAN_KABI_PORT_FRAME   = 0x4E01, /* 24-word trap frame word address     */
  NAN_KABI_PORT_TIMER   = 0x4E02, /* timer interval in instructions, 0=off */
  NAN_KABI_PORT_KSTACK  = 0x4E03, /* kernel stack pointer word            */
  NAN_KABI_PORT_REGIONS = 0x4E04, /* region table word address            */
  NAN_KABI_PORT_TCB     = 0x4E05, /* current TCB word address             */
  NAN_KABI_PORT_STATUS  = 0x4E06, /* INL: bit0 timer pending, bit1 trap   */
  NAN_KABI_PORT_DATA    = 0x4E07, /* LDS/STS window base (default 0xF0000) */
  NAN_KABI_STATUS_TIMER = 1u,
  NAN_KABI_STATUS_TRAP  = 2u,
  NAN_KABI_UNSET        = 0xFFFFFFFFu
};

/* Trap frame: 24 aligned guest words, each holding a 32-bit value in its
 * payload (the interpreter writes class +q/+q words). */
enum {
  NAN_TF_R0 = 0, NAN_TF_R1 = 1, NAN_TF_R2 = 2, NAN_TF_R3 = 3,
  NAN_TF_R4 = 4, NAN_TF_R5 = 5, NAN_TF_R6 = 6, NAN_TF_R7 = 7,
  NAN_TF_R8 = 8, NAN_TF_R9 = 9, NAN_TF_R10 = 10, NAN_TF_R11 = 11,
  NAN_TF_R12 = 12, NAN_TF_R13 = 13, NAN_TF_R14 = 14, NAN_TF_R15 = 15,
  NAN_TF_PC = 16, NAN_TF_K = 17, NAN_TF_ADDRH = 18, NAN_TF_CAUSE = 19,
  NAN_TF_IMM = 20, NAN_TF_RET = 21, NAN_TF_SP = 22, NAN_TF_RESERVED = 23,
  NAN_TF_WORDS = 24
};
enum { NAN_CAUSE_SVC = 0, NAN_CAUSE_IRQ = 1, NAN_CAUSE_FAULT = 2 };

/* Region table entry: 4 guest words {base word, nwords, kind, prot}.
 * nwords == 0 terminates the table. */
enum {
  NAN_REGION_WORDS = 4,
  NAN_REGION_KIND_RAM = 0, NAN_REGION_KIND_DEV = 1,
  NAN_PROT_R = 1, NAN_PROT_W = 2, NAN_PROT_X = 4
};

/* Frozen syscall numbers (append-only).  S1 saves the number in the trap
 * frame; the NaN kernel owns the implementations. */
enum {
  NAN_SYS_YIELD = 0, NAN_SYS_EXIT = 1, NAN_SYS_REGION_MAP = 2,
  NAN_SYS_REGION_QUERY = 3, NAN_SYS_OPEN = 4, NAN_SYS_READ = 5,
  NAN_SYS_WRITE = 6, NAN_SYS_SEEK = 7, NAN_SYS_CLOSE = 8,
  NAN_SYS_SPAWN = 9, NAN_SYS_WAIT = 10, NAN_SYS_TIME = 11,
  NAN_SYS_SHARE = 12, NAN_SYS_THREAD_CREATE = 13,
  NAN_SYS_THREAD_JOIN = 14, NAN_SYS_THREAD_EXIT = 15,
  NAN_SYS_MUTEX = 16, NAN_SYS_COND = 17, NAN_SYS_TLS = 18,
  NAN_SYS_GETPID = 20, NAN_SYS_GETPPID = 21, NAN_SYS_KILL = 22
};

/* nan_run() return values */
enum {
  NAN_BUDGET   = 0,  /* step budget used up, call again            */
  NAN_WAIT_KEY = 1,  /* guest executed KEY with an empty ring       */
  NAN_VSYNC    = 2,  /* guest executed VSYNC in a graphics mode     */
  NAN_HALTED   = 3,  /* HALT, or a trap (see nan_trap_text)         */
  NAN_TIME_WAIT = 4  /* guest polled TICK 256x unchanged: host may sleep ~1 ms */
};
typedef void (*nan_trace_fn)(void *ctx, uint32_t pc, uint32_t payload, int n, int k);
/* port log: dir 0 = IN (val = value returned), 1 = OUT; size 1/2/4. Called for EVERY port access, known or not. */
typedef void (*nan_port_fn)(void *ctx, int dir, uint32_t port, uint32_t val, int size);

/* special key codes the guest sees in cooked mode */
enum {
  NANK_UP = 128, NANK_DOWN = 129, NANK_LEFT = 130, NANK_RIGHT = 131,
  NANK_HOME = 132, NANK_END = 133, NANK_PGUP = 134, NANK_PGDN = 135,
  NANK_INS = 136, NANK_DEL = 137
};

nan_vm *nan_create(void);
/* Power-of-two words; rounded up. 0/NAN_MIN_WORDS is the smallest VM.
   The word count is exposed to guests through CPUID leaf 0x4E4D00FF. */
nan_vm *nan_create_words(uint32_t words);
uint32_t nan_mem_words(const nan_vm *v);
uint32_t nan_vector_lane(const nan_vm *v, int vreg, int lane);
void    nan_destroy(nan_vm *v);
void    nan_reset(nan_vm *v);                       /* clear memory/state */

/* nan0s.img: guest words at byte 0x2200; count is LE32 at byte 504 (or derived from length). */
int  nan_load_image(nan_vm *v, const uint8_t *img, size_t len);
/* Raw 8-byte words copied to guest word 0 (what tools/mkimg.awk packs). */
int  nan_load_words(nan_vm *v, const uint8_t *words, size_t len);

/* Any program: floppy image, .nan text, raw words, saved state. kind = "floppy"|"nan-text"|"words"|"state". 0 ok, -1 error. */
int  nan_load_auto(nan_vm *v, const uint8_t *data, size_t len, const char **kind);
int  nan_load_text(nan_vm *v, const char *text, size_t len);   /* on error nan_load_error() = 1-based line */
int  nan_load_error(const nan_vm *v);

/* Disk: ATA PIO primary master (LBA28). No disk => floating bus. mem is NOT copied. */
void nan_attach_disk_mem(nan_vm *v, uint8_t *data, size_t len);
void nan_attach_disk_fd(nan_vm *v, int fd, size_t len);        /* pread/pwrite */
void nan_detach_disk(nan_vm *v);

void nan_key_event(nan_vm *v, int sc, int down);               /* sc>=0x100: E0-prefixed (0x148 = Up) */
uint32_t nan_text_color_vm(const nan_vm *v, int idx);          /* text colour through attr map + DAC */
void     nan_dac_rgb(const nan_vm *v, int idx, uint8_t rgb[3]);/* 8-bit */
uint32_t nan_dirty(const nan_vm *v);                           /* bumps on ANY display write */
void nan_set_trace(nan_vm *v, nan_trace_fn cb, void *ctx);
void nan_set_port_log(nan_vm *v, nan_port_fn cb, void *ctx);
const char *nan_strerror(int rc);                      /* name of a nan_run() result */

/* Snapshot (pause/resume, golden tests). Sparse: only 4 KB pages that are not all zero. The disk backend and the
 * serial FIFO are NOT part of a snapshot (the host owns both). nan_state_size() is exact for the next nan_save_state().
 * nan_save_state returns bytes written, or 0 if cap is too small. nan_restore_state validates the whole buffer first and
 * returns 0 (state replaced) or -1 (buffer rejected, the VM is untouched). */
size_t nan_state_size(const nan_vm *v);
size_t nan_save_state(const nan_vm *v, uint8_t *buf, size_t cap);
int    nan_restore_state(nan_vm *v, const uint8_t *buf, size_t len);
/* 25 lines of UTF-8 (CP437 mapped), '\n' terminated; trim = strip trailing blanks. Returns bytes. */
size_t nan_text_utf8(const nan_vm *v, char *buf, size_t cap, int trim);

int  nan_run(nan_vm *v, uint32_t max_steps);
void nan_set_time_ms(nan_vm *v, uint32_t ms);       /* TICK source        */
uint64_t nan_steps(const nan_vm *v);
const char *nan_trap_text(const nan_vm *v);         /* "" or "!O006C"     */

/* input */
void nan_scancode(nan_vm *v, uint8_t set1_code);    /* IRQ1 path (make|break) */
void nan_key_char(nan_vm *v, int c);                /* ASCII or NANK_*   */
int  nan_raw_keyboard(const nan_vm *v);

/* display */
int  nan_display_mode(const nan_vm *v);             /* 0 text 80x25, 1 gfx */
void nan_display_size(const nan_vm *v, int *w, int *h);
uint16_t nan_text_cell(const nan_vm *v, int index); /* char | attr<<8     */
/* Fill argb[w*h] (0xAARRGGBB) from the 8-bit framebuffer + DAC; gfx only. */
int  nan_render_gfx(const nan_vm *v, uint32_t *argb, size_t cap_pixels);
/* VGA text colour 0..15 -> 0xFFRRGGBB */
uint32_t nan_text_color(int idx);
uint32_t nan_frame_counter(const nan_vm *v);        /* bumps on mode/VSYNC */

/* serial (PUTC, traps, COM1) */
size_t nan_serial_read(nan_vm *v, char *buf, size_t max);

/* PC speaker: 0 = silent */
uint32_t nan_speaker_hz(const nan_vm *v);

/* debugging */
uint32_t nan_reg(const nan_vm *v, int i);
uint32_t nan_pc(const nan_vm *v);
uint64_t nan_word(const nan_vm *v, uint32_t index);
/* Boundary-driver byte injection into guest memory; no guest policy is executed here. */
int      nan_write_bytes(nan_vm *v, uint32_t byte_address, const uint8_t *data, size_t len);
int      nan_read_bytes(const nan_vm *v, uint32_t byte_address, uint8_t *out, size_t len);
/* Byte-exact bulk NaN16 transport: first_word is a GUEST WORD index,
 * word_count is a count of EIGHT-byte words (not byte count).
 * NaN faces and full payload are untouched; no mathematical execution.
 * Returns -1 atomically on invalid spans and unsupported big-endian hosts.
 * Do not confuse with nan_write_bytes (4-byte *payload* / class reset).
 */
int      nan_write_words_raw(nan_vm *v, uint32_t first_word, const uint8_t *raw_words, size_t word_count);
int      nan_read_words_raw(const nan_vm *v, uint32_t first_word, uint8_t *out, size_t word_count);
void     nan_set_word(nan_vm *v, uint32_t index, uint64_t raw);
void     nan_set_reg(nan_vm *v, int i, uint32_t val);
void     nan_set_pc(nan_vm *v, uint32_t pc);
int      nan_flags(const nan_vm *v);                /* k = 2Z + L         */

#ifdef __cplusplus
}
#endif
#endif
