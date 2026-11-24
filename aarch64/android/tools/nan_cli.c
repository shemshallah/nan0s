/* nan_cli - run a NaN16 image headless. See docs/DESIGN.md. */
#include "../core/nan16.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static uint8_t *slurp(const char *p, size_t *n) {
  FILE *f = fopen(p, "rb"); if (!f) return NULL;
  fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t *b = (uint8_t *)malloc((size_t)l + 1); if (!b || fread(b, 1, (size_t)l, f) != (size_t)l) { fclose(f); return NULL; }
  fclose(f); b[l] = 0; *n = (size_t)l; return b;
}
static int keycode(const char *t) {
  static const struct { const char *n; int c; } k[] = {{"ESC",27},{"ENTER",13},{"TAB",9},{"BS",8},{"SPACE",32},{"COMMA",','},
    {"UP",NANK_UP},{"DOWN",NANK_DOWN},{"LEFT",NANK_LEFT},{"RIGHT",NANK_RIGHT},{"HOME",NANK_HOME},{"END",NANK_END},
    {"PGUP",NANK_PGUP},{"PGDN",NANK_PGDN},{"INS",NANK_INS},{"DEL",NANK_DEL}};
  for (size_t i = 0; i < sizeof k / sizeof k[0]; i++) if (!strcmp(t, k[i].n)) return k[i].c;
  return t[1] ? -1 : (unsigned char)t[0];
}
static void drain(nan_vm *v, int echo) {
  char b[512]; size_t n; while ((n = nan_serial_read(v, b, sizeof b))) if (echo) fwrite(b, 1, n, stdout);
}
static uint8_t *build_training_guest(size_t *len) {
  const char *cmd = access("tools/nmk.awk", R_OK) == 0
      ? "awk -f tools/nmk.awk -v CMD=emit src/training/n16_train.nas"
      : "awk -f ../../tools/nmk.awk -v CMD=emit ../../src/training/n16_train.nas";
  FILE *p = popen(cmd, "r");
  if (!p) return NULL;
  size_t cap = 65536, n = 0;
  uint8_t *b = (uint8_t *)malloc(cap);
  if (!b) { pclose(p); return NULL; }
  for (;;) {
    if (n == cap) {
      if (cap >= 4u * 1024u * 1024u) { free(b); pclose(p); return NULL; }
      cap *= 2;
      uint8_t *next = (uint8_t *)realloc(b, cap);
      if (!next) { free(b); pclose(p); return NULL; }
      b = next;
    }
    size_t got = fread(b + n, 1, cap - n, p);
    n += got;
    if (got == 0) break;
  }
  int status = pclose(p);
  if (status != 0 || n == 0) { free(b); return NULL; }
  *len = n;
  return b;
}
static uint32_t words_for_mb(unsigned long mb) {
  unsigned long long bytes = (unsigned long long)mb * 1024ull * 1024ull;
  unsigned long long want = (bytes + 3ull) / 4ull;
  uint32_t p = 0x10000u;
  while ((unsigned long long)p < want && p < 0x10000000u) p <<= 1;
  return p;
}
/* Guest console control block written by the NaN16 libc:
   0x03EFF000 stdout ptr, +4 len, +8 stderr ptr, +12 len. */
static void dump_guest_console(nan_vm *v, uint32_t ctl, const char *path)
{
  uint32_t ptr, len;
  uint8_t *buf;
  FILE *f;
  if (!path) return;
  ptr = (uint32_t)(nan_word(v, ctl >> 2) >> 16);
  len = (uint32_t)(nan_word(v, (ctl + 4) >> 2) >> 16);
  if (!ptr || !len || len > (64u << 20)) return;
  buf = (uint8_t *)malloc(len);
  if (!buf) return;
  if (nan_read_bytes(v, ptr, buf, len) == 0) {
    f = fopen(path, "wb");
    if (f) { fwrite(buf, 1, len, f); fclose(f); }
    else perror(path);
  }
  free(buf);
}

