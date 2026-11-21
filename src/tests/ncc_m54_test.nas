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
.str "int main(void){\n int e=0; float m=frexp(8.0,&e); printf(\"%.3f %d\\n\",m,e);\n int f=0; float n=frexp(0.75,&f); printf(\"%.3f %d\\n\",n,f);\n int g=0; float q=frexp(-3.0,&g); printf(\"%.3f %d\\n\",q,g);\n float a=nextafter(1.0,2.0), b=nextafter(1.0,0.0);\n float c=nextafter(-1.0,0.0), d=nextafter(0.0,1.0);\n unsigned *p=(unsigned*)&a; printf(\"%x\\n\",*p);\n p=(unsigned*)&b; printf(\"%x\\n\",*p);\n p=(unsigned*)&c; printf(\"%x\\n\",*p);\n p=(unsigned*)&d; printf(\"%x\\n\",*p);\n return 0;\n}\n"
