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
.str "int main(void){ char s[16]; int n=sscanf(\"hello\", \"%s\", s); printf(\"%d %s\\n\", n, s); return 0; }"