int main(int argc, char **argv) {
  const char *vga = NULL, *img = NULL, *keys = NULL, *ppm = NULL, *disk = NULL, *peek = NULL, *dump_bytes = NULL, *state_out = NULL, *corpus = NULL, *candidate_out = NULL, *guest_stdout = NULL, *guest_stderr = NULL, *guest_script = NULL; uint64_t steps = 50000000ull, per_ms = 1000;
  unsigned long mem_mb = 0;
  int train_mode = 0;
  int dump_text = 0, serial = 0, trim = 1;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--img") && i + 1 < argc) img = argv[++i];
    else if (!strcmp(argv[i], "--nannet-train")) { train_mode = 1; if (i + 1 < argc && argv[i + 1][0] != '-') corpus = argv[++i]; }
    else if (!strcmp(argv[i], "--corpus") && i + 1 < argc) { train_mode = 1; corpus = argv[++i]; }
    else if (!strcmp(argv[i], "--candidate-out") && i + 1 < argc) candidate_out = argv[++i];
    else if (!strcmp(argv[i], "--mem") && i + 1 < argc) mem_mb = strtoul(argv[++i], NULL, 0);
    else if (!strcmp(argv[i], "--steps") && i + 1 < argc) steps = strtoull(argv[++i], 0, 0);
    else if (!strcmp(argv[i], "--keys") && i + 1 < argc) keys = argv[++i];
    else if (!strcmp(argv[i], "--dump-ppm") && i + 1 < argc) ppm = argv[++i];
    else if (!strcmp(argv[i], "--dump-vga") && i + 1 < argc) vga = argv[++i];
    else if (!strcmp(argv[i], "--disk") && i + 1 < argc) disk = argv[++i];
    else if (!strcmp(argv[i], "--peek") && i + 1 < argc) peek = argv[++i];
    else if (!strcmp(argv[i], "--dump-bytes") && i + 1 < argc) dump_bytes = argv[++i];
    else if (!strcmp(argv[i], "--guest-stdout") && i + 1 < argc) guest_stdout = argv[++i];
    else if (!strcmp(argv[i], "--guest-stderr") && i + 1 < argc) guest_stderr = argv[++i];
    else if (!strcmp(argv[i], "--guest-script") && i + 1 < argc) guest_script = argv[++i];
    else if (!strcmp(argv[i], "--state-out") && i + 1 < argc) state_out = argv[++i];
    else if (!strcmp(argv[i], "--clock") && i + 1 < argc) { const char *c = argv[++i]; if (!strncmp(c, "steps:", 6)) per_ms = strtoull(c + 6, 0, 0); }
    else if (!strcmp(argv[i], "--dump-text")) dump_text = 1;
    else if (!strcmp(argv[i], "--no-trim")) trim = 0;
    else if (!strcmp(argv[i], "--serial")) serial = 1;
    else { fprintf(stderr, "usage: nan_cli [--img f] [--mem MB] [--nannet-train [corpus.txt]] [--candidate-out state.nan1] [--state-out state.nan1] [--steps N] [--keys \"1,ESC,~,@5000000\"] [--serial] [--dump-text] [--dump-ppm f] [--peek ADDR[:LEN]] [--dump-bytes ADDR:LEN:FILE] [--guest-stdout FILE] [--guest-stderr FILE] [--guest-script PATH] [--disk f] [--clock steps:N]\n"); return 2; }
  }
  if (!img && !train_mode) { fprintf(stderr, "need --img or --nannet-train\n"); return 2; }
  size_t len = 0;
  uint8_t *data = (!img && train_mode) ? build_training_guest(&len) : slurp(img, &len);
  if (!data) { perror(img ? img : "NaN16 training guest"); return 1; }
  if (mem_mb == 0) mem_mb = 128;          /* default: 128 MiB C payload (32M words) */
  nan_vm *v = nan_create_words(words_for_mb(mem_mb));
  if (!v) { fprintf(stderr, "out of memory (mem=%lu MB)\n", mem_mb); return 1; }
  const char *kind; if (nan_load_auto(v, data, len, &kind)) { fprintf(stderr, "cannot load %s (text error line %d)\n", img ? img : "<built trainer>", nan_load_error(v)); return 1; }

  if (train_mode && corpus) {
    size_t corpus_len = 0;
    uint8_t *raw = slurp(corpus, &corpus_len);
    if (!raw) { perror(corpus); return 1; }
    if (corpus_len > 1048576u || memchr(raw, 0, corpus_len)) {
      fprintf(stderr, "corpus must be at most 1 MiB and contain no NUL bytes\n");
      free(raw); return 2;
    }
    static const uint8_t header_lf[] = "N16TXT/1\n";
    static const uint8_t header_crlf[] = "N16TXT/1\r\n";
    int has_header_lf = corpus_len >= sizeof(header_lf) - 1 &&
                        memcmp(raw, header_lf, sizeof(header_lf) - 1) == 0;
    int has_header_crlf = corpus_len >= sizeof(header_crlf) - 1 &&
                          memcmp(raw, header_crlf, sizeof(header_crlf) - 1) == 0;
    size_t header_len = sizeof(header_lf) - 1;
    size_t crlf_len = sizeof(header_crlf) - 1;
    size_t body_offset = has_header_crlf ? crlf_len : (has_header_lf ? header_len : 0);
    size_t body_len = corpus_len - body_offset;
    size_t framed_len = header_len + body_len;
    uint8_t *framed = (uint8_t *)malloc(framed_len + 1);
    if (!framed) { free(raw); return 1; }
    memcpy(framed, header_lf, header_len);
    memcpy(framed + header_len, raw + body_offset, body_len);
    framed[framed_len] = 0;
    int wrc = nan_write_bytes(v, 327680u, framed, framed_len + 1);
    free(framed); free(raw);
    if (wrc) { fprintf(stderr, "corpus does not fit the NaN16 guest buffer\n"); return 1; }
  } else if (train_mode) {
    static const uint8_t sample[] =
      "N16TXT/1\n"
      "NaN16 owns the corpus codec.\n"
      "Runner and Android share one trainer.\n"
      "The intake stages updates before merge.\n";
    if (nan_write_bytes(v, 327680u, sample, sizeof(sample))) {
      fprintf(stderr, "built-in sample does not fit the NaN16 guest buffer\n");
      return 1;
    }
  }
  if (train_mode) serial = 1;
  if (disk) { int fd = open(disk, O_RDWR); struct stat st; if (fd < 0 || fstat(fd, &st)) { perror(disk); return 1; } nan_attach_disk_fd(v, fd, (size_t)st.st_size); }
  if (guest_script) {
    uint32_t n = (uint32_t)strlen(guest_script);
    if (n > 255u) { fprintf(stderr, "guest script path too long\n"); return 2; }
    nan_write_bytes(v, 0x03EFF020u, (const uint8_t *)&n, 4);
    nan_write_bytes(v, 0x03EFF024u, (const uint8_t *)guest_script, n);
  }
  char *kcopy = keys ? strdup(keys) : NULL; char *save = NULL; char *tok = kcopy ? strtok_r(kcopy, ",", &save) : NULL;
  uint64_t pause_until = 0; int rc = NAN_BUDGET;
