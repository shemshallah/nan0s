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
.str "int main(void){ char b[64]; int n=sprintf(b, \"%d %s %.2f\", 42, \"ok\", 3.14159); printf(\"%s|%d\\n\", b, n); char c[8]; int m=snprintf(c, 8, \"abcdef%d\", 123); printf(\"%s|%d\\n\", c, m); char d[4]; int k=snprintf(d, 0, \"xyz\"); printf(\"%d\\n\", k); return 0; }"
