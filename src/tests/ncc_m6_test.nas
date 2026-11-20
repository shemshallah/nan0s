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
.str "int main(void){\n int i=0,s=0;\n do { i++; if(i==2) continue; if(i==4) break; s+=i; } while(i<10);\n printf(\"%d\\n\", s);\n for(i=0;i<3;i++){ s+=i; } printf(\"%d\\n\", s);\n printf(\"%d %d %d\\n\", 1&&0, 1||0, !0);\n printf(\"%d\\n\", (3>2)?7:9);\n int x=5; x+=3; x-=1; x*=2; x/=7; printf(\"%d\\n\",x);\n char *p=malloc(32); strcpy(p,\"abc\"); strcat(p,\"def\");\n printf(\"%s %d\\n\", p, strcmp(p,\"abcdef\"));\n char *q=calloc(8,1); q[0]='X'; q[1]=0;\n printf(\"%s %d %d\\n\", q, abs(-42), atoi(\"123\"));\n char *r=realloc(p,64); strcat(r,\"!\"); printf(\"%s\\n\", r);\n printf(\"%d %d\\n\", memcmp(\"abc\",\"abd\",3)<0, strlen(\"hello\"));\n memset(q,'y',3); q[3]=0; printf(\"%s\\n\", q);\n printf(\"%x %X %x\\n\", 0, 255, 0xDEADBEEF);\n free(r); free(q);\n return 0;\n}\n"
