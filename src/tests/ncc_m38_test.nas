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
.str "int main(void){\n char *e;\n int a=strtol(\"  -1234xyz\",&e,10);\n printf(\"%d|%s|\",a,e);\n printf(\"%d|\",(int)strtol(\"0x1f\",0,0));\n printf(\"%d|\",(int)strtol(\"077\",0,0));\n printf(\"%u|\",strtoul(\"4000000000\",0,10));\n long long b=strtoll(\"-1234567890123zz\",&e,10);\n printf(\"%lld|%s|\",b,e);\n printf(\"%llu\\n\",strtoull(\"18446744073709551615\",0,10));\n char *z; printf(\"%d %d\\n\",(int)strtol(\"zz\",&z,10),*z);\n return 0;\n}\n"
