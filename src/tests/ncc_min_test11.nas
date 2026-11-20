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
.str "int g(int n){ int a; int b; int c; a=1;b=2;c=3; return n+a+b+c; }\nint main(void){ print_int(g(10)); putchar(10); return 0; }\n"
