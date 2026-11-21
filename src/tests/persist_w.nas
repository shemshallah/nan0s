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
.str "#include <stdio.h>\nint main(void){ FILE *f=fopen(\"/persist\",\"w\"); if(!f){puts(\"openw\");return 0;} fputs(\"hello disk\",f); fclose(f); puts(\"wrote\"); return 0; }\n"
