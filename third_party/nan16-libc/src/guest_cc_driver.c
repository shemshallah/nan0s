/* guest_cc_driver.c - tcc1 raw-source/VFS gate driver.
 *
 * The cartridge embeds a small read-only VFS (standard headers, libc.c and a
 * test program).  The self-hosted libtcc must preprocess and compile the raw
 * C files from that VFS and emit a runnable inner cartridge.  No host
 * preprocessed source is used for the input files.
 */
#include <stddef.h>
#include <string.h>
#include "libtcc.h"
#include "guest_cc_src.h"
#include "nan16-runtime.h"

extern int nan16_vfs_add_ro(const char *, const void *, unsigned);
extern int nan16_vfs_get(const char *, unsigned char **, unsigned *);

#define NAN16_PROGRESS (*(volatile unsigned *)0x03F00000u)

int main(void)
{
    TCCState *s;
    unsigned char *data;
    unsigned size;
    unsigned i;

    NAN16_PROGRESS = 1;
    for (i = 0; i < NAN16_EMBED_COUNT; i++) {
        if (nan16_vfs_add_ro(nan16_embed_files[i].name,
                             nan16_embed_files[i].data,
                             nan16_embed_files[i].len) < 0)
            return 1;
    }
    NAN16_PROGRESS = 2;
    s = tcc_new();
    if (!s) return 2;
    tcc_set_output_type(s, TCC_OUTPUT_OBJ);
    tcc_add_include_path(s, "/usr/include");
    tcc_add_sysinclude_path(s, "/usr/include");
    tcc_add_include_path(s, "/usr/lib/tcc/include");
    tcc_add_sysinclude_path(s, "/usr/lib/tcc/include");
    NAN16_PROGRESS = 3;
    if (tcc_compile_string(s, NAN16_RUNTIME_SRC) < 0) return 5;
    NAN16_PROGRESS = 4;
    if (tcc_add_file(s, "/work/libc.c") < 0) return 3;
    NAN16_PROGRESS = 5;
    if (tcc_add_file(s, "/work/prog.c") < 0) return 4;
    NAN16_PROGRESS = 6;
    if (tcc_output_file(s, "out.bin") < 0) return 5;
    NAN16_PROGRESS = 7;
    tcc_delete(s);
    if (nan16_vfs_get("out.bin", &data, &size) < 0) return 6;
    NAN16_PROGRESS = 7;
    *(unsigned *)0x02FFFFF0 = size;
    memcpy((void *)0x03000000, data, size);
    NAN16_PROGRESS = 9;
    return 0;
}
