#include <stddef.h>
#include <string.h>
#include "libtcc.h"

extern int nan16_vfs_add(const char *, const void *, unsigned);
extern int nan16_vfs_get(const char *, unsigned char **, unsigned *);

static const char test_src[] =
    "int main(void){ return 42; }\n";



int main(void)
{
    TCCState *s;
    unsigned char *data;
    unsigned size;

    nan16_vfs_add("test.c", test_src, sizeof(test_src) - 1);
    s = tcc_new();
    if (!s) return 1;
    tcc_set_output_type(s, TCC_OUTPUT_OBJ);
    if (tcc_add_file(s, "test.c") < 0) return 2;
    if (tcc_output_file(s, "out.bin") < 0) return 3;
    tcc_delete(s);
    if (nan16_vfs_get("out.bin", &data, &size) < 0) return 4;
    *(unsigned *)0x02FFFFF0 = size;
    memcpy((void *)0x03000000, data, size);
    return 0;
}