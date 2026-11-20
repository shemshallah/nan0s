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
.str "int add(int a,int b){ return a+b; }\nint mul(int a,int b){ return a*b; }\nint (*g)(int,int);\nint main(void){\n int (*l)(int,int);\n g=add; l=g;\n print_int(l(20,22)); putchar(10);\n l=mul; print_int(g(6,7)); putchar(10);\n print_int(l==mul); print_int(l==add); putchar(10);\n return 0;\n}\n"
