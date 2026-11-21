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
.str "#include <stdio.h>\n#include <string.h>\n#include <setjmp.h>\n#include <stdlib.h>\n#include <stdarg.h>\nstruct P { char c; int i; short s; };\nunion U { int i; char c[4]; };\nstatic int gi=3;\nint add(int a,int b){return a+b;}\nint fib(int n){return n<2?n:fib(n-1)+fib(n-2);}\nint apply(int(*f)(int,int),int a,int b){return f(a,b);}\nint vsum(int n,...){ va_list ap; int s=0; va_start(ap,n); while(n--){ s+=va_arg(ap,int); } va_end(ap); return s; }\nint main(void){\n  int a=-7,b=3; unsigned x=0xFFFFFFFFu;\n  printf(\"%d %d %d %u %u\\n\", a/b, a%b, (a>>1), x+1, (unsigned)a);\n  printf(\"%d %d %d\\n\", (int)(char)300, (int)(short)70000, (int)(unsigned char)-1);\n  long long l=1234567890123LL; printf(\"%lld %lld %lld\\n\", l/7, l%7, -l);\n  int arr[3][4]; int i,j; for(i=0;i<3;i++) for(j=0;j<4;j++) arr[i][j]=i*10+j;\n  int *p=&arr[0][0]; printf(\"%d %d %d\\n\", p[5], *(p+6), (int)(&arr[2][3]-&arr[0][0]));\n  struct P sp; sp.c='A'; sp.i=42; sp.s=7; printf(\"%d %d %d %d\\n\", sp.c, sp.i, sp.s, (int)sizeof(struct P));\n  union U un; un.i=0x41424344; printf(\"%c %c %d\\n\", un.c[0], un.c[3], (int)sizeof(union U));\n  int (*fp)(int,int)=add; printf(\"%d %d %d\\n\", fp(2,3), apply(add,4,5), fib(10));\n  printf(\"%d %d\\n\", vsum(4,1,2,3,4), gi);\n  int k=0; for(;;){ k++; if(k==5) break; } printf(\"%d\\n\",k);\n  switch(k){case 3: k=30; break; case 5: k=50; break; default: k=99;} printf(\"%d\\n\",k);\n  goto out; out: printf(\"goto\\n\");\n  jmp_buf jb; if(setjmp(jb)==0){ longjmp(jb,1); } printf(\"jmp\\n\");\n  char s[32]=\"hello\"; strcat(s,\" world\"); printf(\"%s %d\\n\",s,(int)strlen(s));\n  printf(\"%d %d\\n\", (int)sizeof(int), (int)sizeof(long long));\n  return 0;\n}\n"
