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
.str "#include <stdio.h>\n#include <stdarg.h>\nlong long add(long long a,long long b){return a+b;}\nlong long sum(int n,...){ va_list ap; va_start(ap,n); long long s=0; int i; for(i=0;i<n;i++) s+=va_arg(ap,long long); va_end(ap); return s; }\nstruct P { long long x; int y; };\nstruct P mk(long long a,int b){ struct P p; p.x=a; p.y=b; return p; }\nint main(void){\n long long a=1234567890123LL; unsigned long long u=18446744073709551615ULL;\n printf(\"%lld %llu %llx\\n\",a,u,u);\n printf(\"%lld\\n\",(long long)4000000000U);\n printf(\"%lld\\n\",1LL<<40);\n long long b=(long long)1000000000*3; b+=7; b>>=2; printf(\"%lld\\n\",b);\n printf(\"%d %d %d %d %d %d\\n\",a<b,a==b,a>b,a<=b,a>=b,b-a>0);\n long long ar[3]; ar[0]=5; ar[1]=1LL<<40; ar[2]=ar[0]+ar[1]; printf(\"%lld\\n\",ar[2]);\n struct P p=mk(3000000000LL,7); printf(\"%lld %d\\n\",p.x,p.y);\n printf(\"%lld\\n\",add(4000000000LL,5000000000LL));\n printf(\"%lld\\n\",sum(3,1LL<<40,2LL<<40,3LL<<40));\n long long (*fp)(long long,long long)=add; printf(\"%lld\\n\",fp(9000000000LL,1));\n float f=(float)a; printf(\"%.0f\\n\",f);\n long long g=(long long)1234567890.0f; printf(\"%lld\\n\",g);\n long long d; int n=sscanf(\"-5000000000 1234567890123\",\"%lld %lld\",&d,&g); printf(\"%d %lld %lld\\n\",n,d,g);\n if(d<0) printf(\"neg\\n\"); else printf(\"pos\\n\");\n printf(\"%d\\n\",(int)(u>>63));\n printf(\"%lld %lld\\n\",(long long)-7/2,(long long)-7%2);\n printf(\"[%020lld] [%-20lld]\\n\",42LL,42LL);\n printf(\"%llo\\n\",64ULL);\n return 0;\n}\n"
