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
.str "int main(void){\n wchar_t w[]={104,101,108,108,111,0};\n wchar_t *p=wcschr(w,108); wchar_t *q=wcsrchr(w,108); wchar_t *r=wcsstr(w,w+2);\n printf(\"%d %d %d %d\\n\",p-w,q-w,r-w,(int)wcscspn(w,w+2));\n wchar_t a[]={97,98,99,0}; wchar_t b[]={97,98,100,0}; wchar_t d[8]={0};\n wcsncpy(d,a,3); wcsncat(d,b,2);\n printf(\"%d %d %d %d\\n\",wcsncmp(a,b,2),wcsncmp(a,b,3),wcsspn(a,a),wcsspn(a,b));\n printf(\"%d %d %d %d\\n\",d[0],d[3],wcsncmp(d,a,4),(int)wcslen(d));\n wchar_t m[]={1,2,3,4,0}; wchar_t n[8]={0};\n wchar_t *z=wmemchr(m,3,4); wmemcpy(n,m,5);\n printf(\"%d %d %d\\n\",z-m,wmemcmp(m,n,5),n[3]);\n wmemmove(n+1,n,4); wmemset(n+4,9,2);\n printf(\"%d %d %d %d\\n\",n[1],n[2],n[4],n[5]);\n char mb[16]; wchar_t mw[16]; wchar_t src[]={65,66,67,0};\n int cn=wcstombs(mb,src,16); int wn=mbstowcs(mw,mb,16);\n printf(\"%d %d %s %d %d\\n\",cn,wn,mb,mw[0],wctob(66));\n printf(\"%d %d %d\\n\",btowc(65),mblen(mb,16),wctomb(mb,90));\n wchar_t tok[]={97,44,98,44,99,0}; wchar_t delim[]={44,0};\n wchar_t *t=wcstok(tok,delim); int k=0;\n while(t){ k++; t=wcstok(0,delim); }\n printf(\"%d\\n\",k);\n return 0;\n}\n"
