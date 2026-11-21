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
.str "int fired; void h(int s){ fired++; } int main(void){ signal(SIGALRM,h); int a=alarm(1); int b=alarm(2); printf(\"%d %d\",a,b); putchar(10); return 0; }"
