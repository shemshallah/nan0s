; ncc_include_missing.nas - a missing quoted include must diagnose and halt,
; not hang or silently continue.  The error is on source line 3.
.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r14,#NCC_PS
ADD r14,r14,r13
CALL @nfs_format
LA r1,@c_src
CALL @ncc_compile
CALL @ncc_run
HALT
c_src:
.str "#include <stdio.h>\n\n#include \"missing_header.h\"\nint main(void){ return 0; }\n"
