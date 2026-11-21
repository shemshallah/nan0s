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
.str "int g(int a,int b){return a*b;}\nint h(int a,int b){return a+b;}\nint (*f(void))(int,int){ return h; }\nint (*fp(int k,int z))(int,int){ printf(\"%d,%d \",k,z); return g; }\nint (*proto(int k))(int,int);\nint (*proto(int k))(int,int){ printf(\"[%d]\",k); return h; }\nint main(void){\n int (*p)(int,int)=fp(3,4);\n printf(\"%d \",p(5,6));\n printf(\"%d \",fp(2,5)(1,2));\n printf(\"%d \",proto(9)(10,4));\n printf(\"%d\",f()(7,8));\n putchar(10);\n return 0;\n}\n"
