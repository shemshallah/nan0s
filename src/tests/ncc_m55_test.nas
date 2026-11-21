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
.str "int main(void){\n wchar_t w[]={45,49,50,51,120,0}; wchar_t *e=0;\n long a=wcstol(w,&e,10); printf(\"%ld %d\\n\",a,(int)(e-w));\n wchar_t u[]={102,102,0};\n printf(\"%lu\\n\",wcstoul(u,0,16));\n wchar_t q[]={45,57,57,0};\n printf(\"%lld\\n\",wcstoll(q,0,10));\n wchar_t d[]={51,46,53,120,0}; wchar_t *f=0;\n double z=wcstod(d,&f); printf(\"%.2f %d\\n\",z,(int)(f-d));\n wchar_t m[]={49,56,52,52,54,55,52,52,48,55,51,55,48,57,53,53,49,54,49,53,0};\n printf(\"%llu\\n\",wcstoull(m,0,10));\n return 0;\n}\n"
