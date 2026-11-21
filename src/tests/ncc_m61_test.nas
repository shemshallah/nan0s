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
.str "int main(void){\n char *e;\n float f=strtof(\"3.5xyz\",&e); printf(\"%.2f %s\\n\",f,e);\n double d=strtold(\"-2.25rest\",&e); printf(\"%.2f %s\\n\",d,e);\n printf(\"%.2f %.2f %.2f %.2f\\n\",strtod(\"-2.25\",0),strtof(\"1e-2\",0),strtold(\"-2.5e2\",0),strtod(\"+3.75e1\",0));\n printf(\"%lld %lld %lld\\n\",llabs(-5LL),llabs(5LL),llabs(-9000000000LL));\n char b[16]=\"ab\"; strncat(b,\"cdef\",2); printf(\"%s\\n\",b);\n int q;\n double r=remquo(7.0,2.0,&q); printf(\"%.1f %d\\n\",r,q);\n r=remquo(-7.0,2.0,&q); printf(\"%.1f %d\\n\",r,q);\n r=remquo(5.0,2.0,&q); printf(\"%.1f %d\\n\",r,q);\n r=remquo(6.0,4.0,&q); printf(\"%.1f %d\\n\",r,q);\n printf(\"%.4f %.4f\\n\",remainder(5.0,2.0),remainder(7.0,2.0));\n printf(\"%.1f %.1f\\n\",rint(2.5),nearbyint(3.5));\n mbstate_t st; memset(&st,0,sizeof st);\n printf(\"%d\\n\",mbsinit(&st)!=0);\n printf(\"%u %u %u\\n\",mbrlen(\"a\",1,&st),mbrlen(\"\",1,&st),mbrlen(\"a\",0,&st));\n wchar_t wc=0; printf(\"%u %d\\n\",mbrtowc(&wc,\"A\",1,&st),(int)wc);\n wc=77; printf(\"%u %d\\n\",mbrtowc(&wc,\"\",1,&st),(int)wc);\n char mb[4]; printf(\"%u %d\\n\",wcrtomb(mb,90,&st),(int)(unsigned char)mb[0]);\n const char *s=\"abc\"; wchar_t wb[8]; size_t n=mbsrtowcs(wb,&s,4,&st);\n printf(\"%u %d%d%d %d\\n\",n,(int)wb[0],(int)wb[1],(int)wb[2],s==0);\n const char *s2=\"abc\"; n=mbsrtowcs(wb,&s2,2,&st); printf(\"%u %c %d\\n\",n,*s2,s2==0);\n const char *s3=\"abc\"; n=mbsrtowcs(0,&s3,0,&st); printf(\"%u %s %d\\n\",n,s3,s3==0);\n wchar_t wa[4]; wa[0]=97; wa[1]=98; wa[2]=99; wa[3]=0;\n const wchar_t *w=wa; char cb[8]; n=wcsrtombs(cb,&w,4,&st); printf(\"%u %s %d\\n\",n,cb,w==0);\n const wchar_t *w2=wa; n=wcsrtombs(cb,&w2,2,&st); printf(\"%u %d %d\\n\",n,(int)*w2,w2==0);\n const wchar_t *w3=wa; n=wcsrtombs(0,&w3,0,&st); printf(\"%u %d%d%d %d\\n\",n,(int)w3[0],(int)w3[1],(int)w3[2],w3==0);\n return 0;\n}\n"
