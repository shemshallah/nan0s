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
.str "int main(void){\n printf(\"%d %d \",strspn(\"abc123\",\"abc\"),strcspn(\"abc123\",\"123\"));\n char *p=strpbrk(\"hello\",\"lo\");\n printf(\"%s \",p);\n char s[16]; strcpy(s,\"a,b;c\");\n char *t=strtok(s,\",;\");\n while(t){ printf(\"[%s]\",t); t=strtok(0,\",;\"); }\n printf(\" %d %d\",getenv(\"HOME\")==0,system(\"x\"));\n putchar(10);\n return 0;\n}\n"
