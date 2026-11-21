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
.str "int g(int a,int b){return a+b;}\nint (*f(void))(int,int);\nint g2(int,int);\nint main(void){\n int (*p)(int,int)=g;\n printf(\"%d \",p(2,3));\n printf(\"ok\");\n putchar(10);\n return 0;\n}\n"
