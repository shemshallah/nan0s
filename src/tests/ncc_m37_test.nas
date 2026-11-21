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
.str "int main(void){\n wchar_t f[]={37,100,32,37,115,32,37,108,115,10,0};\n char s[]=\"narrow\"; wchar_t w[]={87,105,100,101,0};\n int n=wprintf(f,42,s,w); printf(\"%d\\n\",n);\n wchar_t g[]={37,120,32,37,88,32,37,99,32,37,37,10,0};\n int m=wprintf(g,255,255,65); printf(\"%d\\n\",m);\n return 0;\n}\n"
