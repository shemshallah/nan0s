; ncc_include_test.nas - #include gate: quoted headers, nested relative
; includes, include guards, standard headers, and a nonstandard <...>
; header resolved from NPAF.  Files are installed into NPAF from this
; outer cart before ncc_compile runs.
.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r14,#NCC_PS
ADD r14,r14,r13
CALL @nfs_format
LA r1,@p_main
SHL r1,r1,2
LA r2,@s_main
MOVI r3,600
CALL @nfs_write
LA r1,@p_local
SHL r1,r1,2
LA r2,@s_local
MOVI r3,400
CALL @nfs_write
LA r1,@p_nested
SHL r1,r1,2
LA r2,@s_nested
MOVI r3,300
CALL @nfs_write
LA r1,@p_deep
SHL r1,r1,2
LA r2,@s_deep
MOVI r3,300
CALL @nfs_write
LA r1,@p_custom
SHL r1,r1,2
LA r2,@s_custom
MOVI r3,200
CALL @nfs_write
; compile /app/main.c so quoted includes resolve from /app/
LA r1,@p_main
ST r1,r0,@ncc_src_path
LA r1,@p_main
SHL r1,r1,2
CALL @nfs_data
CALL @ncc_compile
CALL @ncc_run
HALT

p_main:
.str "/app/main.c"
s_main:
.str "#include <stdio.h>\n#include <stdint.h>\n#include \"local.h\"\n#include \"sub/nested.h\"\n#include <custom.h>\n#include \"local.h\"\nint helper(int x){ return x + 1; }\nint main(void){\n  struct Pair p;\n  p.a = LOCAL_A;\n  p.b = NESTED_B;\n  printf(\"%d %d %d %d %d %d %d\\n\", p.a, p.b, LOCAL_MACRO, (int)sizeof(int32_t), helper(p.a), CUSTOM_VAL, DEEP_VAL);\n  return 0;\n}\n"

p_local:
.str "/app/local.h"
s_local:
.str "#ifndef LOCAL_H\n#define LOCAL_H\n#define LOCAL_A 11\n#define LOCAL_MACRO 77\nstruct Pair { int a; int b; };\nint helper(int x);\n#endif\n"

p_nested:
.str "/app/sub/nested.h"
s_nested:
.str "#ifndef NESTED_H\n#define NESTED_H\n#include \"deep.h\"\n#define NESTED_B 22\n#endif\n"

p_deep:
.str "/app/sub/deep.h"
s_deep:
.str "#ifndef DEEP_H\n#define DEEP_H\n#define DEEP_VAL 22\n#endif\n"

p_custom:
.str "/app/custom.h"
s_custom:
.str "#ifndef CUSTOM_H\n#define CUSTOM_H\n#define CUSTOM_VAL 3\n#endif\n"
