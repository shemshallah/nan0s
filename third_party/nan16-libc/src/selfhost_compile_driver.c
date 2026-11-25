/* selfhost_compile_driver.c - tcc2 driver: compile the embedded preprocessed
   TCC sources with the self-hosted libtcc and emit self2.bin.
   The gate generates compiler_src.h from libc.i, libtcc.i and driver.i. */
#include <stddef.h>
#include <string.h>
#include "libtcc.h"
#include "compiler_src.h"
#include "nan16-runtime.h"

extern int nan16_vfs_add(const char *, const void *, unsigned);
extern int nan16_vfs_get(const char *, unsigned char **, unsigned *);

/* Progress marker used by the resumable gate (1..9).  Keep it outside the
   0x03000000 output-copy buffer (self2 is ~1.9 MB). */
#define NAN16_PROGRESS (*(volatile unsigned *)0x03F00000u)

int main(void)
{
    TCCState *s;
    unsigned char *data;
    unsigned size;

    NAN16_PROGRESS = 1;
    if (nan16_vfs_add("libc.i", compiler_libc, compiler_libc_len) < 0) return 1;
    if (nan16_vfs_add("libtcc.i", compiler_libtcc, compiler_libtcc_len) < 0) return 2;
    if (nan16_vfs_add("driver.i", compiler_driver, compiler_driver_len) < 0) return 3;
    NAN16_PROGRESS = 2;
    s = tcc_new();
    if (!s) return 4;
    tcc_set_output_type(s, TCC_OUTPUT_OBJ);
    NAN16_PROGRESS = 3;
    if (tcc_add_file(s, "libc.i") < 0) return 5;
    NAN16_PROGRESS = 4;
    if (tcc_add_file(s, "libtcc.i") < 0) return 6;
    NAN16_PROGRESS = 5;
    if (tcc_add_file(s, "driver.i") < 0) return 7;
    if (tcc_compile_string(s, NAN16_RUNTIME_SRC) < 0) return 10;
    NAN16_PROGRESS = 6;
    if (tcc_output_file(s, "self2.bin") < 0) return 8;
    NAN16_PROGRESS = 7;
    tcc_delete(s);
    if (nan16_vfs_get("self2.bin", &data, &size) < 0) return 9;
    NAN16_PROGRESS = 8;
    *(unsigned *)0x02FFFFF0 = size;
    memcpy((void *)0x03000000, data, size);
    NAN16_PROGRESS = 9;
    return 0;
}
