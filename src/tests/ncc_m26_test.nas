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
.str "#include <stdio.h>\nint icmp(const void*a,const void*b){ int x=*(int*)a,y=*(int*)b; return x-y; }\nint lcmp(const void*a,const void*b){ long long x=*(long long*)a,y=*(long long*)b; if(x<y) return -1; if(x>y) return 1; return 0; }\nint scmp(const void*a,const void*b){ return strcmp(*(char**)a,*(char**)b); }\njmp_buf env;\nvoid jump(jmp_buf e){ printf(\"deep \"); longjmp(e,5); printf(\"no\"); }\nint main(void){\n int a[6]; a[0]=5;a[1]=1;a[2]=4;a[3]=2;a[4]=3;a[5]=0;\n qsort(a,6,sizeof(int),icmp);\n int i; for(i=0;i<6;i++) printf(\"%d \",a[i]); putchar(10);\n int key=4; int*p=bsearch(&key,a,6,sizeof(int),icmp); printf(\"%d\\n\",*p);\n int nk=9; int*q=bsearch(&nk,a,6,sizeof(int),icmp); printf(\"%d\\n\",q==0);\n long long l[4]; l[0]=5000000000LL;l[1]=-3LL;l[2]=1LL<<40;l[3]=7LL;\n qsort(l,4,sizeof(long long),lcmp);\n for(i=0;i<4;i++){ printf(\"%lld \",l[i]); } putchar(10);\n long long lk=1099511627776LL;\n long long*lp=bsearch(&lk,l,4,sizeof(long long),lcmp); printf(\"%lld\\n\",*lp);\n char *s[4]; s[0]=\"pear\"; s[1]=\"apple\"; s[2]=\"fig\"; s[3]=\"banana\";\n qsort(s,4,sizeof(char*),scmp);\n for(i=0;i<4;i++) printf(\"%s \",s[i]); putchar(10);\n char *k=\"fig\"; char **r=bsearch(&k,s,4,sizeof(char*),scmp); printf(\"%s\\n\",*r);\n int j=setjmp(env); if(j==0){ jump(env); } else { printf(\"caught %d\",j); putchar(10); }\n return 0;\n}\n"
