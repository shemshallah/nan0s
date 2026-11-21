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
.str "int main(void){\n wchar_t a[]={97,98,99,0}; wchar_t b[]={97,98,100,0};\n printf(\"%d %d %d\\n\",wcscoll(a,b),wcscoll(a,a),wcscoll(b,a));\n wchar_t d[8]={0}; int n=wcsxfrm(d,a,8);\n printf(\"%d %d %d %d\\n\",n,d[0],d[1],d[2]);\n return 0;\n}\n"
