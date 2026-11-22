; ncc_include_lines.nas - a syntax error in an included file must report the
; included file's own line number (3), not the including file's line.
.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r14,#NCC_PS
ADD r14,r14,r13
CALL @nfs_format
LA r1,@p_hdr
SHL r1,r1,2
LA r2,@s_hdr
MOVI r3,300
CALL @nfs_write
LA r1,@c_src
CALL @ncc_compile
HALT
c_src:
.str "#include \"line.h\"\nint main(void){ return 0; }\n"
p_hdr:
.str "/line.h"
s_hdr:
.str "#ifndef LINE_H\n#define LINE_H\nint bad = ;\n#endif\n"
