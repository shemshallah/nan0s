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
.str "int main(void){ bool a=true, b=false; _Bool c=7; print_int(a); putchar(32); print_int(b); putchar(32); print_int(c); putchar(32); print_int(sizeof(bool)); putchar(10); return 0; }\n"
