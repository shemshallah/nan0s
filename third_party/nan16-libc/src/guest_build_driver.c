/* guest_build_driver.c - generic raw-source build driver for the NaN16 guest
 * compiler.
 *
 * The cartridge carries a read-only VFS archive of raw C sources (see
 * tools/nan16_vfs_archive.py).  A generated job table names the source files,
 * include paths, preprocessor defines and the fixed guest addresses where each
 * flat cartridge is copied.  This driver runs every job with the self-hosted
 * libtcc, so the compiler reads ordinary source files from its own VFS.  No
 * host preprocessed input is involved.
 *
 * Progress markers at guest byte 0x03F00000 (100*(job+1)+phase, 999=done) let
 * a budget-limited gate checkpoint a run and identify the active source.
 */
#include <stddef.h>
#include <string.h>
#include "libtcc.h"
#include "nan16-runtime.h"
#include "guest_pack.h"
#include "guest_build_job.h"

extern int nan16_vfs_add_pack(const void *, unsigned);
extern int nan16_vfs_get(const char *, unsigned char **, unsigned *);
extern unsigned char *nan16_stderr_data;
extern unsigned nan16_stderr_len;

#define NAN16_PROGRESS (*(volatile unsigned *)0x03F00000u)
#define NAN16_DIAG_BASE ((unsigned char *)0x03E00000u)
#define NAN16_DIAG_MAX 0x2FF00u

static int fail(int code)
{
    unsigned n = nan16_stderr_len;
    if (n > NAN16_DIAG_MAX)
        n = NAN16_DIAG_MAX;
    if (n && nan16_stderr_data)
        memcpy(NAN16_DIAG_BASE, nan16_stderr_data, n);
    NAN16_DIAG_BASE[n] = 0;
    return code;
}

/* Copy the emitted cartridge with a plain driver loop.  Keeping this out of
   libc memcpy also makes a checkpointed copy observable at byte granularity. */
static void copy_out(void *dst, const void *src, unsigned n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    unsigned i;
    for (i = 0; i < n; i++)
        d[i] = s[i];
}

int main(void)
{
    unsigned i, j;

    NAN16_PROGRESS = 1;
    if (nan16_vfs_add_pack((const void *)GUEST_PACK_BASE, GUEST_PACK_LEN) < 0)
        return fail(1);

    for (j = 0; j < GUEST_BUILD_JOB_COUNT; j++) {
        const struct guest_build_job *jb = &guest_build_jobs[j];
        unsigned base = 100u * (j + 1);
        TCCState *s;
        unsigned char *data;
        unsigned size;

        NAN16_PROGRESS = base + 1;
        s = tcc_new();
        if (!s)
            return fail(10 + j);
        tcc_set_output_type(s, TCC_OUTPUT_OBJ);
        for (i = 0; i < jb->ninclude; i++) {
            tcc_add_include_path(s, jb->includes[i]);
            tcc_add_sysinclude_path(s, jb->includes[i]);
        }
        for (i = 0; i < jb->ndefine; i++)
            tcc_define_symbol(s, jb->defines[i], 0);
        for (i = 0; i < jb->nsource; i++) {
            NAN16_PROGRESS = base + 3 + i;
            if (tcc_add_file(s, jb->sources[i]) < 0) {
                tcc_delete(s);
                return fail(20 + j);
            }
        }
        if (jb->runtime) {
            NAN16_PROGRESS = base + 10;
            if (tcc_compile_string(s, NAN16_RUNTIME_SRC) < 0) {
                tcc_delete(s);
                return fail(30 + j);
            }
        }
        NAN16_PROGRESS = base + 11;
        if (tcc_output_file(s, jb->output) < 0) {
            tcc_delete(s);
            return fail(40 + j);
        }
        tcc_delete(s);
        NAN16_PROGRESS = base + 12;
        if (nan16_vfs_get(jb->output, &data, &size) < 0)
            return fail(50 + j);
        *(unsigned *)jb->size_addr = size;
        copy_out((void *)jb->copy_addr, data, size);
    }
    NAN16_PROGRESS = 999;
    return 0;
}
