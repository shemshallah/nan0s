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
.str "typedef unsigned int uint;\nstruct P { int x; char c; int y; };\nunion U { int i; char b[4]; };\nenum Color { RED=1, GREEN, BLUE=5 };\nint fib(int n){ if(n<2) return n; return fib(n-1)+fib(n-2); }\nint main(void){\n char c=-1; unsigned char uc=255; short s=-32768; unsigned short us=65535;\n printf(\"%d %d %d %d\\n\", c, uc, s, us);\n printf(\"%u %u\\n\", 4000000000, (uint)-1);\n struct P p; p.x=3; p.c='Z'; p.y=9;\n struct P *pp=&p;\n printf(\"%d %c %d %d\\n\", p.x, p.c, pp->y, sizeof(struct P));\n union U u; u.i=1094861636; printf(\"%c %c\\n\", u.b[0], u.b[3]);\n enum Color col=GREEN; switch(col){ case RED: printf(\"red\\n\"); break; case GREEN: printf(\"green\\n\"); break; default: printf(\"other\\n\"); }\n int i=0,sum=0; while(i<5){ sum+=i; i++; } printf(\"%d\\n\", sum);\n int j=0; for(j=0;j<3;j++){ if(j==1) continue; printf(\"%d\", j); } printf(\"\\n\");\n int k=0; goto mid; k=99; mid: printf(\"%d\\n\", k);\n int a[4]={1,2,3,4}; int *q=a; printf(\"%d %d\\n\", q[2], *(q+3));\n printf(\"%d\\n\", fib(10));\n char *h=malloc(16); strcpy(h,\"hello\"); strcat(h,\"!\"); printf(\"%s %d\\n\", h, strcmp(h,\"hello!\"));\n return 0;\n}\n"
