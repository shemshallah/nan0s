; ncc_include_recur.nas - a header that includes itself without a complete
; guard must hit the recursion guard (error 0092) instead of expanding forever.
.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r14,#NCC_PS
ADD r14,r14,r13
CALL @nfs_format
LA r1,@p_rec
SHL r1,r1,2
LA r2,@s_rec
MOVI r3,300
CALL @nfs_write
LA r1,@c_src
CALL @ncc_compile
HALT
c_src:
.str "#include \"rec.h\"\nint main(void){ return 0; }\n"
p_rec:
.str "/rec.h"
s_rec:
.str "#ifndef REC_H\n#define REC_H\n#include \"rec.h\"\n#endif\n"
