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
.str "int main(void){\n printf(\"%s|%s|\",strchr(\"abc\",98),strrchr(\"abca\",97));\n char *p=strndup(\"abcdef\",3);\n printf(\"%s|%d|\",p,(int)strlen(p));\n char b[8]; char *q=stpcpy(b,\"hi\");\n printf(\"%s|%d|\",b,(int)(q-b));\n char c[8]; char *r=memccpy(c,\"abcdef\",99,6);\n printf(\"%s|%d|\",c,(int)(r-c));\n char d[8]; char *s=memccpy(d,\"abc\",122,3);\n printf(\"%d\",s==0);\n putchar(10);\n return 0;\n}\n"
