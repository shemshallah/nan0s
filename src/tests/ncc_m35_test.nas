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
.str "int main(void){\n char *s=\"abc\"; char *p=memchr(s,98,3);\n printf(\"%c %d\\n\",*p,(int)(p-s));\n printf(\"%d %d\\n\",strcoll(\"a\",\"b\"),strcoll(\"x\",\"x\"));\n char b[4]; int n=strxfrm(b,\"abcdef\",4);\n printf(\"%s|%d\\n\",b,n);\n printf(\"%s|%s|%s\\n\",strerror(0),strerror(2),strerror(99));\n perror(\"bad\");\n return 0;\n}\n"