#define PUBLISH_TIME() do { \
    uint32_t ms_ = (uint32_t)(nan_steps(v) / per_ms); \
    uint64_t st_ = nan_steps(v); \
    uint32_t lo_ = (uint32_t)st_, hi_ = (uint32_t)(st_ >> 32); \
    nan_write_bytes(v, 0x03EFF010u, (const uint8_t *)&ms_, 4); \
    nan_write_bytes(v, 0x03EFF014u, (const uint8_t *)&lo_, 4); \
    nan_write_bytes(v, 0x03EFF018u, (const uint8_t *)&hi_, 4); \
  } while (0)
  while (nan_steps(v) < steps) {
    nan_set_time_ms(v, (uint32_t)(nan_steps(v) / per_ms));
    PUBLISH_TIME();
    uint64_t left = steps - nan_steps(v); uint32_t slice = left > 100000 ? 100000 : (uint32_t)left;
    rc = nan_run(v, slice); drain(v, serial);
    if (rc == NAN_HALTED) break;
    int can_key = nan_steps(v) >= pause_until || rc == NAN_WAIT_KEY;
    if (can_key && tok) {
      if (tok[0] == '@') { pause_until = nan_steps(v) + strtoull(tok + 1, 0, 0); tok = strtok_r(NULL, ",", &save); continue; }
      int c = keycode(tok); if (c < 0) { fprintf(stderr, "bad key '%s'\n", tok); return 2; }
      nan_key_char(v, c); tok = strtok_r(NULL, ",", &save); continue;
    }
    if (rc == NAN_WAIT_KEY && !tok) break;
  }
  drain(v, serial);
  if (serial && isatty(1)) fputc('\n', stdout);
  if (dump_text) { static char b[16384]; nan_text_utf8(v, b, sizeof b, trim); fputs(b, stdout); }
  if (peek) { /* --peek ADDR[:LEN][,ADDR[:LEN]...]: hex-dump guest words (gate/debug) */
    char *spec = strdup(peek), *sv = NULL;
    for (char *tok = strtok_r(spec, ",", &sv); tok; tok = strtok_r(NULL, ",", &sv)) {
      unsigned long a0 = strtoul(tok, NULL, 0), nw = 1; const char *c = strchr(tok, ':');
      if (c) nw = strtoul(c + 1, NULL, 0);
      for (unsigned long i = 0; i < nw; i++) printf("%08X\n", (uint32_t)(nan_word(v, (uint32_t)(a0 + i)) >> 16));
    }
    free(spec);
  }
  dump_guest_console(v, 0x03EFF000u, guest_stdout);
  dump_guest_console(v, 0x03EFF008u, guest_stderr);
  if (dump_bytes) { /* --dump-bytes ADDR:LEN:FILE [--guest-stdout FILE] [--guest-stderr FILE]: copy guest payload bytes */
    char *spec = strdup(dump_bytes), *sv = NULL;
    char *a = strtok_r(spec, ":", &sv), *n = strtok_r(NULL, ":", &sv), *fn = strtok_r(NULL, ":", &sv);
    if (a && n && fn) {
      unsigned long addr = strtoul(a, NULL, 0), len2 = strtoul(n, NULL, 0);
      uint8_t *buf = malloc(len2 ? len2 : 1);
      if (buf && nan_read_bytes(v, (uint32_t)addr, buf, len2) == 0) {
        FILE *f = fopen(fn, "wb");
        if (f) { fwrite(buf, 1, len2, f); fclose(f); }
        else perror(fn);
      } else fprintf(stderr, "dump-bytes: read failed\n");
      free(buf);
    } else fprintf(stderr, "dump-bytes: expected ADDR:LEN:FILE\n");
    free(spec);
  }
  if (vga) { FILE *f = fopen(vga, "wb"); if (f) { for (int i = 0; i < 2000; i++) { uint16_t c = nan_text_cell(v, i); fputc(c & 255, f); fputc(c >> 8, f); } fclose(f); } }
  if (ppm) {
    int w, h; nan_display_size(v, &w, &h);
    if (nan_display_mode(v) == 1) {
      uint32_t *px = (uint32_t *)malloc((size_t)w * h * 4); FILE *f = fopen(ppm, "wb");
      if (px && f && nan_render_gfx(v, px, (size_t)w * h) == 0) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        for (int i = 0; i < w * h; i++) { uint8_t c[3] = {(uint8_t)(px[i] >> 16), (uint8_t)(px[i] >> 8), (uint8_t)px[i]}; fwrite(c, 1, 3, f); }
      }
      if (f) fclose(f); free(px);
    } else fprintf(stderr, "(text mode: no PPM written)\n");
  }
  if (state_out) { /* --state-out FILE: checkpoint for a resumable run */
    size_t state_len = nan_state_size(v);
    uint8_t *state = (uint8_t *)malloc(state_len ? state_len : 1);
    if (state && state_len && nan_save_state(v, state, state_len) == state_len) {
      FILE *out = fopen(state_out, "wb");
      if (out) {
        if (fwrite(state, 1, state_len, out) != state_len) perror(state_out);
        fclose(out);
      } else perror(state_out);
    } else fprintf(stderr, "could not serialize VM state\n");
    free(state);
  }
  fprintf(stderr, "[nan_cli] %s: %llu steps, rc=%d, pc=%u, trap='%s'\n", kind, (unsigned long long)nan_steps(v), rc, nan_pc(v), nan_trap_text(v));
  int train_ok = !train_mode || (rc == NAN_HALTED && (uint32_t)(nan_word(v, 8449u) >> 16) != 0);
  if (candidate_out) {
    if (!train_mode || !train_ok) {
      fprintf(stderr, "candidate export requires a successful training run\n");
      train_ok = 0;
    } else {
      size_t state_len = nan_state_size(v);
      uint8_t *state = (uint8_t *)malloc(state_len ? state_len : 1);
      if (!state || !state_len || nan_save_state(v, state, state_len) != state_len) {
        fprintf(stderr, "could not serialize candidate VM state\n");
        train_ok = 0;
      } else {
        FILE *out = fopen(candidate_out, "wb");
        int write_ok = 0;
        if (out) {
          write_ok = fwrite(state, 1, state_len, out) == state_len;
          if (fclose(out) != 0) write_ok = 0;
        }
        if (!write_ok) {
          fprintf(stderr, "could not write candidate checkpoint\n");
          train_ok = 0;
        }
      }
      free(state);
    }
  }
  nan_destroy(v); return train_ok ? 0 : 1;
}
