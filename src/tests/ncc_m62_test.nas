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
.str "int main(void){\n printf(\"%lld %lld\\n\",(long long)imaxabs(-5LL),(long long)imaxabs(5LL));\n imaxdiv_t d=imaxdiv(7LL,2LL);\n printf(\"%lld %lld\\n\",d.quot,d.rem);\n printf(\"%lld %lld\\n\",(long long)strtoimax(\"-42\",0,10),(long long)strtoumax(\"42\",0,10));\n wchar_t ws[3]; ws[0]=52; ws[1]=51; ws[2]=0;\n printf(\"%lld %lld\\n\",(long long)wcstoimax(ws,0,10),(long long)wcstoumax(ws,0,10));\n printf(\"%d %d %d %d %d\\n\",iswalpha(65),iswdigit(53),iswspace(32),iswpunct(33),iswcntrl(10));\n printf(\"%d %d\\n\",towlower(65),towupper(97));\n wctype_t wd=wctype(\"digit\"); wctype_t wa=wctype(\"alpha\");\n printf(\"%lu %d %d %d\\n\",(unsigned long)wd,iswctype(55,wd),iswctype(120,wd),iswctype(120,wa));\n wctrans_t tr=wctrans(\"tolower\"); wctrans_t tu=wctrans(\"toupper\");\n printf(\"%d %d %d\\n\",tr,towctrans(65,tr),towctrans(97,tu));\n intmax_t im=5; uintmax_t um=6; printf(\"%lld %llu\\n\",(long long)im,(unsigned long long)um); errno=0; printf(\"%d\\n\",errno); errno=EILSEQ; printf(\"%d\\n\",errno);\n mbstate_t st; wchar_t wc; char bad[2]; bad[0]=200; bad[1]=0;\n printf(\"%d %d\\n\",(int)mbrtowc(&wc,bad,1,&st),errno);\n printf(\"%d %d\\n\",fwide(stdout,1),fwide(stdout,0));\n assert(1); printf(\"assert-ok\\n\");\n printf(\"before\\n\"); assert(0); printf(\"after\\n\");\n return 0;\n}\n"
