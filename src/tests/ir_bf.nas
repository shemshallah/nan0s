.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r1,@c_src
CALL @ncc_compile
HALT
c_src:
.str "struct F{unsigned a:3;unsigned b:5;signed d:4;}; int main(void){ struct F f={1,2,-3}; f.a+=2; f.b=7; struct F *p=&f; p->d=5; struct F a[2]={1,2,3,4}; return 0; }\n"
