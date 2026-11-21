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
.str "int g(int a,int b){return a*b;} int (*f(int k))(int,int){ return g; } int main(void){ f(0); printf(\"ok\"); putchar(10); return 0; }"
