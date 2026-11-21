.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r1,@c_src
CALL @ncc_compile
CALL @ncc_run
HALT
c_src:
.str "#include <stdio.h>\nint main(void){ FILE *f=fopen(\"/persist\",\"r\"); char b[32]; if(!f){puts(\"missing\");return 0;} fgets(b,32,f); printf(\"[%s]\",b); putchar(10); return 0; }\n"
