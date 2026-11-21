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
.str "int main(void){\n int a=0,b=0; wchar_t w[8]={0};\n wchar_t f[]={37,100,32,37,100,32,37,108,115,0};\n int n=wscanf(f,&a,&b,w);\n wchar_t g[]={37,100,32,37,100,32,37,100,32,37,108,115,10,0};\n wprintf(g,n,a,b,w);\n return 0;\n}\n"
